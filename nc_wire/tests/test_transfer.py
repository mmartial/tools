"""Test multi-file transfers over real loopback sockets."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'nc_wire.sh'


class TransferTests(unittest.TestCase):
    def run_transfer(self, failure='', count=1, port=None, existing=None, force=False, verify=True, partial=None, empty=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = [root / ("source ' $special " + str(i)) for i in range(count)]
            for i, source in enumerate(sources):
                source.write_bytes(bytes(range(256)) * ((524288 + i) if partial else (4096 + i)))
            if empty:
                sources[0].write_bytes(b'')
            destination = root / "destination ' with spaces"
            destination.mkdir()
            if existing:
                for source in sources:
                    (destination / source.name).write_bytes(source.read_bytes() if existing == 'same' else b'old content')
            if partial:
                data = sources[0].read_bytes()
                chunk = 64 * 1024 * 1024
                part_data = {
                    'tail': data[:chunk + 123],
                    'bad_first': b'X' + data[1:chunk + 123],
                    'complete': data,
                    'oversized': data + b'extra',
                }[partial]
                (destination / (sources[0].name + '.part')).write_bytes(part_data)
            binaries = root / 'bin'
            binaries.mkdir()
            mocks = {
                'pv': 'python3 -c \'import sys,os; d=sys.stdin.buffer.read(); open(os.environ["TEST_ROOT"]+"/transferred","ab").write(d); sys.stdout.buffer.write(d)\'\n[ "$FAILURE" != pv ]',
                'nc': 'echo "Unexpected netcat invocation" >&2; exit 99',
                'ssh': '''exec python3 - "$@" <<'MOCK'
import os, subprocess, sys
args = sys.argv[1:]
if args[0] in ('-n', '-q'):
    args.pop(0)
command = args[1]
failure = os.environ['FAILURE']
if failure == 'receiver':
    command = command.replace('stream.write(data)', 'raise RuntimeError("Injected receiver failure")')
if failure == 'checksum':
    command = command.replace('stream.write(data)', 'stream.write(bytes([data[0] ^ 1]) + data[1:])')
if failure == 'retry':
    command = command.replace('listener.bind(("", port))', 'listener.bind(("192.0.2.1" if attempt == 0 else "", port))')
command = command.replace('print(port, flush=True)', 'print(port, flush=True); open(os.environ["TEST_ROOT"] + "/ports", "a").write(str(port) + chr(10))')
if command.startswith("python3 "):
    os.execl("/bin/sh", "sh", "-c", "exec " + command)
sys.exit(subprocess.call(command, shell=True))
MOCK''',
            }
            for name, body in mocks.items():
                path = binaries / name
                path.write_text('#!/bin/bash\n' + body + '\n')
                path.chmod(0o755)
            occupied = socket.socket()
            if failure == 'occupied':
                occupied.bind(('0.0.0.0', port or 0))
                occupied.listen()
                port = occupied.getsockname()[1]
            result = subprocess.run(
                ['bash', str(SCRIPT), '-i', ('invalid address' if failure == 'sender' else '127.0.0.1'), '-s', 'mock',
                 '-d', str(destination), *(['-f'] if force else []), *(['-p', str(port)] if port is not None else []), *map(str, sources)],
                env=dict(os.environ, PATH=str(binaries) + ':' + os.environ['PATH'],
                         TEST_ROOT=str(root), FAILURE=failure),
                capture_output=True, text=True, timeout=15,
            )
            occupied.close()
            if existing == 'different' and force and partial:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Both final and .part exist', result.stderr)
                self.assertEqual((destination / sources[0].name).read_bytes(), b'old content')
                self.assertEqual((destination / (sources[0].name + '.part')).read_bytes(), part_data)
                return result.stdout
            if existing == 'different' and not force:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Refusing to overwrite', result.stdout)
                for source in sources:
                    self.assertEqual((destination / source.name).read_bytes(), b'old content')
                self.assertFalse((root / 'ports').exists())
                return result.stdout
            if failure in ('', 'retry'):
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for source in sources:
                    self.assertEqual(source.read_bytes(), (destination / source.name).read_bytes())
                if existing == 'same':
                    self.assertFalse((root / 'ports').exists())
                    self.assertEqual(result.stdout.count('SHA256 matches'), count)
                    return result.stdout
                if empty:
                    self.assertFalse((root / 'ports').exists())
                    return result.stdout
                if partial:
                    self.assertFalse((destination / (sources[0].name + '.part')).exists())
                    transferred = (root / 'transferred').stat().st_size if (root / 'transferred').exists() else 0
                    expected = {'tail': len(data) - chunk, 'bad_first': len(data),
                                'complete': 0, 'oversized': 0}[partial]
                    self.assertEqual(transferred, expected)
                    if partial in ('complete', 'oversized'):
                        self.assertFalse((root / 'ports').exists())
                        return result.stdout
                ports = (root / 'ports').read_text().splitlines()
                self.assertEqual(len(ports), count)
                for line in ports:
                    if port is None:
                        self.assertTrue(49152 <= int(line) <= 65535)
                    else:
                        self.assertEqual(int(line), int(port))
            else:
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse((destination / sources[0].name).exists())
                if failure in ('checksum', 'receiver'):
                    self.assertTrue((destination / (sources[0].name + '.part')).exists())
            return result.stdout

    def test_empty_file(self):
        self.run_transfer(empty=True)

    def test_force_preserves_conflicting_partial(self):
        self.run_transfer(existing='different', force=True, partial='tail')

    def test_resume_from_verified_chunk(self):
        self.run_transfer(partial='tail', verify=False)

    def test_resume_restarts_at_bad_chunk(self):
        self.run_transfer(partial='bad_first')

    def test_complete_partial_needs_no_network(self):
        self.run_transfer(partial='complete')

    def test_extra_partial_tail_is_truncated(self):
        self.run_transfer(partial='oversized')

    def test_real_tcp_transfer(self):
        self.run_transfer()

    def test_multiple_files_with_shell_characters(self):
        self.run_transfer(count=3)

    def test_failures_are_reported(self):
        for failure, message in [('pv', 'Sender failed'), ('sender', 'Sender failed'),
                                 ('receiver', 'failed'),
                                 ('checksum', 'Verification failed'),
                                 ('occupied', 'Receiver failed to become ready')]:
            with self.subTest(failure=failure):
                self.assertIn(message, self.run_transfer(failure))

    def test_retries_occupied_candidate(self):
        self.run_transfer(failure='retry')

    def test_fixed_port_reused_for_multiple_files(self):
        self.run_transfer(count=3, port='09000')

    def test_fixed_port_occupied(self):
        self.assertIn('Receiver failed to become ready', self.run_transfer(failure='occupied', port=16432))

    def test_invalid_ports(self):
        for port in ['0', '65536', '-1', 'abc', '1;echo bad', '999999999999', '']:
            result = subprocess.run(['bash', str(SCRIPT), '-p', port], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Port must be', result.stdout)

    def test_identical_files_skipped_even_with_force(self):
        for force in (False, True):
            self.run_transfer(count=2, existing='same', force=force, verify=False)

    def test_different_files_refused_without_force(self):
        self.run_transfer(count=2, existing='different', verify=False)

    def test_force_overwrites_different_files(self):
        self.run_transfer(count=2, existing='different', force=True)



if __name__ == '__main__':
    unittest.main()
