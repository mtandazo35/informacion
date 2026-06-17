"""One-shot: try to enter privileged mode and list available show commands."""
import socket, time, sys
sys.path.insert(0, r"c:\Users\Manuel\Documents\GitHub\informacion\centinela_work")
from olt_cli import strip_iac, recv_block, HOST, PORT, USER, PWD

def send(s, line, wait=1.0):
    s.sendall((line + "\r\n").encode())
    time.sleep(wait)
    return strip_iac(recv_block(s, 2.5)).decode("latin-1", "replace")

s = socket.create_connection((HOST, PORT), timeout=10)
recv_block(s, 3.0)
s.sendall((USER + "\r\n").encode()); time.sleep(0.6); recv_block(s, 1.5)
s.sendall((PWD + "\r\n").encode());  time.sleep(1.2); recv_block(s, 2.0)

# try enable with the same password first
s.sendall(b"enable\r\n"); time.sleep(0.8)
print("--- enable ---")
print(recv_block(s, 1.5).decode("latin-1", "replace"))

# attempt password
s.sendall((PWD + "\r\n").encode()); time.sleep(1.0)
out = strip_iac(recv_block(s, 2.0)).decode("latin-1", "replace")
print("--- after enable pw ---")
print(out)

# whichever mode we ended in, ask for help
print(send(s, "?", 0.8))
print(send(s, "show ?", 1.0))

s.sendall(b"exit\r\n"); time.sleep(0.3); s.close()
