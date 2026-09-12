"""Directory integration tests using real TCP and a local SSH stand-in."""
import os
import io
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'nc_wire.sh'


class DirectoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.dest = self.root / 'destination'
        self.source.mkdir()
        self.dest.mkdir()
        binaries = self.root / 'bin'
        binaries.mkdir()
        ssh = binaries / 'ssh'
        ssh.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
with open(os.environ['SSH_LOG'], 'a') as log:
    log.write('ssh\\n')
command = sys.argv[-1]
if os.environ.get('SLOW_RECEIVER'):
    command = command.replace('target.write(data)', 'time.sleep(0.02); target.write(data)')
if os.environ.get('NO_HASH'):
    command = command.replace('h = hashlib.sha256()', 'raise RuntimeError("Unexpected hashing")')
if os.environ.get('CORRUPT_RECEIVER'):
    command = command.replace('h.update(data)', 'h.update(b"corrupt")')
os.execl('/bin/sh', 'sh', '-c', 'exec ' + command)
''')
        ssh.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binaries) + ':' + os.environ['PATH'],
                        SSH_LOG=str(self.root / 'ssh.log'))

    def command(self, *extra):
        return ['bash', str(SCRIPT), '-r', '-i', '127.0.0.1', '-s', 'mock',
                '-d', str(self.dest), *extra, str(self.source)]

    def run_copy(self, *extra, success=True):
        result = subprocess.run(self.command(*extra), env=self.env,
                                capture_output=True, text=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_tree_batches_and_verified_retry(self):
        (self.source / 'empty').mkdir()
        nested = self.source / "sub ' $\n folder"
        nested.mkdir()
        for i in range(270):
            (nested / str(i)).write_bytes(bytes([i % 256]) * i)
        (self.dest / 'extra').write_text('keep')
        first = self.run_copy()
        self.assertIn('270 copied', first.stdout)
        self.assertIn('2 folders ready', first.stdout)
        self.assertTrue((self.dest / 'empty').is_dir())
        for file in nested.iterdir():
            self.assertEqual(file.read_bytes(), (self.dest / nested.name / file.name).read_bytes())
        result = self.run_copy()
        self.assertIn('0 copied, 270 verified/skipped', result.stdout)
        self.assertEqual((self.dest / 'extra').read_text(), 'keep')
        self.assertEqual((self.root / 'ssh.log').read_text().splitlines(), ['ssh', 'ssh'])

    def test_corrupt_completed_file_is_detected_and_force_repairs(self):
        (self.source / 'file').write_bytes(b'correct')
        self.run_copy()
        (self.dest / 'file').write_bytes(b'incorrc')
        result = self.run_copy(success=False)
        self.assertIn('1 refused', result.stdout)
        self.assertEqual((self.dest / 'file').read_bytes(), b'incorrc')
        self.run_copy('-f')
        self.assertEqual((self.dest / 'file').read_bytes(), b'correct')

    def test_skip_verify_uses_size_and_reports_unverified_skips(self):
        (self.source / 'file').write_bytes(b'correct')
        (self.dest / 'file').write_bytes(b'changed')
        self.env['NO_HASH'] = '1'
        result = self.run_copy('--skip-verify')
        self.assertIn('1 size-matched/skipped', result.stdout)
        self.assertEqual((self.dest / 'file').read_bytes(), b'changed')

    def test_skip_verify_copies_missing_and_force_repairs_size_mismatch(self):
        (self.source / 'different').write_bytes(b'longer content')
        (self.source / 'missing').write_bytes(b'new')
        (self.dest / 'different').write_bytes(b'old')
        result = self.run_copy('--skip-verify', success=False)
        self.assertIn('1 refused', result.stdout)
        self.assertEqual((self.dest / 'missing').read_bytes(), b'new')
        self.assertEqual((self.dest / 'different').read_bytes(), b'old')
        self.run_copy('--skip-verify', '-f')
        self.assertEqual((self.dest / 'different').read_bytes(), b'longer content')

    def test_skip_verify_still_checks_transferred_bytes(self):
        (self.source / 'file').write_bytes(b'correct')
        self.env['CORRUPT_RECEIVER'] = '1'
        self.run_copy('--skip-verify', success=False)
        self.assertFalse((self.dest / 'file').exists())

    def test_skip_verify_requires_directory_mode(self):
        result = subprocess.run(['bash', str(SCRIPT), '--skip-verify', '-i', 'localhost',
                                 '-s', 'mock', '-d', str(self.dest), str(self.source)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires directory mode', result.stdout)

    def test_cancel_then_retry(self):
        (self.source / 'a-small').write_bytes(b'complete')
        (self.source / 'later' / 'empty-child').mkdir(parents=True)
        with (self.source / 'b-large').open('wb') as stream:
            for _ in range(64):
                stream.write(b'x' * 1024 * 1024)
        env = dict(self.env, SLOW_RECEIVER='1')
        process = subprocess.Popen(self.command(), env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            deadline = time.monotonic() + 15
            incoming = self.dest / '.nc-wire-state' / 'incoming'
            while time.monotonic() < deadline:
                if incoming.exists() and incoming.stat().st_size > 1024 * 1024:
                    break
                if process.poll() is not None:
                    self.fail(str(process.communicate()))
                time.sleep(0.01)
            else:
                self.fail('Transfer did not start')
            self.assertFalse((self.dest / 'later').exists(), 'Future folders must not be created during manifest inspection')
            os.killpg(process.pid, signal.SIGINT)
            output, errors = process.communicate(timeout=10)
            self.assertIn('copied,', output)
            self.assertIn('folders ready;', output)
            self.assertIn('sent in', output)
            self.assertIn('awaiting confirmation', output)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual((self.dest / 'a-small').read_bytes(), b'complete')
            self.assertFalse((self.dest / 'b-large').exists())
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
        result = self.run_copy()
        self.assertIn('1 copied, 1 verified/skipped', result.stdout)
        self.assertTrue((self.dest / 'later' / 'empty-child').is_dir())
        self.assertEqual((self.source / 'b-large').read_bytes(), (self.dest / 'b-large').read_bytes())

    def test_checksum_failure_does_not_publish(self):
        (self.source / 'file').write_bytes(b'correct')
        self.env['CORRUPT_RECEIVER'] = '1'
        self.run_copy(success=False)
        self.assertFalse((self.dest / 'file').exists())
        del self.env['CORRUPT_RECEIVER']
        self.run_copy()

    def test_source_symlink_rejected(self):
        (self.source / 'link').symlink_to('/etc/passwd')
        self.run_copy(success=False)
        self.assertFalse((self.dest / 'link').exists())

    def test_destination_symlink_rejected(self):
        (self.source / 'sub').mkdir()
        (self.source / 'sub' / 'file').write_text('data')
        outside = self.root / 'outside'
        outside.mkdir()
        (self.dest / 'sub').symlink_to(outside, target_is_directory=True)
        self.run_copy(success=False)
        self.assertFalse((outside / 'file').exists())

    def test_missing_destination(self):
        self.dest.rmdir()
        self.run_copy(success=False)
        self.assertFalse(self.dest.exists())

    def test_empty_source_and_occupied_port(self):
        output = self.run_copy('--color', '-v')
        self.assertNotIn('\033[', output.stdout + output.stderr)
        with socket.socket() as listener:
            listener.bind(('', 0))
            listener.listen()
            self.run_copy('-p', str(listener.getsockname()[1]), success=False)

    def test_reserved_state_name_rejected(self):
        (self.source / '.nc-wire-state').mkdir()
        self.run_copy(success=False)


class ProgressTests(unittest.TestCase):
    def test_live_file_progress_and_safe_names(self):
        source = SCRIPT.read_text().split("DIRECTORY_HELPER=$(cat <<'DIRECTORY_PY'\n", 1)[1].split('\nDIRECTORY_PY', 1)[0]
        namespace = {'__name__': 'progress_test'}
        exec(compile(source, str(SCRIPT), 'exec'), namespace)
        progress = namespace['Progress']()
        progress.copied = 20
        progress.folders = 10
        progress.current = ('Copying', 'Photos & Videos/file\n\x1b.jpg', 30, 100)
        line = progress.line()
        self.assertIn('20 files / 10 folders ready', line)
        self.assertIn('30 B / 100 B (30.0%)', line)
        self.assertIn('Photos & Videos', line)
        self.assertNotIn('\n', line)
        self.assertNotIn('\x1b', line)
        progress.current = ('Copying', 'empty', 0, 0)
        self.assertIn('(100.0%)', progress.line())

    def test_overall_and_file_speeds_use_separate_clocks(self):
        from unittest.mock import patch
        source = SCRIPT.read_text().split("DIRECTORY_HELPER=$(cat <<'DIRECTORY_PY'\n", 1)[1].split('\nDIRECTORY_PY', 1)[0]
        namespace = {'__name__': 'speed_test'}
        exec(compile(source, str(SCRIPT), 'exec'), namespace)
        progress = namespace['Progress']()
        progress.started = 10
        progress.file_started = 18
        progress.sent = 100 * 1024 * 1024
        progress.current = ('Copying', 'first', 40 * 1024 * 1024, 80 * 1024 * 1024)
        with patch('time.monotonic', return_value=20):
            self.assertIn('avg: 10.0 MiB/s', progress.line())
            self.assertIn('file: 20.0 MiB/s', progress.line())
            progress.file_started = 20
            progress.current = ('Copying', 'next', 0, 100)
            self.assertIn('file: 0 B/s', progress.line())
            progress.current = ('Verifying', 'next', 0, 100)
            self.assertNotIn(' | file:', progress.line())

    def test_color_is_opt_in_and_respects_terminal_and_no_color(self):
        from unittest.mock import patch
        source = SCRIPT.read_text().split("DIRECTORY_HELPER=$(cat <<'DIRECTORY_PY'\n", 1)[1].split('\nDIRECTORY_PY', 1)[0]
        namespace = {'__name__': 'color_test'}
        exec(compile(source, str(SCRIPT), 'exec'), namespace)
        class Terminal(io.StringIO):
            def isatty(self):
                return True
        terminal = Terminal()
        with patch.dict(os.environ, {'TERM': 'xterm'}, clear=True):
            self.assertEqual(namespace['Progress']().paint('test', '36', terminal), 'test')
            progress = namespace['Progress'](True)
            self.assertEqual(progress.paint('test', '36', terminal), '\033[36mtest\033[0m')
            self.assertEqual(progress.paint('test', '36', io.StringIO()), 'test')
            with patch.dict(os.environ, {'NO_COLOR': ''}):
                self.assertEqual(progress.paint('test', '36', terminal), 'test')
            with patch.dict(os.environ, {'TERM': 'dumb'}):
                self.assertEqual(progress.paint('test', '36', terminal), 'test')

    def test_timer_updates_while_transfer_is_blocked(self):
        from unittest.mock import patch
        source = SCRIPT.read_text().split("DIRECTORY_HELPER=$(cat <<'DIRECTORY_PY'\n", 1)[1].split('\nDIRECTORY_PY', 1)[0]
        namespace = {'__name__': 'progress_test'}
        exec(compile(source, str(SCRIPT), 'exec'), namespace)
        progress = namespace['Progress']()
        progress.tty = True
        progress.current = ('Copying', 'large.bin', 1024, 4096)
        with patch('sys.stderr', new_callable=io.StringIO) as output, patch('shutil.get_terminal_size', return_value=os.terminal_size((240, 24))):
            progress.worker.start()
            try:
                time.sleep(0.5)
            finally:
                progress.stop.set()
                progress.worker.join()
            self.assertGreaterEqual(output.getvalue().count('large.bin'), 2)
            self.assertIn('(25.0%)', output.getvalue())


class FrameTests(unittest.TestCase):
    def setUp(self):
        source = SCRIPT.read_text().split("DIRECTORY_HELPER=$(cat <<'DIRECTORY_PY'\n", 1)[1].split('\nDIRECTORY_PY', 1)[0]
        self.engine = {'__name__': 'frame_test'}
        exec(compile(source, str(SCRIPT), 'exec'), self.engine)

    def test_binary_and_json_remain_separate_with_fragmented_reads(self):
        class Connection:
            def __init__(self):
                self.buffer = bytearray()
                self.offset = 0
            def sendall(self, data):
                self.buffer.extend(data)
            def recv(self, length):
                count = min(length, 1 + self.offset % 8192)
                data = self.buffer[self.offset:self.offset + count]
                self.offset += len(data)
                return data
        connection = Connection()
        wire = self.engine['Wire'](connection)
        payloads = [b'', b'\xbf\xff\n{"action":"write"}\n',
                    bytes(range(256)) * 4096, b'last']
        for index, payload in enumerate(payloads):
            self.engine['send'](wire, {'file': index}, flush=False)
            wire.write_frame(b'D', payload)
            self.engine['send'](wire, {'end': index}, flush=False)
        wire.flush()
        for index, payload in enumerate(payloads):
            self.assertEqual(self.engine['receive'](wire), {'file': index})
            self.assertEqual(wire.read_frame(b'D'), payload)
            self.assertEqual(self.engine['receive'](wire), {'end': index})

    def test_wrong_type_and_truncated_frames_are_reported(self):
        class Connection:
            def __init__(self, data):
                self.data = data
            def recv(self, length):
                result, self.data = self.data[:length], self.data[length:]
                return result
        Wire = self.engine['Wire']
        for data, message in [
            (Wire.HEADER.pack(b'D', 1) + b'\xbf', 'Invalid protocol frame'),
            (Wire.HEADER.pack(b'J', 0xffffffff), 'Invalid protocol frame'),
            (Wire.HEADER.pack(b'J', 10) + b'{}', 'Connection ended mid-frame')]:
            with self.subTest(message=message):
                with self.assertRaisesRegex(RuntimeError, message):
                    self.engine['receive'](Wire(Connection(data)))

    def test_exception_cleanup_does_not_flush(self):
        class Connection:
            def sendall(self, data):
                raise AssertionError('Unexpected flush during cleanup')
        with self.assertRaisesRegex(RuntimeError, 'Original error'):
            with self.engine['Wire'](Connection()) as wire:
                self.engine['send'](wire, {'queued': True}, flush=False)
                raise RuntimeError('Original error')


if __name__ == '__main__':
    unittest.main()
