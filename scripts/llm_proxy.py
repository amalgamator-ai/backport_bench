#!/usr/bin/env python3
"""Host-side LLM egress proxy.

Listens on a Unix socket and forwards every connection to the model endpoint
(TLS passthrough). The sandbox sees only this socket; it has no other route.
"""
import argparse
import os
import socket
import threading
import time


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


def handle(client, endpoint, logfile):
    try:
        upstream = socket.create_connection(endpoint, timeout=30)
    except OSError as e:
        logfile.write(f"connect {endpoint} failed: {e}\n")
        logfile.flush()
        client.close()
        return
    t = threading.Thread(target=pump, args=(upstream, client), daemon=True)
    t.start()
    pump(client, upstream)
    t.join(timeout=5)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--endpoint", required=True, help="host:port")
    ap.add_argument("--log", required=True)
    args = ap.parse_args()

    host, port = args.endpoint.rsplit(":", 1)
    endpoint = (host, int(port))
    try:
        os.unlink(args.socket)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(args.socket)
    srv.listen(64)
    with open(args.log, "a", buffering=1) as logfile:
        logfile.write(f"proxy {args.socket} -> {args.endpoint}\n")
        while True:
            client, _ = srv.accept()
            threading.Thread(
                target=handle, args=(client, endpoint, logfile), daemon=True
            ).start()


if __name__ == "__main__":
    main()
