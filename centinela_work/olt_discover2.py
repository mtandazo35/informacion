"""Discover deeper command tree: gpon interface submode + gigabitethernet show."""
import socket, time, sys
sys.path.insert(0, r"c:\Users\Manuel\Documents\GitHub\informacion\centinela_work")
from olt_cli import strip_iac, recv_block, HOST, PORT, USER, PWD

def send(s, line, wait=0.8, total=3.5):
    s.sendall((line + "\r\n").encode())
    time.sleep(wait)
    return strip_iac(recv_block(s, total)).decode("latin-1", "replace")

s = socket.create_connection((HOST, PORT), timeout=10)
recv_block(s, 3.0)
s.sendall((USER + "\r\n").encode()); time.sleep(0.6); recv_block(s, 1.5)
s.sendall((PWD + "\r\n").encode());  time.sleep(1.2); recv_block(s, 2.0)
s.sendall(b"enable\r\n"); time.sleep(0.6); recv_block(s, 1.5)
s.sendall((PWD + "\r\n").encode()); time.sleep(1.0); recv_block(s, 2.0)
for w in ("terminal length 0","no page","page-break disable","terminal page-break disable"):
    s.sendall((w + "\r\n").encode()); time.sleep(0.2); recv_block(s, 0.8)

queries = [
    "show interface gigabitethernet ?",
    "show interface gigabitethernet 0/1",
    "show interface gigabitethernet 0/2",
    "configure terminal",
    "?",
    "interface gpon 0/1",
    "?",
    "show ?",
    "show onu ?",
    "exit",
    "exit",
]
for q in queries:
    print(f"\n=================== {q} ===================")
    print(send(s, q, 0.8, 4.0).rstrip())

s.sendall(b"exit\r\n"); time.sleep(0.3); s.close()
