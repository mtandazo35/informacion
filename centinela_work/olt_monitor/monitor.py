"""Optical monitoring for VSOL GPON OLT fleet.

Usage:
    python monitor.py collect        # poll all OLTs, write to SQLite
    python monitor.py report         # regenerate HTML from latest snapshot
    python monitor.py run            # collect + report (use in scheduled task)
    python monitor.py purge --days N # delete snapshots older than N days
    python monitor.py list-snaps     # show last 20 snapshots

DB lives next to this script in data.db. HTML report at reports/latest.html.
"""
import os, sys, json, time, sqlite3, argparse, html
from datetime import datetime, timedelta, timezone
from pathlib import Path

from olt_driver import OLTSession

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "olts.json"
DB_PATH     = ROOT / "data.db"
REPORTS_DIR = ROOT / "reports"
REPORTS_DIR.mkdir(parents=True, exist_ok=True)

# ----------------------------- schema -----------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS snapshot (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc      TEXT NOT NULL,
    olt         TEXT NOT NULL,
    duration_ms INTEGER,
    ok          INTEGER NOT NULL,
    error       TEXT
);
CREATE INDEX IF NOT EXISTS idx_snapshot_ts ON snapshot(ts_utc);
CREATE INDEX IF NOT EXISTS idx_snapshot_olt ON snapshot(olt, ts_utc);

CREATE TABLE IF NOT EXISTS pon_sfp (
    snapshot_id INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
    pon         INTEGER NOT NULL,
    temperature REAL,
    voltage     REAL,
    txbias_ma   REAL,
    txpower_dbm REAL
);
CREATE INDEX IF NOT EXISTS idx_pon_sfp_snap ON pon_sfp(snapshot_id);

CREATE TABLE IF NOT EXISTS onu (
    snapshot_id INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
    pon         INTEGER NOT NULL,
    onu_id      INTEGER NOT NULL,
    sn          TEXT NOT NULL,
    phase       TEXT NOT NULL,
    rx_dbm      REAL,
    tx_dbm      REAL,
    voltage_v   REAL,
    bias_ma     REAL,
    temp_c      REAL
);
CREATE INDEX IF NOT EXISTS idx_onu_snap   ON onu(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_onu_sn     ON onu(sn);
CREATE INDEX IF NOT EXISTS idx_onu_locate ON onu(snapshot_id, pon, onu_id);
"""


def db():
    conn = sqlite3.connect(DB_PATH)
    conn.executescript(SCHEMA)
    conn.row_factory = sqlite3.Row
    return conn


# ----------------------------- config -----------------------------

def load_config():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


# ----------------------------- collect -----------------------------

def collect_olt(olt_cfg, conn, thresholds):
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    t0 = time.time()
    rows_inserted = {"pon_sfp": 0, "onu": 0}
    err = None
    snap_id = None
    try:
        cur = conn.cursor()
        cur.execute("INSERT INTO snapshot(ts_utc, olt, ok) VALUES (?,?,0)",
                    (ts, olt_cfg["name"]))
        snap_id = cur.lastrowid

        with OLTSession(olt_cfg["host"], olt_cfg["port"],
                        olt_cfg["user"], olt_cfg["password"],
                        olt_cfg.get("enable_password")) as sess:
            for pon in olt_cfg["pon_ports"]:
                data = sess.read_pon(pon)
                sfp = data["sfp"]
                cur.execute(
                    "INSERT INTO pon_sfp(snapshot_id, pon, temperature, voltage, "
                    "txbias_ma, txpower_dbm) VALUES (?,?,?,?,?,?)",
                    (snap_id, pon, sfp["temperature"], sfp["voltage"],
                     sfp["txbias"], sfp["txpower"]))
                rows_inserted["pon_sfp"] += 1

                for o in data["onus"]:
                    opt = o["opt"]
                    cur.execute(
                        "INSERT INTO onu(snapshot_id, pon, onu_id, sn, phase,"
                        " rx_dbm, tx_dbm, voltage_v, bias_ma, temp_c) "
                        "VALUES (?,?,?,?,?,?,?,?,?,?)",
                        (snap_id, pon, o["id"], o["sn"], o["phase"],
                         opt["rx"]   if opt else None,
                         opt["tx"]   if opt else None,
                         opt["volt"] if opt else None,
                         opt["bias"] if opt else None,
                         opt["temp"] if opt else None))
                    rows_inserted["onu"] += 1
        dur = int((time.time() - t0) * 1000)
        cur.execute("UPDATE snapshot SET ok=1, duration_ms=? WHERE id=?", (dur, snap_id))
        conn.commit()
        return snap_id, rows_inserted, None
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
        if snap_id is not None:
            cur = conn.cursor()
            cur.execute("UPDATE snapshot SET error=?, duration_ms=? WHERE id=?",
                        (err, int((time.time() - t0) * 1000), snap_id))
            conn.commit()
        return snap_id, rows_inserted, err


def cmd_collect(_args):
    cfg = load_config()
    conn = db()
    any_fail = False
    for olt in cfg["olts"]:
        if not olt.get("enabled", True):
            print(f"[skip] {olt['name']} disabled"); continue
        snap_id, rows, err = collect_olt(olt, conn, cfg["thresholds"])
        if err:
            any_fail = True
            print(f"[FAIL] {olt['name']} snap_id={snap_id}: {err}")
        else:
            print(f"[ok]   {olt['name']} snap_id={snap_id} pon={rows['pon_sfp']} onu={rows['onu']}")
    return 1 if any_fail else 0


# ----------------------------- report -----------------------------

def classify_rx(rx, t):
    if rx is None: return ("na", "—")
    if rx > t["rx_critical_high"]: return ("crit", "ALTO")
    if rx <  t["rx_critical_low"]:  return ("crit", "CRITICO")
    if rx <  t["rx_marginal_low"]:  return ("marg", "MARGINAL")
    if rx <  t["rx_warning_low"]:   return ("warn", "WARNING")
    return ("ok", "OK")


def classify_tx(tx, t):
    if tx is None: return ("na", "—")
    if tx < t["tx_min"] or tx > t["tx_max"]: return ("crit", "FUERA")
    return ("ok", "OK")


HTML_HEAD = """<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta http-equiv="refresh" content="60">
<title>OLT Optical Monitor</title>
<style>
:root{--bg:#0f1115;--card:#161a22;--ink:#e6e8eb;--mut:#8a909c;--ok:#3aaf6b;
      --warn:#d2a13f;--marg:#e07e3a;--crit:#d04f4f;--na:#5a606b;--accent:#4fa3ff;}
*{box-sizing:border-box}body{margin:0;font-family:ui-sans-serif,system-ui,Segoe UI,Roboto,Helvetica,Arial;
  background:var(--bg);color:var(--ink);line-height:1.35;font-size:13px}
header{padding:14px 20px;background:#10131a;border-bottom:1px solid #222936;
  display:flex;justify-content:space-between;align-items:center;gap:10px}
header h1{margin:0;font-size:16px;font-weight:600}
header .meta{color:var(--mut);font-size:12px}
main{padding:14px 20px;max-width:1500px;margin:0 auto}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:18px}
.kpi{background:var(--card);border:1px solid #222936;border-radius:8px;padding:10px 12px}
.kpi .lbl{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.06em}
.kpi .val{font-size:22px;font-weight:600;margin-top:2px}
.kpi.ok .val{color:var(--ok)} .kpi.warn .val{color:var(--warn)}
.kpi.marg .val{color:var(--marg)} .kpi.crit .val{color:var(--crit)}
.section{background:var(--card);border:1px solid #222936;border-radius:8px;padding:12px 14px;margin-bottom:14px}
.section h2{margin:0 0 8px;font-size:14px;font-weight:600}
table{width:100%;border-collapse:collapse;font-size:12px}
th,td{padding:5px 7px;text-align:left;border-bottom:1px solid #1d2330}
th{color:var(--mut);font-weight:500;cursor:pointer;user-select:none;white-space:nowrap}
th.sorted-asc::after{content:" \\25B2";color:var(--accent)}
th.sorted-desc::after{content:" \\25BC";color:var(--accent)}
td.num{text-align:right;font-variant-numeric:tabular-nums}
.badge{display:inline-block;padding:2px 7px;border-radius:10px;font-size:10px;font-weight:600;letter-spacing:.04em}
.b-ok{background:rgba(58,175,107,.18);color:var(--ok)}
.b-warn{background:rgba(210,161,63,.18);color:var(--warn)}
.b-marg{background:rgba(224,126,58,.20);color:var(--marg)}
.b-crit{background:rgba(208,79,79,.25);color:var(--crit)}
.b-na{background:rgba(90,96,107,.20);color:var(--na)}
.toolbar{display:flex;gap:10px;align-items:center;margin-bottom:10px;flex-wrap:wrap}
.toolbar input,.toolbar select{background:#0f1218;border:1px solid #2a313e;color:var(--ink);
  padding:6px 8px;border-radius:6px;font-size:12px}
.toolbar input{flex:1;min-width:220px;max-width:380px}
.row-crit{background:rgba(208,79,79,.07)}
.row-marg{background:rgba(224,126,58,.05)}
.row-warn{background:rgba(210,161,63,.04)}
small.mono{color:var(--mut);font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
a{color:var(--accent);text-decoration:none}
.trend{display:inline-block;vertical-align:middle;margin-left:4px}
.spark{stroke:var(--accent);fill:none;stroke-width:1.2}
.spark-pt{fill:var(--accent)}
</style></head><body>
"""

HTML_JS = r"""
<script>
(function(){
  // simple sortable + filter
  document.querySelectorAll('table.sortable').forEach(function(tbl){
    var ths = tbl.tHead.rows[0].cells;
    Array.prototype.forEach.call(ths, function(th, idx){
      th.addEventListener('click', function(){
        var rows = Array.prototype.slice.call(tbl.tBodies[0].rows);
        var asc = !th.classList.contains('sorted-asc');
        Array.prototype.forEach.call(ths, function(t){t.classList.remove('sorted-asc','sorted-desc');});
        th.classList.add(asc ? 'sorted-asc' : 'sorted-desc');
        rows.sort(function(a,b){
          var av=a.cells[idx].dataset.sort||a.cells[idx].textContent.trim();
          var bv=b.cells[idx].dataset.sort||b.cells[idx].textContent.trim();
          var an=parseFloat(av), bn=parseFloat(bv);
          if(!isNaN(an)&&!isNaN(bn)){return asc?an-bn:bn-an;}
          return asc?av.localeCompare(bv):bv.localeCompare(av);
        });
        rows.forEach(function(r){tbl.tBodies[0].appendChild(r);});
      });
    });
  });
  var q=document.getElementById('q'), f=document.getElementById('filter');
  function apply(){
    var qs=(q.value||'').toLowerCase();
    var fs=(f.value||'all');
    document.querySelectorAll('#tbl-onu tbody tr').forEach(function(tr){
      var t=tr.textContent.toLowerCase();
      var st=tr.dataset.status||'ok';
      var okQ=!qs||t.indexOf(qs)>=0;
      var okF=fs==='all'||fs===st||(fs==='alert'&&st!=='ok'&&st!=='na');
      tr.style.display=okQ&&okF?'':'none';
    });
  }
  q&&q.addEventListener('input',apply);
  f&&f.addEventListener('change',apply);
})();
</script>
</body></html>
"""


def fetch_latest_snapshot_ids(conn):
    """Return {olt_name: snapshot_id} for the most recent OK snapshot per OLT."""
    out = {}
    for r in conn.execute(
        "SELECT olt, MAX(id) AS id FROM snapshot WHERE ok=1 GROUP BY olt"):
        out[r["olt"]] = r["id"]
    return out


def fetch_onus(conn, snap_ids):
    if not snap_ids: return []
    qmarks = ",".join("?" for _ in snap_ids)
    rows = list(conn.execute(
        f"SELECT s.olt AS olt, o.* FROM onu o JOIN snapshot s ON s.id=o.snapshot_id "
        f"WHERE o.snapshot_id IN ({qmarks}) ORDER BY s.olt, o.pon, o.onu_id",
        list(snap_ids)))
    return rows


def fetch_sfp(conn, snap_ids):
    if not snap_ids: return []
    qmarks = ",".join("?" for _ in snap_ids)
    rows = list(conn.execute(
        f"SELECT s.olt AS olt, p.* FROM pon_sfp p JOIN snapshot s ON s.id=p.snapshot_id "
        f"WHERE p.snapshot_id IN ({qmarks}) ORDER BY s.olt, p.pon",
        list(snap_ids)))
    return rows


def fetch_history(conn, olt, sn, limit=24):
    """Last N Rx readings for one SN (chronological asc)."""
    rows = list(conn.execute(
        "SELECT s.ts_utc AS ts, o.rx_dbm AS rx FROM onu o "
        "JOIN snapshot s ON s.id=o.snapshot_id "
        "WHERE s.olt=? AND o.sn=? AND o.rx_dbm IS NOT NULL "
        "ORDER BY s.ts_utc DESC LIMIT ?",
        (olt, sn, limit)))
    return list(reversed(rows))


def spark(history):
    """Render a tiny SVG spark of Rx over time."""
    if len(history) < 2: return ""
    vals = [r["rx"] for r in history]
    lo, hi = min(vals), max(vals)
    if hi == lo: hi = lo + 0.1
    w, h = 60, 16
    pts = []
    for i, v in enumerate(vals):
        x = i * w / (len(vals) - 1)
        # invert: better (higher rx) = top
        y = h - (v - lo) * h / (hi - lo)
        pts.append(f"{x:.1f},{y:.1f}")
    last = pts[-1].split(",")
    return (f'<svg class="trend" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
            f'<polyline class="spark" points="{" ".join(pts)}"/>'
            f'<circle class="spark-pt" cx="{last[0]}" cy="{last[1]}" r="1.5"/></svg>')


def cmd_report(_args):
    cfg = load_config()
    t = cfg["thresholds"]
    conn = db()
    snap_ids_by_olt = fetch_latest_snapshot_ids(conn)
    snap_ids = list(snap_ids_by_olt.values())
    onus = fetch_onus(conn, snap_ids)
    sfp  = fetch_sfp(conn,  snap_ids)

    # KPIs
    working = [o for o in onus if o["phase"] == "working" and o["rx_dbm"] is not None]
    crit  = [o for o in working if classify_rx(o["rx_dbm"], t)[0] == "crit"]
    marg  = [o for o in working if classify_rx(o["rx_dbm"], t)[0] == "marg"]
    warn  = [o for o in working if classify_rx(o["rx_dbm"], t)[0] == "warn"]
    offline = [o for o in onus if o["phase"] != "working"]

    parts = [HTML_HEAD]
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    parts.append(f'<header><h1>OLT Optical Monitor</h1>'
                 f'<div class="meta">Generado {html.escape(now)} &middot; '
                 f'{len(snap_ids_by_olt)} OLT(s) &middot; {len(working)} ONUs activas'
                 f'</div></header><main>')

    # KPI cards
    parts.append('<div class="grid">')
    def kpi(lbl, val, klass=""):
        return f'<div class="kpi {klass}"><div class="lbl">{lbl}</div><div class="val">{val}</div></div>'
    parts.append(kpi("OLTs", len(snap_ids_by_olt)))
    parts.append(kpi("ONUs activas", len(working)))
    parts.append(kpi("Críticas", len(crit), "crit" if crit else "ok"))
    parts.append(kpi("Marginales", len(marg), "marg" if marg else "ok"))
    parts.append(kpi("Warning", len(warn), "warn" if warn else "ok"))
    parts.append(kpi("No working", len(offline), "warn" if offline else "ok"))
    parts.append("</div>")

    # Per-ONU table with semaforo (MAIN view — Rx/Tx per client)
    parts.append('<div class="section"><h2>ONUs &mdash; Rx/Tx por cliente</h2>'
                 '<div class="toolbar">'
                 '<input id="q" placeholder="Buscar por SN, OLT, PON, ONU id…">'
                 '<select id="filter">'
                 '<option value="all">Todas</option>'
                 '<option value="alert">Solo alertas</option>'
                 '<option value="crit">Solo críticas</option>'
                 '<option value="marg">Solo marginales</option>'
                 '<option value="warn">Solo warning</option>'
                 '</select></div>')
    parts.append('<table id="tbl-onu" class="sortable"><thead><tr>'
                 '<th>OLT</th><th>PON</th><th>ONU</th><th>SN</th><th>Estado</th>'
                 '<th>Rx (dBm)</th><th>Tx (dBm)</th><th>Temp (°C)</th>'
                 '<th>Bias (mA)</th><th>Salud</th></tr></thead><tbody>')

    for o in onus:
        cls, label = classify_rx(o["rx_dbm"], t)
        row_class = f"row-{cls}" if cls in ("crit","marg","warn") else ""
        # Health column: Rx + Tx
        tx_cls, tx_label = classify_tx(o["tx_dbm"], t)
        # show trend sparkline
        hist = fetch_history(conn, o["olt"], o["sn"], 24)
        sp = spark(hist) if len(hist) >= 2 else ""
        rx_disp = f'{o["rx_dbm"]:.2f}' if o["rx_dbm"] is not None else "—"
        tx_disp = f'{o["tx_dbm"]:.2f}' if o["tx_dbm"] is not None else "—"
        tp_disp = f'{o["temp_c"]:.1f}' if o["temp_c"] is not None else "—"
        bi_disp = f'{o["bias_ma"]:.2f}' if o["bias_ma"] is not None else "—"
        badge_rx = f'<span class="badge b-{cls}">{label}</span>'
        badge_tx = f'<span class="badge b-{tx_cls}">Tx {tx_label}</span>' if tx_cls != "ok" else ""
        parts.append(
            f'<tr class="{row_class}" data-status="{cls}">'
            f'<td>{html.escape(o["olt"])}</td>'
            f'<td class="num">0/{o["pon"]}</td>'
            f'<td class="num">{o["onu_id"]}</td>'
            f'<td><small class="mono">{html.escape(o["sn"])}</small></td>'
            f'<td>{html.escape(o["phase"])}</td>'
            f'<td class="num" data-sort="{o["rx_dbm"] if o["rx_dbm"] is not None else 0}">{rx_disp}{sp}</td>'
            f'<td class="num" data-sort="{o["tx_dbm"] if o["tx_dbm"] is not None else 0}">{tx_disp}</td>'
            f'<td class="num" data-sort="{o["temp_c"] if o["temp_c"] is not None else 0}">{tp_disp}</td>'
            f'<td class="num" data-sort="{o["bias_ma"] if o["bias_ma"] is not None else 0}">{bi_disp}</td>'
            f'<td>{badge_rx} {badge_tx}</td></tr>')
    parts.append("</tbody></table></div>")

    # SFP per OLT/PON (moved AFTER the main ONU table)
    parts.append('<div class="section"><h2>OLT-side: SFP por puerto PON '
                 '<small style="color:var(--mut);font-weight:400">(potencia óptica del OLT, no por cliente)</small></h2>')
    parts.append('<table class="sortable"><thead><tr>'
                 '<th>OLT</th><th>PON</th><th>Temp (°C)</th><th>Voltaje (V)</th>'
                 '<th>TxBias (mA)</th><th>TxPower (dBm)</th></tr></thead><tbody>')
    for r in sfp:
        parts.append(
            f'<tr><td>{html.escape(r["olt"])}</td>'
            f'<td class="num">0/{r["pon"]}</td>'
            f'<td class="num" data-sort="{r["temperature"] or 0}">{r["temperature"] or "—"}</td>'
            f'<td class="num" data-sort="{r["voltage"] or 0}">{r["voltage"] or "—"}</td>'
            f'<td class="num" data-sort="{r["txbias_ma"] or 0}">{r["txbias_ma"] or "—"}</td>'
            f'<td class="num" data-sort="{r["txpower_dbm"] or 0}">{r["txpower_dbm"] or "—"}</td></tr>')
    parts.append("</tbody></table></div>")

    # Snapshot info
    parts.append('<div class="section"><h2>Últimos snapshots por OLT</h2>')
    parts.append('<table><thead><tr><th>OLT</th><th>Cuando (UTC)</th><th>Snapshot ID</th><th>Duración</th><th>Estado</th></tr></thead><tbody>')
    for r in conn.execute(
        "SELECT olt, ts_utc, id, duration_ms, ok, error FROM snapshot "
        "WHERE id IN (" + ",".join("?" for _ in snap_ids) + ") ORDER BY olt", snap_ids):
        parts.append(
            f'<tr><td>{html.escape(r["olt"])}</td>'
            f'<td>{html.escape(r["ts_utc"])}</td>'
            f'<td>{r["id"]}</td>'
            f'<td>{r["duration_ms"]/1000:.1f}s</td>'
            f'<td>{"OK" if r["ok"] else html.escape(r["error"] or "FAIL")}</td></tr>')
    parts.append("</tbody></table></div>")

    parts.append("</main>")
    parts.append(HTML_JS)

    out = REPORTS_DIR / "latest.html"
    out.write_text("".join(parts), encoding="utf-8")
    print(f"Reporte: {out}")
    return 0


# ----------------------------- maintenance -----------------------------

def cmd_run(args):
    rc = cmd_collect(args)
    cmd_report(args)
    return rc


def cmd_purge(args):
    conn = db()
    cutoff = (datetime.now(timezone.utc) - timedelta(days=args.days)).isoformat(timespec="seconds")
    cur = conn.cursor()
    cur.execute("DELETE FROM onu WHERE snapshot_id IN (SELECT id FROM snapshot WHERE ts_utc < ?)", (cutoff,))
    cur.execute("DELETE FROM pon_sfp WHERE snapshot_id IN (SELECT id FROM snapshot WHERE ts_utc < ?)", (cutoff,))
    cur.execute("DELETE FROM snapshot WHERE ts_utc < ?", (cutoff,))
    conn.commit()
    print(f"Purged snapshots older than {cutoff}")
    return 0


def cmd_serve(args):
    """Serve reports/ over HTTP. Index redirects to latest.html."""
    import http.server, socketserver, functools, webbrowser, threading, base64, hmac
    host = args.host
    port = args.port

    auth_value = args.auth if args.auth is not None else os.environ.get("OLT_MONITOR_AUTH")
    expected_auth = None
    auth_user = None
    if auth_value:
        if ":" not in auth_value:
            print("ERROR: --auth must be in USER:PASS format", file=sys.stderr)
            return 2
        auth_user = auth_value.split(":", 1)[0]
        expected_auth = "Basic " + base64.b64encode(auth_value.encode("utf-8")).decode("ascii")

    class Handler(http.server.SimpleHTTPRequestHandler):
        def _check_auth(self):
            if expected_auth is None:
                return True
            received = self.headers.get("Authorization", "")
            if hmac.compare_digest(expected_auth, received):
                return True
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="olt-monitor"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        def do_GET(self):
            if not self._check_auth():
                return
            if self.path in ("/", "/index.html"):
                self.send_response(302)
                self.send_header("Location", "/latest.html")
                self.end_headers()
                return
            return super().do_GET()
        def do_HEAD(self):
            if not self._check_auth():
                return
            return super().do_HEAD()
        def log_message(self, fmt, *a):
            # quieter than default
            sys.stderr.write(f"[{self.log_date_time_string()}] {fmt % a}\n")

    handler = functools.partial(Handler, directory=str(REPORTS_DIR))
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer((host, port), handler) as httpd:
        bind_url = f"http://{'localhost' if host in ('127.0.0.1','localhost') else host}:{port}/"
        print(f"Serving {REPORTS_DIR} at {bind_url}")
        if expected_auth is not None:
            print(f"Auth: BASIC (user={auth_user})")
        else:
            print("Auth: DISABLED")
            if host == "0.0.0.0":
                sys.stderr.write("WARNING: serving without auth on 0.0.0.0 — accessible from the network.\n")
        print(f"(latest.html auto-refreshes every 60s; Ctrl+C para salir)")
        if args.open_browser:
            threading.Timer(0.5, lambda: webbrowser.open(bind_url)).start()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nbye"); return 0
    return 0


def cmd_list_snaps(_args):
    conn = db()
    rows = conn.execute(
        "SELECT id, ts_utc, olt, duration_ms, ok, error "
        "FROM snapshot ORDER BY id DESC LIMIT 20")
    print(f"{'id':>5} {'ts_utc':<27} {'olt':<20} {'ms':>6}  ok  err")
    for r in rows:
        print(f"{r['id']:>5} {r['ts_utc']:<27} {r['olt']:<20} {r['duration_ms'] or 0:>6}  {r['ok']:>2}  {r['error'] or ''}")
    return 0


# ----------------------------- main -----------------------------

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("collect")
    sub.add_parser("report")
    sub.add_parser("run")
    p = sub.add_parser("purge"); p.add_argument("--days", type=int, default=30)
    sub.add_parser("list-snaps")
    p = sub.add_parser("serve")
    p.add_argument("--host", default="127.0.0.1",
                   help="Bind address. Use 0.0.0.0 para exponer al LAN (sin auth).")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--open-browser", action="store_true",
                   help="Abrir el navegador automáticamente.")
    p.add_argument("--auth", default=None,
                   help="HTTP Basic auth credentials in USER:PASS format. "
                        "If not provided, falls back to the OLT_MONITOR_AUTH "
                        "environment variable (useful for systemd EnvironmentFile). "
                        "If neither is set, the server runs without authentication.")
    args = ap.parse_args()
    return {"collect": cmd_collect, "report": cmd_report, "run": cmd_run,
            "purge": cmd_purge, "list-snaps": cmd_list_snaps,
            "serve": cmd_serve}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
