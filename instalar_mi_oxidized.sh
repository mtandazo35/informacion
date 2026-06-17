#!/bin/bash
#
# Instalador BARE-METAL de Oxidized + Caddy (TLS interno) + Telegram
# Optimizado para flotas de ~300 MikroTik (RouterOS) sobre WAN.
#
# Diseñado para ser ejecutado en MÚLTIPLES VPS Debian 13:
#   - Pre-flight checks (disco, RAM, internet, apt-lock)
#   - Retries automáticos en apt/gem (fallos de red transitorios)
#   - Pin de versiones de gems (reproducibilidad)
#   - Soporte env-vars para deploy NO-interactivo
#   - Self-test final que valida el endpoint web
#   - Modo --update-only para iterar sin tocar paquetes
#
# Uso interactivo:
#   bash instalar_mi_oxidized.sh
#
# Uso no-interactivo (deploy masivo):
#   OX_NON_INTERACTIVE=1 \
#   OX_SERVER_IP=10.254.254.8 \
#   OX_WEB_PASS=mipassw0rd \
#   OX_MK_USER=Respaldo \
#   OX_MK_PASS=mikpass \
#   OX_TG_TOKEN=12345:ABC \
#   OX_TG_CHAT_ID=-100123 \
#   bash instalar_mi_oxidized.sh
#
# Modo update-only (no toca paquetes, solo reescribe configs):
#   bash instalar_mi_oxidized.sh --update-only
#
set -euo pipefail

# ===========================================================================
# Constantes
# ===========================================================================
SCRIPT_VERSION="2.0"

# Versiones pinneadas (reproducibilidad entre VPS)
OXIDIZED_VERSION="0.37.0"
OXIDIZED_WEB_VERSION="0.18.1"

OX_USER="oxidized"
OX_HOME="/var/lib/oxidized"
OX_CONF_DIR="${OX_HOME}/.config/oxidized"
OX_SSH_DIR="${OX_HOME}/.ssh"
CADDY_DIR="/etc/caddy"
DOC_DIR="/root"

# Modo
UPDATE_ONLY=0

# ===========================================================================
# Helpers
# ===========================================================================
log()   { echo -e "$@"; }
warn()  { echo -e "⚠️  $*" >&2; }
die()   { echo -e "❌ $*" >&2; exit 1; }
ok()    { echo -e "✅ $*"; }

usage() {
    cat << EOF
Instalador Oxidized v${SCRIPT_VERSION}

Uso:
  $0                     Instalación interactiva
  $0 --update-only       Solo reescribe configs (no toca paquetes)
  $0 --help              Esta ayuda

Env vars para deploy no-interactivo (OX_NON_INTERACTIVE=1 las requiere todas
excepto los OX_TG_*):
  OX_NON_INTERACTIVE=1   No prompts
  OX_SERVER_IP           IP del servidor (bind + TLS cert)
  OX_WEB_PASS            Password admin del UI
  OX_MK_USER             Usuario MikroTik (default: Respaldo)
  OX_MK_PASS             Password MikroTik
  OX_TG_TOKEN            Token bot Telegram (opcional)
  OX_TG_CHAT_ID          Chat ID Telegram (opcional)
EOF
}

backup_if_exists() {
    local f="$1"
    [ -f "$f" ] && cp -a "$f" "$f.bak.$(date +%Y%m%d_%H%M%S)"
}

# Retry con backoff exponencial
retry() {
    local max=$1; shift
    local n=0
    local delay=5
    until "$@"; do
        n=$((n+1))
        if [ $n -ge $max ]; then
            return 1
        fi
        log "  ↳ Reintento $n/$max en ${delay}s..."
        sleep $delay
        delay=$((delay*2))
    done
}

# Esperar a que el lock de apt se libere (max 5 min)
wait_apt_lock() {
    local timeout=300
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/apt/lists/lock     >/dev/null 2>&1; do
        if [ $timeout -le 0 ]; then
            die "Timeout esperando lock de apt (¿otro proceso de apt activo?)"
        fi
        log "  ↳ Esperando lock de apt ($timeout s restantes)..."
        sleep 5
        timeout=$((timeout-5))
    done
}

# Wrapper de apt con retries y wait-for-lock
apt_safe() {
    wait_apt_lock
    retry 3 env DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

# ===========================================================================
# 0. Parse flags
# ===========================================================================
for arg in "$@"; do
    case "$arg" in
        --update-only) UPDATE_ONLY=1 ;;
        --help|-h)     usage; exit 0 ;;
        *)             die "Flag desconocido: $arg (usa --help)" ;;
    esac
done

echo "============================================================"
echo "🚀 Oxidized BARE-METAL v${SCRIPT_VERSION}"
[ $UPDATE_ONLY -eq 1 ] && echo "   Modo: UPDATE-ONLY (no toca paquetes)"
echo "============================================================"

# ===========================================================================
# 1. Pre-flight checks
# ===========================================================================
log ""
log "🔍 Pre-flight checks..."

# Root
[ "$(id -u)" = "0" ] || die "Este script debe correrse como root."

# OS
[ -f /etc/debian_version ] || die "Solo Debian/Ubuntu (no se encontró /etc/debian_version)."

# Disco (necesita ~2 GB libres para compilación de gems + paquetes)
FREE_GB=$(df --output=avail / | tail -1 | awk '{print int($1/1024/1024)}')
[ "$FREE_GB" -lt 2 ] && die "Solo ${FREE_GB} GB libres en /. Necesitas ≥ 2 GB."
log "  ↳ Disco: ${FREE_GB} GB libres ✓"

# RAM
MEM_GB=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
if [ "$MEM_GB" -lt 1 ]; then
    die "Solo ${MEM_GB} GB de RAM. Mínimo absoluto: 1 GB."
elif [ "$MEM_GB" -lt 4 ]; then
    warn "Solo ${MEM_GB} GB de RAM. Para 300 nodos se recomiendan ≥ 8 GB."
else
    log "  ↳ RAM: ${MEM_GB} GB ✓"
fi

# Internet (solo si vamos a instalar paquetes)
if [ $UPDATE_ONLY -eq 0 ]; then
    if ! curl -fsSL --max-time 10 https://deb.debian.org/ >/dev/null 2>&1; then
        die "Sin internet (no llego a deb.debian.org). Verifica DNS/firewall."
    fi
    log "  ↳ Internet: OK ✓"
fi

# ===========================================================================
# 2. Capturar entrada (env vars o prompts)
# ===========================================================================
NON_INTERACTIVE="${OX_NON_INTERACTIVE:-0}"

# SERVER_IP
if [ -n "${OX_SERVER_IP:-}" ]; then
    SERVER_IP="$OX_SERVER_IP"
else
    [ "$NON_INTERACTIVE" = "1" ] && die "OX_SERVER_IP requerido en modo no-interactivo"
    echo ""
    DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    read -r -p "🌐 IP del servidor [${DETECTED_IP:-introducir}]: " SERVER_IP
    SERVER_IP=${SERVER_IP:-$DETECTED_IP}
fi
[ -n "$SERVER_IP" ] || die "SERVER_IP vacío."

# WEB_PASS
if [ -n "${OX_WEB_PASS:-}" ]; then
    WEB_PASS="$OX_WEB_PASS"
else
    [ "$NON_INTERACTIVE" = "1" ] && die "OX_WEB_PASS requerido en modo no-interactivo"
    echo ""
    echo "🔐 Password 'admin' (basic auth web):"
    while true; do
        read -r -s -p "  Contraseña: " WEB_PASS; echo
        read -r -s -p "  Confirma:   " WEB_PASS2; echo
        [ -n "$WEB_PASS" ] && [ "$WEB_PASS" = "$WEB_PASS2" ] && break
        echo "    ↳ Vacía o no coinciden. Reintenta."
    done
    unset WEB_PASS2
fi

# Telegram (opcional)
TG_TOKEN="${OX_TG_TOKEN:-}"
TG_CHAT_ID="${OX_TG_CHAT_ID:-}"
if [ -z "$TG_TOKEN" ] && [ "$NON_INTERACTIVE" != "1" ]; then
    echo ""
    echo "📱 Telegram (Enter para omitir):"
    read -r -p "  Token del bot: " TG_TOKEN
    read -r -p "  Chat ID:       " TG_CHAT_ID
fi

# MikroTik creds
MK_USER="${OX_MK_USER:-}"
if [ -z "$MK_USER" ]; then
    if [ "$NON_INTERACTIVE" = "1" ]; then
        MK_USER="Respaldo"
    else
        echo ""
        read -r -p "🔧 Usuario MikroTik [Respaldo]: " MK_USER
        MK_USER=${MK_USER:-Respaldo}
    fi
fi

MK_PASS="${OX_MK_PASS:-}"
if [ -z "$MK_PASS" ]; then
    if [ "$NON_INTERACTIVE" = "1" ]; then
        warn "OX_MK_PASS vacío → se usará 'CAMBIAR_ME'. Editar config manualmente."
        MK_PASS="CAMBIAR_ME"
    else
        read -r -s -p "  Password MikroTik: " MK_PASS; echo
        if [ -z "$MK_PASS" ]; then
            warn "Password vacío → 'CAMBIAR_ME' (editar config antes de usar)"
            MK_PASS="CAMBIAR_ME"
        fi
    fi
fi

# ===========================================================================
# 3. Instalación de paquetes (omitido en modo --update-only)
# ===========================================================================
if [ $UPDATE_ONLY -eq 0 ]; then
    # --- Caddy APT repo ---
    if ! command -v caddy >/dev/null 2>&1; then
        log ""
        log "📦 Añadiendo repo oficial de Caddy..."
        apt_safe update -y
        apt_safe install -y debian-keyring debian-archive-keyring \
            apt-transport-https curl gnupg

        retry 3 bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
        retry 3 bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list"
    fi

    # --- Sistema ---
    log "📦 Instalando deps del sistema..."
    apt_safe update -y
    apt_safe install -y \
        caddy openssh-client jq git ca-certificates \
        ruby ruby-dev build-essential pkg-config \
        libssl-dev libsqlite3-dev libxml2-dev libxslt1-dev zlib1g-dev libicu-dev \
        ruby-rugged

    # --- Usuario sistema 'oxidized' ---
    if ! id "${OX_USER}" >/dev/null 2>&1; then
        log "👤 Creando usuario sistema '${OX_USER}'..."
        useradd --system --create-home --home-dir "${OX_HOME}" \
            --shell /usr/sbin/nologin --comment "Oxidized" "${OX_USER}"
    fi
    mkdir -p "${OX_HOME}"
    chown "${OX_USER}:${OX_USER}" "${OX_HOME}"

    # --- Oxidized + oxidized-web vía gem (pinneado) ---
    if ! gem list -i oxidized -v "${OXIDIZED_VERSION}" >/dev/null 2>&1; then
        log "💎 Instalando oxidized ${OXIDIZED_VERSION}..."
        retry 3 gem install --no-document --conservative \
            oxidized -v "${OXIDIZED_VERSION}"
    fi
    if ! gem list -i oxidized-web -v "${OXIDIZED_WEB_VERSION}" >/dev/null 2>&1; then
        log "💎 Instalando oxidized-web ${OXIDIZED_WEB_VERSION}..."
        retry 3 gem install --no-document \
            oxidized-web -v "${OXIDIZED_WEB_VERSION}"
    fi
    OX_BIN=$(command -v oxidized) || die "oxidized no está en PATH tras gem install"
    log "  ↳ binario: ${OX_BIN}"
else
    # En modo --update-only, ya debe estar instalado
    OX_BIN=$(command -v oxidized) || die "oxidized no instalado (no uses --update-only en VPS limpio)"
fi

# Parar servicios para reescribir configs limpio
systemctl stop oxidized 2>/dev/null || true

# ===========================================================================
# 4. SSH keypair
# ===========================================================================
mkdir -p "${OX_SSH_DIR}"
if [ ! -f "${OX_SSH_DIR}/id_oxidized" ]; then
    log ""
    log "🔑 Generando llave SSH ed25519..."
    ssh-keygen -t ed25519 -f "${OX_SSH_DIR}/id_oxidized" -N "" \
        -C "oxidized@$(hostname)" -q
fi
chown -R "${OX_USER}:${OX_USER}" "${OX_SSH_DIR}"
chmod 700 "${OX_SSH_DIR}"
chmod 600 "${OX_SSH_DIR}/id_oxidized"
chmod 644 "${OX_SSH_DIR}/id_oxidized.pub"

# ===========================================================================
# 5. bcrypt hash para Caddy
# ===========================================================================
log "🔐 Calculando hash bcrypt..."
ADMIN_HASH=$(caddy hash-password --plaintext "$WEB_PASS" 2>/dev/null)
unset WEB_PASS
[ -n "$ADMIN_HASH" ] || die "Falló caddy hash-password."

# ===========================================================================
# 6. Caddyfile
# ===========================================================================
log "🛡️  Escribiendo Caddyfile..."
backup_if_exists "${CADDY_DIR}/Caddyfile"
cat > "${CADDY_DIR}/Caddyfile" << EOF
{
    admin off
    auto_https disable_redirects
}

http://${SERVER_IP} {
    bind ${SERVER_IP}
    redir https://{host}{uri} permanent
}

https://${SERVER_IP} {
    bind ${SERVER_IP}
    tls internal

    basic_auth {
        admin ${ADMIN_HASH}
    }

    reverse_proxy 127.0.0.1:8888 {
        header_up X-Real-IP {remote_host}
    }

    encode gzip

    log {
        output stdout
        format console
    }
}
EOF
chown root:caddy "${CADDY_DIR}/Caddyfile"
chmod 640 "${CADDY_DIR}/Caddyfile"
unset ADMIN_HASH

# ===========================================================================
# 7. sysctls (TCP tuning para 300 SSH concurrentes)
# ===========================================================================
log "🔧 Aplicando sysctls..."
cat > /etc/sysctl.d/90-oxidized.conf << 'EOF'
# Tuning para Oxidized → ~300 MikroTik por SSH/WAN
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 120
net.ipv4.ip_local_port_range = 15000 65000
net.core.somaxconn = 1024
EOF
sysctl --system >/dev/null

# ===========================================================================
# 8. Config de Oxidized (tuneado)
#    Heredoc unquoted con backslashes escapados (\\w, \\s, \\$)
# ===========================================================================
mkdir -p "${OX_CONF_DIR}"
log "⚙️  Escribiendo config Oxidized..."
backup_if_exists "${OX_CONF_DIR}/config"
cat > "${OX_CONF_DIR}/config" << EOF
---
username: ${MK_USER}
password: ${MK_PASS}
model: routeros

# Tuneado para ~300 MikroTik WAN
interval: 21600
threads: 15
timeout: 90
retries: 3
use_max_threads: false

use_syslog: false
debug: false
prompt_format: !ruby/regexp /^(\\[[^\\]]+\\][>#]|[\\w.@-]+[#>])\\s?\$/

extensions:
  oxidized-web:
    load: true
    listen: 127.0.0.1
    port: 8888

input:
  default: ssh
  ssh:
    secure: false
  keepalive:
    interval: 30
    maxcount: 3

vars:
  routeros_short_prompt: true
  resolve_dns: false
  remove_secret: true
  ssh_keys: "${OX_SSH_DIR}/id_oxidized"
  auth_methods:
    - publickey
    - password

groups:
  mikrotiks:
    username: ${MK_USER}
    password: ${MK_PASS}

hooks:
  telegram_alert:
    type: exec
    events: [post_store, node_fail]
    cmd: ${OX_CONF_DIR}/telegram.sh

source:
  default: csv
  csv:
    file: "${OX_CONF_DIR}/router.db"
    delimiter: !ruby/regexp /:/
    map:
      name: 0
      model: 1
      group: 2
      ip: 3
    vars_map:
      ssh_port: 4

output:
  default: git
  git:
    user: Oxidized
    email: backups@tu-red.local
    repo: "${OX_CONF_DIR}/backups.git"
EOF
unset MK_PASS

# ===========================================================================
# 9. router.db (no se sobrescribe si existe)
# ===========================================================================
if [ ! -f "${OX_CONF_DIR}/router.db" ]; then
    log "📝 Creando router.db de ejemplo..."
    cat > "${OX_CONF_DIR}/router.db" << 'EOF'
Router-Principal:routeros:mikrotiks:205.235.6.153:2288
EOF
fi

# ===========================================================================
# 10. telegram.env + telegram.sh
# ===========================================================================
log "📱 Escribiendo telegram.env / telegram.sh..."
backup_if_exists "${OX_CONF_DIR}/telegram.env"
{
    echo "TG_TOKEN=${TG_TOKEN:-TU_TOKEN_AQUI}"
    echo "TG_CHAT_ID=${TG_CHAT_ID:-TU_ID_AQUI}"
} > "${OX_CONF_DIR}/telegram.env"

backup_if_exists "${OX_CONF_DIR}/telegram.sh"
cat > "${OX_CONF_DIR}/telegram.sh" << EOF
#!/bin/bash
set -u
ENV_FILE="${OX_CONF_DIR}/telegram.env"
REPO="${OX_CONF_DIR}/backups.git"

[ -f "\$ENV_FILE" ] || exit 0
# shellcheck disable=SC1090
. "\$ENV_FILE"

[ -z "\${TG_TOKEN:-}" ] && exit 0
[ -z "\${TG_CHAT_ID:-}" ] && exit 0
[ "\$TG_TOKEN" = "TU_TOKEN_AQUI" ] && exit 0
[ "\$TG_CHAT_ID" = "TU_ID_AQUI" ] && exit 0

case "\${OX_EVENT:-}" in
    node_fail)
        MSG="❌ *ALERTA Oxidized*%0AFalló: %0A*Nombre:* \${OX_NODE_NAME}%0A*IP:* \${OX_NODE_IP}"
        ;;
    post_store)
        # Solo notificar si el último commit tocó este nodo
        if [ -d "\$REPO" ]; then
            if ! git -C "\$REPO" log -1 --name-only --pretty=format: 2>/dev/null \\
                | grep -qF "\${OX_NODE_NAME}"; then
                exit 0
            fi
        fi
        MSG="✅ *Cambio respaldado*%0A*Nombre:* \${OX_NODE_NAME}%0A*IP:* \${OX_NODE_IP}"
        ;;
    *)
        exit 0
        ;;
esac

curl -fsS -X POST "https://api.telegram.org/bot\${TG_TOKEN}/sendMessage" \\
    -d chat_id="\${TG_CHAT_ID}" \\
    -d text="\${MSG}" \\
    -d parse_mode="Markdown" >/dev/null || true
EOF
unset TG_TOKEN TG_CHAT_ID

# ===========================================================================
# 11. systemd: unit principal + restart timer + git gc timer
# ===========================================================================
log "🔒 Escribiendo unit systemd con hardening..."
cat > /etc/systemd/system/oxidized.service << EOF
[Unit]
Description=Oxidized network device configuration backup tool
Documentation=https://github.com/ytti/oxidized
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OX_USER}
Group=${OX_USER}
WorkingDirectory=${OX_HOME}
Environment="HOME=${OX_HOME}"
ExecStart=${OX_BIN}
Restart=on-failure
RestartSec=10
LimitNOFILE=16384

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${OX_HOME}
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

log "⏱️  Timer: restart preventivo semanal..."
cat > /etc/systemd/system/oxidized-restart.service << 'EOF'
[Unit]
Description=Restart preventivo de oxidized

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart oxidized
EOF

cat > /etc/systemd/system/oxidized-restart.timer << 'EOF'
[Unit]
Description=Restart preventivo semanal

[Timer]
OnCalendar=Sun 04:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

log "🧹 Timer: git gc semanal..."
cat > /etc/systemd/system/oxidized-gitgc.service << EOF
[Unit]
Description=git gc del repo de backups

[Service]
Type=oneshot
User=${OX_USER}
Group=${OX_USER}
WorkingDirectory=${OX_CONF_DIR}/backups.git
ExecStart=/usr/bin/git gc --aggressive --prune=now
EOF

cat > /etc/systemd/system/oxidized-gitgc.timer << 'EOF'
[Unit]
Description=git gc semanal

[Timer]
OnCalendar=Sun 05:00
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF

# ===========================================================================
# 12. Ownership y permisos finales
# ===========================================================================
log "🔒 Aplicando permisos..."
chown -R "${OX_USER}:${OX_USER}" "${OX_HOME}"
chmod 700 "${OX_CONF_DIR}"
chmod 600 "${OX_CONF_DIR}/config"
chmod 600 "${OX_CONF_DIR}/telegram.env"
chmod 750 "${OX_CONF_DIR}/telegram.sh"
chmod 640 "${OX_CONF_DIR}/router.db"

# ===========================================================================
# 13. Documentación generada (DISTRIBUIR_LLAVE.md, RESTORE.md)
# ===========================================================================
PUBKEY_CONTENT=$(cat "${OX_SSH_DIR}/id_oxidized.pub")

cat > "${DOC_DIR}/DISTRIBUIR_LLAVE.md" << EOF
# Distribuir llave SSH a los MikroTik

## 1. Pubkey

\`\`\`
${PUBKEY_CONTENT}
\`\`\`

## 2. En cada MikroTik (WinBox/SSH como admin)

\`\`\`
/user group add name=backup-readonly \\
    policy=ssh,read,test,sensitive,!write,!policy,!api,!ftp,!reboot,!winbox,!web,!password

/user add name=${MK_USER} group=backup-readonly \\
    address=${SERVER_IP}/32 password=<password-fallback>
\`\`\`

> Sin **sensitive**, \`/export\` censura passwords/PSK con \`[FILTERED]\`.

## 3. Importar la pubkey

\`\`\`bash
sudo -u oxidized scp -P <puerto> ${OX_SSH_DIR}/id_oxidized.pub \\
    ${MK_USER}@<IP_MIKROTIK>:oxidized.pub
sudo -u oxidized ssh -p <puerto> ${MK_USER}@<IP_MIKROTIK> \\
    "/user ssh-keys import public-key-file=oxidized.pub user=${MK_USER}"
\`\`\`

## 4. Bulk para 300 nodos (necesita sshpass)

\`\`\`bash
apt install -y sshpass
sudo -u oxidized bash -c '
while IFS=: read -r name model group ip port; do
    [ -z "\$ip" ] && continue
    port=\${port:-22}
    echo "→ \$name (\$ip:\$port)"
    sshpass -p "<PASS>" scp -P "\$port" -o StrictHostKeyChecking=accept-new \\
        ${OX_SSH_DIR}/id_oxidized.pub ${MK_USER}@\$ip:oxidized.pub
    sshpass -p "<PASS>" ssh -p "\$port" ${MK_USER}@\$ip \\
        "/user ssh-keys import public-key-file=oxidized.pub user=${MK_USER}"
done < ${OX_CONF_DIR}/router.db
'
\`\`\`

## 5. Endurecimiento

Cuando TODOS los MikroTik tengan la llave, edita config y quita los
\`password:\` (global y por grupo). Deja \`auth_methods: [publickey]\`.
EOF

cat > "${DOC_DIR}/RESTORE.md" << EOF
# Disaster Recovery — Oxidized

## A respaldar off-site

\`\`\`
/etc/caddy/Caddyfile
/etc/systemd/system/oxidized.service
/etc/systemd/system/oxidized-restart.{service,timer}
/etc/systemd/system/oxidized-gitgc.{service,timer}
/etc/sysctl.d/90-oxidized.conf
${OX_HOME}/
├── .ssh/                   ← llave SSH a MikroTiks
└── .config/oxidized/
    ├── config              ← credenciales + tuning
    ├── router.db
    ├── telegram.env
    ├── telegram.sh
    └── backups.git/        ← TODO el histórico (LO CRÍTICO)
\`\`\`

## Mirror del repo git (recomendado)

\`\`\`bash
sudo -u ${OX_USER} git -C ${OX_CONF_DIR}/backups.git \\
    remote add origin git@TU-GITEA:netops/mikrotik-backups.git

sudo -u ${OX_USER} bash -c '
( crontab -l 2>/dev/null; \\
  echo "0 3 * * * git -C ${OX_CONF_DIR}/backups.git push --mirror origin" \\
) | crontab -'
\`\`\`

## Restore desde cero

1. VPS Debian 13 nuevo.
2. Volcar archivos del backup off-site.
3. Re-correr instalador (idempotente, hace .bak).
4. \`git clone --mirror <backup> ${OX_CONF_DIR}/backups.git\`
5. \`chown -R ${OX_USER}:${OX_USER} ${OX_HOME}\`
6. \`systemctl restart oxidized caddy\`
EOF

# ===========================================================================
# 14. Habilitar y arrancar todo
# ===========================================================================
log ""
log "▶️  Habilitando servicios y timers..."
systemctl daemon-reload
systemctl enable oxidized caddy oxidized-restart.timer oxidized-gitgc.timer >/dev/null 2>&1 || true
systemctl restart caddy
systemctl restart oxidized

# ===========================================================================
# 15. SELF-TEST end-to-end
# ===========================================================================
log ""
log "🧪 Self-test..."

# Esperar a que oxidized arranque el extension web (~5-10 s)
self_test_pass=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if ss -tln 2>/dev/null | grep -q "127.0.0.1:8888"; then
        self_test_pass=1
        break
    fi
    sleep 1
done

if [ "$self_test_pass" = "1" ]; then
    ok "Oxidized REST escuchando en 127.0.0.1:8888"
else
    warn "Oxidized REST NO está escuchando — revisa: journalctl -u oxidized -n 50"
fi

# Test Caddy en puerto 443
if ss -tln 2>/dev/null | grep -q "${SERVER_IP}:443"; then
    ok "Caddy escuchando en ${SERVER_IP}:443"
else
    warn "Caddy NO escucha 443 — revisa: journalctl -u caddy -n 50"
fi

# Test HTTPS responde (cualquier código != 000 cuenta como conectó)
HTTP_CODE=$(curl -ks -o /dev/null -w "%{http_code}" --max-time 5 \
    "https://${SERVER_IP}/" 2>/dev/null || echo "000")
case "$HTTP_CODE" in
    401) ok "HTTPS responde 401 (basic auth requerido) — OK" ;;
    200|302) ok "HTTPS responde ${HTTP_CODE} — OK" ;;
    000)     warn "HTTPS no responde (connect failed)" ;;
    502|503) warn "HTTPS responde ${HTTP_CODE} (Caddy no llega al backend)" ;;
    *)       warn "HTTPS responde ${HTTP_CODE} (inesperado)" ;;
esac

# ===========================================================================
# 16. Resumen
# ===========================================================================
echo ""
echo "============================================================"
echo "✅ INSTALACIÓN FINALIZADA"
echo "------------------------------------------------------------"
echo "  Web:        https://${SERVER_IP}/   (usuario: admin)"
echo "  Versiones:  oxidized ${OXIDIZED_VERSION} + oxidized-web ${OXIDIZED_WEB_VERSION}"
echo ""
echo "  Tuning aplicado:"
echo "      threads=15  timeout=90s  retries=3  interval=6h"
echo "      LimitNOFILE=16384  SSH keepalive 30s"
echo "      Restart preventivo: domingo 04:00"
echo "      git gc:             domingo 05:00"
echo ""
echo "  Comandos útiles:"
echo "      systemctl status oxidized caddy"
echo "      journalctl -u oxidized -f"
echo "      systemctl list-timers oxidized-*"
echo ""
echo "  Próximos pasos:"
echo "      1. nano ${OX_CONF_DIR}/router.db   (inventario de MikroTik)"
echo "      2. nano ${OX_CONF_DIR}/config      (si MK_PASS=CAMBIAR_ME)"
echo "      3. systemctl restart oxidized"
echo "      4. cat ${DOC_DIR}/DISTRIBUIR_LLAVE.md"
echo ""
if systemctl is-active --quiet oxidized && systemctl is-active --quiet caddy; then
    echo "  Estado: Oxidized ✅  Caddy ✅"
else
    echo "  ⚠️ Algún servicio no está activo. Ver logs:"
    echo "      journalctl -u oxidized -n 50"
    echo "      journalctl -u caddy -n 50"
fi
echo "============================================================"
