# OLT Optical Monitor

Monitor de niveles ópticos para una flota de OLTs GPON VSOL.

## Qué es esto

Herramienta en Python que se conecta por telnet a una o varias OLTs VSOL, recolecta los niveles ópticos del SFP por puerto PON (lado OLT) y los niveles Rx/Tx de cada ONU (vía OMCI), guarda cada snapshot en una base SQLite local y genera un reporte HTML con semáforos de salud y mini-gráficos de tendencia de Rx por ONU.

Pensado para correr cada 15-30 min como tarea programada y tener siempre `reports/latest.html` actualizado.

## Requisitos

- Python 3.8+
- Acceso telnet a las OLTs (puerto 2233 por defecto en VSOL)
- Windows (testeado) — funciona también en Linux/Mac cambiando solo el método de scheduling
- Sin dependencias externas: stdlib pura

## Instalación rápida

1. Editar `olts.json` con los datos de tu OLT (host, port, user, password, enable_password, pon_ports).
2. Probar manualmente:
   ```
   python monitor.py collect
   python monitor.py report
   ```
3. Abrir `reports/latest.html` en el navegador.
4. Programar ejecución automática:
   ```
   powershell -ExecutionPolicy Bypass -File install_task.ps1
   ```

## Configuración (olts.json)

Ejemplo mínimo:

```json
{
  "olts": [
    {
      "name": "OLT-EsteroMedio",
      "host": "10.10.10.1",
      "port": 2233,
      "user": "admin",
      "password": "xxxxxxxx",
      "enable_password": "xxxxxxxx",
      "pon_ports": ["0/1", "0/2", "0/3", "0/4"]
    }
  ],
  "thresholds": {
    "rx_critical_low": -27.0,
    "rx_marginal_low": -25.0,
    "rx_warning_low":  -23.0,
    "rx_critical_high": -8.0,
    "tx_min": 0.0,
    "tx_max": 5.0,
    "temp_warn": 70.0,
    "temp_crit": 85.0,
    "rx_trend_alert_db_per_week": 2.0
  },
  "settings": {
    "report_path": "reports/latest.html",
    "db_path": "data.db",
    "retention_days": 60
  }
}
```

Campos por OLT:

- `name`: etiqueta libre que aparece en el reporte.
- `host` / `port`: IP/puerto telnet de la OLT (VSOL usa 2233).
- `user` / `password`: credenciales del usuario telnet.
- `enable_password`: contraseña para entrar a modo privilegiado (`enable`).
- `pon_ports`: lista de puertos PON a barrer (ej. `["0/1", "0/2"]`).

Umbrales (`thresholds`), todos en dBm salvo temperatura:

- `rx_critical_low` (-27): Rx por debajo → crítico, ONU al borde del receptor.
- `rx_marginal_low` (-25): zona marginal, propenso a flaps.
- `rx_warning_low` (-23): warning, todavía operativa pero baja.
- `rx_critical_high` (-8): Rx por encima → saturación del receptor, hay que poner atenuador.
- `tx_min` / `tx_max`: rango aceptable del transmisor de la ONU.
- `temp_warn` / `temp_crit`: temperatura de la ONU (°C).
- `rx_trend_alert_db_per_week`: caída de Rx semanal que dispara alerta (uso futuro).

## Comandos

- `python monitor.py collect` — recolectar una vez. Conecta a cada OLT, lee SFP y ONUs, guarda snapshot. No genera reporte.
- `python monitor.py report` — regenerar el HTML a partir del último snapshot en la DB.
- `python monitor.py run` — atajo: `collect` + `report`. Es el comando que usa la tarea programada.
- `python monitor.py purge --days 30` — borrar snapshots con más de N días.
- `python monitor.py list-snaps` — listar los últimos 20 snapshots (id, timestamp, OLT, ok/error).

## El reporte HTML

`reports/latest.html` contiene:

- KPIs arriba: total de OLTs, ONUs activas, críticas, marginales, en warning y no-working.
- Tabla SFP por puerto PON (lado OLT): Tx/Rx, temperatura, voltaje, bias.
- Tabla de ONUs ordenable, filtrable por estado/PON y con búsqueda libre (serial, nombre, descripción).
- Cada fila trae semáforo según el Rx (OK / WARNING / MARGINAL / CRÍTICO) y, cuando hay ≥2 snapshots para esa ONU, un mini-sparkline SVG con la tendencia de Rx.
- Tabla de snapshots recientes al pie con errores si los hubo.

El HTML es autocontenido (CSS y SVG inline), se puede abrir local o compartir por correo.

## Tarea programada (Windows)

Instalar:

```
powershell -ExecutionPolicy Bypass -File install_task.ps1
```

Verificar en GUI: `taskschd.msc` → buscar `OLT-Optical-Monitor`.

Ver desde PowerShell:

```
Get-ScheduledTask -TaskName "OLT-Optical-Monitor"
Get-ScheduledTaskInfo -TaskName "OLT-Optical-Monitor"
```

Logs de cada ejecución: `monitor.log` en el directorio del proyecto.

Desinstalar:

```
Unregister-ScheduledTask -TaskName "OLT-Optical-Monitor" -Confirm:$false
```

En Linux/Mac usar cron en lugar de Task Scheduler, ejemplo:

```
*/20 * * * * cd /path/olt_monitor && /usr/bin/python3 monitor.py run >> monitor.log 2>&1
```

## Agregar más OLTs

Agregar otro bloque al array `olts` en `olts.json`:

```json
{
  "name": "OLT-NuevoSitio",
  "host": "10.20.0.1",
  "port": 2233,
  "user": "admin",
  "password": "...",
  "enable_password": "...",
  "pon_ports": ["0/1", "0/2", "0/3", "0/4", "0/5", "0/6", "0/7", "0/8"]
}
```

Las próximas corridas la incluirán automáticamente. Importante: el driver solo entiende la sintaxis CLI de VSOL/BDCom. Para Huawei (MA56xx), ZTE (C300/C320) o Fiberhome hay que escribir otro driver — los comandos `show interface gpon`, `show onu info`, etc. son distintos.

## Troubleshooting

- **`Connection refused` / `timeout`** — verificar IP, puerto (2233 en VSOL, no 23), firewall en la OLT o intermedios, y que la OLT responda ping.
- **`Login fail` / no entra a enable** — la contraseña del usuario telnet a veces difiere de la del web; revisar también `enable_password`.
- **`snapshot ok=0` para una OLT** — correr `python monitor.py list-snaps` para ver el campo `error`. Típicamente es timeout o un prompt inesperado del CLI.
- **HTML vacío o "sin datos"** — todavía no se hizo ningún `collect`. Correr `python monitor.py collect` primero.
- **`database is locked`** — hay otra instancia corriendo. Pasa cuando un ciclo aún no terminó y se dispara el siguiente. Aumentar el intervalo o deshabilitar la tarea programada antes de correr manualmente.
- **El ciclo tarda mucho** — con ~268 ONUs un ciclo toma ~2 min. Está bien con intervalos de 15-30 min. Si tarda más, revisar latencia a la OLT o reducir `pon_ports`.

## Cómo entender los valores ópticos

Niveles típicos de Rx en una ONU GPON 1490 nm:

| Rx (dBm)       | Estado                                          |
| -------------- | ----------------------------------------------- |
| > -23          | Excelente                                       |
| -23 a -25      | Warning, revisar a futuro                       |
| -25 a -27      | Marginal, probable flap                         |
| < -27          | Crítico, al borde del receptor                  |
| > -8           | ALTO, saturación: poner atenuador               |

Tx normal de la ONU: 0.5 a 3 dBm. Por encima de 5 dBm es anormal; por debajo de 0 dBm hay un problema en el láser de la ONU.

Una caída de Rx > 2 dB en una semana sobre la misma ONU indica degradación del enlace (fusión, conector sucio, fibra estresada) aunque el valor absoluto todavía esté en verde.

## Limitaciones conocidas

- En este firmware VSOL, `show pon rx_power onu` devuelve vacío. No podemos leer la Rx de cada ONU desde el lado OLT; usamos los valores que reporta la propia ONU vía OMCI (`show onu optical-info`), que de todas formas son los relevantes para diagnóstico de cliente.
- El driver es específico de VSOL/BDCom. Otras marcas (Huawei, ZTE, Fiberhome) requieren otro driver.
- Telnet va en texto plano. No usar sobre redes no confiables; en general la OLT no expone SSH.
- La detección de prompt en el driver es por regex sobre el banner del CLI; si cambian el hostname con caracteres raros puede haber que ajustar la regex en `olt_driver.py`.

## Estructura del proyecto

```
olt_monitor/
├── olts.json          # config de la flota + umbrales
├── olt_driver.py      # driver telnet VSOL (stdlib pura)
├── monitor.py         # CLI: collect / report / run / purge / list-snaps
├── install_task.ps1   # instalador de la tarea programada Windows
├── data.db            # SQLite (se crea en primer run; gitignored)
├── reports/
│   └── latest.html    # reporte generado
├── monitor.log        # log de la tarea programada
└── README.md
```

## Licencia

Uso interno.
