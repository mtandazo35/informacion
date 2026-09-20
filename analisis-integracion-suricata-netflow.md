# Integrar `netflow-isp-platform` con `suricata-ids-lab` — análisis técnico

**Fecha:** 2026-09-20
**Alcance:** qué aportaría de verdad integrar los dos proyectos, qué habría que construir y qué riesgos tiene.
**Método:** lectura completa del código de ambos repositorios, no de sus README.

| Repositorio | Commit analizado | Tamaño | Estado real |
|---|---|---|---|
| `mtandazo35/suricata-ids-lab` | `6f5058e` (2026-09-20) | ~8.900 líneas, 1 archivo | **En producción** en 2 cajas |
| `mtandazo35/netflow-isp-platform` | `57781b1` (2026-08-24) | ~2.100 líneas, 38 archivos | **MVP, ~50% cableado** (ver §2) |

---

## 1. Qué hace cada uno, en una línea

- **Suricata IDS**: ve el **contenido** del tráfico espejado (TZSP del MikroTik), lo compara contra firmas y listas de reputación, y **actúa** mandando CPEs a una *address-list* del router.
- **NetFlow**: ve **todos los flujos** que atraviesan el router (quién habló con quién, cuántos bytes, cuánto tiempo), sin mirar el contenido, y los agrega por abonado.

La diferencia importante: **Suricata solo ve lo que alguna regla reconoce; NetFlow ve todo pero no sabe qué es.** Son complementarios de verdad, no redundantes.

---

## 2. Hallazgo central: el motor de correlación de NetFlow no está conectado

Esto condiciona todo el resto del análisis, así que va primero.

El repositorio tiene **dos capas que no se tocan entre sí**:

**Capa A — la que corre** (`processor/processor.py` → API → ClickHouse):
`nfcapd` escribe archivos → `processor.py` los pasa por `nfdump -o json` → `normalize()` asigna identidad **leyendo un JSON estático** (`config/subscribers.json`, mapeo IP→nombre fijo) → POST a la API → ClickHouse.

**Capa B — la que está escrita, probada y NO se usa** (`backend/app/correlation.py`, `pipeline.py`):
`IPAssignment.contains()`, `match_session()`, `correlate_domain()`, `enrich_flow()`.

Verificación:

```
grep -rn "enrich_flow|match_session|correlate_domain|IPAssignment" --include=*.py .
  → solo aparecen en pipeline.py, correlation.py y los tests. Ningún otro llamador.
```

Consecuencias concretas, hoy:

1. **La asignación histórica por tiempo no se aplica.** Lo que corre es un mapeo IP→nombre estático. El README dice *"Asignación temporal de flujos a clientes PPPoE, DHCP o estáticas, incluso con IP reutilizada"*: eso existe como **biblioteca con tests**, no como pipeline.
2. **PostgreSQL está desplegado pero muerto.** La tabla `subscriber_ip_assignments` (el corazón de la identidad histórica, bien diseñada e indexada) **no la lee ni la escribe nadie**: `backend/requirements.txt` ni siquiera incluye un driver de Postgres, y `db.py` solo abre ClickHouse.
3. **La atribución de dominio siempre sale vacía.** Existe el endpoint `/api/v1/dns-answers` y la tabla `dns_answers`, pero **no hay ningún productor** que los alimente (los adaptadores de Technitium/AdGuard/Unbound están en "próximos componentes"). Sin datos DNS, `domain` = `''` y `application` = `Unidentified` para todo.
4. **No hay sincronización con RouterOS ni RADIUS** (también en "próximos"). La identidad real de PPPoE/DHCP hay que cargarla a mano.

**Lectura honesta:** el diseño es bueno y los tests son serios (7 archivos de test sobre funciones puras). Pero lo que hoy funciona end-to-end es *"contabilizar bytes por IP"*, no *"analítica por abonado con dominio y aplicación"*. Cualquier estimación debe partir de ahí.

---

## 3. Qué ganaríamos de verdad

Cinco mejoras, ordenadas por valor real para el caso de uso (detectar CPEs infectados que atacan hacia afuera).

### 3.1 Detectar lo que Suricata no puede ver — el hueco más grande

Suricata solo alerta si una **firma** coincide. Hay dos incidentes en la historia del proyecto que lo demuestran:

- ET Open **no trae detección de port-scan** activa, por eso hubo que escribir reglas propias.
- Esas reglas genéricas (`$HOME_NET any -> $EXTERNAL_NET any` con `threshold track by_src`) **tumbaron la VM 172.19.1.3 por OOM**: en un espejo de ISP casaban cada paquete y mantenían un contador por cada IP origen.

NetFlow resuelve exactamente eso **sin cargar al IDS**, porque el patrón está en los metadatos:

| Comportamiento | Cómo se ve en NetFlow | Hoy con Suricata |
|---|---|---|
| Escaneo horizontal | 1 CPE → cientos de destinos, pocos bytes, flujos muy cortos | solo si hay regla de ese puerto |
| *Beaconing* de C2 | conexiones al mismo destino a intervalo regular | solo si la firma existe |
| Participación en DDoS | subida sostenida anómala frente a su plan | invisible |
| Exfiltración | subida >> bajada, sostenida | invisible |

Esto es **detección por comportamiento**, complementaria a la detección por firma, y no requiere ninguna regla nueva en Suricata.

### 3.2 Confirmar la gravedad de una alerta con volumen

Hoy el panel dice *"este CPE tuvo 40 alertas de CnC"*. No sabe si movió **2 KB o 4 GB**. Para decidir una cuarentena, eso cambia todo: la misma alerta con 4 GB subidos es exfiltración; con 2 KB puede ser ruido.

Encaja directamente en la **ficha de evidencia** que ya existe (`/cuarentena/ficha`), como una fila más junto a las firmas y la reputación.

### 3.3 Poner nombre a las IPs destino

`correlate_domain()` resuelve *"a qué dominio corresponde esta IP destino"* cruzando las respuestas DNS del cliente con la IP del flujo dentro de la ventana del TTL. Hoy el panel muestra la IP y, como mucho, el operador del bloque por RDAP.

Pasaríamos de:
> `203.0.113.7` — *contaboserver.net*

a:
> `203.0.113.7` — **`panel.malware-c2.top`** *(vía DNS del propio cliente, confianza alta)*

Eso mejora el Top de destinos, la evidencia de cuarentena y el mapa.

### 3.4 Arreglar un defecto real de nuestro histórico de abonados

Nuestro `historial_abonado(ip, ts)` (dashboard) compara **solo por IP**:

```python
if r.get("ip") == ip and r.get("ts", 0) <= ts and ...
```

El diseño de NetFlow incluye el **router exportador en la clave** (`IPAssignment.contains(client_ip, event_time, exporter_ip)`), justo por el caso de **rangos privados repetidos en nodos distintos** (dos routers con `10.0.0.5`).

Hoy no nos afecta porque cada caja habla con **un** MikroTik. Pero si una caja llegara a cubrir varios routers, **le atribuiríamos el ataque al abonado equivocado**. Es un fallo silencioso, del tipo que no da error y produce una acusación falsa.

### 3.5 Vista por abonado, no solo por IP

Un abonado con PPPoE cambia de IP. Hoy sus alertas quedan repartidas entre varias IPs sin unificar. La tabla `subscriber_ip_assignments` permite preguntar *"todo lo de este abonado en 30 días"*, que es justamente el punto **"Ficha por abonado"** que quedó pendiente en el backlog.

---

## 4. Lo que ya tenemos y NO hace falta traer

Aquí está el ahorro más grande del análisis.

### 4.1 Las respuestas DNS ya las produce Suricata — falta una línea de configuración

`correlate_domain()` necesita: IP del cliente, dominio, IP respondida y TTL. **Suricata ya genera exactamente eso**, pero nuestro instalador lo está descartando:

```yaml
  - eve-log:
      filename: dns.json
      types:
        - dns:
            requests: yes
            responses: no      # <-- aquí se pierden las respuestas
```

Cambiar `responses: yes` nos da la atribución de dominio **sin colector DNS, sin adaptadores de Technitium/AdGuard/Unbound y sin NetFlow**. Es el punto 3 de "próximos componentes" de aquel repositorio, resuelto con una línea en el nuestro.

*(Hay que medir el volumen extra en disco antes de activarlo en producción: las respuestas son bastante más voluminosas que las consultas.)*

### 4.2 Parte de la volumetría también

Suricata puede emitir registros `flow` en `eve.json` (bytes y paquetes por flujo). Hoy están desactivados. **No sustituye a NetFlow** — solo ve el tráfico espejado y es mucho más pesado que los metadatos de NetFlow — pero da volumetría sin stack nuevo.

### 4.3 Ya tenemos lo que al otro proyecto le falta

`abonado_de()` consulta el MikroTik en vivo (`/ppp/active/print` + `/ip/dhcp-server/lease/print`) y `_registrar_hist_abonados` mantiene el histórico. Eso **es** la "sincronización con RouterOS API" que NetFlow tiene pendiente. Si se integraran, **nuestra caja sería la fuente de identidad** de la suya, no al revés.

---

## 5. Tres caminos posibles

### Opción A — Trasplantar ideas, sin desplegar NetFlow

No se levanta ningún contenedor. Se porta a `suricata-ids-lab`:

1. `responses: yes` en `dns.json` + tabla en memoria dominio↔IP con TTL.
2. `correlate_domain()` adaptado (es Python puro, sin dependencias: encaja con nuestro diseño).
3. Clave `(ip, exporter)` en `historial_abonado` (arregla §3.4).
4. Nombre de dominio en Top destinos, ficha de evidencia y mapa.

- **Aporta:** §3.3, §3.4 y parte de §3.5.
- **No aporta:** §3.1 y §3.2 (hace falta NetFlow de verdad).
- **Esfuerzo estimado:** 2–4 días. Sin servicios nuevos, sin Docker, sin RAM extra.
- **Riesgo:** bajo. Todo cae dentro de la arquitectura actual.

### Opción B — NetFlow como sensor aparte, integrado por API

Se despliega el stack de NetFlow **en otra máquina** y el panel de Suricata le consulta volumetría.

Trabajo necesario **en `netflow-isp-platform`** (lo de §2):

| Tarea | Por qué |
|---|---|
| Conectar `enrich_flow()` al procesador | hoy el motor de correlación no se ejecuta |
| Integrar PostgreSQL (driver, lecturas, escrituras) | la tabla de identidad está muerta |
| Alimentar identidad desde nuestro MikroTik | sustituye al JSON estático |
| Autenticar los endpoints de analítica | hoy `/api/v1/analytics/*` están **abiertos**, sin clave |
| Arreglar el consumo de memoria del procesador | ver §6.1 |
| Detección por comportamiento (escaneo, beaconing) | **no existe**; es §3.1, el mayor valor, y hay que escribirla entera |
| Añadir `LICENSE` | el repo no tiene, igual que pasaba con el de Suricata |

Trabajo **en `suricata-ids-lab`**: cliente HTTP hacia esa API + volumen en la ficha + sección nueva en el panel.

- **Aporta:** todo lo de §3.
- **Esfuerzo estimado:** 3–5 semanas de trabajo real. La mitad no es "integrar", es **terminar el MVP**.
- **Riesgo:** medio-alto (ver §6).

### Opción C — Fusionar los dos proyectos

**No la recomiendo.** Las arquitecturas son opuestas por diseño:

| | suricata-ids-lab | netflow-isp-platform |
|---|---|---|
| Despliegue | un script, un `curl \| bash` | 5 contenedores Docker |
| Dependencias | **cero** (Python stdlib) | FastAPI, ClickHouse, Postgres, nfdump, nginx |
| Actualización | botón en el panel, con rollback | `docker compose build` |
| RAM | cientos de MB | ClickHouse solo ya pide varios GB |

Fusionarlos significa perder el one-liner y el auto-update, que es justo lo que hace mantenible la flota.

---

## 6. Riesgos concretos

### 6.1 El procesador repite el patrón que ya causó dos OOM

En `processor/processor.py`:

```python
result = subprocess.run(["nfdump", "-r", str(path), "-o", "json"], capture_output=True, text=True)
payload = json.loads(result.stdout)     # archivo entero en memoria, dos veces
```

La salida completa de `nfdump` se carga en memoria como texto **y** como objetos Python. Con archivos de un ISP eso son cientos de MB por lote.

Es **exactamente** el patrón que tumbó la VM dos veces en este proyecto (el dict `flujos` sin cota y el `threshold track by_src`). Antes de poner esto en producción hay que hacerlo incremental (`nfdump` línea a línea) y ponerle un `RLIMIT_AS`, como ya se hizo en el generador de reportes.

### 6.2 Recursos: no cabe en las cajas actuales

Las VM del sensor son de ~4 GB y ya sufrieron OOM. ClickHouse + PostgreSQL + nfcapd + API **no caben** junto a Suricata. Obliga a una máquina aparte: es un coste, no un detalle.

### 6.3 Carga en el router

`/ip traffic-flow` exporta **cada flujo** (RouterOS no hace muestreo). En un CCR con varios Gbps eso consume CPU en el router, que además ya está haciendo el espejo TZSP. Hay que medirlo en laboratorio antes de activarlo en el núcleo, y acotar `interfaces=` (el propio README avisa del doble conteo con `interfaces=all`).

### 6.4 Superficie de exposición

Los endpoints de analítica no piden clave; solo la ingesta. Y el panel web va por HTTP plano. Antes de que contenga datos de abonados, eso necesita autenticación y estar detrás de VPN o proxy.

### 6.5 Límite legal e interpretativo

El propio README lo dice bien: el indicador de reventa **no es prueba**, y DoH/DoT/VPN/CDN/ECH rompen la atribución de dominio. Aplicado a seguridad: que un CPE tenga mucho tráfico no lo hace un atacante. Si esto llega a alimentar cuarentenas automáticas, el volumen debe ser **evidencia corroborante**, nunca disparador por sí solo — la misma regla de "doble señal" que ya aplica el panel.

---

## 7. Recomendación

**Hacer la Opción A ahora y decidir la B con datos, no antes.**

Motivos:

1. La Opción A entrega **hoy** la mejora más visible (nombres de dominio en destinos y evidencia) por 2–4 días de trabajo, sin infraestructura nueva y sin salir de la arquitectura que ya funciona.
2. El mayor valor de NetFlow (§3.1, detección por comportamiento) **todavía no está escrito en ese repositorio**. No se "integra": se desarrolla. Conviene saberlo antes de comprometer semanas.
3. La Opción B debería empezar por una **prueba de una sola caja**: activar `traffic-flow` en un MikroTik, medir CPU del router y volumen de flujos reales durante una semana. Ese dato define si el stack aguanta y cuánto hardware pide. Sin él, cualquier estimación de capacidad es adivinar.

Un paso intermedio barato, si se quiere volumetría antes de decidir: activar los registros `flow` de Suricata (§4.2) en **una** caja y medir. Da una aproximación del valor de §3.2 sin desplegar nada.

---

## Apéndice — referencias verificables

| Afirmación | Dónde comprobarlo |
|---|---|
| El motor de correlación no se usa | `grep -rn "enrich_flow\|match_session" --include=*.py .` → solo tests |
| Postgres sin driver | `backend/requirements.txt` (4 paquetes, ninguno de Postgres) |
| Analítica sin autenticar | `backend/app/main.py`: `dependencies=[Depends(require_ingest_key)]` solo en los `POST` |
| Carga del archivo entero en memoria | `processor/processor.py` líneas 153-161 |
| Identidad por JSON estático | `processor/processor.py` → `customer_metadata()` |
| Respuestas DNS descartadas | `install-suricata.sh`, bloque `filename: dns.json` → `responses: no` |
| Histórico sin router en la clave | `install-suricata.sh` → `def historial_abonado` |
| Incidentes OOM previos | memoria `project_suricata_ids_lab` (2026-09-07, dos incidentes) |
