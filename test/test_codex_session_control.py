import base64
import hashlib
import importlib.util
import json
import socket
import struct
import tempfile
import threading
import time
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('control', Path(__file__).resolve().parents[1] / 'scripts/codex-session-control.py')
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


class FakeRpc:
    def __init__(self, threads=None):
        self.calls = []
        self.threads = threads or {'a': {}, 'b': {}}

    def request(self, method, params):
        self.calls.append((method, params))
        if method == 'model/list':
            return {'data': [{'model': 'gpt-6.1-sol', 'displayName': 'Sol', 'supportedReasoningEfforts': [{'reasoningEffort': 'high'}], 'defaultReasoningEffort': 'high'}]}
        if method == 'thread/loaded/list':
            return {'data': list(self.threads)}
        if method == 'thread/read':
            return {'thread': self.threads[params['threadId']]}
        if method == 'thread/settings/update':
            if self.threads[params['threadId']].get('fail'):
                raise control.ControlError('unsupported')
            return {}
        if method == 'thread/turns/list':
            return {'data': [{'id': 'turn-1', 'status': self.threads[params['threadId']].get('turn_status', 'inProgress')}]}
        if method == 'turn/settings/update':
            thread = self.threads[params['threadId']]
            if thread.get('live_fail'):
                if thread.get('ends_on_update'):
                    thread['status'] = {'type': 'idle'}
                raise control.ControlError('turn ended or update rejected')
            return {}
        raise AssertionError(method)


class SettingsTests(unittest.TestCase):
    def test_all_live_tabs_including_vscode_origins_are_updated_once(self):
        rpc = FakeRpc({'a': {'source': 'cli'}, 'b': {'source': 'vscode'}, 'child': {'parentThreadId': 'a'}})
        result = control.apply(rpc, 'gpt-6.1-sol', 'high', [
            {'launch_session_id': value} for value in ['a', 'b', 'a', 'child', None, 'closed']
        ])
        self.assertEqual(result, {'updated': ['a', 'b'], 'skipped': ['child', 'unknown', 'closed'], 'failed': []})
        updates = [params for method, params in rpc.calls if method == 'thread/settings/update']
        self.assertEqual(updates, [
            {'threadId': value, 'model': 'gpt-6.1-sol', 'effort': 'high', 'serviceTier': None} for value in ['a', 'b']
        ])
        self.assertFalse(any(method in ['turn/start', 'thread/resume', 'turn/interrupt', 'config/batchWrite'] for method, _ in rpc.calls))

    def test_unsupported_model_and_effort_make_no_changes(self):
        for model, effort in [('invented', 'high'), ('gpt-6.1-sol', 'max')]:
            rpc = FakeRpc()
            with self.assertRaises(control.ControlError):
                control.apply(rpc, model, effort, [{'launch_session_id': 'a'}])
            self.assertEqual([method for method, _ in rpc.calls], ['model/list'])

    def test_failed_tab_does_not_prevent_other_tab(self):
        rpc = FakeRpc({'a': {'fail': True}, 'b': {}})
        self.assertEqual(control.apply(rpc, 'gpt-6.1-sol', 'high', [
            {'launch_session_id': 'a'}, {'launch_session_id': 'b'}
        ]), {'updated': ['b'], 'skipped': [], 'failed': ['a']})

    def test_other_codex_home_is_skipped(self):
        rpc = FakeRpc()
        result = control.apply(rpc, 'gpt-6.1-sol', 'high', [{'launch_session_id': 'a', 'unsupported_home': True}])
        self.assertEqual(result['skipped'], ['a'])
        self.assertFalse(any(method == 'thread/settings/update' for method, _ in rpc.calls))

    def test_busy_tabs_update_active_turn_as_well_as_future_settings(self):
        rpc = FakeRpc({'a': {'status': {'type': 'active'}}, 'b': {'status': {'type': 'idle'}}})
        result = control.apply(rpc, 'gpt-6.1-sol', 'high', [{'launch_session_id': 'a'}, {'launch_session_id': 'b'}])
        self.assertEqual(result['updated'], ['a', 'b'])
        self.assertEqual([params for method, params in rpc.calls if method == 'turn/settings/update'], [
            {'threadId': 'a', 'turnId': 'turn-1', 'model': 'gpt-6.1-sol', 'effort': 'high', 'serviceTier': None}
        ])
        turn_reads = [params for method, params in rpc.calls if method == 'thread/turns/list']
        self.assertEqual(turn_reads, [{'threadId': 'a', 'limit': 1, 'sortDirection': 'desc', 'itemsView': 'notLoaded'}])

    def test_completed_turn_race_is_not_a_failure(self):
        for details in [{'turn_status': 'completed'}, {'live_fail': True, 'ends_on_update': True}]:
            rpc = FakeRpc({'a': {'status': {'type': 'active'}, **details}})
            self.assertEqual(control.apply(rpc, 'gpt-6.1-sol', 'high', [{'launch_session_id': 'a'}])['updated'], ['a'])

    def test_active_turn_failure_is_reported_and_other_tabs_still_update(self):
        rpc = FakeRpc({'a': {'status': {'type': 'active'}, 'live_fail': True}, 'b': {}})
        result = control.apply(rpc, 'gpt-6.1-sol', 'high', [{'launch_session_id': 'a'}, {'launch_session_id': 'b'}])
        self.assertEqual(result, {'updated': ['a', 'b'], 'skipped': [], 'failed': [], 'live_updated': [], 'live_failed': ['a']})

    def test_slow_busy_lookup_cannot_starve_other_tabs_default_updates(self):
        rpc = FakeRpc({'a': {'status': {'type': 'active'}}, 'b': {}})
        def unavailable():
            raise TimeoutError('busy lookup deadline')
        result = control.apply(rpc, 'gpt-6.1-sol', 'high', [{'launch_session_id': 'a'}, {'launch_session_id': 'b'}], unavailable)
        self.assertEqual(result['updated'], ['a', 'b'])
        self.assertEqual(result['live_failed'], ['a'])
        self.assertEqual([params['threadId'] for method, params in rpc.calls if method == 'thread/settings/update'], ['a', 'b'])


class WebSocketTests(unittest.TestCase):
    def make_client(self):
        client, server = socket.socketpair()
        rpc = control.CodexRpc.__new__(control.CodexRpc)
        rpc.sock, rpc.buffer, rpc.traffic, rpc.serial = client, bytearray(), 0, 0
        rpc.deadline = time.monotonic() + 2
        self.addCleanup(client.close)
        self.addCleanup(server.close)
        return rpc, server

    def test_fragmented_json_and_ping(self):
        rpc, server = self.make_client()
        server.sendall(b'\x01\x06{"id":' + b'\x89\x01x' + b'\x80\x021}')
        self.assertEqual(rpc.message(), {'id': 1})
        self.assertEqual(server.recv(2), b'\x8a\x81')

    def test_client_masks_frames(self):
        rpc, server = self.make_client()
        rpc.send({'method': 'test'})
        data = server.recv(1024)
        self.assertEqual(data[0], 129)
        self.assertTrue(data[1] & 128)
        mask, payload = data[2:6], data[6:]
        self.assertEqual(json.loads(bytes(value ^ mask[i % 4] for i, value in enumerate(payload))), {'method': 'test'})

    def test_oversized_frame_is_rejected_before_body_read(self):
        rpc, server = self.make_client()
        server.sendall(b'\x81\x7f' + struct.pack('!Q', control.MAX_FRAME + 1))
        with self.assertRaises(control.ControlError):
            rpc.message()

    def test_binary_masked_and_invalid_continuation_frames_rejected(self):
        for frame in [b'\x82\x00', b'\x81\x80', b'\x80\x00', b'\x49\x00']:
            rpc, server = self.make_client()
            server.sendall(frame)
            with self.assertRaises(control.ControlError):
                rpc.message()

    def test_rpc_ignores_notifications_and_rejects_errors(self):
        rpc, server = self.make_client()
        frames = [{'method': 'usage'}, {'id': 1, 'result': {}}, {'id': 2, 'error': {'message': 'private detail'}}]
        for value in frames:
            data = json.dumps(value).encode()
            server.sendall(bytes([129, len(data)]) + data)
        self.assertEqual(rpc.request('model/list', {}), {})
        with self.assertRaisesRegex(control.ControlError, 'Codex rejected model/list'):
            rpc.request('model/list', {})

    def test_deadline_is_bounded(self):
        rpc, _ = self.make_client()
        rpc.deadline = time.monotonic() - 1
        with self.assertRaises(control.ControlError):
            rpc.request('model/list', {})

    def test_real_local_upgrade_and_initialization_against_fixture(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            (home / 'app-server-control').mkdir()
            server = socket.socket(socket.AF_UNIX)
            server.bind(str(home / 'app-server-control/app-server-control.sock'))
            server.listen(1)
            server.settimeout(3)
            errors = []
            def serve():
                try:
                    conn, _ = server.accept()
                    with conn:
                        conn.settimeout(3)
                        header = bytearray()
                        while b'\r\n\r\n' not in header:
                            header.extend(conn.recv(1024))
                        key = next(line.split(': ', 1)[1] for line in header.decode().split('\r\n') if line.startswith('Sec-WebSocket-Key:'))
                        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                        conn.sendall(f'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n'.encode())
                        conn.recv(4096)
                        payload = b'{"id":1,"result":{}}'
                        conn.sendall(bytes([129, len(payload)]) + payload)
                        conn.recv(4096)
                except Exception as error:
                    errors.append(error)
            thread = threading.Thread(target=serve)
            thread.start()
            try:
                rpc = control.CodexRpc(home)
                rpc.close()
            finally:
                thread.join(4)
                server.close()
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])


if __name__ == '__main__':
    unittest.main()
