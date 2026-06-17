"""Improved OLT runner: prompt-aware reader, robust across long outputs."""
import socket, time, re, sys

HOST = "177.234.245.132"
PORT = 2233
USER = "Manuel"
PWD  = "Manunacho.24"

# matches gpon-olt-Estero-Medio> | # | (config)# | (config-pon-0/x)#
PROMPT_RE = re.compile(rb"gpon-olt-[\w\-]+(?:\([^)]+\))?[>#]\s*$")
MORE_TOKENS = (b"--More--", b"-- More --", b"---- More ----", b"<Press any key")

def strip_iac(data: bytes) -> bytes:
    out = bytearray(); i = 0
    while i < len(data):
        b = data[i]
        if b == 0xFF and i + 2 < len(data):
            cmd = data[i+1]
            if cmd in (0xFB, 0xFC, 0xFD, 0xFE): i += 3; continue
            if cmd == 0xFA:
                j = data.find(b"\xff\xf0", i+2)
                if j == -1: break
                i = j + 2; continue
            i += 2; continue
        out.append(b); i += 1
    return bytes(out)

def read_until_prompt(s, overall_timeout=15.0):
    deadline = time.time() + overall_timeout
    s.settimeout(0.5)
    buf = b""
    while time.time() < deadline:
        try:
            chunk = s.recv(8192)
            if not chunk: break
            buf += chunk
            # pagination
            for tok in MORE_TOKENS:
                if tok in buf[-300:]:
                    s.sendall(b" ")
                    buf = buf.replace(tok, b"")
                    break
            # if last line matches prompt, we are done
            tail = buf.split(b"\n")[-1]
            if PROMPT_RE.search(tail):
                return buf
        except socket.timeout:
            continue
    return buf

def cmd(s, line, total=15.0):
    s.sendall((line + "\r\n").encode())
    raw = read_until_prompt(s, total)
    return strip_iac(raw).decode("latin-1", "replace")

def login(s):
    read_until_prompt(s, 5.0)  # banner + Login:
    s.sendall((USER + "\r\n").encode()); time.sleep(0.4)
    read_until_prompt(s, 5.0)  # Password:
    s.sendall((PWD + "\r\n").encode())
    out = read_until_prompt(s, 8.0)
    # enable
    s.sendall(b"enable\r\n"); time.sleep(0.4)
    read_until_prompt(s, 5.0)
    s.sendall((PWD + "\r\n").encode())
    out2 = read_until_prompt(s, 8.0)
    # turn off pagination
    for w in ("terminal length 0","no page","page-break disable","terminal page-break disable"):
        s.sendall((w + "\r\n").encode())
        read_until_prompt(s, 3.0)
    return strip_iac(out + out2).decode("latin-1","replace")

def run(commands, conn_timeout=10.0, per_cmd=15.0):
    s = socket.create_connection((HOST, PORT), timeout=conn_timeout)
    login(s)
    for c in commands:
        print(f"\n========== {c} ==========")
        print(cmd(s, c, per_cmd).rstrip())
    s.sendall(b"end\r\n"); time.sleep(0.2)
    s.sendall(b"exit\r\n"); time.sleep(0.2); s.close()

if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print("usage: olt2.py <cmd> [<cmd> ...] | --file path", file=sys.stderr); sys.exit(2)
    if args[0] == "--file":
        with open(args[1], "r", encoding="utf-8") as f:
            cmds = [ln.strip() for ln in f if ln.strip() and not ln.strip().startswith("#")]
    else:
        cmds = args
    run(cmds)
