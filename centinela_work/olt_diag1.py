"""Diagnostic batch #1:
   - find which gigabit ports are actually UP (uplink)
   - global health: alarms, fan, cpu, syslog
   - per PON: state of ONUs and aggregated alarms
"""
import socket, time, sys
sys.path.insert(0, r"c:\Users\Manuel\Documents\GitHub\informacion\centinela_work")
from olt_cli import strip_iac, recv_block, HOST, PORT, USER, PWD

def send(s, line, wait=0.7, total=4.0):
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

cmds = [
    # 1) find live ge ports
    "show interface gigabitethernet 0/3",
    "show interface gigabitethernet 0/4",
    "show interface gigabitethernet 0/5",
    "show interface gigabitethernet 0/6",
    "show interface gigabitethernet 0/7",
    "show interface gigabitethernet 0/8",
    "show interface gigabitethernet 0/9",
    "show interface gigabitethernet 0/10",
    # 2) global health from privileged exec is limited -> jump to config
    "configure terminal",
    "show alarm ?",
    "show alarm-event ?",
    "show alarm",
    "show alarm-event",
    "show fan",
    "show cpu",
    "show perf-stats",
    "show syslog",
    "show log",
    "show pon ?",
    "show pon",
    "show rogue-onu-detect",
    "show running-config | include uplink",
    "show running-config | include hostname",
    "show running-config | include enable-password",
    "end",
]
for c in cmds:
    print(f"\n=== {c} ===")
    print(send(s, c, 0.6, 4.5).rstrip())

s.sendall(b"exit\r\n"); time.sleep(0.3); s.close()
