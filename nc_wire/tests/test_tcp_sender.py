"""Real loopback regression: run explicitly where local sockets are allowed."""
import hashlib
from pathlib import Path
import socket
import subprocess
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'nc_wire.sh'


class SenderTest(unittest.TestCase):
    def test_slow_receiver_gets_entire_file(self):
        source = SCRIPT.read_text()
        function = source[source.index('send_file() {'):source.index('# Pre-flight checks')]
        token = 'ab' * 32
        payload = bytes(range(256)) * 65536
        received = bytearray()
        errors = []
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            listener.settimeout(15)

            def receive():
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(15)
                        while True:
                            data = connection.recv(65536)
                            if not data:
                                break
                            received.extend(data)
                            time.sleep(0.001)
                except Exception as exc:
                    errors.append(exc)

            worker = threading.Thread(target=receive)
            worker.start()
            result = subprocess.run(
                ['bash', '-c', function + '\n'
                 'DEST_IP=127.0.0.1\nDEST_PORT=$1\nDEST_TOKEN=$2\nsend_file', 'test',
                 str(listener.getsockname()[1]), token],
                input=payload, capture_output=True, timeout=30,
            )
            worker.join(20)
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(bytes(received[:len(token)]), token.encode('ascii'))
        self.assertEqual(len(received) - len(token), len(payload))
        self.assertEqual(hashlib.sha256(bytes(received[len(token):])).digest(), hashlib.sha256(payload).digest())


if __name__ == '__main__':
    unittest.main()
