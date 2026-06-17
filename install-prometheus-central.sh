#!/bin/bash
# ==============================================================================
# Prometheus CENTRAL — Instalador para flota de servidores DNS
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Ejecutar como root: sudo bash $0"

# ==============================================================================
# VARIABLES
# ==============================================================================
MGMT_NETWORKS=(
    "205.235.2.173/32"    # Grafana
    "205.235.6.128/25"    # Red administración
    "10.99.99.0/25"       # Red privada VPN
    "205.235.2.128/26"    # Red usuarios/servicios internos
)

SSH_ALLOWED_NETWORKS=(
    "205.235.6.128/25"    # Red administración
    "10.99.99.0/25"       # Red privada VPN
)

PROMETHEUS_PORT=9090
PROMETHEUS_RETENTION="30d"
SCRAPE_INTERVAL="15s"
UNBOUND_EXPORTER_PORT=9167
NODE_EXPORTER_PORT=9100
TARGETS_DIR="/etc/prometheus/targets"
FLEET_FILE="${TARGETS_DIR}/dns-fleet.yml"

# ==============================================================================
# BANNER
# ==============================================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Prometheus CENTRAL — Flota DNS                   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
info "Sistema:  $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
info "RAM:      $(free -h | awk '/Mem/{print $2}')"
info "Disco /:  $(df -h / | awk 'NR==2{print $4}') libres"
info "IP:       $(hostname -I | awk '{print $1}')"
echo ""

DISK_FREE_GB=$(df --output=avail -BG / | awk 'NR==2{gsub("G",""); print $1}')
if [[ "${DISK_FREE_GB:-0}" -lt 60 ]]; then
    warn "Menos de 60GB libres en /. Con 30+ servidores y retención ${PROMETHEUS_RETENTION},"
    warn "el TSDB puede llenar el disco. Ampliar el disco o reducir la retención."
fi

# ==============================================================================
# 1. INSTALACIÓN
# ==============================================================================
log "Instalando Prometheus y UFW..."
apt-get update -qq
apt-get install -y -qq prometheus curl ufw

# ==============================================================================
# 2. CONFIGURACIÓN — file_sd para la flota
# ==============================================================================
log "Escribiendo configuración..."

mkdir -p "$TARGETS_DIR"

[[ -f /etc/prometheus/prometheus.yml ]] && \
    cp /etc/prometheus/prometheus.yml \
       /etc/prometheus/prometheus.yml.bak.$(date +%Y%m%d%H%M%S)

cat > /etc/prometheus/prometheus.yml << EOF
# ==============================================================================
# Prometheus central — flota de servidores DNS
# Targets de la flota: ${FLEET_FILE} (se recarga solo, sin reiniciar)
# ==============================================================================
global:
  scrape_interval: ${SCRAPE_INTERVAL}
  evaluation_interval: ${SCRAPE_INTERVAL}

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['127.0.0.1:${PROMETHEUS_PORT}']

  - job_name: 'unbound'
    file_sd_configs:
      - files: ['${TARGETS_DIR}/dns-fleet.yml']
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+)'
        replacement: '\${1}:${UNBOUND_EXPORTER_PORT}'
        target_label: __address__

  - job_name: 'node_dns'
    file_sd_configs:
      - files: ['${TARGETS_DIR}/dns-fleet.yml']
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+)'
        replacement: '\${1}:${NODE_EXPORTER_PORT}'
        target_label: __address__
EOF

if [[ ! -f "$FLEET_FILE" ]]; then
    cat > "$FLEET_FILE" << 'FLEET'
# ==============================================================================
# Flota de servidores DNS — un bloque por servidor
# La IP va SIN puerto: los jobs 'unbound' y 'node_dns' añaden 9167/9100 solos.
# Agregar/quitar servidores aquí; Prometheus recarga en <30s sin reiniciar.
# Helper: dns-target add <nombre> <pop> <ip>
# ==============================================================================
# - targets: ['10.0.53.10']
#   labels:
#     server: 'dns-quevedo-1'
#     pop: 'quevedo'
#
# - targets: ['10.0.53.11']
#   labels:
#     server: 'dns-babahoyo-1'
#     pop: 'babahoyo'
FLEET
fi

chown -R prometheus:prometheus "$TARGETS_DIR"

promtool check config /etc/prometheus/prometheus.yml >/dev/null || \
    err "prometheus.yml inválido — revisar antes de continuar."

cat > /etc/default/prometheus << EOF
ARGS="--web.listen-address=[::]:${PROMETHEUS_PORT} --storage.tsdb.retention.time=${PROMETHEUS_RETENTION}"
EOF

# ==============================================================================
# 3. HELPER dns-target
# ==============================================================================
log "Instalando helper /usr/local/bin/dns-target..."
cat > /usr/local/bin/dns-target << 'HELPER'
#!/bin/bash
set -euo pipefail
FLEET="/etc/prometheus/targets/dns-fleet.yml"
case "${1:-}" in
  add)
    [[ $# -ne 4 ]] && { echo "Uso: dns-target add <nombre> <pop> <ip>"; exit 1; }
    NAME=$2; POP=$3; IP=$4
    grep -q "'$IP'" "$FLEET" && { echo "[x] $IP ya está en la flota."; exit 1; }
    printf '\n- targets: ['"'"'%s'"'"']\n  labels:\n    server: '"'"'%s'"'"'\n    pop: '"'"'%s'"'"'\n' \
        "$IP" "$NAME" "$POP" >> "$FLEET"
    echo "[+] $NAME ($POP, $IP) agregado. Prometheus lo recoge en <30s."
    ;;
  list)
    grep -E "targets:|server:|pop:" "$FLEET" | grep -v '^#' || echo "(flota vacía)"
    ;;
  *)
    echo "Uso: dns-target {add <nombre> <pop> <ip> | list}"
    exit 1
    ;;
esac
HELPER
chmod +x /usr/local/bin/dns-target

# ==============================================================================
# 4. ARRANQUE
# ==============================================================================
log "Iniciando Prometheus..."
systemctl enable prometheus
systemctl restart prometheus
sleep 3
systemctl is-active --quiet prometheus || \
    err "Prometheus no arrancó. Revisar: journalctl -u prometheus -n 30"
log "Prometheus activo en :${PROMETHEUS_PORT} (retención ${PROMETHEUS_RETENTION})."

# ==============================================================================
# 5. FIREWALL — UFW con SSH y Prometheus restringidos
# ==============================================================================
log "Configurando UFW..."

# Habilitar IPv6
sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw 2>/dev/null || true

# Reset limpio y políticas por defecto
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH solo desde redes autorizadas (agregar ANTES de enable para no perder acceso)
for net in "${SSH_ALLOWED_NETWORKS[@]}"; do
    ufw allow proto tcp from "$net" to any port 22 comment "SSH mgmt"
done

# Prometheus :9090 solo desde redes de gestión
for net in "${MGMT_NETWORKS[@]}"; do
    ufw allow proto tcp from "$net" to any port "${PROMETHEUS_PORT}" comment "Prometheus API"
done

# Activar sin prompt interactivo
ufw --force enable
log "UFW activo."
ufw status numbered

# ==============================================================================
# 6. VALIDACIÓN
# ==============================================================================
echo ""
log "Ejecutando validaciones..."
PASS=0; FAIL=0
check() {
    local desc=$1; shift
    if eval "$@" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ${desc}"; PASS=$((PASS+1))
    else
        echo -e "  ${RED}✗${NC} ${desc}"; FAIL=$((FAIL+1))
    fi
}

check "Prometheus healthy" \
    "curl -s --max-time 5 http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy | grep -qi 'healthy'"
check "Config válida (promtool)" \
    "promtool check config /etc/prometheus/prometheus.yml"
check "Fleet file legible por prometheus" \
    "sudo -u prometheus test -r ${FLEET_FILE}"
check "API de targets responde" \
    "curl -s --max-time 5 http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/targets | grep -c 'activeTargets'"
check "Helper dns-target instalado" \
    "command -v dns-target"
check "UFW activo" \
    "ufw status | grep -q 'Status: active'"
check "SSH bloqueado por defecto (puerto no abierto globalmente)" \
    "! ufw status | grep -E '^22.*ALLOW.*Anywhere$'"

# ==============================================================================
# 7. RESUMEN
# ==============================================================================
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           PROMETHEUS CENTRAL LISTO                  ║${NC}"
echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
printf "${BLUE}║${NC}  Tests: ${GREEN}%d OK${NC} / ${RED}%d FAIL${NC}\n" "$PASS" "$FAIL"
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  Web/API:    http://${SERVER_IP}:${PROMETHEUS_PORT}  (solo MGMT_NETWORKS)"
echo -e "${BLUE}║${NC}  Retención:  ${PROMETHEUS_RETENTION}"
echo -e "${BLUE}║${NC}  Flota:      ${FLEET_FILE}"
echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║${NC}  SSH permitido desde:"
for net in "${SSH_ALLOWED_NETWORKS[@]}"; do
    echo -e "${BLUE}║${NC}    - ${net}"
done
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  SIGUIENTES PASOS:"
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  1. En cada servidor DNS (instalador de Unbound):"
echo -e "${BLUE}║${NC}       INSTALL_PROMETHEUS=false"
echo -e "${BLUE}║${NC}       CENTRAL_PROMETHEUS_IPS=(\"${SERVER_IP}\")"
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  2. Dar de alta cada servidor aquí:"
echo -e "${BLUE}║${NC}       dns-target add dns-quevedo-1 quevedo 10.0.53.10"
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  3. En Grafana (otro servidor), datasource Prometheus:"
echo -e "${BLUE}║${NC}       URL: http://${SERVER_IP}:${PROMETHEUS_PORT}"
echo -e "${BLUE}║${NC}     (verificar que la IP de Grafana esté en MGMT_NETWORKS)"
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  Vista de flota en Grafana: query  up{job=\"unbound\"}"
echo -e "${BLUE}║${NC}  Dashboard detalle (importar ID): 11705"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

[[ $FAIL -gt 0 ]] && warn "Revisar los tests fallidos antes de dar de alta la flota."
exit 0
