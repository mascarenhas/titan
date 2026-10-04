#!/usr/bin/env python3
"""Finite raw loopback peer; no third-party packages or provider imports."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import sys
import time

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def frame(opcode, data=b"", *, masked=False, final=True):
    header = bytes([(0x80 if final else 0) | opcode])
    length = len(data)
    flag = 0x80 if masked else 0
    if length < 126:
        header += bytes([flag | length])
    elif length < 65536:
        header += bytes([flag | 126]) + struct.pack("!H", length)
    else:
        header += bytes([flag | 127]) + struct.pack("!Q", length)
    if masked:
        mask = os.urandom(4)
        header += mask
        data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
    return header + data


class Wire:
    def __init__(self, stream):
        self.stream, self.buffer = stream, b""

    def exact(self, count):
        while len(self.buffer) < count:
            chunk = self.stream.recv(max(65536, count - len(self.buffer)))
            if not chunk:
                raise EOFError("peer transport ended before complete frame")
            self.buffer += chunk
        result, self.buffer = self.buffer[:count], self.buffer[count:]
        return result

    def headers(self):
        while b"\r\n\r\n" not in self.buffer:
            chunk = self.stream.recv(65536)
            if not chunk:
                raise EOFError("opening ended before headers")
            self.buffer += chunk
            if len(self.buffer) > 65536:
                raise ValueError("opening header budget exceeded")
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        fields = {}
        for line in lines[1:]:
            key, value = line.split(b":", 1)
            key = key.lower()
            if key in fields:
                raise ValueError("duplicate opening header")
            fields[key] = value.strip()
        return lines[0], fields

    def receive(self, masked):
        first, second = self.exact(2)
        if first & 0x70 or bool(second & 0x80) != masked:
            raise ValueError("RSV or role mask mismatch")
        opcode, final, length = first & 15, bool(first & 0x80), second & 127
        if length == 126:
            length = struct.unpack("!H", self.exact(2))[0]
            if length < 126:
                raise ValueError("nonminimal length")
        elif length == 127:
            length = struct.unpack("!Q", self.exact(8))[0]
            if length < 65536 or length >= 1 << 63:
                raise ValueError("nonminimal/invalid length")
        if length > 2 * 1024 * 1024:
            raise ValueError("peer frame budget exceeded")
        if opcode >= 8 and (not final or length > 125):
            raise ValueError("invalid control frame")
        mask = self.exact(4) if masked else None
        data = self.exact(length)
        if mask:
            data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
        return opcode, final, data


def accept_key(key):
    return base64.b64encode(hashlib.sha1(key + GUID).digest())


def opening(wire, client, port):
    if client:
        key = base64.b64encode(os.urandom(16))
        wire.stream.sendall(b"GET /bench HTTP/1.1\r\nHost: localhost:" + str(port).encode()
            + b"\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13"
            + b"\r\nSec-WebSocket-Key: " + key + b"\r\n\r\n")
        status, fields = wire.headers()
        if status != b"HTTP/1.1 101 Switching Protocols" or fields.get(b"sec-websocket-accept") != accept_key(key):
            raise ValueError("invalid measured-server opening")
    else:
        request, fields = wire.headers()
        key = fields.get(b"sec-websocket-key", b"")
        if request != b"GET /bench HTTP/1.1" or len(base64.b64decode(key, validate=True)) != 16:
            raise ValueError("invalid measured-client opening")
        wire.stream.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            + b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept_key(key) + b"\r\n\r\n")
    if fields.get(b"upgrade", b"").lower() != b"websocket" or b"upgrade" not in fields.get(b"connection", b"").lower().split(b","):
        raise ValueError("opening lacks upgrade tokens")


def wait_marker(path, text):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            if Path(path).read_text() == text:
                return
        except FileNotFoundError:
            pass
        time.sleep(0.001)
    raise TimeoutError("sideband marker missing")


def fixture_client_context(ca):
    context = ssl.create_default_context(cafile=ca)
    # Existing native CA fixtures predate Python's default strict-extension
    # profile. Keep chain + hostname verification, matching their Titan use.
    context.verify_flags &= ~ssl.VERIFY_X509_STRICT
    assert context.verify_mode == ssl.CERT_REQUIRED and context.check_hostname
    return context


def finish(wire, peer_client, graceful):
    # Graceful sends Close from Titan. Abort must end without additional data.
    try:
        opcode, final, data = wire.receive(not peer_client)
    except (EOFError, ConnectionResetError, ssl.SSLEOFError):
        if graceful:
            raise
        return
    if not graceful or opcode != 8 or not final or data != b"\x03\xe8":
        raise ValueError("unexpected bytes or missing graceful Close")
    wire.stream.sendall(frame(8, data, masked=peer_client))


def exercise(stream, config):
    ws = config["transport"] in ("ws", "wss")
    peer_client = config["role"] == "server"
    payload = b"x" * config["size"]
    count, operation = config["count"], config["operation"]
    wire = Wire(stream)
    if ws:
        opening(wire, peer_client, config["port"])
    wait_marker(config["go_marker"], "go\n")
    frames = 0
    if not ws:
        if operation == "read":
            for _ in range(count):
                stream.sendall(payload)
        else:
            remaining = len(payload) * count
            while remaining:
                chunk = stream.recv(min(65536, remaining))
                if not chunk or chunk != b"x" * len(chunk):
                    raise ValueError("wrong measured raw output")
                remaining -= len(chunk)
        # Drain only after the exact byte budget. A deliberate TLS abort can
        # reset input or fail a post-handshake output attempted by SSL recv.
        # No raw TLS close_notify is expected.
        try:
            if stream.recv(1):
                raise ValueError("raw endpoint exceeded byte budget")
        except (ConnectionResetError, BrokenPipeError, ssl.SSLEOFError):
            pass
        return {"messages": count, "frames": None, "bytes": count * len(payload)}
    opcode = 1 if config["kind"] == "text" else 2
    fragment = config.get("fragment", 0) or max(1, len(payload))
    if operation in ("read", "read_ping", "fairness"):
        for _ in range(count):
            if operation == "read_ping":
                stream.sendall(frame(9, b"control", masked=peer_client))
            parts = [payload[index:index + fragment] for index in range(0, len(payload), fragment)] or [b""]
            for index, part in enumerate(parts):
                stream.sendall(frame(opcode if index == 0 else 0, part,
                                     masked=peer_client, final=index == len(parts) - 1))
                frames += 1
            if operation == "read_ping":
                pong, final, data = wire.receive(not peer_client)
                if (pong, final, data) != (10, True, b"control"):
                    raise ValueError("wrong automatic Pong")
        if operation == "fairness":
            Path(config["preload_marker"]).write_text("preloaded\n")
    elif operation == "ping":
        for _ in range(count):
            ping, final, data = wire.receive(not peer_client)
            if ping != 9 or not final:
                raise ValueError("expected Ping")
            stream.sendall(frame(10, data, masked=peer_client))
            frames += 1
    else:
        for _ in range(count):
            received = bytearray()
            index = 0
            while True:
                actual_opcode, final, data = wire.receive(not peer_client)
                if actual_opcode != (opcode if index == 0 else 0) or len(data) > 16384:
                    raise ValueError("wrong output fragment type or size")
                received.extend(data)
                frames += 1
                index += 1
                if len(received) > len(payload):
                    raise ValueError("message exceeded expected size")
                if final:
                    break
            if received != payload:
                raise ValueError("wrong measured message")
    finish(wire, peer_client, config["cleanup"] == "graceful")
    return {"messages": count, "frames": frames, "bytes": count * len(payload)}


def run(config):
    secure = config["transport"] in ("wss", "tls")
    client = config["role"] == "server"
    sessions = config["count"] if config["operation"] == "sessions" else 1
    per_session = dict(config, count=0, operation="read") if config["operation"] == "sessions" else config
    results = []
    listener = None
    context = None
    if secure:
        if client:
            context = fixture_client_context(config["ca"])
        else:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(config["certificate"], config["key"])
    if not client:
        listener = socket.socket()
        listener.bind(("127.0.0.1", config["port"]))
        listener.listen(1)
        listener.settimeout(30)
        Path(config["listen_marker"]).write_text("listening\n")
    try:
        for index in range(sessions):
            results.append(run_session(config, per_session, client, context, listener, index + 1))
    finally:
        if listener is not None:
            listener.close()
    return {"sessions": sessions, "results": results,
            "python_version":sys.version, "peer_openssl":ssl.OPENSSL_VERSION}


def run_session(config, per_session, client, context, listener, generation):
    if client:
        wait_marker(config["listen_marker"], f"listening:{generation}\n")
        deadline = time.monotonic() + 30
        while True:
            try:
                stream = socket.create_connection(("127.0.0.1", config["port"]), timeout=30)
                break
            except ConnectionRefusedError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.001)
        if context:
            stream = context.wrap_socket(stream, server_hostname="localhost")
    else:
        stream, _ = listener.accept()
        if context:
            stream = context.wrap_socket(stream, server_side=True)
    with stream:
        stream.settimeout(30)
        return exercise(stream, per_session)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    args = parser.parse_args()
    print(json.dumps(run(json.loads(args.config.read_text())), sort_keys=True))
