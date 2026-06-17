#!/usr/bin/env python3
"""
unbound-log-exporter
Lee los logs de consultas DNS de Unbound desde journald y exporta
métricas Prometheus por IP de origen, dominio destino y pares IP→dominio.

Puerto por defecto: 9169 (en 127.0.0.1)
Uso: python3 unbound-log-exporter.py [host:port]

Requiere en unbound.conf:
    verbosity: 1
    log-queries: yes
"""
import re
import subprocess
import sys
from collections import defaultdict
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread, Lock

# Formato de log de Unbound con log-queries: yes
# Ejemplo: [1234:0] info: 192.168.1.1@54321 google.com. A IN
LOG_RE = re.compile(
    r'\binfo:\s+([^\s@#/\\]+?)(?:@\d+)?\s+([\w.\-]+\.?)\s+(\S+)\s+IN\s*$'
)

_lock = Lock()
_state = {
    'clients': defaultdict(int),   # {ip: count}
    'domains': defaultdict(int),   # {(domain, qtype): count}
    'pairs':   defaultdict(int),   # {(ip, domain, qtype): count}
    'n':       0,
}


def _prune(d, keep):
    return defaultdict(int, dict(sorted(d.items(), key=lambda x: -x[1])[:keep]))


def _tail_logs():
    proc = subprocess.Popen(
        ['journalctl', '-fu', 'unbound', '--output=cat', '--no-pager'],
        stdout=subprocess.PIPE, text=True, bufsize=1
    )
    for line in proc.stdout:
        m = LOG_RE.search(line)
        if not m:
            continue
        ip, domain, qtype = m.groups()
        domain = domain.rstrip('.')
        with _lock:
            _state['clients'][ip] += 1
            _state['domains'][(domain, qtype)] += 1
            _state['pairs'][(ip, domain, qtype)] += 1
            _state['n'] += 1
            if _state['n'] % 50_000 == 0:
                _state['clients'] = _prune(_state['clients'], 200)
                _state['domains'] = _prune(_state['domains'], 500)
                _state['pairs']   = _prune(_state['pairs'],   2_000)


def _metrics():
    lines = []
    with _lock:
        lines += [
            '# HELP unbound_client_queries_total Consultas DNS acumuladas por IP de origen',
            '# TYPE unbound_client_queries_total counter',
        ]
        for ip, n in sorted(_state['clients'].items(), key=lambda x: -x[1])[:100]:
            lines.append(f'unbound_client_queries_total{{client_ip="{ip}"}} {n}')

        lines += [
            '# HELP unbound_domain_queries_total Consultas DNS acumuladas por dominio destino',
            '# TYPE unbound_domain_queries_total counter',
        ]
        for (dom, qt), n in sorted(_state['domains'].items(), key=lambda x: -x[1])[:200]:
            lines.append(f'unbound_domain_queries_total{{domain="{dom}",qtype="{qt}"}} {n}')

        lines += [
            '# HELP unbound_client_domain_queries_total Consultas DNS por IP de origen y dominio destino',
            '# TYPE unbound_client_domain_queries_total counter',
        ]
        for (ip, dom, qt), n in sorted(_state['pairs'].items(), key=lambda x: -x[1])[:500]:
            lines.append(
                f'unbound_client_domain_queries_total{{'
                f'client_ip="{ip}",domain="{dom}",qtype="{qt}"}} {n}'
            )

    return '\n'.join(lines) + '\n'


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ('/', '/metrics'):
            self.send_response(404)
            self.end_headers()
            return
        body = _metrics().encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; version=0.0.4; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    listen = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1:9169'
    host, port = listen.rsplit(':', 1)
    Thread(target=_tail_logs, daemon=True).start()
    print(f'unbound-log-exporter escuchando en {listen}', flush=True)
    HTTPServer((host, int(port)), _Handler).serve_forever()
