#!/bin/bash

# --- 0. SOLICITUD DE VARIABLES ---
clear
echo "=========================================================="
echo "      INSTALADOR ISP-MAX - CLOUDFLARE EDITION             "
echo "=========================================================="
read -p ">> Nombre de Empresa (Nombre BD): " EMPRESA
read -p ">> Dominio (app.ejemplo.com): " D_FRONT
echo "=========================================================="

# Validar inputs
if [[ -z "$EMPRESA" || -z "$D_FRONT" ]]; then
    echo "ERROR: Todos los campos son obligatorios."
    exit 1
fi

echo "Iniciando instalación... (Modo Cloudflare SSL)"
echo "El detalle técnico se está guardando en /root/instalador_isp.log"
echo "=========================================================="

# --- CONFIGURACIÓN DE LOGS ---
LOG_FILE="/root/instalador_isp.log"
touch "$LOG_FILE"
exec 3>&1 4>&2
exec >"$LOG_FILE" 2>&1

set -euo pipefail
trap 'echo "ERROR en línea $LINENO. Revisa $LOG_FILE" >&3' ERR

status_update() {
    echo "$1" >&3
}

# --- INICIO DEL PROCESO ---

status_update "[1/7] Configurando memoria SWAP de 2GB..."
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
fi

status_update "[2/7] Instalando paquetes del sistema..."
apt update && apt upgrade -y
apt install -y git wget curl chromium nginx redis-server libreoffice fonts-liberation net-tools postgresql-client

status_update "[3/7] Instalando Node.js 22 LTS..."
wget -qO- https://raw.githubusercontent.com/creationix/nvm/v0.39.0/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install 22
nvm use 22
nvm alias default 22
npm install -g pm2 @quasar/cli
ln -sf "$(which node)" /usr/bin/node
ln -sf "$(which npm)" /usr/bin/npm
ln -sf "$(which pm2)" /usr/bin/pm2
ln -sf "$(which quasar)" /usr/bin/quasar

status_update "[4/7] Restaurando Base de Datos desde nube..."
DB_HOST="205.235.2.151"
DB_USER="postgres"
DB_PASS="FernanS.A2018"
export PGPASSWORD="$DB_PASS"

wget -q "https://database.ispmax.ec/plantilla.sql" -O /home/plantilla.sql

# Creamos la BD si no existe
createdb -h "$DB_HOST" -p 5432 -U "$DB_USER" "$EMPRESA" 2>/dev/null || true

# INTEGRACIÓN DE IMAGEN.PNG: plantilla.sql es formato texto plano, se restaura con psql -f
status_update "Restaurando plantilla en la BD mediante psql..."
psql -h "$DB_HOST" -p 5432 -U "$DB_USER" -d "$EMPRESA" -f /home/plantilla.sql

unset PGPASSWORD

status_update "[5/7] Configurando Backend y persistencia PM2..."
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use 22

npm install -g @nestjs/cli

GH_TOKEN="TU_GITHUB_PERSONAL_ACCESS_TOKEN"
mkdir -p /home/isp-max
cd /home/isp-max
rm -rf backend
git clone "https://Ferjebay:${GH_TOKEN}@github.com/inigualitysoft/backend-isp.git" backend
cd backend

status_update "Instalando dependencias del Backend..."
npm install

cat > .env <<ENVEOF
STAGE=prod
SISTEMA=linux
DB_PASSWORD=${DB_PASS}
DB_NAME=${EMPRESA}
DB_HOST=${DB_HOST}
DB_PORT=6432
DB_USERNAME=${DB_USER}
PORT=3000
CLIENTE=${EMPRESA}
HOST_API=http://localhost:3000
HOST_WEBSOCKET=https://websocket.isp-max.net
HOST_API_WHATSAPP=https://wapp.maat.ec
DOMINIO=https://${D_FRONT}
URL_SLACK=https://hooks.slack.com/services/TU_SLACK_WEBHOOK_URL
INTERVALO_MINUTOS=0
LIBREOFFICE_PATH_LINUX="/usr/bin/soffice"
LIBREOFFICE_CWD_LINUX="/usr/bin"
HOST_API_FACTURACION=https://apifact.inigualitysoft.com/api
JWT_SECRET=8f9a2b7c4e6d1a3f5b8c9e2d4a7b1c6e9f3a5b8d2c7e4a9b6d1f3c8e5a2b7d4
ENVEOF

status_update "Compilando Backend..."
./node_modules/.bin/nest build

pm2 delete "BACK-ISP" 2>/dev/null || true
pm2 start dist/main.js --name "BACK-ISP"
pm2 save

status_update "Registrando PM2 como servicio systemd (autostart al reiniciar)..."
NODE_BIN_DIR="$(dirname "$(which node)")"
PM2_BIN="$(which pm2)"

cat > /etc/systemd/system/pm2-root.service <<SYSDEOF
[Unit]
Description=PM2 process manager for root
Documentation=https://pm2.keymetrics.io/
After=network.target

[Service]
Type=forking
User=root
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Environment=PATH=${NODE_BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PM2_HOME=/root/.pm2
PIDFile=/root/.pm2/pm2.pid
Restart=on-failure

ExecStart=${PM2_BIN} resurrect
ExecReload=${PM2_BIN} reload all
ExecStop=${PM2_BIN} kill

[Install]
WantedBy=multi-user.target
SYSDEOF

systemctl daemon-reload
systemctl enable pm2-root.service
systemctl restart pm2-root.service

# Aseguramos que nginx y redis arranquen en el boot
systemctl enable nginx
systemctl enable redis-server

status_update "[6/7] Compilando Frontend Quasar..."
cd /home/isp-max
rm -rf frontend
git clone "https://Ferjebay:${GH_TOKEN}@github.com/inigualitysoft/frontend-isp.git" frontend
cd frontend
npm install

cat > .env <<ENVEOF
VITE_VUE_APP_KEY_JWT=3St03SMyPuBliCK3y
VITE_API_WHATSAPP=https://wapp.maat.ec
VITE_WEBSOCKET=https://websocket.isp-max.net
VITE_CONSUMIDOR_FINAL_ID=c6bd5731-c659-4a2a-8c5f-375d3aa495aa
VITE_BASE_URL=/api
VITE_COMPANY_NAME=${EMPRESA}
VITE_HOST_API_FACTURACION=https://apifact.inigualitysoft.com/api
VITE_HOST_KEY_PERMISOS=Qu4s4r!Pr0t3g3-M1s*P3rm1s0s#2024@S3gur0
ENVEOF

status_update "Compilando Frontend..."
export NODE_OPTIONS="--max-old-space-size=3072"
./node_modules/.bin/quasar build

mkdir -p /var/www/isp-front
rm -rf /var/www/isp-front/*
cp -r dist/spa/* /var/www/isp-front/
chown -R www-data:www-data /var/www/isp-front
chmod -R 755 /var/www/isp-front

status_update "[7/7] Configurando Nginx..."
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/frontend <<NGINXEOF
server {
  listen 80;
  server_name ${D_FRONT};
  root /var/www/isp-front;
  index index.html;

  location ^~ /api/ {
    client_max_body_size 500M;
    proxy_pass http://localhost:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_cache_bypass \$http_upgrade;
    
    proxy_read_timeout 300s;
    proxy_connect_timeout 300s;
    proxy_send_timeout 300s;
  }

  location / {
    try_files \$uri \$uri/ /index.html;
  }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/frontend /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# --- FINALIZACIÓN ---
exec 1>&3 2>&4

echo -e "\n"
echo "=========================================================="
echo "          ¡INSTALACIÓN COMPLETADA CON ÉXITO!              "
echo "=========================================================="
echo -e "Acceso: \e[32mhttps://${D_FRONT}\e[0m"
echo "=========================================================="
echo "Log: /root/instalador_isp.log"
echo "=========================================================="

chmod +x "$0" 2>/dev/null || true
