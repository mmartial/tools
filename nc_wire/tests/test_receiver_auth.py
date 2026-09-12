"""Security regression: the single-file receiver must reject unauthenticated connections."""
import hashlib
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'nc_wire.sh'


class ReceiverAuthTests(unittest.TestCase):
    def setUp(self):
        source = SCRIPT.read_text()
        start = source.index("REMOTE_HELPER=$(cat <<'PY'")
        start = source.index('\n', start) + 1
        end = source.index('\nPY\n', start)
        self.code = source[start:end]
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.final = Path(self.temp.name) / 'target'

    def start_receiver(self, offset=0):
        process = subprocess.Popen(
            ['python3', '-c', self.code, 'false', 'receive', str(self.final), str(offset), ''],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        line = process.stdout.readline()
        port, token = line.split()
        return process, int(port), token

    def test_rogue_connection_without_token_is_rejected(self):
        process, port, token = self.start_receiver()
        with socket.create_connection(('127.0.0.1', port), timeout=10) as rogue:
            rogue.sendall(b'x' * 64)
            rogue.shutdown(socket.SHUT_WR)
            rogue.recv(1)
        stdout, stderr = process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn('Invalid transfer token', stderr)
        part = Path(str(self.final) + '.part')
        self.assertTrue(part.exists())
        self.assertEqual(part.read_bytes(), b'')

    def test_legitimate_retry_with_correct_token_succeeds(self):
        process, port, token = self.start_receiver()
        with socket.create_connection(('127.0.0.1', port), timeout=10) as rogue:
            rogue.sendall(b'y' * 64)
            rogue.shutdown(socket.SHUT_WR)
            rogue.recv(1)
        process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)

        payload = bytes(range(256)) * 4096
        process, port, token = self.start_receiver()
        with socket.create_connection(('127.0.0.1', port), timeout=10) as sender:
            sender.sendall(token.encode('ascii'))
            sender.sendall(payload)
            sender.shutdown(socket.SHUT_WR)
            while sender.recv(65536):
                pass
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        part = Path(str(self.final) + '.part')
        self.assertEqual(part.read_bytes(), payload)
        self.assertEqual(hashlib.sha256(part.read_bytes()).digest(), hashlib.sha256(payload).digest())


if __name__ == '__main__':
    unittest.main()
