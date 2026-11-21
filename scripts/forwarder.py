#!/usr/bin/env python3
"""Sandbox-side forwarder.

Inside the network namespace the only reachable peer is loopback. This listens
on 127.0.0.1:<port> and bridges each connection to the host proxy through the
bind-mounted Unix socket.
"""
import argparse
import socket
import threading


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client, unix_path):
    try:
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        upstream.connect(unix_path)
    except OSError:
        client.close()
        return
    t = threading.Thread(target=pump, args=(upstream, client), daemon=True)
    t.start()
    pump(client, upstream)
    t.join(timeout=5)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, default=443)
    ap.add_argument("--unix", required=True)
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.listen))
    srv.listen(64)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client, args.unix), daemon=True).start()


if __name__ == "__main__":
    main()
