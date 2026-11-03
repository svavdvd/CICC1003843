import configparser
import os
import threading
import time
from collections import OrderedDict
from queue import Queue

import serial
from Arm_Lib import Arm_Device
from flask import Flask, jsonify, request

from logger import setup_log


logger = setup_log('arm')
app = Flask(__name__)

CONFIG_PATH = os.environ.get(
    'C5MB_PI_CONFIG', os.path.join(os.path.dirname(__file__), 'config.ini'))
config = configparser.ConfigParser()
config.read(CONFIG_PATH, encoding='utf-8')


def _position(name, default):
    raw = config.get('arm_positions', name, fallback=default)
    values = [int(item.strip()) for item in raw.split(',')]
    if len(values) != 5:
        raise RuntimeError('arm position {} must have five angles'.format(name))
    return values


POSITIONS = {
    'initial': _position('initial', '90,90,90,0,90'),
    'pickup': _position('pickup', '90,38,26,22,90'),
    'lift': _position('lift', '90,90,0,90,90'),
    'right_pre': _position('right_pre', '90,90,90,0,90'),
    'right_approach': _position('right_approach', '-10,90,90,0,90'),
    'right_drop': _position('right_drop', '-10,65,0,30,90'),
    'left_pre': _position('left_pre', '90,90,90,0,90'),
    'left_drop': _position('left_drop', '196,55,11,24,90'),
}

PUMP_PORT = config.get('arm_hardware', 'pump_serial', fallback='/dev/XIPAN')
PUMP_BAUD = config.getint('arm_hardware', 'pump_baud', fallback=9600)
DRY_RUN = config.getboolean('arm_hardware', 'dry_run', fallback=False)
PUMP_ON = bytes.fromhex('A0 01 01 A2')
PUMP_OFF = bytes.fromhex('A0 01 00 A1')

_pump_serial = None
_pump_lock = threading.Lock()
_arm_device = None
_arm_lock = threading.Lock()
_motion_lock = threading.Lock()

_events_lock = threading.Lock()
_events = OrderedDict()
_queue = Queue(maxsize=32)


def _get_arm():
    global _arm_device
    with _arm_lock:
        if _arm_device is None:
            _arm_device = Arm_Device()
            time.sleep(0.1)
        return _arm_device


def _write_pump(command):
    global _pump_serial
    with _pump_lock:
        for attempt in range(2):
            try:
                if _pump_serial is None or not _pump_serial.is_open:
                    _pump_serial = serial.Serial(PUMP_PORT, PUMP_BAUD, timeout=1)
                _pump_serial.write(command)
                _pump_serial.flush()
                time.sleep(0.1)
                return
            except Exception:
                logger.exception('pump serial attempt %s failed', attempt + 1)
                if _pump_serial is not None:
                    try:
                        _pump_serial.close()
                    except Exception:
                        pass
                _pump_serial = None
        raise RuntimeError('cannot write pump serial {}'.format(PUMP_PORT))


def pump_on():
    _write_pump(PUMP_ON)


def pump_off():
    _write_pump(PUMP_OFF)


def arm_move(position, duration_ms=500):
    arm = _get_arm()
    for index, angle in enumerate(position):
        servo_id = index + 1
        move_time = int(duration_ms * 1.2) if servo_id == 5 else duration_ms
        arm.Arm_serial_servo_write(servo_id, angle, move_time)
        time.sleep(0.1 if servo_id == 5 else 0.01)
    time.sleep(duration_ms / 1000.0)


def _run_trajectory(action, speed, delay_seconds):
    if action not in ('left', 'right'):
        raise RuntimeError('unsupported arm action: {}'.format(action))
    if DRY_RUN:
        logger.warning('dry-run PL action=%s speed=%s delay=%s',
                       action, speed, delay_seconds)
        time.sleep(0.05)
        return
    time.sleep(max(0.0, delay_seconds))
    with _motion_lock:
        arm_move(POSITIONS['initial'], speed)
        arm_move(POSITIONS['pickup'], speed)
        pump_on()
        try:
            arm_move(POSITIONS['lift'], speed)
            if action == 'right':
                arm_move(POSITIONS['right_pre'], speed)
                arm_move(POSITIONS['right_approach'], speed)
                arm_move(POSITIONS['right_drop'], speed)
                release_pre = POSITIONS['right_pre']
            else:
                arm_move(POSITIONS['left_pre'], speed)
                arm_move(POSITIONS['left_drop'], speed)
                release_pre = POSITIONS['left_pre']
            pump_off()
            time.sleep(0.5)
            arm_move(release_pre, speed)
            arm_move(POSITIONS['initial'], 1000)
            time.sleep(0.5)
        except Exception:
            try:
                pump_off()
            except Exception:
                logger.exception('emergency pump release failed')
            raise


def _update_event(event_id, **updates):
    with _events_lock:
        record = _events[event_id]
        record.update(updates)


def _event_snapshot(event_id):
    with _events_lock:
        record = _events.get(event_id)
        return None if record is None else dict(record)


def _normalize_command(data):
    event_id = str(data.get('event_id', '')).strip()
    if not event_id:
        raise ValueError('event_id is required')
    action = data.get('action')
    if action is None:
        action = {'OK': 'right', 'NG': 'left'}.get(data.get('flags'))
    if action not in ('left', 'right'):
        raise ValueError('action must be left or right')
    speed = int(data.get(
        'speed', config.getint('Configuration', 'speed', fallback=1300)))
    delay_seconds = float(data.get(
        'delay_seconds', data.get(
            'time', config.getfloat('Configuration', 'time', fallback=4.0))))
    if speed < 100 or speed > 10000:
        raise ValueError('speed is outside safe configured range')
    if delay_seconds < 0 or delay_seconds > 30:
        raise ValueError('delay_seconds is outside safe configured range')
    return {
        'event_id': event_id,
        'action': action,
        'speed': speed,
        'delay_seconds': delay_seconds,
    }


@app.after_request
def after_request(response):
    response.headers.add('Access-Control-Allow-Origin', '*')
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type,Authorization')
    response.headers.add('Access-Control-Allow-Methods', 'GET,POST')
    return response


@app.route('/grab', methods=['POST'])
def grab():
    try:
        command = _normalize_command(request.get_json(force=True))
    except Exception as error:
        return jsonify({'error': str(error)}), 400
    event_id = command['event_id']
    with _events_lock:
        existing = _events.get(event_id)
        if existing is not None:
            if existing['action'] != command['action']:
                return jsonify({'error': 'event_id already has another action'}), 409
            return jsonify(dict(existing)), 200
        if _queue.full():
            return jsonify({'error': 'arm queue is full'}), 503
        _events[event_id] = {
            'event_id': event_id,
            'action': command['action'],
            'state': 'queued',
            'error': '',
            'created_at': time.time(),
            'started_at': None,
            'finished_at': None,
        }
        while len(_events) > 100:
            oldest_id, oldest = next(iter(_events.items()))
            if oldest['state'] in ('queued', 'running'):
                break
            del _events[oldest_id]
    _queue.put_nowait(command)
    return jsonify(_event_snapshot(event_id)), 202


@app.route('/events/<event_id>', methods=['GET'])
def event_status(event_id):
    record = _event_snapshot(event_id)
    if record is None:
        return jsonify({'error': 'event not found'}), 404
    return jsonify(record), 200


@app.route('/health', methods=['GET'])
def health():
    with _events_lock:
        running = [item['event_id'] for item in _events.values()
                   if item['state'] == 'running']
    return jsonify({
        'status': 'ok',
        'queue_depth': _queue.qsize(),
        'running_events': running,
        'pump_serial': PUMP_PORT,
        'dry_run': DRY_RUN,
    })


@app.route('/use_arm', methods=['POST'])
def use_arm():
    data = request.get_json(force=True)
    with _motion_lock:
        servo_id = data.get('id')
        angle = data.get('angle')
        if servo_id not in (None, '') and angle not in (None, ''):
            _get_arm().Arm_serial_servo_write(int(servo_id), int(angle), 1000)
        switch = data.get('switch')
        if switch not in (None, ''):
            pump_on() if str(switch).lower() == 'true' else pump_off()
    return jsonify(data)


@app.route('/get_arm', methods=['GET'])
def get_arm_position():
    servo_id = int(request.args.get('id'))
    return str(_get_arm().Arm_serial_servo_read(servo_id))


class Consumer(threading.Thread):
    def run(self):
        while True:
            command = _queue.get()
            event_id = command['event_id']
            try:
                _update_event(event_id, state='running', started_at=time.time())
                logger.info('executing PL event %s action=%s',
                            event_id, command['action'])
                _run_trajectory(command['action'], command['speed'],
                                command['delay_seconds'])
                _update_event(event_id, state='succeeded',
                              finished_at=time.time())
            except Exception as error:
                logger.exception('PL event %s failed', event_id)
                _update_event(event_id, state='failed', error=str(error),
                              finished_at=time.time())
            finally:
                _queue.task_done()


consumer = Consumer(name='arm-consumer')
consumer.daemon = True
consumer.start()


if __name__ == '__main__':
    app.run(debug=False, host='0.0.0.0', port=8899, threaded=True)
