import socket, time, sys

HOST = "177.234.245.132"
PORT = 2233
USER = "Manuel"
PWD  = "Manunacho.24"

def recv_all(s, t=2.0):
    s.settimeout(t)
    out = b""
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            out += chunk
    except socket.timeout:
        pass
    return out

def strip_iac(data: bytes) -> bytes:
    # Very small telnet IAC stripper just so the banner is readable
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        if b == 0xFF and i + 2 < len(data):
            i += 3
            continue
        out.append(b)
        i += 1
    return bytes(out)

s = socket.create_connection((HOST, PORT), timeout=8)
banner = recv_all(s, 3.0)
print("=== BANNER ===")
print(strip_iac(banner).decode("latin-1", errors="replace"))

s.sendall((USER + "\r\n").encode())
time.sleep(1.0)
after_user = recv_all(s, 2.0)
print("=== AFTER USER ===")
print(strip_iac(after_user).decode("latin-1", errors="replace"))

s.sendall((PWD + "\r\n").encode())
time.sleep(1.5)
after_pwd = recv_all(s, 2.5)
print("=== AFTER PASSWORD ===")
print(strip_iac(after_pwd).decode("latin-1", errors="replace"))

# Try a harmless command to verify we are at a prompt
s.sendall(b"\r\n")
time.sleep(0.5)
prompt = recv_all(s, 1.5)
print("=== PROMPT ===")
print(strip_iac(prompt).decode("latin-1", errors="replace"))

s.sendall(b"exit\r\n")
time.sleep(0.5)
s.close()
print("=== DONE ===")
