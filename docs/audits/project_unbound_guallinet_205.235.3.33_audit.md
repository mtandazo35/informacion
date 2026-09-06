---
name: Auditoría Unbound Guallinet 205.235.3.33
description: Auditoría de solo lectura del resolver Unbound maat-dns-guallinet, iniciada 2026-09-03 y continuada 2026-09-06
type: project
status: fase_auditoria_completada
tags:
  - dns
  - unbound
  - seguridad
  - auditoria
---

# Auditoría Unbound — maat-dns-guallinet

## Alcance y reglas

- Host: `205.235.3.33` (`maat-dns-guallinet`).
- Auditoría autorizada exclusivamente en modo lectura.
- No editar configuración, instalar paquetes, recargar/reiniciar servicios, vaciar caché ni reiniciar estadísticas.
- No guardar ni exponer claves privadas.
- Entorno ISP con CGNAT: no recomendar `ip-ratelimit` ni firewall rate-limit por IP cliente. Ver [[feedback_cgnat_no_ip_ratelimit]].
- Cualquier cambio futuro requiere análisis previo, respaldo y aprobación explícita. Ver [[feedback_analyze_only]] y [[feedback_backup_before_changes]].

## Acceso y plataforma observada

- SSH solo acepta clave pública.
- Huella ED25519 observada: `SHA256:PS8i45CY1PIXw2xzZz4MRRlYgCwmV3xjlvWWswbiHDE`.
- Acceso de auditoría confirmado como `root`; la clave privada no se documenta.
- Debian 13.6 trixie, kernel `6.12.74+deb13+1-amd64`, VM KVM/QEMU, 8 vCPU, 7.8 GiB RAM, 2 GiB swap.
- Unbound `1.22.0-2+deb13u3`, OpenSSL 3.5.7, libevent 2.1.12.

## Estado confirmado 2026-09-03

- `unbound-checkconf`: sin errores.
- Servicio habilitado y activo desde 2026-08-30.
- DNS UDP/TCP 53 activo en IPv4 e IPv6; UFW `INPUT DROP` limita IPv4 a bloques autorizados.
- No es un open resolver según doble control ACL Unbound + UFW.
- Control remoto solo por socket Unix `/run/unbound.ctl`, modo `0660 root:unbound`; TCP/8953 no expuesto.
- TCP/853 cerrado; DoT/DoQ no configurados.
- DNSSEC funcional: `dnssec-failed.org` devuelve `SERVFAIL`; trust anchor RFC 5011 válido y última consulta exitosa.
- `hide-identity`, `hide-version`, `qname-minimisation`, `aggressive-nsec`, `minimal-responses`, `harden-dnssec-stripped`, `harden-glue` activos.
- EDNS buffer: 1232 bytes.
- RPZ diario: 572,296 dominios, staging + promoción atómica + `unbound-checkconf` + canarios + rollback.

## Métricas base

- Uptime estadístico: 347,951 s.
- Consultas: 2,689,195 (promedio aproximado 7.73 qps).
- Cache hits: 2,238,802 (83.25 %).
- Cache misses: 450,393.
- RPZ NXDOMAIN: 222,975 (8.29 % de las consultas).
- `requestlist.exceeded`: 6,718 (0.25 %); `requestlist.overwritten`: 0.
- SERVFAIL: 1,123; REFUSED: 5,004; DNSSEC bogus: 204.
- Unbound: 1.26 GiB RSS, 36.5 % de un núcleo en la muestra; sin swap.
- Journal total: 497 MiB.

## Hallazgos priorizados

### Alta — versión con vulnerabilidades posteriores al parche Debian de mayo

La versión Debian instalada es la candidata actual del repositorio configurado y corrige DSA-6304-1, pero Debian todavía marca vulnerabilidades de julio de 2026 en trixie. Rutas aplicables observadas:

- CVE-2026-50252: `so-reuseport: yes` + múltiples workers; reducción de entropía efectiva de puertos y posible cache poisoning.
- CVE-2026-50251: `unwanted-reply-threshold: 10000`; un dominio controlado puede forzar vaciados repetidos de caché.
- CVE-2026-46582: `serve-expired: yes`; replay de wildcard en ruta serve-expired con posibilidad de cache poisoning.
- CVE-2026-42955: `harden-referral-path: yes`; variante ghost-domain sobre glue A/AAAA.

Upstream corrige estas rutas desde 1.25.2; 1.26.0 es la versión upstream publicada al momento de la revisión. No se aplicó ningún parche ni upgrade.

Fuentes:

- https://security-tracker.debian.org/tracker/source-package/unbound
- https://security-tracker.debian.org/tracker/DSA-6304-1
- https://www.nlnetlabs.nl/projects/unbound/security-advisories/

### Media — separación de privilegios y sandbox

- El proceso principal baja correctamente a UID/GID `unbound` y queda con `CapEff=0`.
- No usa chroot ni seccomp y la unidad carece de la mayoría de protecciones systemd; `systemd-analyze security` reportó exposición 9.6/10.
- El usuario `unbound` pertenece globalmente a `systemd-journal`; el daemon principal puede leer el journal completo.
- `unbound-log-exporter` y `unbound-exporter` también usan `unbound`, carecen de sandbox fuerte y acceden por identidad al socket de control.
- `unbound-rpz-block-exporter` sí tiene hardening razonable (3.7/10).

### Media — cadena de suministro/DoS del actualizador RPZ

- Tarea diaria corre como root y descarga varios feeds HTTPS sin firma criptográfica.
- Valida caracteres/longitud de dominios y conserva la zona anterior si el feed queda vacío o cae más de 50 %.
- No limita tamaño descargado, tamaño descomprimido, número máximo de dominios ni crecimiento superior.
- ThreatFox se descomprime leyendo el primer miembro ZIP completo en memoria: riesgo de ZIP-bomb o agotamiento de disco/RAM.
- Aspectos positivos: `mktemp`, `flock`, staging, promoción atómica, backup, checkconf, canarios y rollback.

### Media — telemetría y privacidad

- dnstap captura consultas de clientes.
- El exportador publica métricas con IP cliente, dominio y par cliente/dominio.
- RPZ registra IP y dominio bloqueado en journal; Prometheus puede conservar estas etiquetas según su retención.
- `/var/log/unbound-rpz-blocks.jsonl` estaba vacío y protegido `0640`; logrotate diario, 20 MiB, 14 rotaciones.

### Media — indicios de ráfagas/pérdida

- `requestlist.exceeded=6718` y una muestra mostró `Recv-Q=1280` en un socket UDP/53.
- Promedio bajo, pero posible saturación en ráfagas; requiere correlación temporal y revisión de contadores del kernel.
- No proponer rate limit por IP debido a CGNAT. Evaluar defensas per-name (`ratelimit`, `max-global-quota`) cuando se diseñen cambios.

### Baja

- `remote-control` está definido tanto en `unbound.conf` como en `unbound.conf.d/remote-control.conf`; se observaron dos FDs/listeners para el mismo path.
- No hay `private-address` explícito para mitigación de DNS rebinding.
- Root hints contiene cabecera de abril de 2024, pero es idéntico al archivo del paquete `dns-root-data 2025080400~deb13u1`; no se considera desactualización local independiente.

## Bitácora de acciones de auditoría

- 2026-09-03: identificación SSH y fijación de host key; intentos fallidos no ejecutaron comandos.
- 2026-09-03: acceso root confirmado con clave local autorizada.
- 2026-09-03: lectura de SO, paquetes, versión, unidad systemd, configuración, ACL, RPZ, sockets, UFW, logs, estadísticas `stats_noreset`, trust anchor y scripts de actualización.
- 2026-09-03: consultas externas normales UDP/TCP, CHAOS, DNSSEC y puertos 853/8953.
- 2026-09-03: consulta de Debian Security Tracker y avisos oficiales NLnet Labs.
- 2026-09-06: auditoría reanudada; pendiente capturar delta operativo, opciones efectivas, pruebas funcionales/RPZ, contadores UDP y eventos desde la muestra inicial.

## Continuación y cierre — 2026-09-06

### Resumen ejecutivo actualizado

El resolver está activo, estable y no se comporta como open resolver gracias a ACL de Unbound más UFW. DNSSEC, TCP, EDNS y RPZ funcionan. No obstante, se confirmaron dos riesgos prioritarios: la versión conserva rutas afectadas por vulnerabilidades divulgadas en julio de 2026 y la salida IPv6 está rota, provocando demoras y timeouts de caché fría, especialmente durante validación DNSSEC. `serve-expired` enmascara parte del problema entregando respuestas antiguas al segundo configurado.

También se confirmó pérdida silenciosa del historial JSONL de bloqueos RPZ desde el 31 de agosto, exposición de datos personales en métricas durante 30 días y un volumen muy alto de logs RPZ. Evaluación cualitativa de esta fase: riesgo global **medio-alto** hasta resolver versión vulnerable, conectividad IPv6 y persistencia/privacidad RPZ.

### Delta operativo

- Servicio activo desde 2026-08-30, sin reinicios (`NRestarts=0`).
- Uptime estadístico: 619,205 s.
- Consultas: 22,842,766; hits 21,334,186; misses 1,508,580.
- Hit ratio acumulado aproximado: 93.4 %; el delta desde 2026-09-03 fue cercano a 94.7 %.
- Incremento entre muestras: aproximadamente 20.15 millones en 271,253 s, unos 74.3 qps promedio.
- RPZ NXDOMAIN 1,381,310; passthru 31,570; SERVFAIL 20,229; DNSSEC bogus 1,714.
- `requestlist.avg=12.44`, `max=1087`, `exceeded=30,456`, `overwritten=0`; 94 pendientes en la muestra.
- Recursión promedio 374.6 ms; mediana 277.5 ms.
- Memoria de Unbound aproximada: 1.42 GB, pico 1.44 GB; sin OOM.
- Los contadores acumulados pueden variar ante recargas internas; se interpretaron como tendencia sin ejecutar `stats_reset`.

Opciones efectivas relevantes: `ratelimit: 0`, `ip-ratelimit: 0`, `max-global-quota: 128`, `deny-any: no`, `answer-cookie: no`, `unwanted-reply-threshold: 10000`, `serve-expired: yes`, `serve-expired-client-timeout: 1000`, `discard-timeout: 1900`, `private-address` vacío y `harden-unverified-glue: no`.

### Alta — salida IPv6 rota con impacto real

- Dirección local `2803:c310:ff10:20::53/64`; gateway `2803:c310:ff10:20::1`.
- El vecino del gateway permanece `INCOMPLETE`; ping al gateway devuelve destino inalcanzable.
- Fallaron pruebas IPv6 a un root server, Cloudflare y Google, además de una consulta directa al root. La misma consulta por IPv4 funcionó.
- Unbound mantiene `do-ip6: yes`; su infraestructura mostró RTO de 6–12 s hacia autoritativos IPv6.
- `dnssec-failed.org` en caché fría agotó timeout por UDP y terminó EOF por TCP. Con `CD` devolvió datos inmediatamente; cuando el DNSKEY quedó disponible por IPv4, la consulta normal devolvió el `SERVFAIL` correcto en 4 ms.
- Se observaron solicitudes pendientes esperando Apple, Microsoft, Cloudflare y otros destinos por IPv6.

Conclusión: el origen está en L2/gateway IPv6 aguas arriba, no en el motor DNS. Afecta consultas normales y validación DNSSEC; `serve-expired-client-timeout=1000` oculta parte del impacto.

### Media — pérdida silenciosa del historial RPZ

- `unbound-rpz-block-exporter` sigue activo y sus métricas avanzan; superaba 1.96 millones de bloqueos contabilizados.
- `/var/log/unbound-rpz-blocks.jsonl.1` contiene 61,673,323 bytes y termina el 2026-08-31 00:31.
- El archivo actual fue creado a las 00:32 y permanece en 0 bytes.
- La unidad usa `ProtectSystem=strict` y `ReadWritePaths` sobre el archivo individual. Tras la rotación, la raíz del namespace está en solo lectura y el nuevo archivo queda fuera del bind writable efectivo.
- El programa captura `OSError` con `pass`; el fallo de escritura queda oculto y systemd muestra el servicio sano.
- Logrotate rota diariamente o a 20 MiB, conserva 14 copias y usa `create 0640 unbound unbound`, sin `copytruncate` ni acción post-rotación.

Impacto: no hay evidencia JSONL persistente nueva desde el 31 de agosto, aunque métricas en memoria y Prometheus continúan.

### Media — privacidad, Prometheus y logs

- Los exportadores RPZ/dnstap exponen top de dominios e IP de cliente; el journal contiene pares IP/dominio.
- Prometheus scrapea cada 15 s, conserva 30 días y su TSDB ocupaba aproximadamente 231 MiB.
- Exportadores 9100/9167/9169/9170 escuchan solo en loopback.
- Prometheus escucha en `*:9090`, sin archivo de autenticación web; UFW restringe el puerto a redes de gestión, por lo que la protección depende del firewall.
- El journal usa aproximadamente 502 MiB, junto al límite `SystemMaxUse=500M`. El rate limit de journald y de la unidad Unbound está desactivado.
- Muestras breves de RPZ generaron cientos de KiB. La rotación rápida reduce la ventana histórica y añade I/O/CPU.
- `/etc/rsyslog.d/10-unbound.conf` descarta los mensajes del programa Unbound para evitar duplicarlos en syslog.
- Se vieron repeticiones masivas asociadas con C2/Mirai y otros dominios bloqueados; conviene investigar los clientes afectados fuera de esta auditoría del resolver.

### Capacidad y red

- Kernel: `UdpInErrors=0`, `UdpRcvbufErrors=0`, `UdpSndbufErrors=0`; no hay evidencia de pérdida por buffers UDP.
- Conntrack: 31,663 de 262,144, sin presión crítica.
- `eth0` acumuló 22,719 RX drops, pero el contador específico del driver `rx0_drops=0`; vigilar tendencia.
- UFW procesó cerca de 848 millones de paquetes y descartó aproximadamente 30.7 millones según política.
- Muchos ICMP port-unreachable desde clientes autorizados contienen respuestas DNS tardías, compatible con sockets cerrados o con otro resolver que respondió primero.
- Parte importante de `requestlist.exceeded` y de la latencia coincide con los RTO IPv6.

No proponer límites por IP debido a CGNAT. Cualquier protección adicional debe basarse en nombre/QTYPE, cuotas globales y pruebas de carga.

### Pruebas funcionales adicionales

- `cloudflare.com A +dnssec`: respuesta cacheada con AD y EDNS 1232.
- DNS por TCP y root `DNSKEY +dnssec`: correctos.
- `version.bind CH TXT`: `REFUSED`, comportamiento esperado.
- Dominio canario RPZ: NXDOMAIN.
- Whitelist: `lgtvsdp.com`, `graph.instagram.com` y `amazonsilk.com` no quedaron bloqueados.
- DNSSEC inválido: validación correcta una vez disponible el material por IPv4; caché fría afectada por IPv6 roto.

### Plan propuesto — no ejecutado

1. Corregir gateway/NDP/ruta IPv6 aguas arriba. Si IPv6 no se ofrece realmente, evaluar desactivar solo la salida IPv6 de Unbound como mitigación temporal, con ventana y pruebas.
2. Planificar una actualización soportada a una versión con los parches de julio de 2026; validar en staging DNSSEC, RPZ, rendimiento, `so-reuseport` y `serve-expired`.
3. Corregir persistencia RPZ mediante un directorio dedicado writable administrado por systemd (`LogsDirectory`) o una rotación compatible; registrar y alertar los `OSError`.
4. Reducir datos sensibles: eliminar pares cliente/dominio, pseudonimizar IP, limitar labels y revisar la retención de 30 días.
5. Separar usuarios/grupos de Unbound, lectura del journal y socket de control; endurecer unidades gradualmente.
6. Añadir límites de descarga, descompresión y conteo a RPZ, junto con verificación criptográfica cuando el proveedor la ofrezca.
7. Evaluar en laboratorio `ratelimit` por nombre, `deny-any`, `answer-cookie`, `harden-unverified-glue` y `private-address`. No usar `ip-ratelimit` ni UFW limit por IP en este CGNAT.

### Bitácora adicional

- 2026-09-06: delta operativo, opciones efectivas, memoria/CPU, requestlist y estadísticas sin reset.
- 2026-09-06: pruebas de transporte IPv4/IPv6, gateway NDP, DNSSEC de caché fría e infraestructura de Unbound.
- 2026-09-06: revisión de kernel UDP, interfaz, conntrack, UFW, journal, rsyslog y volumen RPZ.
- 2026-09-06: auditoría de exportadores, namespace, archivo JSONL/logrotate y retención de Prometheus.
- 2026-09-06: consolidación de hallazgos y propuestas; ninguna corrección aplicada.

## Estado final de esta fase

Auditoría de Unbound completada con evidencia suficiente. Quedan pendientes únicamente decisiones y cambios de remediación, no autorizados por el alcance actual.
