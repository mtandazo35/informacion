"""Telnet driver for VSOL GPON OLT (BDCom-derived CLI).

Connects, logs in, enters privileged exec, and exposes helpers to:
  - read the OLT-side PON SFP transceiver values (per port)
  - read each ONU's optical_info via OMCI
  - read the per-PON ONU state list
"""
import socket, time, re

PROMPT_RE = re.compile(rb"gpon-olt-[\w\-]+(?:\([^)]+\))?[>#]\s*$")
ANSI_RE   = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
MORE_TOKENS = (b"--More--", b"-- More --", b"---- More ----", b"<Press any key")


def _strip_iac(data: bytes) -> bytes:
    out = bytearray(); i = 0
    while i < len(data):
        b = data[i]
        if b == 0xFF and i + 2 < len(data):
            c = data[i+1]
            if c in (0xFB, 0xFC, 0xFD, 0xFE):
                i += 3; continue
            if c == 0xFA:
                j = data.find(b"\xff\xf0", i+2)
                if j == -1: break
                i = j + 2; continue
            i += 2; continue
        out.append(b); i += 1
    return bytes(out)


def _clean(raw: bytes) -> str:
    text = _strip_iac(raw).decode("latin-1", "replace")
    text = ANSI_RE.sub("", text)
    # OLT uses bare \r mid-line as column separator -> normalize so splitlines works
    text = text.replace("\r\n", "\n").replace("\r", " ")
    return text


class OLTSession:
    def __init__(self, host, port, user, password, enable_password=None, conn_timeout=10.0):
        self.host = host; self.port = port
        self.user = user; self.password = password
        self.enable_password = enable_password or password
        self.s = None
        self.conn_timeout = conn_timeout

    def _read_until_prompt(self, total=15.0):
        deadline = time.time() + total
        self.s.settimeout(0.5)
        buf = b""
        while time.time() < deadline:
            try:
                chunk = self.s.recv(8192)
                if not chunk: break
                buf += chunk
                for tok in MORE_TOKENS:
                    if tok in buf[-300:]:
                        self.s.sendall(b" ")
                        buf = buf.replace(tok, b"")
                        break
                tail = buf.split(b"\n")[-1]
                if PROMPT_RE.search(tail): return buf
            except socket.timeout:
                continue
        return buf

    def cmd(self, line, total=15.0):
        self.s.sendall((line + "\r\n").encode())
        return _clean(self._read_until_prompt(total))

    def __enter__(self):
        self.s = socket.create_connection((self.host, self.port), timeout=self.conn_timeout)
        # banner + Login
        self._read_until_prompt(5.0)
        self.s.sendall((self.user + "\r\n").encode()); time.sleep(0.4)
        self._read_until_prompt(5.0)
        self.s.sendall((self.password + "\r\n").encode())
        self._read_until_prompt(8.0)
        # enable
        self.s.sendall(b"enable\r\n"); time.sleep(0.3)
        self._read_until_prompt(5.0)
        self.s.sendall((self.enable_password + "\r\n").encode())
        self._read_until_prompt(8.0)
        # silence pagination
        for w in ("terminal length 0", "no page", "page-break disable", "terminal page-break disable"):
            self.s.sendall((w + "\r\n").encode()); self._read_until_prompt(3.0)
        # enter config
        self.s.sendall(b"configure terminal\r\n"); self._read_until_prompt(3.0)
        return self

    def __exit__(self, *a):
        try:
            self.s.sendall(b"end\r\n"); time.sleep(0.2)
            self.s.sendall(b"exit\r\n"); time.sleep(0.2)
        except Exception: pass
        try: self.s.close()
        except Exception: pass

    # ---- domain helpers ----

    SFP_RE = re.compile(r"(Temperature|Voltage|TxBias|TxPower):\s*([\d.]+)\s*\S+")
    STATE_LINE_RE = re.compile(r"GPON0/\d+:(\d+)\s+enable\s+(\w+)\s+(\w+)\s+(\S+)")

    @staticmethod
    def _parse_sfp(text):
        out = {"temperature": None, "voltage": None, "txbias": None, "txpower": None}
        for m in OLTSession.SFP_RE.finditer(text):
            out[m.group(1).lower()] = float(m.group(2))
        return out

    @staticmethod
    def _parse_optical(text):
        d = {}
        for ln in text.splitlines():
            if ":" in ln:
                k, _, v = ln.partition(":")
                d[k.strip()] = v.strip()
        def _f(label):
            v = d.get(label, "")
            m = re.search(r"(-?\d+\.\d+)", v)
            return float(m.group(1)) if m else None
        return {
            "rx":   _f("Rx optical level(ONU)"),
            "tx":   _f("Tx optical level"),
            "volt": _f("Power feed voltage"),
            "bias": _f("Laser bias current"),
            "temp": _f("Temperature"),
        }

    def read_pon(self, pon: int):
        """Enter PON interface ONCE; read SFP + state + all working-ONU opticals.

        Returns:
            {
              "sfp":  {temperature, voltage, txbias, txpower},
              "onus": [{id, omcc, phase, sn, opt|None}, ...]
            }
        opt is None for non-working ONUs.
        """
        self.cmd(f"interface gpon 0/{pon}", 3)
        sfp_text   = self.cmd("show pon optical transceiver", 4)
        state_text = self.cmd("show onu state", 8)
        onus = []
        for m in self.STATE_LINE_RE.finditer(state_text):
            onu_id, omcc, phase, sn = int(m.group(1)), m.group(2), m.group(3), m.group(4)
            opt = None
            if phase == "working":
                opt_text = self.cmd(f"show onu {onu_id} optical_info", 4)
                opt = self._parse_optical(opt_text)
            onus.append({"id": onu_id, "omcc": omcc, "phase": phase, "sn": sn, "opt": opt})
        self.cmd("exit", 3)
        return {"sfp": self._parse_sfp(sfp_text), "onus": onus}
