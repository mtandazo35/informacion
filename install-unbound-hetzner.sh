#!/bin/bash
# ==============================================================================
# Unbound DNS — Instalador UNIVERSAL para ISP
# >>> ESTA COPIA: VARIABLES PRECARGADAS PARA LA PRUEBA EN HETZNER <<<
# (cliente = solo el PC de admin 205.235.6.129; sin clientes v6; IPV6_MODE=auto)
# Para producción usar install-unbound-isp.sh con las redes reales.
# Modo: Recursivo puro (sin forwards — .ec se resuelve recursivamente)
# Target: Debian 12/13, cualquier tamaño de máquina.
#
# Se adapta solo al entorno:
#   - UFW: lo instala y activa si falta (allow 22 antes de enable)
#   - Cache: dimensionado según la RAM real (msg=RAM/16, rrset=RAM/8, con topes)
#   - IPv6: detectado; comportamiento según IPV6_MODE (auto|require|off)
#   - Variables placeholder: rechazadas al inicio con mensaje claro
#
# Cambios vs versión anterior:
#  - ELIMINADO forward .ec a UFInet: cache+prefetch absorben los misses,
#    y la recursión directa evita dependencia de terceros y riesgo DNSSEC
#  - Exporter: letsencrypt/unbound_exporter (.deb oficial); el repo ar51au no existe
#  - Flags correctos del exporter: tcp:// + -unbound.ca "" -unbound.cert ""
#  - resolv.conf se bloquea SOLO después de validar que Unbound resuelve
#  - Pipelines protegidos contra set -e -o pipefail (curl/grep/wget)
#  - ACL: 0.0.0.0/0 deny (drop) en vez de refuse; UFW solo a CLIENT_NETWORKS
#  - ratelimit upstream + unwanted-reply-threshold (ip-ratelimit OFF, ver nota)
#  - serve-expired-client-timeout: intenta upstream antes de servir stale
#  - Drop-in systemd LimitNOFILE=65536
# ==============================================================================
set -euo pipefail

# ── Colores ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Ejecutar como root: sudo bash $0"

# ==============================================================================
# VARIABLES — REVISAR ANTES DE INSTALAR
# ==============================================================================

# PRUEBA: el único "cliente" autorizado es el PC de administración.
# Desde 205.235.6.129 → dig @IP_HETZNER google.com debe resolver.
# Desde cualquier otra IP → TIMEOUT.
CLIENT_NETWORKS=(
    "205.235.6.129/32"
)

# PRUEBA: sin clientes IPv6. El servidor igual escucha/recurre por v6
# si la máquina tiene v6 global (IPV6_MODE=auto lo detecta).
CLIENT_NETWORKS_V6=()

# Performance — auto-detectado pero ajustable
NUM_THREADS=$(nproc)
# slabs: potencia de 2 >= num_threads para evitar lock contention
NUM_SLABS=1
while [[ $NUM_SLABS -lt $NUM_THREADS ]]; do
    NUM_SLABS=$((NUM_SLABS * 2))
done

# IPv6: "require" → aborta si el servidor no tiene v6 global con ruta
#       (RECOMENDADO para la flota de producción: política "todo server con v6").
#       "auto"    → lo usa si existe; si no, avisa y sigue solo-v4 (labs/pruebas).
#       "off"     → deshabilitado.
IPV6_MODE="auto"

# Cache: "auto" dimensiona según la RAM real (msg=RAM/16, rrset=RAM/8,
# topes 512m/1024m). El consumo REAL es ~2x lo configurado por overhead
# de malloc + infra/key cache; la fórmula deja ~60% de la RAM al resto.
# Para fijar a mano, reemplazar "auto" por valores tipo "256m"/"512m".
MSG_CACHE_SIZE="auto"
RRSET_CACHE_SIZE="auto"

# TTL mínimo: 120s acelera el cache pero retrasa failover de CDNs/GSLB
# que usan TTLs de 30-60s. No subir de 120.
CACHE_MIN_TTL=120
CACHE_MAX_TTL=86400

# Puerto del exporter Prometheus
EXPORTER_PORT=9167

# ── Prometheus ─────────────────────────────────────────────────────────────────
# false → (RECOMENDADO para flotas) solo exporters; los scrapea un Prometheus
#         central. Los exporters quedan expuestos SOLO a CENTRAL_PROMETHEUS_IPS.
# true  → instala Prometheus EN ESTE servidor (autocontenido). Solo para hosts
#         aislados donde el central no alcanza los exporters. Tradeoff: si el
#         host cae, pierdes métricas E historial que explicaría la caída.
INSTALL_PROMETHEUS=false
PROMETHEUS_PORT=9090
PROMETHEUS_RETENTION="30d"

# IP del Prometheus central que scrapea los exporters de este servidor.
# Usado solo con INSTALL_PROMETHEUS=false.
CENTRAL_PROMETHEUS_IPS=(
    "205.235.2.148"
)

# IPs de administración con acceso directo a los exporters (:9167, :9100).
# Agregar Grafana, PC del admin, etc. Independiente de INSTALL_PROMETHEUS.
ADMIN_IPS=(
    "205.235.6.129"
)

# Desde dónde se permite consultar Prometheus :9090 (Grafana, PC de gestión).
# Usado solo con INSTALL_PROMETHEUS=true.
MGMT_NETWORKS=(
    "192.168.88.0/24"
)

# Versiones fallback (se intenta detectar la última automáticamente)
EXPORTER_FALLBACK_TAG="v0.6.0"
NODE_EXPORTER_VERSION="1.8.2"

# ==============================================================================
# GUARDAS — fallar AQUÍ, con mensaje claro, no a mitad de la instalación
# ==============================================================================
[[ ${#CLIENT_NETWORKS[@]} -eq 0 && ${#CLIENT_NETWORKS_V6[@]} -eq 0 ]] && \
    err "CLIENT_NETWORKS y CLIENT_NETWORKS_V6 están vacíos — ningún cliente podría consultar."
for net in "${CLIENT_NETWORKS_V6[@]}"; do
    [[ "$net" == *XXXX* ]] && \
        err "CLIENT_NETWORKS_V6 contiene el placeholder '${net}' — reemplazar con el prefijo real (o dejar el array vacío)."
done

# ── Cache auto según RAM ───────────────────────────────────────────────────────
RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if [[ "$MSG_CACHE_SIZE" == "auto" ]]; then
    _M=$(( RAM_MB / 16 )); (( _M < 32 )) && _M=32; (( _M > 512 )) && _M=512
    MSG_CACHE_SIZE="${_M}m"
fi
if [[ "$RRSET_CACHE_SIZE" == "auto" ]]; then
    _R=$(( RAM_MB / 8 )); (( _R < 64 )) && _R=64; (( _R > 1024 )) && _R=1024
    RRSET_CACHE_SIZE="${_R}m"
fi

# ── Detección IPv6 (global + ruta por defecto) ─────────────────────────────────
HAS_V6=false
if ip -6 addr show scope global 2>/dev/null | grep -q inet6 && \
   ip -6 route show default 2>/dev/null | grep -qE 'via|dev'; then
    HAS_V6=true
fi
case "$IPV6_MODE" in
    require)
        [[ "$HAS_V6" == true ]] || err "IPV6_MODE=require pero el servidor no tiene IPv6 global con ruta. Configurar v6 o usar IPV6_MODE=auto."
        DO_IP6="yes" ;;
    auto)
        if [[ "$HAS_V6" == true ]]; then DO_IP6="yes"
        else DO_IP6="no"; warn "Sin IPv6 global/ruta — instalando solo-v4 (IPV6_MODE=auto). En producción usar IPV6_MODE=require."
        fi ;;
    off)  DO_IP6="no" ;;
    *)    err "IPV6_MODE inválido: '${IPV6_MODE}' (usar auto|require|off)" ;;
esac
if [[ "$DO_IP6" == "yes" ]]; then V6_LISTEN="    interface: ::0"; else V6_LISTEN=""; fi

# ==============================================================================
# BANNER
# ==============================================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Unbound DNS ISP — Instalador (rev)             ║${NC}"
echo -e "${BLUE}║  Modo: Recursivo puro (sin forwards)                 ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
info "Sistema:  $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
info "vCPU:     ${NUM_THREADS} threads"
info "RAM:      $(free -h | awk '/Mem/{print $2}')"
info "IP:       $(hostname -I | awk '{print $1}')"
info "IPv6:     ${DO_IP6} (modo ${IPV6_MODE})"
info "Cache:    ${MSG_CACHE_SIZE} msg + ${RRSET_CACHE_SIZE} rrset (auto según ${RAM_MB}MB RAM)"
warn "VARIABLES DE PRUEBA: cliente único = 205.235.6.129 (PC admin). NO usar en producción."
echo ""

# ==============================================================================
# 0. UFW PRIMERO — universal
# ==============================================================================
# Sin firewall activo, los exporters (:9167, :9100) quedarían abiertos a
# cualquiera que alcance la IP. Orden crítico: allow 22 ANTES de enable.
if ! command -v ufw &>/dev/null; then
    log "Instalando UFW..."
    apt-get update -qq
    apt-get install -y -qq ufw
fi
if ! ufw status | grep -q "Status: active"; then
    log "Activando UFW (default deny incoming, SSH permitido)..."
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 22/tcp comment "SSH" >/dev/null
    ufw --force enable >/dev/null
    log "UFW activo."
else
    info "UFW ya activo — omitido."
fi

# ==============================================================================
# 1. DEPENDENCIAS
# ==============================================================================
log "Instalando Unbound y dependencias..."
apt-get update -qq
apt-get install -y -qq unbound unbound-anchor dnsutils curl wget

# systemd-resolved ocupa el puerto 53 (stub listener)
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    warn "Deshabilitando systemd-resolved (conflicto puerto 53)..."
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
fi

# NOTA: resolv.conf se modifica DESPUÉS de validar Unbound (sección 5).
# Hacerlo antes deja el host sin DNS si Unbound no arranca.

# ==============================================================================
# 2. DNSSEC — Trust Anchor
# ==============================================================================
# CRÍTICO: sin este archivo, el módulo validador no inicializa y Unbound
# muere al arrancar. unbound-anchor puede no crear el archivo en Debian
# (su exit code 1 además es normal: significa "clave actualizada"), así
# que se verifica el resultado y se siembra desde dns-root-data si falta.
log "Configurando DNSSEC trust anchor..."
mkdir -p /var/lib/unbound
unbound-anchor -a /var/lib/unbound/root.key 2>/dev/null || true
if [[ ! -s /var/lib/unbound/root.key ]]; then
    if [[ -f /usr/share/dns/root.key ]]; then
        cp /usr/share/dns/root.key /var/lib/unbound/root.key
        log "Trust anchor sembrado desde dns-root-data (RFC 5011 lo mantiene desde ahora)."
    else
        apt-get install -y -qq dns-root-data
        [[ -f /usr/share/dns/root.key ]] && cp /usr/share/dns/root.key /var/lib/unbound/root.key
    fi
fi
[[ -s /var/lib/unbound/root.key ]] || \
    err "No se pudo crear /var/lib/unbound/root.key — Unbound NO va a arrancar sin él."
chown -R unbound:unbound /var/lib/unbound

# ==============================================================================
# 2b. KERNEL — Buffers de red
# ==============================================================================
log "Aplicando tuning de kernel (buffers de red)..."
cat > /etc/sysctl.d/99-unbound.conf << SYSCTL
# Buffers de red para Unbound ISP
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.core.rmem_default=262144
net.core.wmem_default=262144
SYSCTL
sysctl -p /etc/sysctl.d/99-unbound.conf -q

# ==============================================================================
# 2c. SYSTEMD — Límite de file descriptors
# ==============================================================================
# outgoing-range 8192 x NUM_THREADS sockets ≈ 33k fds con 4 vCPU.
# No depender del hard limit por defecto de la distro.
log "Configurando LimitNOFILE para Unbound..."
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

# Backup si ya existe
[[ -f /etc/unbound/unbound.conf ]] && \
    cp /etc/unbound/unbound.conf /etc/unbound/unbound.conf.bak.$(date +%Y%m%d%H%M%S)

# Construir bloque de access-control
# deny = drop silencioso. Mejor que refuse en un resolver expuesto:
# no participa en reflexión ni confirma a escáneres que existe el servicio.
ACL_BLOCK="    access-control: 0.0.0.0/0 deny\n"
ACL_BLOCK+="    access-control: ::0/0 deny\n"
ACL_BLOCK+="    access-control: 127.0.0.0/8 allow\n"
ACL_BLOCK+="    access-control: ::1/128 allow\n"
for net in "${CLIENT_NETWORKS[@]}"; do
    ACL_BLOCK+="    access-control: ${net} allow\n"
done
for net in "${CLIENT_NETWORKS_V6[@]}"; do
    ACL_BLOCK+="    access-control: ${net} allow\n"
done

cat > /etc/unbound/unbound.conf << CONF
# ==============================================================================
# Unbound DNS — Configuración ISP
# Modo: Recursivo puro (sin forwards). Los dominios .ec se resuelven
# recursivamente igual que el resto del árbol DNS.
# Generado: $(date)
# NOTA: este archivo NO incluye /etc/unbound/unbound.conf.d/ a propósito.
# En upgrades del paquete, dpkg preguntará por el conffile: elegir "keep".
# ==============================================================================

server:

    # ── Red ────────────────────────────────────────────────────────────────────
    interface: 0.0.0.0
${V6_LISTEN}
    port: 53
    do-udp: yes
    do-tcp: yes
    do-ip4: yes
    # do-ip6 habilita escuchar clientes v6 Y la recursión saliente v6.
    # Valor decidido por la detección automática + IPV6_MODE.
    do-ip6: ${DO_IP6}
    so-reuseport: yes
    edns-buffer-size: 1232

    # ── Performance ────────────────────────────────────────────────────────────
    num-threads: ${NUM_THREADS}
    so-rcvbuf: 8m
    so-sndbuf: 8m
    outgoing-range: 8192
    num-queries-per-thread: 4096

    # Slabs: potencia de 2 para reducir lock contention
    msg-cache-slabs: ${NUM_SLABS}
    rrset-cache-slabs: ${NUM_SLABS}
    infra-cache-slabs: ${NUM_SLABS}
    key-cache-slabs: ${NUM_SLABS}

    # ── Caché ──────────────────────────────────────────────────────────────────
    msg-cache-size: ${MSG_CACHE_SIZE}
    rrset-cache-size: ${RRSET_CACHE_SIZE}
    neg-cache-size: 4m
    # Más hosts en infra-cache para volumen ISP (default 10000)
    infra-cache-numhosts: 100000

    # Prefetch: renueva entradas populares antes de que expiren
    prefetch: yes
    prefetch-key: yes
    target-fetch-policy: "3 2 1 0 0"

    # TTL
    cache-min-ttl: ${CACHE_MIN_TTL}
    cache-max-ttl: ${CACHE_MAX_TTL}

    # Serve stale: PRIMERO intenta el upstream (1.8s); solo si no responde
    # sirve el dato vencido. Sin client-timeout, Unbound sirve stale siempre
    # primero, entregando datos de hasta 24h aunque el upstream esté sano.
    serve-expired: yes
    serve-expired-ttl: ${CACHE_MAX_TTL}
    serve-expired-reply-ttl: 30
    serve-expired-client-timeout: 1800

    # ── DNSSEC ─────────────────────────────────────────────────────────────────
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    val-clean-additional: yes
    # Aggressive NSEC: reduce queries para dominios inexistentes
    aggressive-nsec: yes

    # ── Privacidad / Seguridad ─────────────────────────────────────────────────
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    use-caps-for-id: yes

    # Anti cache-poisoning: descarta y limpia cache si llegan
    # demasiadas respuestas no solicitadas
    unwanted-reply-threshold: 10000000

    # Rate limit hacia upstream POR ZONA (qps): mitiga random-subdomain
    # attacks lanzados desde clientes infectados contra dominios ajenos
    ratelimit: 1000

    # ip-ratelimit: la decisión depende de CÓMO llegan las queries.
    # - IPv4 NATeado (pocas IPs de routers MikroTik): DEBE quedar en 0;
    #   un límite por IP estrangularía a un router completo.
    # - IPv6 SIN NAT con clientes consultando directo: cada cliente es una
    #   IP origen distinta → activar ip-ratelimit SÍ tiene sentido como
    #   protección por-cliente (un hogar legítimo no pasa de ~100 qps):
    #       ip-ratelimit: 1000
    #       ip-ratelimit-slabs: ${NUM_SLABS}
    #   PERO: como Unbound usa un solo valor global y las queries v4 siguen
    #   llegando NATeadas por los mismos routers, activarlo limitaría
    #   también a esos routers. Mantener en 0 mientras coexistan ambos
    #   modelos; el control por-cliente fino va en el MikroTik.
    ip-ratelimit: 0

    # ── Control de acceso ──────────────────────────────────────────────────────
$(printf "%b" "$ACL_BLOCK")

    # ── Logging ────────────────────────────────────────────────────────────────
    verbosity: 1
    log-queries: no
    log-replies: no
    log-local-actions: no
    log-servfail: yes

    # ── Estadísticas para Prometheus ───────────────────────────────────────────
    statistics-interval: 0
    statistics-cumulative: yes
    extended-statistics: yes

# ── Control remoto (usado por unbound_exporter) ────────────────────────────────
# Socket unix: el exporter lo usa SIN TLS. Con TCP, el exporter exige
# certificados siempre ("open : no such file" si se le pasan vacíos).
# El socket se crea root:unbound modo 0660 → el exporter corre como
# usuario unbound y conecta por pertenencia al grupo.
remote-control:
    control-enable: yes
    control-interface: /run/unbound.ctl

# ==============================================================================
# SIN FORWARDS: todo el árbol DNS (incluido .ec) se resuelve recursivamente.
# Si alguna vez se mide latencia consistentemente mala (>50ms) hacia los
# autoritativos de .ec, se puede reintroducir el forward añadiendo:
#     forward-zone:
#         name: "ec."
#         forward-addr: <resolver_local>
# (recordar el riesgo DNSSEC: dominios .ec firmados pueden dar SERVFAIL
#  si el resolver intermedio no pasa los registros DNSSEC correctamente)
# ==============================================================================
CONF

# ==============================================================================
# 4. INICIAR UNBOUND
# ==============================================================================
log "Validando sintaxis de la configuración..."
unbound-checkconf /etc/unbound/unbound.conf || err "Configuración inválida."

log "Iniciando Unbound..."
systemctl enable unbound
systemctl reset-failed unbound 2>/dev/null || true
systemctl restart unbound
sleep 3

systemctl is-active --quiet unbound || {
    err "Unbound no arrancó. Revisar: journalctl -u unbound -n 30"
}

# Validar que resuelve ANTES de tocar resolv.conf
dig @127.0.0.1 google.com A +short +time=5 &>/dev/null || {
    err "Unbound activo pero no resuelve. NO se modificó resolv.conf. Revisar logs."
}
log "Unbound activo y resolviendo."

# ==============================================================================
# 5. RESOLV.CONF — solo ahora que Unbound está validado
# ==============================================================================
log "Apuntando resolv.conf a 127.0.0.1..."
# Backup del contenido original (cat -L por si es symlink de systemd-resolved)
[[ ! -f /etc/resolv.conf.pre-unbound ]] && \
    cat /etc/resolv.conf > /etc/resolv.conf.pre-unbound 2>/dev/null || true

chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chattr +i /etc/resolv.conf
log "resolv.conf → 127.0.0.1 (protegido con chattr +i; original en /etc/resolv.conf.pre-unbound)."

# ==============================================================================
# 6. UNBOUND EXPORTER (Prometheus)
# ==============================================================================
# Repo oficial: letsencrypt/unbound_exporter (publica .deb solo para amd64).
# Conexión por SOCKET UNIX (/run/unbound.ctl): es el único modo sin TLS
# del exporter — con tcp:// exige certificados siempre. Corre como usuario
# unbound para tener permiso de grupo sobre el socket (root:unbound 0660).
log "Instalando unbound_exporter (letsencrypt)..."

EXPORTER_INSTALLED=false
ARCH=$(dpkg --print-architecture)

if [[ "$ARCH" == "amd64" ]]; then
    # Detectar último tag vía redirect de GitHub (sin API → sin rate limit).
    # Pipeline protegido: si falla, usar fallback en vez de matar el script.
    LATEST_TAG=$(curl -sf --max-time 10 -o /dev/null -w '%{redirect_url}' \
        "https://github.com/letsencrypt/unbound_exporter/releases/latest" 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' || true)
    [[ -z "$LATEST_TAG" ]] && LATEST_TAG="$EXPORTER_FALLBACK_TAG"

    EXPORTER_URL="https://github.com/letsencrypt/unbound_exporter/releases/download/${LATEST_TAG}/unbound_exporter-${LATEST_TAG}.x86_64.deb"

    if wget -q --timeout=20 "$EXPORTER_URL" -O /tmp/unbound_exporter.deb 2>/dev/null \
       && dpkg -i /tmp/unbound_exporter.deb &>/dev/null; then
        EXPORTER_INSTALLED=true
        log "unbound_exporter ${LATEST_TAG} instalado (/usr/bin/unbound_exporter)."
    fi
else
    warn "Arquitectura ${ARCH}: no hay .deb oficial; compilar con: go install github.com/letsencrypt/unbound_exporter@latest"
fi

if [[ "$EXPORTER_INSTALLED" == false ]]; then
    warn "No se pudo instalar unbound_exporter — métricas Prometheus NO disponibles."
    warn "Manual: https://github.com/letsencrypt/unbound_exporter/releases"
else
    # Con Prometheus local, el exporter solo necesita escuchar en loopback
    # (menos superficie expuesta). Con Prometheus central, escucha en todas.
    if [[ "$INSTALL_PROMETHEUS" == true ]]; then
        EXPORTER_BIND="127.0.0.1"
    else
        EXPORTER_BIND=""
    fi

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
    -web.listen-address "${EXPORTER_BIND}:${EXPORTER_PORT}"
Restart=on-failure
RestartSec=5
User=unbound

[Install]
WantedBy=multi-user.target
SVC

    systemctl daemon-reload
    systemctl enable unbound-exporter
    systemctl restart unbound-exporter
fi

# ==============================================================================
# 7. NODE EXPORTER
# ==============================================================================
if ! systemctl is-active --quiet node_exporter 2>/dev/null && \
   ! systemctl is-active --quiet node-exporter 2>/dev/null && \
   ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q node-exporter; then
    log "Instalando node_exporter..."
    NE_ARCH="$ARCH"  # GitHub usa amd64/arm64, igual que dpkg
    if wget -q --timeout=30 \
        "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${NE_ARCH}.tar.gz" \
        -O /tmp/node_exporter.tar.gz 2>/dev/null; then
        tar -xzf /tmp/node_exporter.tar.gz -C /tmp/
        mv "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${NE_ARCH}/node_exporter" /usr/local/bin/
        chmod +x /usr/local/bin/node_exporter

        if [[ "$INSTALL_PROMETHEUS" == true ]]; then
            NE_BIND="127.0.0.1"
        else
            NE_BIND=""
        fi

        cat > /etc/systemd/system/node-exporter.service << SVC2
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/node_exporter --web.listen-address="${NE_BIND}:9100"
Restart=on-failure
DynamicUser=yes

[Install]
WantedBy=multi-user.target
SVC2

        systemctl daemon-reload
        systemctl enable node-exporter
        systemctl start node-exporter
        log "node_exporter instalado."
    else
        warn "No se pudo descargar node_exporter — continuar sin métricas de host."
    fi
else
    info "node_exporter ya está corriendo — omitido."
fi

# ==============================================================================
# 7b. PROMETHEUS LOCAL (opcional, INSTALL_PROMETHEUS=true)
# ==============================================================================
# Se usa el paquete de Debian (no binario de GitHub): trae usuario de sistema,
# unidad systemd y recibe parches de seguridad vía apt. La versión del repo
# es algo más vieja que upstream, pero para scrapear 3 targets locales sobra.
if [[ "$INSTALL_PROMETHEUS" == true ]]; then
    log "Instalando Prometheus (paquete Debian)..."
    apt-get install -y -qq prometheus

    # Backup de la config del paquete
    [[ -f /etc/prometheus/prometheus.yml ]] && \
        cp /etc/prometheus/prometheus.yml /etc/prometheus/prometheus.yml.bak.$(date +%Y%m%d%H%M%S)

    cat > /etc/prometheus/prometheus.yml << PROM
# Prometheus local — scrape de los exporters de este mismo host
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['127.0.0.1:${PROMETHEUS_PORT}']

  - job_name: 'unbound'
    static_configs:
      - targets: ['127.0.0.1:${EXPORTER_PORT}']

  - job_name: 'node'
    static_configs:
      - targets: ['127.0.0.1:9100']
PROM

    # Validar config antes de arrancar (promtool viene con el paquete)
    if command -v promtool &>/dev/null; then
        promtool check config /etc/prometheus/prometheus.yml >/dev/null || \
            err "prometheus.yml inválido — revisar antes de continuar."
    fi

    # El paquete Debian lee ARGS de /etc/default/prometheus.
    # Escucha en todas las interfaces (Grafana externo); UFW restringe
    # el acceso a MGMT_NETWORKS en la sección de firewall.
    cat > /etc/default/prometheus << DEFP
ARGS="--web.listen-address=0.0.0.0:${PROMETHEUS_PORT} --storage.tsdb.retention.time=${PROMETHEUS_RETENTION}"
DEFP

    systemctl enable prometheus
    systemctl restart prometheus
    sleep 3
    systemctl is-active --quiet prometheus || \
        err "Prometheus no arrancó. Revisar: journalctl -u prometheus -n 30"
    log "Prometheus activo en :${PROMETHEUS_PORT} (retención ${PROMETHEUS_RETENTION})."
else
    info "INSTALL_PROMETHEUS=false — solo exporters; scrapear desde Prometheus central."
fi

# ==============================================================================
# 8. FIREWALL — puerto 53 SOLO para redes de clientes
# ==============================================================================
# Abrir 53 a 0.0.0.0/0 expone el resolver a escaneo y reflexión aunque la
# ACL lo proteja. Defensa en capas: UFW filtra antes de que llegue a Unbound.
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "Configurando UFW (53 solo desde redes de clientes v4 y v6)..."
    # UFW solo genera reglas ip6tables si IPV6=yes en /etc/default/ufw
    if grep -q '^IPV6=no' /etc/default/ufw 2>/dev/null; then
        sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
        ufw reload 2>/dev/null || true
        warn "IPV6 activado en UFW (/etc/default/ufw) y recargado."
    fi
    for net in "${CLIENT_NETWORKS[@]}" "${CLIENT_NETWORKS_V6[@]}"; do
        ufw allow proto udp from "$net" to any port 53 comment "DNS UDP clientes" 2>/dev/null || true
        ufw allow proto tcp from "$net" to any port 53 comment "DNS TCP clientes" 2>/dev/null || true
    done
    ufw allow 22/tcp comment "SSH" 2>/dev/null || true
    if [[ "$INSTALL_PROMETHEUS" == true ]]; then
        # Prometheus web/API solo desde redes de gestión (Grafana, admin)
        for net in "${MGMT_NETWORKS[@]}"; do
            ufw allow proto tcp from "$net" to any port "${PROMETHEUS_PORT}" comment "Prometheus gestion" 2>/dev/null || true
        done
        # Los exporters escuchan solo en 127.0.0.1 — no necesitan reglas.
    else
        # Prometheus central: exporters accesibles SOLO desde sus IPs
        for ip in "${CENTRAL_PROMETHEUS_IPS[@]}"; do
            ufw allow proto tcp from "$ip" to any port "${EXPORTER_PORT}" comment "scrape unbound_exporter" 2>/dev/null || true
            ufw allow proto tcp from "$ip" to any port 9100 comment "scrape node_exporter" 2>/dev/null || true
        done
    fi
    # IPs de admin: acceso directo a exporters (Grafana, PC de gestión)
    for ip in "${ADMIN_IPS[@]}"; do
        ufw allow proto tcp from "$ip" to any port "${EXPORTER_PORT}" comment "exporter admin" 2>/dev/null || true
        ufw allow proto tcp from "$ip" to any port 9100 comment "node_exporter admin" 2>/dev/null || true
    done
fi

# ==============================================================================
# 9. VALIDACIÓN
# ==============================================================================
echo ""
log "Ejecutando validaciones..."
sleep 3

PASS=0; FAIL=0

check() {
    local desc=$1; shift
    if eval "$@" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ${desc}"
        PASS=$((PASS+1))
    else
        echo -e "  ${RED}✗${NC} ${desc}"
        FAIL=$((FAIL+1))
    fi
}

# Resolución básica
check "google.com resuelve"   "dig @127.0.0.1 google.com A +short +time=5 | grep -q '\\.'"
check "netflix.com resuelve"  "dig @127.0.0.1 netflix.com A +short +time=5 | grep -q '\\.'"
check "amazon.com resuelve"   "dig @127.0.0.1 amazon.com A +short +time=5 | grep -q '\\.'"
check "youtube.com resuelve"  "dig @127.0.0.1 youtube.com A +short +time=5 | grep -q '\\.'"

# .ec recursivo (sin forward)
check ".ec resuelve (recursivo)" "dig @127.0.0.1 nic.ec A +short +time=5 | grep -q '\\.'"

# IPv6 (solo si quedó habilitado)
if [[ "$DO_IP6" == "yes" ]]; then
check "Escucha en ::1 (queries v6)" \
    "dig @::1 google.com A +short +time=5 | grep -q '\\.'"
check "Registros AAAA resuelven" \
    "dig @127.0.0.1 google.com AAAA +short +time=5 | grep -q ':'"
check "Conectividad v6 saliente a root server" \
    "dig @2001:500:2::c . NS +time=5 | grep -q 'NOERROR'"
else
info "IPv6 deshabilitado en esta instalación — tests v6 omitidos."
fi

# DNSSEC
check "DNSSEC validación (AD flag)" \
    "dig @127.0.0.1 cloudflare.com A +dnssec +time=5 | grep -q ' ad[; ]'"
check "DNSSEC bogus rechazado" \
    "dig @127.0.0.1 dnssec-failed.org A +time=5 | grep -q 'SERVFAIL'"

# ACL — validación real solo desde fuera:
# desde un host que NO esté en CLIENT_NETWORKS:
#   dig @<IP_SERVIDOR> google.com A +time=3
# Con UFW + deny debe dar TIMEOUT (drop), no REFUSED.

# Prometheus
check "unbound_exporter responde en :${EXPORTER_PORT}" \
    "curl -s --max-time 5 http://127.0.0.1:${EXPORTER_PORT}/metrics | grep -c 'unbound_up' >/dev/null"
check "node_exporter responde en :9100" \
    "curl -s --max-time 5 http://127.0.0.1:9100/metrics | grep -c 'node_' >/dev/null"

if [[ "$INSTALL_PROMETHEUS" == true ]]; then
    check "Prometheus healthy" \
        "curl -s --max-time 5 http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy | grep -ci 'healthy' >/dev/null"
    # Esperar al primer ciclo de scrape (15s) antes de evaluar targets
    info "Esperando primer scrape de Prometheus (15s)..."
    sleep 16
    check "Los 3 targets de Prometheus en estado UP" \
        "[ \"\$(curl -s --max-time 5 http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/targets | grep -o '\"health\":\"up\"' | wc -l)\" -ge 3 ]"
fi

# Latencia (pipelines protegidos contra pipefail)
echo ""
log "Latencia de resolución:"
for domain in google.com netflix.com amazon.com; do
    ms=$(dig @127.0.0.1 "$domain" A +noall +stats +time=5 2>/dev/null | \
         awk '/Query time/{print $4}' || true)
    echo -e "  ${BLUE}→${NC} ${domain}: ${ms:-?}ms"
done

# ==============================================================================
# 10. RESUMEN FINAL
# ==============================================================================
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              INSTALACIÓN COMPLETA                   ║${NC}"
echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║${NC}  Tests: ${GREEN}${PASS} OK${NC} / ${RED}${FAIL} FAIL${NC}"
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  DNS:        ${SERVER_IP}:53 (UDP/TCP, IPv6: ${DO_IP6}, solo redes de clientes)"
if [[ "$INSTALL_PROMETHEUS" == true ]]; then
echo -e "${BLUE}║${NC}  Prometheus: ${SERVER_IP}:${PROMETHEUS_PORT} (retención ${PROMETHEUS_RETENTION}, acceso: MGMT_NETWORKS)"
echo -e "${BLUE}║${NC}  Exporters:  127.0.0.1:${EXPORTER_PORT} y 127.0.0.1:9100 (solo locales)"
else
echo -e "${BLUE}║${NC}  Exporter:   ${SERVER_IP}:${EXPORTER_PORT}"
echo -e "${BLUE}║${NC}  Node exp:   ${SERVER_IP}:9100"
fi
echo -e "${BLUE}║${NC}  Threads:    ${NUM_THREADS} workers"
echo -e "${BLUE}║${NC}  Cache cfg:  ${MSG_CACHE_SIZE} msg + ${RRSET_CACHE_SIZE} rrset (RSS real ~1.5-2GB)"
echo -e "${BLUE}║${NC}  Modo:       Recursivo puro (sin forwards, .ec incluido)"
echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
if [[ "$INSTALL_PROMETHEUS" == true ]]; then
echo -e "${BLUE}║${NC}  En Grafana, agregar datasource Prometheus:"
echo -e "${BLUE}║${NC}    URL: http://${SERVER_IP}:${PROMETHEUS_PORT}"
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  (la IP de Grafana debe estar en MGMT_NETWORKS)"
else
echo -e "${BLUE}║${NC}  Agregar al prometheus.yml del servidor central:  "
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  - job_name: 'unbound'"
echo -e "${BLUE}║${NC}    static_configs:"
echo -e "${BLUE}║${NC}      - targets: ['${SERVER_IP}:${EXPORTER_PORT}']"
echo -e "${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  - job_name: 'node_unbound'"
echo -e "${BLUE}║${NC}    static_configs:"
echo -e "${BLUE}║${NC}      - targets: ['${SERVER_IP}:9100']"
echo -e "${BLUE}║${NC}"
fi
echo -e "${BLUE}║${NC}  Dashboard Grafana (importar ID): 11705"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

[[ $FAIL -gt 0 ]] && warn "Revisar los tests fallidos antes de poner en producción."
exit 0
