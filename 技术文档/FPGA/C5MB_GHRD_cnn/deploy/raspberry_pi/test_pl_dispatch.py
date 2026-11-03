import configparser
import logging
import unittest

from pl_dispatch import PlCommandDispatcher


class FakeResponse(object):
    def __init__(self, body, status_code=200):
        self._body = body
        self.status_code = status_code

    def json(self):
        return self._body

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError('HTTP {}'.format(self.status_code))


class FakeRequests(object):
    def __init__(self):
        self.acks = []
        self.arm_commands = []

    def post(self, url, **kwargs):
        if url.endswith('/grab'):
            self.arm_commands.append(kwargs['json'])
            return FakeResponse({'state': 'queued'}, 202)
        if url.endswith('/ack'):
            self.acks.append(kwargs['json'])
            return FakeResponse({'acknowledged': True})
        if url.endswith('/predict'):
            return FakeResponse({
                'event_id': 99,
                'action': 'right',
                'alarm': False,
                'pl_fault': 0,
            })
        raise AssertionError(url)

    def get(self, url, **kwargs):
        return FakeResponse({'state': 'succeeded'})


def make_config():
    config = configparser.ConfigParser()
    config.add_section('pl_integration')
    config.set('pl_integration', 'poll_interval_seconds', '0.001')
    config.set('pl_integration', 'action_timeout_seconds', '1')
    return config


class DispatcherTests(unittest.TestCase):
    def test_right_action_acknowledges_success(self):
        transport = FakeRequests()
        dispatcher = PlCommandDispatcher(
            make_config(), logging.getLogger('test'), lambda: None, transport)
        event_id = dispatcher.submit({
            'event_id': 7,
            'action': 'right',
            'alarm': False,
            'pl_fault': 0,
        }, speed=1300, delay_seconds=0)
        self.assertEqual(event_id, 7)
        self.assertTrue(dispatcher.wait_idle(1))
        self.assertEqual(transport.arm_commands[0]['action'], 'right')
        self.assertTrue(transport.acks[0]['success'])

    def test_defect_action_triggers_alarm(self):
        transport = FakeRequests()
        alarm_calls = []
        dispatcher = PlCommandDispatcher(
            make_config(), logging.getLogger('test'),
            lambda: alarm_calls.append(True), transport)
        dispatcher.submit({
            'event_id': 8,
            'action': 'left',
            'alarm': True,
            'pl_fault': 0,
        }, speed=1300, delay_seconds=0)
        self.assertTrue(dispatcher.wait_idle(1))
        self.assertEqual(alarm_calls, [True])
        self.assertEqual(transport.arm_commands[0]['action'], 'left')
        self.assertTrue(transport.acks[0]['success'])

    def test_hold_is_fail_safe_and_does_not_move_arm(self):
        transport = FakeRequests()
        dispatcher = PlCommandDispatcher(
            make_config(), logging.getLogger('test'), lambda: None, transport)
        dispatcher.submit({
            'event_id': 9,
            'action': 'hold',
            'alarm': False,
            'pl_fault': 0,
        }, speed=1300, delay_seconds=0)
        self.assertTrue(dispatcher.wait_idle(1))
        self.assertEqual(transport.arm_commands, [])
        self.assertFalse(transport.acks[0]['success'])


if __name__ == '__main__':
    unittest.main()
