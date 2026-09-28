# Arquitectura de suricata-ids-lab

IDS para ISP: mira el tráfico de los abonados por un espejo del MikroTik, decide qué CPE
está infectado, y puede cortarlo en el propio router.

Repositorio: `github.com/mtandazo35/suricata-ids-lab` · instalación con un one-liner.

---

## 1. La decisión que explica todo lo demás

**Todo el sistema vive en un solo archivo: `install-suricata.sh` (~17.400 líneas).**

Dentro, cada programa va como *heredoc*: el instalador los escribe en disco al ejecutarse.
No hay paquetes, ni dependencias externas de Python, ni repositorio que clonar en la caja.

Se hizo así porque el despliegue típico es *"una VPS limpia y un one-liner"*, a veces en
casa de un cliente y sin más herramientas que `curl`. Un solo archivo se descarga, se lee
entero antes de ejecutarlo y se versiona con un solo SHA.

El precio es real y conviene conocerlo: un archivo enorme, y **no se puede editar con las
herramientas normales** — hay que parchearlo con scripts, porque los heredocs largos se
rompen al pasarlos por el shell.

Lo que compensa ese precio es `validar.sh` (sección 6).

---

## 2. Por dónde entra el tráfico

```text
   MikroTik del cliente
        |
        |  /ip firewall mangle  action=sniff-tzsp
        |  connection-bytes=0-10000   (solo el arranque de cada conexion)
        |
        v  TZSP sobre UDP/37008
   ┌──────────────────┐
   │  tzsp-decap.py   │  desencapsula, filtra por origen autorizado,
   │  (249 lineas)    │  recorta cada flujo y cuenta lo que pasa
   └────────┬─────────┘
            │  trama Ethernet cruda
            v
      veth: ids-in ──► ids-mon          (una pareja por MikroTik)
            │
            v
   ┌──────────────────┐
   │    Suricata      │  af-packet, un cluster-id por interfaz
   └────────┬─────────┘
            │
            v
   /var/log/suricata/eve.json  +  dns.json
```

**Por qué el veth.** Suricata no entiende TZSP crudo: sólo genera `truncated packet`. El
receptor desencapsula y le entrega tramas Ethernet por un par virtual, que Suricata captura
como si fuera una interfaz real.

**Por qué el recorte.** Suricata detecta en el *arranque* de cada conexión: el SYN, el
handshake TLS con su SNI, la cabecera HTTP, el DNS. Lo demás es payload, y con TLS ni
siquiera se puede inspeccionar. Con un sensor remoto, espejar todo satura el enlace — y
como TZSP va sobre UDP, lo que no cabe **no se retrasa: desaparece**, y Suricata deja de
alertar sin avisar de nada.

**Multi-nodo.** Cada MikroTik tiene su pareja veth (`ids-mon`, `ids-mon2`…) y su
`cluster-id` propio. Sin eso, tres nodos con `10.0.0.x` se confundirían entre sí y un
bloqueo podría ir al router equivocado.

---

## 3. Los programas

| Programa | Tamaño | Qué hace |
|---|---:|---|
| `suricata-dashboard` | ~12.400 líneas | **El panel.** Servidor HTTP propio (stdlib), sin framework. Cuarentena, informes, reputación, ajustes, usuarios, documentación |
| `suricata-html-report` | ~2.270 | Recorre los logs y genera el informe HTML y los JSON que consume el panel |
| `suricata-mikrotik-init` | 286 | Deja el router configurado desde el sensor: address-list, espejo, DNS, fasttrack |
| `tzsp-decap.py` | 249 | Receptor TZSP |
| `suricata-espejo` | 237 | Responde *"¿estoy leyendo tráfico?"* en una línea |
| `suricata-report` | 216 | Informe diario en texto, por Telegram |
| `suricata-feeds-update` | 192 | Baja feeds de reputación con procedencia y caducidad por fuente |
| `suricata-panel-update` | 138 (sh) | Actualiza el panel desde GitHub, con respaldo, validación y rollback |
| `evebox-passwd` | 36 | Clave de EveBox por pty |
| `suricata-rules-update` | 9 (sh) | `suricata-update` + recarga en caliente |

Servicios permanentes: **`suricata`**, **`tzsp-decap`**, **`suricata-dashboard`**.
Temporizadores: informe diario (07:30), reglas ET Open (04:30), logrotate.
Cron: feeds cada 15 min.

---

## 4. Los datos

No hay base de datos salvo una SQLite pequeña. El estado son archivos, y eso es
deliberado: se inspeccionan con `cat`, se respaldan con `cp` y no hay servicio que se caiga.

**Configuración — `/etc/`**

| Archivo | Contenido |
|---|---|
| `suricata-dashboard.conf` | puerto, clave (hasheada), `MIS_REDES`, ventana |
| `suricata-mikrotik.conf` | conexión API al router (600) |
| `suricata-routers.json` | los nodos, con sus credenciales (600) |
| `suricata-publicas.json` | rangos públicos declarados **y el origen de cada uno** |
| `suricata-exclusiones.json` | qué se silencia, por IP + puerto + firma |
| `suricata-nunca-bloquear.lst` | lo que jamás va a cuarentena |
| `suricata-destinos-confianza.lst` | destinos marcados como legítimos |
| `suricata-feeds.conf` | claves de API (600) |

**Estado y resultados — `/var/log/`**

`cuarentena.json` (candidatos), `conducta.json` (informe de 3 días), `metricas.json`
(tendencia, 400 días), `publicas-dnsbl.json` (listas negras + historial de movimientos),
`abonados.json` (mapa IP↔cliente), `bitacora.log` (quién hizo qué),
`dashboard-login.log` (quién intentó entrar), `tzsp.json` (estado del receptor).

**Persistencia — `/var/lib/`**

`suricata-panel/historial.db` (SQLite: lo contado sobrevive a un reinicio y a logrotate),
`suricata-feeds/` (una lista por fuente, con su caducidad), `suricata-geoip/`,
`suricata-mapa/`.

---

## 5. El ciclo de decisión

```text
eve.json ──► suricata-html-report ──► cuarentena.json ──► panel ──► API RouterOS
   (logs)      (cada ~6 h, hilo             (candidatos)     (decide)    (address-list)
                de fondo con nice)
```

**1 · Detectar.** El generador recorre los logs y sus rotados —un informe de 3 días nunca
está en un solo archivo— y sólo cuenta a los abonados dentro de `MIS_REDES`.

**2 · Clasificar.** Cada CPE recibe un nivel de confianza que **cuenta pruebas
independientes, no volumen**: firmas CnC distintas, destino en lista de reputación,
actividad sostenida, patrón compartido con otros CPE, consulta de dominio malicioso. Con
dos o más → **Confirmado**; con una → **Sin confirmar**. Mil alertas de la misma firma
siguen siendo una sola prueba.

**3 · Actuar.** El panel manda la IP a una `address-list` del MikroTik por la API. Con
`ENABLED=0` (por defecto) **no envía nada**: sugiere y registra.

**4 · Reducir el ruido.** El bloque *"Firmas que aparecen en demasiados abonados"* detecta
solo las reglas demasiado generales: si una dispara en el 80% de los clientes, es la regla,
no una epidemia.

---

## 6. Cómo se protege

**`validar.sh` es el corazón del mantenimiento.** Un solo comando que:

- extrae cada programa del instalador y comprueba su sintaxis (`bash -n`, `ast.parse`);
- pasa **pyflakes** — caza el `NameError` en una rama poco frecuente, que un `except`
  ancho convertiría en un fallo mudo;
- comprueba CRLF y el SHA256 de lo vendorizado;
- y ejecuta **51 archivos de prueba**.

Las pruebas son **de comportamiento y viven en el repositorio**: extraen las funciones
reales del instalador y comprueban resultados, no que el código exista. Incluyen un banco
de PCAP donde los casos benignos son bloqueantes — si el sistema empieza a alertar por
navegación normal, la suite falla.

Ha cazado en producción: precedencia de operadores, una función anidada usada desde fuera,
una variable pisada, una entidad HTML escapada dos veces y un byte NUL en el archivo.

---

## 7. Invariantes

Reglas que el sistema no debe romper, y por qué:

- **Un `cluster-id` por interfaz de espejo.** Duplicarlo da `failed to set fanout mode` y
  Suricata lee 0 bytes mientras el tráfico entra.
- **El origen del espejo va en allowlist.** Un origen no autorizado se rechaza entero y en
  silencio: el panel diría *"viendo tráfico"* con el sensor ciego.
- **Con cobertura del sensor por debajo del 95%, el panel no afirma que la red está
  limpia.** Un IDS que no alerta se parece mucho a una red sana.
- **El DNS nunca se recorta.** Es diminuto y es donde más se detecta.
- **Nada se borra sin saber de dónde vino.** Una entrada de origen desconocido no entra en
  un borrado en bloque.
- **El historial no se borra al quitar lo que lo generó.** Son meses de mediciones que no
  se pueden reconstruir.
- **Las credenciales no pasan por la línea de comandos.** Quedan en el historial del shell
  y a la vista en `ps`.

---

## 8. Límites conocidos

- **Con NAT no se puede atribuir un baneo a un CPE concreto.** Detrás de una pública hay
  cientos de abonados y nada une una denuncia con uno. El sistema ordena **candidatos** por
  cuánto encajan con el tipo de abuso denunciado; llamarlos culpables sería mentir sobre
  alguien a quien se le va a cortar el internet.
- **Si el espejo es post-NAT, no hay atribución posible.** El sensor ve la IP pública.
- **El panel y el generador comparten proceso.** El GIL los serializa: una generación
  pesada hace lento el panel aunque sobren núcleos.
- **El panel habla HTTP plano.** Va detrás de un proxy o por VPN, y el firewall se cierra
  a las redes de gestión.
- **`api-ssl` sin certificado en el router** negocia Diffie-Hellman anónimo: cifrado pero
  **no autenticado**, y entonces no hay huella que anclar.

---

## 9. Dónde mirar cuando algo falla

| Síntoma | Primero |
|---|---|
| "No veo nada" | `suricata-espejo` — dice cuánto entra, cuánto llega y qué hacer |
| "El panel va lento" | el caudal de entrada, no el código ([medir el cable primero](#)) |
| "Faltan alertas" | `kernel_drops` y `memcap` en `stats.log` |
| "No corta" | `ENABLED` en Ajustes → MikroTik, y si el router está dado de alta |
| "El informe sale vacío" | `MIS_REDES` frente a las redes reales de los abonados |
