#!/bin/bash
# ==============================================================================
# Unbound DNS — Instalador Universal para VPS / ISP
# Compatible: Debian 12/13, Ubuntu 22.04/24.04
#
# Qué instala:
#   - Unbound 1.22+ recursivo puro (DNSSEC, RFC 5011/8145/8198)
#   - DoT (853) y DoH (8053) con cert Let's Encrypt automático
#   - Query logging → /var/log/unbound/queries.log (90 días)
#   - Prometheus + node_exporter + unbound_exporter + log_exporter
#   - UFW firewall (DNS solo a CLIENT_NETWORKS, SSH abierto)
#   - Swap 2GB, kernel tuning, journald cap
# ==============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Colores ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
ask()  { echo -e "${CYAN}${BOLD}→${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Ejecutar como root: sudo bash $0"

# ── Variables (se llenan por menú o por valores hardcodeados) ──────────────────
CLIENT_NETWORKS=()
DOT_DOMAIN=""

# ==============================================================================
# MENÚ INTERACTIVO
# ==============================================================================

# Valida IPv4/IPv6 individual o CIDR
validate_network() {
    local input="$1"
    # IPv4 con CIDR opcional
    if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
        local IFS='.'; read -ra octets <<< "${input%%/*}"
        for oct in "${octets[@]}"; do [[ "$oct" -gt 255 ]] && return 1; done
        return 0
    fi
    # IPv6 con CIDR opcional (simplificado)
    if [[ "$input" =~ ^[0-9a-fA-F:]+(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$ ]]; then
        return 0
    fi
    return 1
}

# Normaliza IP sin CIDR → agrega /32 (IPv4) o /128 (IPv6)
normalize_network() {
    local input="$1"
    if [[ "$input" != *"/"* ]]; then
        if [[ "$input" == *":"* ]]; then echo "${input}/128"
        else echo "${input}/32"; fi
    else
        echo "$input"
    fi
}

interactive_menu() {
    local SERVER_IP; SERVER_IP=$(hostname -I | awk '{print $1}')
    local RAM_MB; RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)

    clear
    echo ""
    echo -e "${BLUE}${BOLD}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║         Unbound DNS ISP — Instalador Interactivo          ║${NC}"
    echo -e "${BLUE}${BOLD}╠═══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}${BOLD}║${NC}  Servidor: ${BOLD}${SERVER_IP}${NC}   RAM: ${RAM_MB}MB   CPU: $(nproc) vCPU"
    echo -e "${BLUE}${BOLD}║${NC}  Sistema:  $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')"
    echo -e "${BLUE}${BOLD}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # ── PASO 1: Redes de clientes ───────────────────────────────────────────────
    echo -e "${BOLD}[1/2] REDES CON ACCESO AL DNS${NC}"
    echo -e "      Ingresa las IPs o rangos que podrán consultar este servidor."
    echo -e "      Formatos válidos:  ${CYAN}203.0.113.0/24${NC}  •  ${CYAN}1.2.3.4${NC}  •  ${CYAN}2803:2540::/32${NC}"
    echo -e "      Escribe ${CYAN}todos${NC} para acceso público (0.0.0.0/0)."
    echo -e "      Escribe ${CYAN}listo${NC} cuando termines (mínimo 1 entrada)."
    echo ""

    while true; do
        ask "Red o IP (o 'todos' / 'listo'): "
        read -r input
        input=$(echo "$input" | tr '[:upper:]' '[:lower:]' | xargs)

        case "$input" in
            todos|all|"0.0.0.0/0")
                CLIENT_NETWORKS=("0.0.0.0/0")
                ok "Acceso público habilitado (0.0.0.0/0)"
                break
                ;;
            listo|done|"")
                if [[ ${#CLIENT_NETWORKS[@]} -eq 0 ]]; then
                    warn "Debes ingresar al menos una red."
                    continue
                fi
                break
                ;;
            *)
                local net; net=$(normalize_network "$input")
                if validate_network "$net"; then
                    # Evitar duplicados
                    local dup=false
                    for existing in "${CLIENT_NETWORKS[@]}"; do
                        [[ "$existing" == "$net" ]] && dup=true && break
                    done
                    if [[ "$dup" == true ]]; then
                        warn "  ${net} ya está en la lista."
                    else
                        CLIENT_NETWORKS+=("$net")
                        ok "Agregado: ${net}"
                    fi
                else
                    warn "  '${input}' no es una IP o CIDR válido. Ejemplos: 192.168.1.0/24  10.0.0.1"
                fi
                ;;
        esac
    done

    echo ""
    echo -e "  Redes configuradas:"
    for net in "${CLIENT_NETWORKS[@]}"; do
        echo -e "    ${CYAN}•${NC} $net"
    done
    echo ""

    # ── PASO 2: Dominio DoH/DoT ─────────────────────────────────────────────────
    echo -e "${BOLD}[2/2] DOMINIO PARA DoH / DoT  (DNS-over-HTTPS / DNS-over-TLS)${NC}"
    echo -e "      Requisito: el dominio debe tener un registro ${CYAN}A → ${SERVER_IP}${NC}"
    echo -e "      El instalador obtiene el certificado Let's Encrypt automáticamente."
    echo ""
    ask "Dominio (ej: dns.tuempresa.com) [Enter = sin DoH]: "
    read -r input
    input=$(echo "$input" | xargs)

    if [[ -n "$input" ]]; then
        # Validar que sea un dominio (no IP, contiene punto, sin espacios ni /)
        if [[ "$input" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
            DOT_DOMAIN="$input"
            ok "DoH/DoT habilitado → ${CYAN}https://${DOT_DOMAIN}:8053/dns-query${NC}"
        else
            warn "Dominio inválido ('${input}'). DoH/DoT deshabilitado."
        fi
    else
        info "DoH/DoT deshabilitado."
    fi
    echo ""

    # ── RESUMEN Y CONFIRMACIÓN ──────────────────────────────────────────────────
    echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  RESUMEN DE INSTALACIÓN${NC}"
    echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"
    echo -e "  Servidor:         ${BOLD}${SERVER_IP}${NC}"
    echo -e "  Redes permitidas: ${CYAN}$(IFS=', '; echo "${CLIENT_NETWORKS[*]}")${NC}"
    if [[ -n "$DOT_DOMAIN" ]]; then
        echo -e "  DoH/DoT:          ${CYAN}${DOT_DOMAIN}${NC} (cert Let's Encrypt automático)"
    else
        echo -e "  DoH/DoT:          deshabilitado"
    fi
    echo -e "  RAM:              ${RAM_MB}MB  •  Cache: $(( RAM_MB/16 ))m msg + $(( RAM_MB/8 ))m rrset"
    echo -e "  DNSSEC:           RFC 5011 + RFC 8198 (ICANN compliant)"
    echo -e "  Prometheus:       ${CYAN}http://${SERVER_IP}:9090${NC}"
    echo -e "  Logs DNS:         /var/log/unbound/queries.log (90 días)"
    echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"
    echo ""
    ask "¿Iniciar instalación? [S/n]: "
    read -r input
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]' | xargs)
    [[ "$input" == "n" || "$input" == "no" ]] && { echo "Instalación cancelada."; exit 0; }
    echo ""
}

# Ejecutar menú solo si hay terminal interactiva
if [[ -t 0 ]]; then
    interactive_menu
else
    # Modo no-interactivo: CLIENT_NETWORKS debe estar configurado arriba
    [[ ${#CLIENT_NETWORKS[@]} -eq 0 ]] && \
        err "Sin terminal interactiva y CLIENT_NETWORKS vacío. Edita el script o ejecútalo con una TTY."
fi

# ==============================================================================
# AUTO-DETECCIÓN
# ==============================================================================
NUM_THREADS=$(nproc)
NUM_SLABS=1
while [[ $NUM_SLABS -lt $NUM_THREADS ]]; do NUM_SLABS=$((NUM_SLABS * 2)); done

RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
_M=$(( RAM_MB / 16 )); (( _M < 32  )) && _M=32;  (( _M > 512  )) && _M=512;  MSG_CACHE_SIZE="${_M}m"
_R=$(( RAM_MB / 8  )); (( _R < 64  )) && _R=64;  (( _R > 1024 )) && _R=1024; RRSET_CACHE_SIZE="${_R}m"

SERVER_IP=$(hostname -I | awk '{print $1}')

HAS_V6=false
if ip -6 addr show scope global 2>/dev/null | grep -q inet6 && \
   ip -6 route show default 2>/dev/null | grep -qE 'via|dev'; then
    HAS_V6=true
fi
DO_IP6="no"; V6_LISTEN=""
if [[ "$HAS_V6" == true ]]; then
    DO_IP6="yes"; V6_LISTEN="    interface: ::0"
    info "IPv6 detectado — habilitado."
else
    info "Sin IPv6 global — modo solo-v4."
fi

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
EXPORTER_PORT=9167
LOG_EXPORTER_PORT=9169
PROMETHEUS_PORT=9090
EXPORTER_FALLBACK_TAG="v0.6.0"
NODE_EXPORTER_VERSION="1.8.2"

# ==============================================================================
# BANNER DE INSTALACIÓN
# ==============================================================================
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║        Unbound DNS ISP — Instalando...                    ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
info "IP: ${SERVER_IP}  •  vCPU: ${NUM_THREADS}  •  RAM: ${RAM_MB}MB  •  IPv6: ${DO_IP6}"
info "Cache: ${MSG_CACHE_SIZE} msg + ${RRSET_CACHE_SIZE} rrset  •  DoH: ${DOT_DOMAIN:-no}"
echo ""

# ==============================================================================
# 0. UFW — firewall primero
# ==============================================================================
if ! command -v ufw &>/dev/null; then
    log "Instalando UFW..."
    apt-get update -qq
    apt-get install -y -qq ufw
fi
if ! ufw status | grep -q "Status: active"; then
    log "Activando UFW (SSH abierto, resto deny)..."
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 22/tcp comment "SSH" >/dev/null
    ufw --force enable >/dev/null
    log "UFW activo."
else
    info "UFW ya activo."
fi

# ==============================================================================
# 1. DEPENDENCIAS
# ==============================================================================
log "Instalando Unbound y dependencias..."
apt-get update -qq
apt-get install -y -qq unbound unbound-anchor dnsutils curl wget rsyslog

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    warn "Deshabilitando systemd-resolved (conflicto puerto 53)..."
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
fi

# ==============================================================================
# 2. DNSSEC — Trust Anchor
# ==============================================================================
log "Configurando DNSSEC trust anchor..."
mkdir -p /var/lib/unbound
unbound-anchor -a /var/lib/unbound/root.key 2>/dev/null || true
if [[ ! -s /var/lib/unbound/root.key ]]; then
    if [[ -f /usr/share/dns/root.key ]]; then
        cp /usr/share/dns/root.key /var/lib/unbound/root.key
    else
        apt-get install -y -qq dns-root-data
        [[ -f /usr/share/dns/root.key ]] && cp /usr/share/dns/root.key /var/lib/unbound/root.key
    fi
fi
[[ -s /var/lib/unbound/root.key ]] || err "No se pudo crear /var/lib/unbound/root.key"
chown -R unbound:unbound /var/lib/unbound

# ==============================================================================
# 2b. KERNEL TUNING
# ==============================================================================
log "Aplicando tuning de kernel..."
cat > /etc/sysctl.d/99-unbound.conf << 'SYSCTL'
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.core.rmem_default=262144
net.core.wmem_default=262144
net.core.netdev_max_backlog=5000
vm.swappiness=10
SYSCTL
sysctl -p /etc/sysctl.d/99-unbound.conf -q

# ==============================================================================
# 2c. SWAP — protección OOM
# ==============================================================================
if ! swapon --show | grep -q '.'; then
    log "Creando swap 2GB..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
    info "Swap ya presente."
fi

# ==============================================================================
# 2d. JOURNALD + SYSTEMD LIMITS
# ==============================================================================
if ! grep -q 'SystemMaxUse' /etc/systemd/journald.conf; then
    printf '\nSystemMaxUse=500M\nRuntimeMaxUse=100M\n' >> /etc/systemd/journald.conf
    systemctl restart systemd-journald
fi

mkdir -p /etc/systemd/system/unbound.service.d
cat > /etc/systemd/system/unbound.service.d/limits.conf << 'DROPIN'
[Service]
LimitNOFILE=65536
DROPIN
systemctl daemon-reload

# ==============================================================================
# 3. CONFIGURACIÓN UNBOUND
# ==============================================================================
log "Escribiendo /etc/unbound/unbound.conf..."
[[ -f /etc/unbound/unbound.conf ]] && \
    cp /etc/unbound/unbound.conf "/etc/unbound/unbound.conf.bak.$(date +%Y%m%d%H%M%S)"

ACL_BLOCK="    access-control: 0.0.0.0/0 deny\n"
ACL_BLOCK+="    access-control: ::0/0 deny\n"
ACL_BLOCK+="    access-control: 127.0.0.0/8 allow\n"
ACL_BLOCK+="    access-control: ::1/128 allow\n"
for net in "${CLIENT_NETWORKS[@]}"; do
    if [[ "$net" == *":"* ]]; then
        ACL_BLOCK+="    access-control: ${net} allow\n"
    else
        ACL_BLOCK+="    access-control: ${net} allow\n"
    fi
done

cat > /etc/unbound/unbound.conf << CONF
# Unbound DNS — generado por install-unbound-isp.sh
# $(date)

server:

    # ── Red ────────────────────────────────────────────────────────────────────
    interface: 0.0.0.0
${V6_LISTEN}
    port: 53
    do-udp: yes
    do-tcp: yes
    do-ip4: yes
    do-ip6: ${DO_IP6}
    so-reuseport: yes
    edns-buffer-size: 1232

    # ── Performance ────────────────────────────────────────────────────────────
    num-threads: ${NUM_THREADS}
    so-rcvbuf: 8m
    so-sndbuf: 8m
    outgoing-range: 8192
    num-queries-per-thread: 4096
    jostle-timeout: 200
    minimal-responses: yes
    msg-cache-slabs: ${NUM_SLABS}
    rrset-cache-slabs: ${NUM_SLABS}
    infra-cache-slabs: ${NUM_SLABS}
    key-cache-slabs: ${NUM_SLABS}

    # ── Módulos ────────────────────────────────────────────────────────────────
    module-config: "validator iterator"

    # ── Caché ──────────────────────────────────────────────────────────────────
    msg-cache-size: ${MSG_CACHE_SIZE}
    rrset-cache-size: ${RRSET_CACHE_SIZE}
    neg-cache-size: 4m
    infra-cache-numhosts: 100000
    prefetch: yes
    prefetch-key: yes
    target-fetch-policy: "3 2 1 0 0"
    cache-min-ttl: 120
    cache-max-ttl: 86400
    serve-expired: yes
    serve-expired-ttl: 86400
    serve-expired-reply-ttl: 30
    serve-expired-client-timeout: 300

    # ── DNSSEC ─────────────────────────────────────────────────────────────────
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    val-clean-additional: yes
    val-log-level: 1
    aggressive-nsec: yes
    add-holddown: 2592000
    del-holddown: 2592000
    keep-missing: 31622400
    harden-algo-downgrade: yes
    harden-referral-path: yes
    harden-large-queries: yes
    harden-short-bufsize: yes

    # ── Privacidad / Seguridad ─────────────────────────────────────────────────
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    qname-minimisation-strict: yes
    use-caps-for-id: yes
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10
    unwanted-reply-threshold: 10000
    ratelimit: 1000
    ratelimit-factor: 10
    ratelimit-backoff: yes
    ip-ratelimit: 0

    # ── Control de acceso ──────────────────────────────────────────────────────
$(printf "%b" "$ACL_BLOCK")
    # ── Logging ────────────────────────────────────────────────────────────────
    verbosity: 1
    log-queries: yes
    log-replies: no
    log-servfail: yes

    # ── Estadísticas ───────────────────────────────────────────────────────────
    statistics-interval: 0
    statistics-cumulative: yes
    extended-statistics: yes

remote-control:
    control-enable: yes
    control-interface: /run/unbound.ctl
CONF

# ==============================================================================
# 3b. DoT / DoH — cert Let's Encrypt automático
# ==============================================================================
if [[ -n "$DOT_DOMAIN" ]]; then
    log "Configurando DoT/DoH para ${DOT_DOMAIN}..."

    if ! command -v certbot &>/dev/null; then
        log "  Instalando certbot..."
        apt-get install -y -qq certbot
    fi

    CERT_LIVE="/etc/letsencrypt/live/${DOT_DOMAIN}"
    if [[ ! -d "$CERT_LIVE" ]]; then
        log "  Obteniendo certificado Let's Encrypt para ${DOT_DOMAIN}..."
        ufw allow 80/tcp comment "certbot-temp" >/dev/null 2>&1 || true
        if certbot certonly --standalone --non-interactive --agree-tos \
                --register-unsafely-without-email -d "$DOT_DOMAIN" 2>&1; then
            log "  Certificado obtenido."
        else
            warn "  certbot falló. Verificar que ${DOT_DOMAIN} apunte a ${SERVER_IP} y que el puerto 80 esté accesible."
            warn "  DoT/DoH deshabilitado — continuar sin él."
            DOT_DOMAIN=""
        fi
        ufw delete allow 80/tcp >/dev/null 2>&1 || true
    else
        log "  Certificado existente en ${CERT_LIVE}."
    fi

    if [[ -n "$DOT_DOMAIN" && -d "$CERT_LIVE" ]]; then
        mkdir -p /etc/unbound/tls
        cp -L "${CERT_LIVE}/fullchain.pem" /etc/unbound/tls/fullchain.pem
        cp -L "${CERT_LIVE}/privkey.pem"   /etc/unbound/tls/privkey.pem
        chown root:unbound /etc/unbound/tls/*.pem
        chmod 750 /etc/unbound/tls
        chmod 644 /etc/unbound/tls/fullchain.pem
        chmod 640 /etc/unbound/tls/privkey.pem

        cat >> /etc/unbound/unbound.conf << DOTCONF

# DoT (853) y DoH (8053)
server:
    interface: 0.0.0.0@853
    interface: 0.0.0.0@8053
    tls-port: 853
    https-port: 8053
    tls-service-key: "/etc/unbound/tls/privkey.pem"
    tls-service-pem: "/etc/unbound/tls/fullchain.pem"
DOTCONF

        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/reload-unbound.sh << HOOK
#!/bin/bash
DOMAIN="${DOT_DOMAIN}"
cp -L "/etc/letsencrypt/live/\${DOMAIN}/fullchain.pem" /etc/unbound/tls/fullchain.pem
cp -L "/etc/letsencrypt/live/\${DOMAIN}/privkey.pem"   /etc/unbound/tls/privkey.pem
chown root:unbound /etc/unbound/tls/*.pem
chmod 644 /etc/unbound/tls/fullchain.pem
chmod 640 /etc/unbound/tls/privkey.pem
systemctl reload unbound 2>/dev/null || systemctl restart unbound
logger -t certbot-unbound "Unbound TLS cert renovado para \${DOMAIN}"
HOOK
        chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-unbound.sh
        log "  DoT/DoH configurado + hook de renovación instalado."
    fi
else
    info "DoT/DoH deshabilitado."
fi

# ==============================================================================
# 4. INICIAR UNBOUND
# ==============================================================================
log "Validando y arrancando Unbound..."
unbound-checkconf /etc/unbound/unbound.conf || err "Config inválida — revisar arriba."

systemctl enable unbound
systemctl reset-failed unbound 2>/dev/null || true
systemctl restart unbound
sleep 3
systemctl is-active --quiet unbound || err "Unbound no arrancó. Ver: journalctl -u unbound -n 30"

dig @127.0.0.1 google.com A +short +time=5 &>/dev/null || \
    err "Unbound activo pero no resuelve. Ver: journalctl -u unbound -n 30"
log "Unbound activo y resolviendo."

# ==============================================================================
# 5. RESOLV.CONF
# ==============================================================================
[[ ! -f /etc/resolv.conf.pre-unbound ]] && \
    cat /etc/resolv.conf > /etc/resolv.conf.pre-unbound 2>/dev/null || true
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chattr +i /etc/resolv.conf
log "resolv.conf → 127.0.0.1 (protegido con chattr +i)."

# ==============================================================================
# 6. QUERY LOGGING via rsyslog
# ==============================================================================
log "Configurando query logging..."
mkdir -p /var/log/unbound
chown unbound:unbound /var/log/unbound

printf '%s\n' \
    '# Logs de Unbound → archivo dedicado' \
    ':programname, isequal, "unbound" /var/log/unbound/queries.log' \
    '& stop' \
    > /etc/rsyslog.d/10-unbound.conf

cat > /etc/logrotate.d/unbound-queries << 'LOGROTATECFG'
/var/log/unbound/queries.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0640 unbound unbound
    postrotate
        systemctl kill -s HUP rsyslog 2>/dev/null || true
    endscript
}
LOGROTATECFG

systemctl is-active --quiet rsyslog && systemctl restart rsyslog || \
    { systemctl enable --now rsyslog 2>/dev/null || true; }
log "  Logs: /var/log/unbound/queries.log (retención 90 días)"

# ==============================================================================
# 7. UNBOUND EXPORTER
# ==============================================================================
log "Instalando unbound_exporter..."
EXPORTER_INSTALLED=false

if [[ "$ARCH" == "amd64" ]]; then
    LATEST_TAG=$(curl -sf --max-time 10 -o /dev/null -w '%{redirect_url}' \
        "https://github.com/letsencrypt/unbound_exporter/releases/latest" 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' || true)
    [[ -z "$LATEST_TAG" ]] && LATEST_TAG="$EXPORTER_FALLBACK_TAG"
    EXPORTER_URL="https://github.com/letsencrypt/unbound_exporter/releases/download/${LATEST_TAG}/unbound_exporter-${LATEST_TAG}.x86_64.deb"
    if wget -q --timeout=20 "$EXPORTER_URL" -O /tmp/unbound_exporter.deb 2>/dev/null && \
       dpkg -i /tmp/unbound_exporter.deb &>/dev/null; then
        EXPORTER_INSTALLED=true
        log "unbound_exporter ${LATEST_TAG} instalado."
    fi
fi

if [[ "$EXPORTER_INSTALLED" == true ]]; then
    cat > /etc/systemd/system/unbound-exporter.service << SVC
[Unit]
Description=Unbound Prometheus Exporter
After=unbound.service
Wants=unbound.service

[Service]
ExecStart=/usr/bin/unbound_exporter \\
    -unbound.host "unix:///run/unbound.ctl" \\
    -unbound.ca "" \\
    -unbound.cert "" \\
    -unbound.key "" \\
    -web.listen-address "127.0.0.1:${EXPORTER_PORT}"
Restart=on-failure
RestartSec=5
User=unbound

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    systemctl enable unbound-exporter
    systemctl restart unbound-exporter
else
    warn "No se pudo instalar unbound_exporter (solo amd64 disponible)."
fi

# ==============================================================================
# 7b. NODE EXPORTER
# ==============================================================================
NODE_INSTALLED=false
if ! systemctl is-active --quiet node_exporter 2>/dev/null && \
   ! systemctl is-active --quiet node-exporter 2>/dev/null; then
    NE_ARCH="$ARCH"
    [[ "$ARCH" == "x86_64" ]] && NE_ARCH="amd64"
    if wget -q --timeout=30 \
        "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${NE_ARCH}.tar.gz" \
        -O /tmp/node_exporter.tar.gz 2>/dev/null && \
       tar -xzf /tmp/node_exporter.tar.gz -C /tmp/ 2>/dev/null; then
        mv "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${NE_ARCH}/node_exporter" /usr/local/bin/
        chmod +x /usr/local/bin/node_exporter
        cat > /etc/systemd/system/node-exporter.service << 'SVC2'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/node_exporter --web.listen-address="127.0.0.1:9100"
Restart=on-failure
DynamicUser=yes

[Install]
WantedBy=multi-user.target
SVC2
        systemctl daemon-reload
        systemctl enable node-exporter
        systemctl start node-exporter
        NODE_INSTALLED=true
        log "node_exporter instalado."
    else
        warn "No se pudo descargar node_exporter."
    fi
fi

# ==============================================================================
# 7c. LOG EXPORTER
# ==============================================================================
LOG_EXPORTER_BIN=/usr/local/bin/unbound-log-exporter.py
log "Instalando unbound-log-exporter..."
cat > "$LOG_EXPORTER_BIN" << 'PYEOF'
#!/usr/bin/env python3
import re, subprocess, sys
from collections import defaultdict
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread, Lock

LOG_RE = re.compile(r'info: ([\d.:a-fA-F]+?)(?:@\d+)? ([\w.\-]+\.?) (\w+) IN')
_lock = Lock()
_state = {'clients': defaultdict(int), 'domains': defaultdict(int), 'pairs': defaultdict(int), 'n': 0}

def _prune(d, keep):
    return defaultdict(int, dict(sorted(d.items(), key=lambda x: -x[1])[:keep]))

def _tail_logs():
    proc = subprocess.Popen(
        ['journalctl', '-fu', 'unbound', '--output=cat', '--no-pager'],
        stdout=subprocess.PIPE, text=True, bufsize=1)
    for line in proc.stdout:
        m = LOG_RE.search(line)
        if not m: continue
        ip, domain, qtype = m.groups()
        domain = domain.rstrip('.')
        with _lock:
            _state['clients'][ip] += 1
            _state['domains'][(domain, qtype)] += 1
            _state['pairs'][(ip, domain, qtype)] += 1
            _state['n'] += 1
            if _state['n'] % 50000 == 0:
                _state['clients'] = _prune(_state['clients'], 200)
                _state['domains'] = _prune(_state['domains'], 500)
                _state['pairs']   = _prune(_state['pairs'],   2000)

def _metrics():
    lines = []
    with _lock:
        lines += ['# HELP unbound_client_queries_total Consultas por IP cliente',
                  '# TYPE unbound_client_queries_total counter']
        for ip, n in sorted(_state['clients'].items(), key=lambda x: -x[1])[:100]:
            lines.append(f'unbound_client_queries_total{{client_ip="{ip}"}} {n}')
        lines += ['# HELP unbound_domain_queries_total Consultas por dominio',
                  '# TYPE unbound_domain_queries_total counter']
        for (dom, qt), n in sorted(_state['domains'].items(), key=lambda x: -x[1])[:200]:
            lines.append(f'unbound_domain_queries_total{{domain="{dom}",qtype="{qt}"}} {n}')
    return '\n'.join(lines) + '\n'

class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ('/', '/metrics'):
            self.send_response(404); self.end_headers(); return
        body = _metrics().encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; version=0.0.4; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass

if __name__ == '__main__':
    listen = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1:9169'
    host, port = listen.rsplit(':', 1)
    Thread(target=_tail_logs, daemon=True).start()
    print(f'unbound-log-exporter en {listen}', flush=True)
    HTTPServer((host, int(port)), _Handler).serve_forever()
PYEOF
chmod +x "$LOG_EXPORTER_BIN"

cat > /etc/systemd/system/unbound-log-exporter.service << SVC3
[Unit]
Description=Unbound Log Exporter (metricas por IP y dominio)
After=unbound.service

[Service]
ExecStart=/usr/bin/python3 ${LOG_EXPORTER_BIN} 127.0.0.1:${LOG_EXPORTER_PORT}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SVC3

systemctl daemon-reload
systemctl enable unbound-log-exporter
systemctl restart unbound-log-exporter

# ==============================================================================
# 7d. PROMETHEUS LOCAL
# ==============================================================================
log "Instalando Prometheus..."
apt-get install -y -qq prometheus

[[ -f /etc/prometheus/prometheus.yml ]] && \
    cp /etc/prometheus/prometheus.yml "/etc/prometheus/prometheus.yml.bak.$(date +%Y%m%d%H%M%S)"

cat > /etc/prometheus/prometheus.yml << PROM
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'unbound'
    static_configs:
      - targets: ['127.0.0.1:${EXPORTER_PORT}']
    relabel_configs:
      - target_label: instance
        replacement: '${SERVER_IP}'

  - job_name: 'node'
    static_configs:
      - targets: ['127.0.0.1:9100']
    relabel_configs:
      - target_label: instance
        replacement: '${SERVER_IP}'

  - job_name: 'unbound-log'
    static_configs:
      - targets: ['127.0.0.1:${LOG_EXPORTER_PORT}']
    relabel_configs:
      - target_label: instance
        replacement: '${SERVER_IP}'
PROM

cat > /etc/default/prometheus << DEFP
ARGS="--web.listen-address=0.0.0.0:${PROMETHEUS_PORT} --storage.tsdb.retention.time=30d"
DEFP

systemctl enable prometheus
systemctl restart prometheus
sleep 3

# ==============================================================================
# 8. UFW — puertos finales
# ==============================================================================
log "Configurando reglas UFW..."
for net in "${CLIENT_NETWORKS[@]}"; do
    ufw allow proto udp from "$net" to any port 53 comment "DNS UDP" >/dev/null 2>&1 || true
    ufw allow proto tcp from "$net" to any port 53 comment "DNS TCP" >/dev/null 2>&1 || true
done
if [[ -n "$DOT_DOMAIN" && -f /etc/unbound/tls/fullchain.pem ]]; then
    ufw allow proto tcp to any port 853  comment "DoT" >/dev/null 2>&1 || true
    ufw allow proto tcp to any port 8053 comment "DoH" >/dev/null 2>&1 || true
fi
for net in "${CLIENT_NETWORKS[@]}"; do
    ufw allow proto tcp from "$net" to any port "$PROMETHEUS_PORT" comment "Prometheus" >/dev/null 2>&1 || true
done

# ==============================================================================
# 9. VALIDACIÓN
# ==============================================================================
echo ""
log "Ejecutando validaciones..."
sleep 3

PASS=0; FAIL=0
check() {
    local desc=$1 cmd=$2
    if (set +o pipefail; eval "$cmd") &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ${desc}"; PASS=$((PASS+1))
    else
        echo -e "  ${RED}✗${NC} ${desc}"; FAIL=$((FAIL+1))
    fi
}

check "google.com resuelve"        "dig @127.0.0.1 google.com A +short +time=5 | grep -q '\\.'"
check "cloudflare.com resuelve"    "dig @127.0.0.1 cloudflare.com A +short +time=5 | grep -q '\\.'"
check "DNSSEC AD flag"             "dig @127.0.0.1 cloudflare.com A +dnssec +time=5 | grep -q ' ad[; ]'"
check "DNSSEC bogus rechazado"     "dig @127.0.0.1 dnssec-failed.org A +time=5 | grep -q 'SERVFAIL'"
check "RFC 5011 KSK-2017"          "grep -q 'id = 20326.*VALID' /var/lib/unbound/root.key"
if [[ "$DO_IP6" == "yes" ]]; then
    check "IPv6 escucha"           "dig @::1 google.com A +short +time=5 | grep -q '\\.'"
fi
if [[ -n "$DOT_DOMAIN" && -f /etc/unbound/tls/fullchain.pem ]]; then
    check "DoT cert presente"      "openssl x509 -in /etc/unbound/tls/fullchain.pem -noout -subject 2>/dev/null | grep -q '${DOT_DOMAIN}'"
    check "DoT puerto 853"         "ss -tlnp | grep -q ':853'"
fi
[[ "$EXPORTER_INSTALLED" == true ]] && \
    check "unbound_exporter"       "curl -s --max-time 5 http://127.0.0.1:${EXPORTER_PORT}/metrics | grep -q 'unbound_up'"
check "node_exporter"              "curl -s --max-time 5 http://127.0.0.1:9100/metrics | grep -q 'node_'"
check "Prometheus"                 "curl -s --max-time 5 http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy | grep -qi 'healthy'"
check "Log exporter"               "curl -s --max-time 5 http://127.0.0.1:${LOG_EXPORTER_PORT}/metrics | grep -q 'unbound_client'"

echo ""
log "Latencia de resolución (caché frío):"
for domain in google.com cloudflare.com; do
    ms=$(dig @127.0.0.1 "$domain" A +noall +stats +time=5 2>/dev/null | awk '/Query time/{print $4}' || echo "?")
    echo -e "  ${BLUE}→${NC} ${domain}: ${ms}ms"
done

# ==============================================================================
# 10. RESUMEN FINAL
# ==============================================================================
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              INSTALACIÓN COMPLETA                        ║${NC}"
echo -e "${BLUE}╠═══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║${NC}  Tests: ${GREEN}${PASS} OK${NC} / ${RED}${FAIL} FAIL${NC}"
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  DNS (UDP/TCP):    ${BOLD}${SERVER_IP}:53${NC}"
echo -e "${BLUE}║${NC}  Redes permitidas: $(IFS=', '; echo "${CLIENT_NETWORKS[*]}")"
if [[ -n "$DOT_DOMAIN" && -f /etc/unbound/tls/fullchain.pem ]]; then
echo -e "${BLUE}║${NC}  DoT:              tls://${DOT_DOMAIN}:853"
echo -e "${BLUE}║${NC}  DoH:              https://${DOT_DOMAIN}:8053/dns-query"
fi
echo -e "${BLUE}║${NC}  Prometheus:       http://${SERVER_IP}:${PROMETHEUS_PORT}"
echo -e "${BLUE}║${NC}  Logs DNS:         /var/log/unbound/queries.log (90 días)"
echo -e "${BLUE}║${NC}  DNSSEC:           RFC 5011 auto-rollover + RFC 8198 NSEC"
echo -e "${BLUE}║${NC}  Cache:            ${MSG_CACHE_SIZE} msg + ${RRSET_CACHE_SIZE} rrset (${NUM_THREADS} threads)"
echo -e "${BLUE}╠═══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║${NC}  Grafana datasource → http://${SERVER_IP}:${PROMETHEUS_PORT}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

[[ $FAIL -gt 0 ]] && warn "Revisar los tests fallidos antes de poner en producción."
exit 0
