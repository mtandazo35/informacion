"""Build a full optical report for all PON ports and all working ONUs."""
import socket, time, re, sys
sys.path.insert(0, r"c:\Users\Manuel\Documents\GitHub\informacion\centinela_work")
from olt2 import read_until_prompt, strip_iac, login, HOST, PORT

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

def clean(text):
    text = ANSI_RE.sub("", text)
    # OLT uses \r\x1b[NNNC to position columns; after stripping ANSI we still
    # have bare \r mid-line which splitlines() would mistakenly break on.
    # Normalize \r\n then convert standalone \r to a single space.
    text = text.replace("\r\n", "\n").replace("\r", " ")
    return text

def cmd(s, line, total=12.0):
    s.sendall((line + "\r\n").encode())
    raw = read_until_prompt(s, total)
    return clean(strip_iac(raw).decode("latin-1", "replace"))

def parse_state(text):
    """Parse 'show onu state' output -> list of (onu_id, sn, phase)."""
    onus = []
    for ln in text.splitlines():
        m = re.match(r"GPON0/\d:(\d+)\s*enable\s*(\w+)\s*(\w+)\s*(\w+)", ln)
        if m:
            onu_id = int(m.group(1))
            omcc, phase, sn = m.group(2), m.group(3), m.group(4)
            onus.append((onu_id, sn, phase))
    return onus

def parse_optical(text):
    """Parse 'show onu N optical_info' output -> dict of fields."""
    out = {}
    for ln in text.splitlines():
        if ":" in ln:
            k, _, v = ln.partition(":")
            out[k.strip()] = v.strip()
    return out

def main():
    s = socket.create_connection((HOST, PORT), timeout=10)
    login(s)
    cmd(s, "configure terminal", 4)
    pon_data = {}
    for pon in range(1, 9):
        print(f"\n##### PON 0/{pon} #####", flush=True)
        cmd(s, f"interface gpon 0/{pon}", 3)
        # OLT-side SFP
        sfp_text = cmd(s, "show pon optical transceiver", 4)
        # ONU state (list)
        state_text = cmd(s, "show onu state", 6)
        onus = parse_state(state_text)
        working = [(oid, sn) for oid, sn, ph in onus if ph == "working"]
        # Per-ONU optical
        rows = []
        for oid, sn in working:
            opt_text = cmd(s, f"show onu {oid} optical_info", 3)
            d = parse_optical(opt_text)
            rx = d.get("Rx optical level(ONU)", "?")
            tx = d.get("Tx optical level", "?")
            temp = d.get("Temperature", "?")
            volt = d.get("Power feed voltage", "?")
            bias = d.get("Laser bias current", "?")
            rows.append({"id": oid, "sn": sn, "rx": rx, "tx": tx,
                         "temp": temp, "volt": volt, "bias": bias})
            print(f"  ONU {oid:>3} {sn:<14} Rx={rx:>8} Tx={tx:>7} T={temp:>10} V={volt:>7} I={bias:>10}", flush=True)
        pon_data[pon] = {"sfp": sfp_text, "state": state_text,
                          "total_seen": len(onus),
                          "working": len(working),
                          "rows": rows}
        cmd(s, "exit", 3)
    cmd(s, "end", 3)
    s.sendall(b"exit\r\n"); time.sleep(0.3); s.close()

    # Persist
    import json
    with open(r"c:\Users\Manuel\Documents\GitHub\informacion\centinela_work\optical_report.json","w",encoding="utf-8") as f:
        json.dump(pon_data, f, indent=2)
    print("\nSaved optical_report.json")

if __name__ == "__main__":
    main()
