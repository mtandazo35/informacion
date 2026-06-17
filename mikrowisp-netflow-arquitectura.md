# Arquitectura Netflow Mikrowisp — Ingeniería Inversa

Relevamiento realizado el 2026-06-16 sobre servidor de producción `205.235.2.133`.  
Software: **Mikrowisp v6.65** (ISP management, PHP IonCube, MariaDB).  
ISP: ~2014 clientes activos, 3 routers MikroTik CCR.

---

## Diagrama general

```
MikroTik 1 — VELOCINET          MikroTik 2 — RB 28MARZO
  IP pública: 45.224.152.200      IP pública: 45.224.152.205
  Modelo: CCR2216-1G-12XS         Modelo: CCR2116-12G-4S+
  VPN IP:  10.8.0.2               VPN IP:  10.8.0.3
  Redes:   10.10.0.0/22           Redes:   10.10.60.0/23
           10.40.0.0/23                    (GPON 28 de Marzo)
           10.0.x.0/25 (x=0..15)
           20.0.0.0/23
        │                               │
        │         OpenVPN TCP:1194      │
        └──────────────┬────────────────┘
                       │
          MikroTik 3 — Core Provincias Unidas
            IP pública: 45.224.152.204
            Modelo: CCR2116-12G-4S+
            VPN IP:  10.8.0.4
            Redes:   10.10.22.0/23
                     10.10.14.0/23
                     10.10.10.0/24
                       │
          ┌────────────▼──────────────────────────┐
          │   Servidor Mikrowisp  205.235.2.133    │
          │   tun0: 10.8.0.1/24                   │
          │                                        │
          │   ┌──────────────────────────────────┐ │
          │   │  nfcapd  UDP:9996                │ │
          │   │  -t 60 (rota cada 60s)           │ │
          │   │  -n 1,10.8.0.2,flows/1           │ │
          │   │  -n 2,10.8.0.3,flows/2           │ │
          │   │  -n 4,10.8.0.4,flows/4           │ │
          │   └──────────┬───────────────────────┘ │
          │              │ archivos nfcapd.YYYYMMDDhhmm │
          │   ┌──────────▼───────────────────────┐ │
          │   │  flow.php (cron */5 min)          │ │
          │   │  lee con nfdump                  │ │
          │   │  → trafico_tmp (DB)              │ │
          │   └──────────────────────────────────┘ │
          │                                        │
          │   Apache + PHP-FPM  Apache + FreeRADIUS│
          │   MariaDB: Mikrowisp6                  │
          │   Node.js (w.js — notificaciones)      │
          └────────────────────────────────────────┘
```

---

## Componentes y puertos

| Servicio      | Puerto         | Propósito                            |
|---------------|----------------|--------------------------------------|
| OpenVPN       | TCP 1194       | Túnel hacia los 3 routers MikroTik   |
| nfcapd        | UDP 9996       | Colector NetFlow v9                  |
| Apache        | TCP 80/443     | Panel web Mikrowisp                  |
| MariaDB       | TCP 3306 local | Base de datos                        |
| FreeRADIUS    | UDP 1812/1813  | Autenticación PPPoE clientes         |
| SSH           | TCP 22         | Administración                       |

---

## Cómo corre nfcapd

### Comando exacto en producción
```bash
/usr/local/bin/nfcapd \
  -E \                          # extended mode (más campos NetFlow)
  -p 9996 \                     # puerto UDP de escucha
  -t 60 \                       # rotación de archivos cada 60 segundos
  -n 1,10.8.0.2,/var/www/html/flows/1 \
  -n 2,10.8.0.3,/var/www/html/flows/2 \
  -n 4,10.8.0.4,/var/www/html/flows/4
```

**No tiene service systemd** — arranca manualmente o desde Mikrowisp al levantar el servidor.  
La clave de la bandera `-n` es: `id_fuente,ip_origen_udp,directorio_destino`.  
Como cada MikroTik tiene IP VPN fija, nfcapd sabe a qué directorio escribir.

### src.txt (mapa de fuentes para Mikrowisp)
```
1,10.8.0.2,/var/www/html/flows/1
2,10.8.0.3,/var/www/html/flows/2
4,10.8.0.4,/var/www/html/flows/4
```

### Archivos que genera
```
/var/www/html/flows/1/nfcapd.202606161805   (~21 MB por minuto)
/var/www/html/flows/1/nfcapd.202606161806
/var/www/html/flows/1/nfcapd.current.XXXXXX  (en escritura activa)
```

### Leer los flows (nfdump)
```bash
nfdump -r /var/www/html/flows/1/nfcapd.202606161805 -c 10
# Salida:
# Date first seen  Duration  Proto  Src IP:Port  Dst IP:Port  Packets  Bytes
# 2026-06-16 18:04:23  00:00:15  TCP  10.40.0.14:37282 -> 172.217.28.106:443   4  266
```

---

## Esquema de base de datos (tablas clave)

### `server` — Los 3 routers MikroTik
```
id  nodo                     ip           estado     flow  openvpn  port_api
1   VELOCINET                10.8.0.2     CONECTADO  1     0        8728
2   RB 28MARZO               10.8.0.3     CONECTADO  1     0        8728
4   Core Provincias Unidas   10.8.0.4     CONECTADO  1     0        8728
```
- `flow=1` activa la captura NetFlow desde ese router.
- `velocidad=queues` → controla ancho de banda vía Simple Queues (no PCQ).
- API RouterOS en puerto 8728/8730 con credenciales en base64.

### `ipv4` — Pools de IPs por router
```
id  nodo  nombre            red          cidr  tipo  rangos
30  1     Red OLT HUAWEI    10.10.0.0    22    0     10.10.0.0,10.10.1.0,10.10.2.0,10.10.3.0
40  4     Red 2 Provincias  10.10.22.0   23    0     10.10.22.0,10.10.23.0
44  2     RED GPON 28MARZO  10.10.60.0   23    0     10.10.60.0,10.10.61.0
```

### `usuarios` — Clientes ISP (2014 activos)
Campos relevantes: `id, nombre, ip, router (FK→server.id), plan (FK→perfiles.id), estado, user (PPPoE/RADIUS user)`

### `conexiones` — Sesiones activas
```
id  ip           src          user        router
    10.10.2.44   10.8.0.2     pppoe_user  1
```
- `ip` = IP del cliente
- `src` = IP del router VPN que lo sirve
- Se usa para correlacionar flows → usuario

### `trafico_tmp` — Tráfico procesado por flow.php
```
id  src           bytes   user        tipo  router
    10.10.2.44    208     pppoe_user  1     1
```
- `tipo` probable: 1=download, 0=upload
- `flow.php` matchea `nfdump src IP` → `conexiones.ip` → `usuarios.user`

### `perfiles` — Planes de servicio
```
id  plan                  costo   velocidad
2   Plan Domicilio 150    17.00   50000K/50000K
3   Plan Turbo 250        20.00   750000K/750000K
25  Plan Ultra 350        25.00   100000K/100000K
26  Plan Max 450          30.00   125000K/125000K
27  Plan Hyper 550        35.00   150000K/150000K
```
- `velocidad` es el nombre del Queue en MikroTik
- Mikrowisp crea/actualiza los Queues vía RouterOS API

### `radcheck` / `radreply` / `radusergroup` — FreeRADIUS
Tablas estándar de FreeRADIUS, Mikrowisp las gestiona directamente via DB.

---

## Flujo completo de un cliente

```
1. Cliente se conecta PPPoE a MikroTik
        ↓
2. MikroTik → FreeRADIUS (UDP 1812) → radcheck/usuarios
        ↓
3. RADIUS acepta → cliente obtiene IP del pool (ipv4)
        ↓
4. Mikrowisp registra conexión en tabla `conexiones`
        ↓
5. MikroTik crea Simple Queue para el cliente
   (vía RouterOS API port 8728 desde cron `lanzador.php`)
        ↓
6. MikroTik exporta NetFlow v9 → nfcapd UDP:9996
   (usando IP VPN del túnel OpenVPN, no la pública)
        ↓
7. nfcapd escribe nfcapd.YYYYMMDDhhmm cada 60s
        ↓
8. flow.php (cada 5 min) → nfdump lee los archivos
   → matchea src_ip con conexiones.ip
   → acumula bytes en trafico_tmp
        ↓
9. Mikrowisp web muestra gráficos de tráfico por cliente
```

---

## Configuración OpenVPN (transporte de flows)

```ini
# /etc/openvpn/server/server.conf
local 205.235.2.133
port 1194
proto tcp
dev tun
topology subnet
server 10.8.0.0 255.255.255.0
auth SHA1
data-ciphers AES-256-CBC
client-config-dir /etc/openvpn/mikrowisp    # IPs fijas por cliente
up /etc/openvpn/mikrowisp/rutas.sh          # rutas al levantar
```

IPs fijas por cliente (CN del certificado):
```bash
# /etc/openvpn/mikrowisp/<common-name>  (archivo vacío = sin rutas especiales)
# Las rutas se inyectan en rutas.sh con 'route add -net X gw 10.8.0.Y'
```

---

## Instalación nfdump en servidor nuevo

```bash
# Opción 1: paquete (versión vieja pero funcional)
apt install nfdump

# Opción 2: compilar v1.7.6 (la que usa producción)
apt install -y build-essential libpcap-dev libbz2-dev libzstd-dev autoconf automake
wget https://github.com/phaag/nfdump/archive/refs/tags/v1.7.6.tar.gz
tar xf v1.7.6.tar.gz && cd nfdump-1.7.6
./autogen.sh && ./configure --enable-zstd --enable-bzip2
make -j$(nproc) && make install
```

## Servicio systemd para nfcapd (producción no lo tiene, recomendado)

```ini
# /etc/systemd/system/nfcapd.service
[Unit]
Description=NetFlow Collector nfcapd
After=network.target openvpn-server@server.service

[Service]
User=www-data
ExecStart=/usr/local/bin/nfcapd -E -p 9996 -t 60 \
  -n 1,10.8.0.2,/var/www/html/flows/1 \
  -n 2,10.8.0.3,/var/www/html/flows/2 \
  -n 4,10.8.0.4,/var/www/html/flows/4
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
mkdir -p /var/www/html/flows/{1,2,4}
chown -R www-data:www-data /var/www/html/flows/
systemctl enable --now nfcapd
```

## Configurar MikroTik para exportar NetFlow

```routeros
# En cada MikroTik, apuntar al IP del túnel VPN del servidor (10.8.0.1)
/ip traffic-flow
  set enabled=yes interfaces=all active-flow-timeout=1m

/ip traffic-flow target
  add dst-address=10.8.0.1 port=9996 version=9
```

## Fix CPU al 100% (overlap de flow.php)

```bash
# Reemplazar en crontab -u www-data -e:
# Antes:
*/5 * * * * /usr/bin/php /var/www/html/admin/cron/flow.php >/dev/null 2>&1

# Después (previene ejecuciones simultáneas):
*/5 * * * * flock -n /tmp/flow.lock /usr/bin/php /var/www/html/admin/cron/flow.php >/dev/null 2>&1
```

---

## Notas para proyecto nuevo

- **nfcapd no necesita Mikrowisp**: es software libre, se puede usar con cualquier stack.
- La clave del diseño es asignar **IP VPN fija a cada router** y usar esa IP como identificador de fuente (`-n id,ip,dir`).
- Los flows se generan desde el **túnel VPN**, no desde la IP pública — el servidor debe ser el gateway VPN.
- Cada minuto se generan archivos de ~20 MB por router activo (escala con el tráfico).
- `nfdump` puede filtrar por IP, protocolo, puerto, rango de tiempo: muy flexible para consultas.
- Para proyecto nuevo: considerar **Elasticsearch/ClickHouse** en lugar de MariaDB para escalar el volumen de flows a largo plazo.
