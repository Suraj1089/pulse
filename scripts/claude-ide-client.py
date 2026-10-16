#!/usr/bin/env python3
"""Stands in for Claude Code in scripts/memory-check.sh.

Waits for a Pulse lock file in $CLAUDE_CONFIG_DIR/ide, connects the way the
claude CLI does (auth token header, "mcp" subprotocol, initialize, tools/list),
then stays connected until killed. Each message from Pulse is logged to the
file named by the first argument, so the caller can check that the real app
answered and sent the selection. Standard library only.
"""
import base64
import glob
import json
import os
import socket
import struct
import sys
import time


def frame(payload):
    """A masked client text frame."""
    mask = os.urandom(4)
    length = len(payload)
    if length < 126:
        header = struct.pack("!BB", 0x81, 0x80 | length)
    elif length < 65536:
        header = struct.pack("!BBH", 0x81, 0x80 | 126, length)
    else:
        header = struct.pack("!BBQ", 0x81, 0x80 | 127, length)
    return header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def read_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def main():
    log = open(sys.argv[1], "a", buffering=1)
    directory = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "ide")
    deadline = time.time() + 30
    while True:
        locks = glob.glob(os.path.join(directory, "*.lock"))
        if locks:
            break
        if time.time() > deadline:
            log.write("error no lock file\n")
            sys.exit(1)
        time.sleep(0.2)
    lock_path = locks[0]
    time.sleep(0.2)  # renamed into place whole, but be patient anyway
    with open(lock_path) as f:
        lock = json.load(f)
    port = int(os.path.basename(lock_path).split(".")[0])

    sock = socket.create_connection(("127.0.0.1", port), timeout=30)
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        "GET / HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Connection: Upgrade\r\n"
        "Upgrade: websocket\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Protocol: mcp\r\n"
        f"X-Claude-Code-Ide-Authorization: {lock['authToken']}\r\n\r\n"
    )
    sock.sendall(request.encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            log.write("error handshake refused\n")
            sys.exit(1)
        head += chunk
    status = head.split(b"\r\n", 1)[0].decode()
    if " 101 " not in status:
        log.write(f"error {status}\n")
        sys.exit(1)
    log.write(f"connected {lock['ideName']} {port}\n")

    messages = [
        {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "method": "ide_connected", "params": {"pid": os.getpid()}},
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    ]
    for message in messages:
        sock.sendall(frame(json.dumps(message).encode()))

    sock.settimeout(None)
    while True:
        try:
            first, second = read_exact(sock, 2)
        except EOFError:
            log.write("closed\n")
            return
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", read_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", read_exact(sock, 8))[0]
        payload = read_exact(sock, length)
        if first & 0x0F != 0x1:
            continue
        message = json.loads(payload)
        if "method" in message:
            log.write(f"{message['method']} {message.get('params', {}).get('filePath', '')}\n")
        else:
            log.write(f"response {message.get('id')} {'error' if 'error' in message else 'ok'}\n")


if __name__ == "__main__":
    main()
