"""A stand-in for glanced's attention socket, for the reconnect test.

Binds late on purpose: the bug this guards against only appears when the
shell tries to connect before the daemon exists, which is the boot race
between omarchy-shell and glanced.service.
"""

import os
import socket
import sys
import threading
import time

EVENT = (
    '{"schemaVersion": 1, "t": %.3f, "state": "tracking", '
    '"present": true, "yaw": -4.2, "pitch": 1.0, "conf": 1.0}\n'
)


def serve(conn):
    t = 0.0
    try:
        while True:
            conn.sendall((EVENT % t).encode())
            t += 0.125
            time.sleep(0.125)
    except OSError:
        pass


def main():
    path, delay = sys.argv[1], float(sys.argv[2])
    time.sleep(delay)

    if os.path.exists(path):
        os.unlink(path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(5)
    print("fake daemon listening", flush=True)

    while True:
        conn, _ = server.accept()
        print("subscriber connected", flush=True)
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
