# Auditoría `suricata-ids-lab` — 2026-09-20

**Objeto:** validar el estado del repositorio tras una sesión larga de cambios (mapa interactivo, tablas ordenables, quitado masivo, CI, licencia).
**Método:** ejecución del validador y de las pruebas funcionales, más revisión crítica del código por dos revisores independientes en paralelo (uno sobre el generador de reportes, otro sobre el panel web). Todos los hallazgos se verificaron leyendo el código antes de corregirlos.
**Veredicto:** el repositorio queda **correcto y verificable**, pero la auditoría encontró **9 defectos reales**, 4 de ellos introducidos ese mismo día. Todos corregidos y con prueba que los cubre.

---

## 1. Estado verificable

Repositorio: `github.com/mtandazo35/suricata-ids-lab`, rama `main`, commit **`bc55257`**.

SHA256 de los archivos auditados:

```
682c4283ac2c12b6453189d21f3b879bfc582642dbefea819b399ef2473d5648  install-suricata.sh
93c7a6d133ad294aca14d918112653c93d5aaeb669904a9449a56faad8b03365  validar.sh
732f9e0c287c0c74b0d3310e99a72b8b76aac4d152bfc8e68871ac3775916e40  tests/run.sh
bd696aa65a55ee9e59b8eca0543cfd4b416cf7e0d060b9ba533f2548b8eece4d  tests/extraer.py
008f8a225ffd348d0b732a979faf3ee5b045f258a9763f99527bdb848c18a449  README.md
ce49593ac767b758ecd3748b2c6b17c4271bcbbb60d87cff30b5c5b8b22e41c5  LICENSE
1416f4fe42072bab1ecde88c2d6e3b860134ae05b40ddd73d892910bbc87a598  .github/workflows/ci.yml
```

Comprobaciones ejecutadas (todas en verde, y también en GitHub Actions):

| Comprobación | Resultado |
|---|---|
| `bash -n` de los 5 scripts | OK |
| `ast.parse` + `pyflakes` de los 4 programas Python incrustados | OK, sin avisos |
| `sh -n` de los 2 programas shell incrustados | OK |
| `node --check` del JavaScript del mapa | OK |
| Finales de línea LF en todo lo versionado | OK |
| SHA256 de `vendor/mapa/*` contra las 3 constantes del instalador | OK |
| 8 pruebas funcionales de comportamiento | OK |

**Verificación del propio validador:** se le inyectó (a) un error de sintaxis Python, (b) un CRLF, (c) un SHA256 desincronizado, (d) JavaScript inválido y (e) **un fallo de comportamiento con la sintaxis intacta** (que el router caído no cortara el bucle). Detectó los cinco. Un validador que no falla no sirve como garantía.

---

## 2. Hallazgos

Orden por gravedad. "Nuevo" = introducido en la sesión auditada; "preexistente" = ya estaba.

### 2.1 — GRAVE · Nuevo · Fuga de memoria multiplicativa en el generador

`pais_srcs` y `pais_ports` (acumuladores del mapa) **no guardan una entrada por CPE o por puerto, sino un par `(país, CPE)` y `(país, puerto)`**. Un CPE que ataca a 20 países ocupa 20 entradas: el crecimiento es **multiplicativo**, no lineal.

Ningún tope, en un script donde todo lo demás grande sí lo tiene (`MAX_FLUJOS`, `MAX_IPS`, `MAX_CARD`) y que **ya murió dos veces por OOM** por exactamente esta clase de fallo. Orden de magnitud estimado en un espejo con 50.000 CPEs: entre 135 y 270 MB, sobre un `RLIMIT_AS` de 1,5 GB que ya aloja otras estructuras. El síntoma sería `MemoryError` sin captura → el generador muere antes de escribir el HTML → el panel se congela en el reporte viejo y reintenta indefinidamente.

**Corregido:** tope de 800 por país con el mismo patrón que `MAX_CARD`. Como solo se muestran los 4–6 primeros de cada lista, no cambia lo que se ve; el "+N más" pasa a ser un mínimo, que sigue siendo cierto.

### 2.2 — GRAVE · Preexistente · Pérdida silenciosa del registro de cuarentena

`guardar_enviados()` usaba **un temporal con el mismo nombre para todos los hilos** (`<archivo>.tmp`). El panel es multihilo y además tiene un hilo de fondo que escribe ese mismo registro. Dos escrituras solapadas pueden publicar un JSON a medias; y como `cargar_enviados()` se traga cualquier excepción devolviendo `{}`, el resultado es la **pérdida del registro entero en silencio**: los CPEs siguen bloqueados en el router pero el panel ya no los ve, no los puede liberar y pierde todos los motivos.

**Corregido:** temporal único por proceso e hilo, más un cerrojo alrededor de lectura y escritura.

### 2.3 — GRAVE · Nuevo · El quitado masivo podía borrar lo que otro hilo acababa de escribir

`/cuarentena/quitar-varios` cargaba el registro **antes** del bucle y lo reescribía entero **al final**. Entre medias puede haber minutos hablando con el router (cada IP es una conexión). Si durante ese rato el barrido rápido registraba un CPE recién infectado, el guardado final **lo borraba del registro aunque siguiera bloqueado en el router** — y como el reconciliador solo recorre el registro, no lo liberaría nunca: cliente bloqueado indefinidamente y sin rastro.

**Corregido:** `quitar_enviados()` relee el registro dentro del cerrojo y saca solo las IPs que tocan. Cubierto por prueba que simula la escritura concurrente.

### 2.4 — MEDIA · Nuevo (regresión del mismo día) · Regeneraciones de reporte redundantes

El arreglo del distintivo "En cuarentena" hizo que cualquier cambio del registro pidiera regenerar el resumen. Dos efectos no previstos:

- `FORCE_REGEN` se limpiaba **antes** de `mk_sync_enviados()`, así que un cambio detectado por el sync pedía **otra generación idéntica** al ciclo siguiente.
- Un quitado masivo encadenaba varias generaciones seguidas.

Importa porque generar es caro y es el **mismo hilo** que hace el barrido rápido de ALTO y mide la salud del sensor: mientras genera, esas dos cosas se retrasan.

**Corregido:** la marca se limpia después del sync, y las regeneraciones forzadas se agrupan con una separación mínima de 60 s.

### 2.5 — MEDIA · Preexistente · Se borraba del registro aunque el router fallara

`/cuarentena/quitar` hacía `env.pop(ip)` **fuera** del `if ok`. Si el `mk_remove` fallaba, la IP desaparecía del panel pero **seguía bloqueada en el router**, sin forma de reintentar ni de liberarla. Las rutas nuevas ya lo hacían bien; la vieja no.

**Corregido:** las cuatro rutas de quitado solo borran del registro si el router confirmó.

### 2.6 — MEDIA · Nuevo · Falso "quitada" por lista equivocada

`mk_remove` devuelve **éxito** con "0 entradas quitadas" cuando la IP no está en esa address-list. Como el token de selección (`cuar|IP` / `dns|IP`) no se contrastaba con el registro, una IP pedida por la lista equivocada producía un ✓ sin haber quitado nada. En el masivo eso es una hilera de vistos buenos con falsa confianza.

**Corregido:** se comprueba que la IP esté en el registro correspondiente antes de llamar al router.

### 2.7 — MEDIA · Nuevo · El masivo no abortaba con el router caído

Con el MikroTik sin responder y 500 IPs seleccionadas: 500 × 6 s de timeout ≈ más de 45 minutos en un hilo de petición. "Enviar todos" sí cortaba ante un error de conexión; el quitado no.

**Corregido:** corta en el primer error de conexión y lo dice. Además el tope de 500 por petición ya no descarta en silencio: informa cuántas quedaron sin procesar.

### 2.8 — MEDIA · Preexistente · Escritura no atómica del reporte HTML

Era el **único** punto del script que no usaba `.tmp` + `os.replace()`. El archivo existe con `mtime` nuevo desde el primer byte; el panel elige el reporte por `mtime` y exige encontrar un `<main>`: sobre un archivo a medio escribir **no casa y sirve "En vivo" en blanco**. Si además el generador muere durante la escritura, ese HTML truncado queda como "el más reciente".

**Corregido:** escritura atómica como el resto del script.

### 2.9 — BAJA · Nuevo · Dos fallos de interfaz

- El modal del masivo quedaba **bloqueado para siempre** si no llegaba a navegar (ni Cancelar ni Escape).
- La recarga del masivo **perdía la posición de la página**, justo lo contrario de lo que yo mismo había documentado ese día.

**Corregidos** ambos, con prueba.

### 2.10 — Adicional: `dns_sids` sin tope (preexistente)

El conjunto de dominios por CPE no tenía cota y la clave es el **dominio completo**. Con un túnel DNS o dominios DGA bajo un dominio de los feeds, un solo abonado infectado podía añadir una entrada por consulta única. Replica literalmente el incidente de OOM nº 1, y su contenido **ni siquiera se usa** (solo su `len()`). **Corregido** con tope.

---

## 3. Hallazgos verificados como NO defectos

Se comprobaron y se descartan explícitamente:

- **Autorización de las rutas nuevas**: las tres rutas de quitado usan el mismo control de rol (`_operador()`), coherente con las preexistentes; el rol de lectura recibe 403.
- **CSRF**: la cookie es `SameSite=Strict` y el `fetch` es *same-origin*; la ruta JSON nueva no abre un hueco.
- **Bitácora**: las tres rutas registran; no falta auditoría en ninguna.
- **Tamaño del HTML del mapa**: los datos embebidos están acotados (≈250 países × 16 elementos); no puede inflar la página.
- **Escapado del mapa**: los datos se inyectan como JSON y se escapan en cliente antes de cada `innerHTML`; correcto.
- **GeoIP**: un archivo corrupto o truncado degrada a "sin país" sin tumbar el proceso; la caché distingue "país desconocido" de "no consultado".
- **Lectura de las dos listas de cuarentena**: correcta.
- **El coste de I/O añadido** por releer el registro en cada guardado es despreciable frente a la llamada al router.

---

## 4. Riesgos abiertos (no corregidos, con criterio)

Reales y verificados, pero fuera del alcance de una corrección segura en esta pasada. **Ninguno es regresión**; todos escalan con el tamaño del despliegue.

1. **`riesgo()` recorre el dict completo de flujos por cada candidato** (hasta 200.000 claves × número de candidatos, que no tiene tope). Con miles de candidatos DNS puede superar el `timeout=600` del generador → reintentos que nunca producen reporte. *Arreglo propuesto:* precalcular un índice `origen → flujos` una sola vez.
2. **`cuarentena.json` no acota el número de candidatos** (~4 KB por candidato). Con 10.000 candidatos son ~40 MB escritos cada 5 min y cargados enteros por el panel.
3. **`by_dst` y la caché de GeoIP no tienen tope**, y ahora el mapa añade una tercera estructura con el mismo conjunto de claves: el coste por IP destino distinta se multiplica por 3. Si se acota una, conviene acotar las tres a la vez.
4. **Sesión caducada a mitad del quitado masivo** se reporta como "sin respuesta" en cada IP, sin pista de que fue la sesión.
5. **Las rutas de envío** (no las de quitado) siguen haciendo leer-modificar-escribir sobre el registro fuera del cerrojo. La ventana es mucho más corta que la del masivo, pero existe.

---

## 5. Lo que cambió en la forma de validar

La auditoría destapó que **las pruebas escritas durante la sesión vivían en un directorio temporal**: ni el CI ni el usuario podían re-ejecutarlas, así que la protección contra regresiones que yo daba por hecha no existía.

Ahora están en `tests/` dentro del repositorio, con su extractor y su runner, y las ejecuta tanto `validar.sh` como el CI en cada push. No necesitan Suricata ni un MikroTik: cada prueba extrae la pieza real del instalador y la ejecuta contra dobles.

| Prueba | Qué garantiza |
|---|---|
| `test_mapa.js` | zoom por país, detalle por IP/puerto, y que "Vista completa" no pinte países de negro |
| `test_orden.js`, `test_orden_persiste.js` | orden asc/desc, fechas por tiempo real, y que el orden sobreviva a la recarga |
| `test_posicion.js` | que una acción no te mande al principio de la página |
| `test_masivo_ui.js`, `test_masivo_progreso.js` | selección, avance visible, y que un fallo a mitad no detenga el resto |
| `test_ruta_quitar_uno.py`, `test_ruta_quitar_varios.py` | que el router caído **no** borre del registro, que no haya falsos éxitos, y que no se pise lo que escribe el hilo de fondo |

Varias nacieron de fallos reales ya corregidos, así que **fallan si el fallo vuelve**.

---

## 6. Conclusión

El repositorio está en estado correcto y, por primera vez, **verificable de forma reproducible**: `./validar.sh` comprueba sintaxis, integridad de los assets, finales de línea y comportamiento, y el CI lo repite en cada push.

El dato que conviene retener: de los 9 defectos, **4 los introduje el mismo día** y ninguno lo habrían detectado la sintaxis ni los tests que existían entonces. El más grave (2.1) era una repetición del fallo que ya había tumbado la VM dos veces, en código nuevo. La revisión sistemática no fue un trámite.

**Recomendación operativa:** desplegar `bc55257` en una caja primero (canario) y observar un ciclo completo de 5 minutos antes de actualizar la segunda; el cambio de la regeneración y el del cerrojo afectan al hilo de fondo, que es el que mantiene vivo el panel.
