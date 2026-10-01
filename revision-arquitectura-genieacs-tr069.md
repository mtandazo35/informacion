# Revisión del planteamiento de arquitectura local GenieACS/TR-069

Revisión de un documento de arquitectura propuesto para `genieacs-installer`,
contrastado con el código del instalador y con el comportamiento medido de una
flota real de 12 CPE multimarca (TP-Link, Cudy, Mercusys, ZTE), mezcla de
TR-098 y TR-181.

Las direcciones de este documento son de los rangos de documentación
(RFC 5737) y los nombres de equipo son modelos comerciales: no hay direcciones
ni clientes reales.

---

## 1. Resumen

El planteamiento general es correcto y el principio que lo ordena —el ACS no
sale a internet, son los CPE los que lo alcanzan por la red del operador— es la
arquitectura adecuada y la que ya está en uso.

Dos problemas, y el segundo es el que importa:

1. **Pide como pendiente cosas que ya están implementadas.** Buena parte de las
   recomendaciones de los apartados de firewall y health check están en el
   instalador desde hace versiones. El documento parece escrito sin leer el
   `install.sh` actual.
2. **Recomienda un modelo de aprovisionamiento que ya se evaluó y se descartó**,
   y da por resueltos los tres puntos donde se pierde el tiempo de verdad:
   cómo llega el CPE a conocer la URL del ACS, qué pasa de verdad tras un
   factory reset, y por qué fallan los Connection Request en un ISP.

Como documento de principios sirve. Como hoja de ruta hay que corregirlo.

---

## 2. Lo que acierta

- **El principio de aislamiento.** «El ACS no sale hacia Internet para
  administrar los CPE; son los CPE los que alcanzan el servicio TR-069» es la
  formulación correcta y conviene conservarla literal.
- **El reparto de puertos y alcances**: CWMP 7547 hacia las redes de CPE, UI
  hacia la red administrativa, NBI hacia el backend, MongoDB solo en loopback.
- **No asumir un único árbol de parámetros.** Separar TR-098
  (`InternetGatewayDevice.*`) de TR-181 (`Device.*`) y normalizar por encima es
  exactamente lo necesario: en una flota de 12 equipos conviven los dos.
- **Perfiles por fabricante + modelo + firmware.** La terna es la correcta: un
  firmware nuevo puede mover las instancias y romper un perfil que funcionaba.
- **El aviso sobre firmware**: no enviarlo por coincidencia de fabricante. Una
  actualización equivocada inutiliza el equipo físicamente, y es de los pocos
  errores de esta plataforma que no tienen vuelta atrás.
- **Separar estados de vinculación** (descubierto, identificado, pendiente,
  vinculado, aprovisionado) y la matriz de pruebas por fabricante.

---

## 3. Lo que ya está implementado

| El documento pide | Estado real en `install.sh` |
|---|---|
| Que `status` evolucione a una auditoría PASS/WARN/FAIL con código de salida | Ya lo es: devuelve 0 sin fallos y 1 con ellos |
| Comprobar MongoDB en localhost | Ya se comprueba, con un parser que no se deja engañar por una línea comentada |
| Comprobar servicios, usuario de servicio, JWT, permisos del `.env`, logrotate, timer de respaldo | Todos presentes |
| Comprobar dispositivos, tasks y faults | Ya se consultan por `mongosh` |
| «El instalador no debería limitarse a `ufw allow 7547/tcp`» | No se limita: abre 7547 y, en modo producción, 80/443 tras proxy TLS. **NBI 7557 y FS 7567 se dejan cerrados a propósito**, con aviso en pantalla |
| MongoDB sin publicar | Ya es así por defecto |

De la lista de comprobaciones propuestas, lo único que falta de verdad son
cuatro: **disco disponible, memoria, CPU y edad del último respaldo**. Esa sí
es una mejora concreta y pequeña, y es lo que conviene pedir.

---

## 4. Correcciones de fondo

### 4.1 Plantillas por modelo: el camino que se descartó

El documento propone una plantilla por modelo (`plantilla_<fabricante>_<modelo>`).
Es una cinta de correr: cada modelo y cada firmware nuevo obliga a escribir una
plantilla a mano, y hasta que alguien la escriba ese equipo no se aprovisiona.

El modelo adoptado es **el perfil derivado del árbol**: se deduce del propio
equipo qué instancia es la WAN, cuál la LAN y qué radio corresponde a cada
banda, se guarda bajo la clave `fabricante|clase|modelo|firmware`, y solo se
corrige a mano el concepto que falle. Un modelo que nadie ha visto antes queda
cubierto en cuanto un equipo reporta su árbol.

Dos detalles que el enfoque por plantillas esconde y que se descubren al
derivar del árbol real:

- La banda de un radio se decide por `OperatingFrequencyBand`, **no por el
  número de instancia**: hay modelos donde el radio 1 es el de 5 GHz.
- El VLANID de una interfaz WAN **no está en la interfaz**, sino en la
  terminación de la que cuelga (`IP.Interface.N` → `Ethernet.VLANTermination.M`
  → `VLANID`). Una plantilla escrita de memoria lo pone en el sitio
  equivocado.

### 4.2 Factory reset: el ACS pierde lo que sabía

El documento dice que tras el reset «el ACS recupera la vinculación». Medido en
un equipo real: tras el BOOTSTRAP, **el árbol almacenado en el ACS pasó de 285
parámetros a 42**. El ACS reconoce al equipo por OUI/serie, pero lo que sabía
de él se borra y hay que volver a leerlo con un `GetParameterNames`.

Además, el reset borra en el CPE el `ManagementServer.URL`. Si no vuelve a
recibirlo —normalmente por DHCP— el equipo no regresa solo, por mucho que el
ACS lo esté esperando.

Redacción sugerida: tras un factory reset el equipo vuelve a aparecer, pero
hace falta (a) que recupere la URL del ACS por DHCP y (b) un refresco del árbol
antes de reaplicar el aprovisionamiento.

### 4.3 «Conoce ManagementServer.URL» es el 90 % del trabajo

El flujo de descubrimiento pasa de «obtiene configuración de red» a «conoce
`ManagementServer.URL`» como si fuera un paso trivial. Es el punto donde se
atascan los despliegues. Lo que falta nombrar:

- **Opción 43 del DHCP**, con sus tres codificaciones: TLV (subopción 1 +
  longitud + URL), URL plana para equipos que no entienden el TLV, y
  **opción 125** (RFC 3925, enterprise 3561 del Broadband Forum) que varios
  Huawei y ONT leen en lugar de la 43.
- En RouterOS 7, el *matcher* por la opción 60 (`dslforum.org`) permite servir
  TLV a unos equipos y URL plana a otros. **RouterOS 6 no tiene matchers** y
  obliga a elegir una sola codificación.
- **Un CPE con el cliente TR-069 apagado no se despierta con DHCP.** Caso real:
  un AP respondía al ping y servía su web, pero con el puerto 7547 cerrado y
  cero contactos al ACS. Ninguna opción de DHCP arregla eso; se activa en la
  interfaz del equipo. Señal rápida para distinguirlo: si el 7547 del CPE está
  cerrado, el cliente no está corriendo.

### 4.4 Connection Request: falta nombrar el NAT

El apartado dice que «deberá verificarse» el Connection Request sin mencionar
por qué falla en un ISP: el ACS solo alcanza al CPE si puede llegar a su
`ConnectionRequestURL`. Con CGNAT (`100.64.0.0/10`) o con NAT por medio, esa
dirección no es alcanzable desde la red de gestión salvo que el enrutamiento lo
contemple expresamente.

Sin Connection Request todo sigue funcionando, pero cada orden espera al
siguiente Periodic Inform. Con un intervalo de 300 s eso son hasta cinco
minutos de ceguera, y conviene decirlo porque determina qué se le puede
prometer al NOC.

### 4.5 La prioridad P0 está mal calibrada

Poner el firewall como P0 asume un ACS expuesto. En un despliegue local, con
NBI y FS ya cerrados por el instalador, el riesgo real está en otra parte.

El P0 medido es la **cobertura del árbol**: en una flota de 12 equipos, 6
tenían el árbol sin refrescar en el ACS (entre 28 y 45 parámetros frente a los
3.500–5.200 de un equipo leído). Sin árbol no hay identificación, ni perfil, ni
capacidades, ni aprovisionamiento. Ese es el cuello de botella.

---

## 5. Lo que no aparece y hace falta

- **El panel de gestión** construido sobre el NBI no figura ni en la
  arquitectura ni en la lista de respaldos, y su base de datos guarda
  credenciales WiFi y PPPoE de abonados. Debe entrar en ambos apartados.
- **Catálogo de modelos portable.** Lo aprendido de cada modelo (árbol de
  rutas, perfil deducido, correcciones a mano) puede exportarse de un
  laboratorio e importarse en producción, para que la instalación nueva no
  arranque en blanco. Resuelve el problema que el documento intenta atacar con
  plantillas.
- **Capacidades por modelo con tres estados.** No basta con «soporta / no
  soporta»: mientras el árbol esté incompleto la respuesta honesta es «todavía
  no se sabe». Afirmar que un modelo no soporta algo porque no aparece en un
  árbol a medias es un error que se paga en soporte.
- **Separar los respaldos por propósito.** El respaldo del ACS sirve para
  restaurar esa misma instalación; llevar modelos aprendidos de un sitio a otro
  es otra cosa y no debe mezclarse, porque el primero arrastra credenciales.

---

## 6. Cambios concretos que pediría al documento

1. Sustituir el apartado de plantillas por modelo por el perfil derivado del
   árbol, dejando las correcciones manuales como excepción y no como norma.
2. Reescribir el apartado de factory reset con lo que ocurre de verdad: el ACS
   pierde el árbol y el CPE pierde la URL.
3. Añadir un apartado propio de **entrega del ACS por DHCP** (opciones 43 y
   125, codificaciones, matcher de RouterOS 7, y el caso del cliente TR-069
   apagado).
4. Nombrar NAT y CGNAT en el apartado de Connection Request.
5. Reordenar prioridades: cobertura del árbol y entrega por DHCP por delante
   del endurecimiento del firewall en un despliegue local.
6. Reducir el apartado de health check a lo que falta de verdad: **disco,
   memoria, CPU y edad del último respaldo**.
7. Incorporar el panel y su base de datos a la arquitectura y al respaldo.

---

## 7. Criterio de validación

El criterio que propone el documento —un ciclo completo de descubrimiento,
identificación, clasificación, vinculación, aprovisionamiento, monitoreo,
factory reset, redescubrimiento y reaprovisionamiento— es bueno y conviene
conservarlo, con una condición: **cada casilla de la matriz por fabricante se
marca con un equipo real delante**, no por analogía con otro modelo de la misma
marca. Dos equipos del mismo fabricante difieren en el árbol más de lo que
parece, y entre dos firmwares del mismo modelo también.
