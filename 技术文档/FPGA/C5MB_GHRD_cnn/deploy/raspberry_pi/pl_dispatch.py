import threading
import time

import requests


class PlDispatchError(RuntimeError):
    pass


class PlCommandDispatcher(object):
    """Executes PL decisions on Raspberry Pi hardware and ACKs the PL event."""

    def __init__(self, config, logger, alarm_callback, request_session=None):
        section = 'pl_integration'
        self._hps_base_url = config.get(
            section, 'hps_base_url', fallback='http://172.16.68.110:8082').rstrip('/')
        self._arm_base_url = config.get(
            section, 'arm_base_url', fallback='http://127.0.0.1:8899').rstrip('/')
        self._predict_timeout = config.getfloat(
            section, 'predict_timeout_seconds', fallback=35.0)
        self._request_timeout = config.getfloat(
            section, 'request_timeout_seconds', fallback=5.0)
        self._action_timeout = config.getfloat(
            section, 'action_timeout_seconds', fallback=60.0)
        self._poll_interval = config.getfloat(
            section, 'poll_interval_seconds', fallback=0.25)
        self._ack_retries = config.getint(section, 'ack_retries', fallback=3)
        self._logger = logger
        self._alarm_callback = alarm_callback
        self._requests = request_session or requests
        self._lock = threading.Lock()
        self._inflight = None
        self._last_result = None

    def busy(self):
        with self._lock:
            return self._inflight is not None

    def status(self):
        with self._lock:
            return {
                'busy': self._inflight is not None,
                'event_id': self._inflight,
                'last_result': self._last_result,
            }

    def predict(self, image_bytes):
        if self.busy():
            raise PlDispatchError('actuator is still processing the previous PL event')
        files = {
            'image_file': ('capture.jpg', image_bytes, 'image/jpeg'),
        }
        response = self._requests.post(
            self._hps_base_url + '/predict',
            files=files,
            timeout=(3.0, self._predict_timeout),
        )
        response.raise_for_status()
        output = response.json()
        if not isinstance(output, dict):
            raise PlDispatchError('HPS /predict response is not a JSON object')
        return output

    def submit(self, output, speed, delay_seconds):
        event_id = self._read_event_id(output)
        try:
            action = output['action']
            if action not in ('left', 'right', 'hold'):
                raise PlDispatchError('invalid PL action: {}'.format(action))
            alarm = output['alarm']
            if not isinstance(alarm, bool):
                raise PlDispatchError('PL alarm field must be boolean')
            if int(output.get('pl_fault', 0)) != 0:
                raise PlDispatchError('PL reported fault {}'.format(output['pl_fault']))
        except Exception as error:
            self._send_ack(event_id, False, str(error))
            raise

        with self._lock:
            if self._inflight is not None:
                raise PlDispatchError('another PL event is already in flight')
            self._inflight = event_id

        worker = threading.Thread(
            target=self._execute,
            args=(event_id, action, alarm, int(speed), float(delay_seconds)),
            name='pl-event-{}'.format(event_id),
        )
        worker.daemon = True
        worker.start()
        return event_id

    def wait_idle(self, timeout_seconds):
        deadline = time.monotonic() + timeout_seconds
        while self.busy() and time.monotonic() < deadline:
            time.sleep(0.01)
        return not self.busy()

    @staticmethod
    def _read_event_id(output):
        if 'event_id' not in output:
            raise PlDispatchError('HPS response has no event_id')
        event_id = int(output['event_id'])
        if event_id <= 0:
            raise PlDispatchError('event_id must be positive')
        return event_id

    def _execute(self, event_id, action, alarm, speed, delay_seconds):
        success = False
        detail = ''
        try:
            if action == 'hold':
                raise PlDispatchError('PL requested HOLD; no workpiece movement was made')
            if alarm:
                self._alarm_callback()

            command = {
                'event_id': event_id,
                'action': action,
                'speed': speed,
                'delay_seconds': delay_seconds,
            }
            response = self._requests.post(
                self._arm_base_url + '/grab',
                json=command,
                timeout=self._request_timeout,
            )
            response.raise_for_status()
            success, detail = self._wait_for_arm(event_id)
            if not success:
                raise PlDispatchError(detail)
        except Exception as error:
            detail = str(error)
            self._logger.error(
                'PL event %s actuator execution failed: %s', event_id, detail,
                exc_info=True,
            )
        finally:
            ack_ok = self._send_ack(event_id, success, detail)
            with self._lock:
                self._last_result = {
                    'event_id': event_id,
                    'success': success,
                    'ack_sent': ack_ok,
                    'detail': detail,
                }
                self._inflight = None

    def _wait_for_arm(self, event_id):
        deadline = time.monotonic() + self._action_timeout
        url = self._arm_base_url + '/events/{}'.format(event_id)
        while time.monotonic() < deadline:
            response = self._requests.get(url, timeout=self._request_timeout)
            response.raise_for_status()
            state = response.json()
            name = state.get('state')
            if name == 'succeeded':
                return True, ''
            if name == 'failed':
                return False, state.get('error', 'arm action failed')
            if name not in ('queued', 'running'):
                return False, 'invalid arm event state: {}'.format(name)
            time.sleep(self._poll_interval)
        return False, 'arm action timed out after {:.1f}s'.format(self._action_timeout)

    def _send_ack(self, event_id, success, detail):
        payload = {
            'event_id': int(event_id),
            'success': bool(success),
            'detail': detail,
        }
        for attempt in range(1, self._ack_retries + 1):
            try:
                response = self._requests.post(
                    self._hps_base_url + '/ack',
                    json=payload,
                    timeout=self._request_timeout,
                )
                response.raise_for_status()
                self._logger.info(
                    'PL event %s ACK success=%s', event_id, success)
                return True
            except Exception as error:
                self._logger.error(
                    'PL event %s ACK attempt %s/%s failed: %s',
                    event_id, attempt, self._ack_retries, error,
                )
                if attempt < self._ack_retries:
                    time.sleep(0.25 * attempt)
        return False
