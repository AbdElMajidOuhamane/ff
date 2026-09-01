import socket, base64, os, struct, sys

HOST, PORT = "127.0.0.1", 3000

def read_exact(s, n):
    b = b""
    while len(b) < n:
        b += s.recv(n - len(b))
    return b

def read_frame(s):
    b0, b1 = read_exact(s, 2)
    op = b0 & 0x0F
    l = b1 & 0x7F
    if l == 126:
        l = struct.unpack(">H", read_exact(s, 2))[0]
    elif l == 127:
        l = struct.unpack(">Q", read_exact(s, 8))[0]
    assert (b1 & 0x80) == 0, "server frames must be unmasked"
    p = read_exact(s, l)
    return op, p

def send_frame(s, op, payload):
    mask = os.urandom(4)
    masked = bytes(payload[i] ^ mask[i % 4] for i in range(len(payload)))
    hdr = bytes([0x80 | op])
    n = len(payload)
    if n <= 125:
        hdr += bytes([0x80 | n])
    elif n <= 0xFFFF:
        hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
    s.sendall(hdr + mask + masked)

def fail(msg):
    print("FAIL:", msg); sys.exit(1)

key = base64.b64encode(os.urandom(16)).decode()
s = socket.create_connection((HOST, PORT))
req = (
    f"GET /ws HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n"
    f"Connection: Upgrade\r\nUpgrade: websocket\r\n"
    f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n"
)
s.sendall(req.encode())
resp = s.recv(4096)
assert resp.startswith(b"HTTP/1.1 101"), fail(f"handshake: {resp[:40]!r}")

send_frame(s, 0x1, b"hello")
op, p = read_frame(s)
assert op == 0x1 and p == b"echo: hello", fail(f"text echo: op={op} p={p!r}")

blob = bytes([0, 1, 2, 0xFE, 0xFF, 128, 255])
send_frame(s, 0x2, blob)
op, p = read_frame(s)
assert op == 0x2 and p == blob, fail(f"binary echo: op={op} len={len(p)}")

send_frame(s, 0x8, struct.pack(">H", 1000) + b"done")
op, p = read_frame(s)
assert op == 0x8 and len(p) >= 2, fail(f"close echo: op={op}")
assert struct.unpack(">H", p[:2])[0] == 1000, fail("close code")
assert p[2:] == b"done" or p[2:] == b"", fail(f"close reason: {p[2:]!r}")
s.close()
print("PASS: ws handshake, text echo, binary echo, close(code,reason)")
