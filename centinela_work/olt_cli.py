"""
Reusable non-interactive telnet runner for the VSOL GPON OLT.

Usage:
    python olt_cli.py "cmd1" "cmd2" ...
    python olt_cli.py --file cmds.txt
    echo "show version" | python olt_cli.py -

Handles:
  - login
  - IAC stripping so output is readable
  - --More-- pagination (sends space)
  - per-command settling delay
"""
import socket, time, sys, os

HOST = "177.234.245.132"
PORT = 2233
USER = "Manuel"
PWD  = "Manunacho.24"

READ_TIMEOUT_FIRST = 2.5     # initial wait after sending a command
READ_TIMEOUT_IDLE  = 0.8     # idle wait between subsequent reads
MORE_TOKENS = (b"--More--", b"-- More --", b"---- More ----", b" More ", b"<Press any key")

def strip_iac(data: bytes) -> bytes:
    out = bytearray(); i = 0
    while i < len(data):
        b = data[i]
        if b == 0xFF and i + 2 < len(data):
            cmd = data[i+1]
            if cmd in (0xFB, 0xFC, 0xFD, 0xFE):  # WILL/WONT/DO/DONT
                i += 3; continue
            if cmd == 0xFA:  # subneg until IAC SE
                j = data.find(b"\xff\xf0", i+2)
                if j == -1: break
                i = j + 2; continue
            i += 2; continue
        out.append(b); i += 1
    return bytes(out)

def recv_block(s, total_timeout):
    """Read until a quiet period of READ_TIMEOUT_IDLE or total_timeout elapses."""
    deadline = time.time() + total_timeout
    s.settimeout(READ_TIMEOUT_IDLE)
    buf = b""
    while time.time() < deadline:
        try:
            chunk = s.recv(8192)
            if not chunk:
                break
            buf += chunk
            # handle pagination on the fly
            for tok in MORE_TOKENS:
                if tok in buf[-200:]:
                    s.sendall(b" ")
                    break
        except socket.timeout:
            # idle pause -> consider response complete
            break
    return buf

def login(s):
    banner = recv_block(s, 3.0)
    s.sendall((USER + "\r\n").encode()); time.sleep(0.6)
    recv_block(s, 1.5)
    s.sendall((PWD + "\r\n").encode());  time.sleep(1.2)
    prompt = recv_block(s, 2.0)
    return strip_iac(banner + prompt).decode("latin-1", "replace")

def run_cmds(commands):
    s = socket.create_connection((HOST, PORT), timeout=10)
    boot = login(s)
    print("=== LOGIN ===")
    print(boot.rstrip())

    # try a couple of common "no pagination" toggles silently
    for warmup in ("terminal length 0", "no page", "page-break disable"):
        s.sendall((warmup + "\r\n").encode()); time.sleep(0.3)
        recv_block(s, 1.0)

    for cmd in commands:
        cmd = cmd.rstrip()
        if not cmd: continue
        print(f"\n=== CMD: {cmd} ===")
        s.sendall((cmd + "\r\n").encode())
        out = recv_block(s, READ_TIMEOUT_FIRST + 5.0)
        text = strip_iac(out).decode("latin-1", "replace")
        # remove embedded "--More--" leftovers
        for tok in (b"--More--", b"-- More --"):
            text = text.replace(tok.decode(), "")
        print(text.rstrip())

    s.sendall(b"exit\r\n"); time.sleep(0.3); s.close()

def main():
    args = sys.argv[1:]
    cmds = []
    if not args:
        print("usage: olt_cli.py <cmd> [<cmd> ...] | --file path | -", file=sys.stderr); sys.exit(2)
    if args[0] == "--file":
        with open(args[1], "r", encoding="utf-8") as f:
            cmds = [ln.strip() for ln in f if ln.strip() and not ln.strip().startswith("#")]
    elif args[0] == "-":
        cmds = [ln.strip() for ln in sys.stdin if ln.strip() and not ln.strip().startswith("#")]
    else:
        cmds = args
    run_cmds(cmds)

if __name__ == "__main__":
    main()
