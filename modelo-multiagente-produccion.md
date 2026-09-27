# Modelo multiagente de desarrollo, auditoría y paso a producción

Guía de trabajo para cualquier proyecto. Define quién hace qué, cuánto rigor aplica cada
cambio, qué evidencia hace falta para aprobar y qué bloquea un despliegue.

Sustituye a la primera versión de este modelo. Los cambios principales están al final, en
[Qué cambió y por qué](#16-qué-cambió-respecto-a-la-primera-versión).

---

## 1. Principio de fondo

> Diseñar → desarrollar → **intentar romper** → corregir → auditar → desplegar → observar.

El objetivo no es producir código que funcione. Es entregar sistemas **correctos, seguros,
reversibles, probados y observables**.

Y una regla que manda sobre el resto:

> **El proceso existe para encontrar defectos. Si un paso no ha encontrado nunca nada,
> sobra.**

Un modelo que nadie cumple porque es demasiado caro protege menos que uno modesto que se
aplica siempre.

---

## 2. Lo primero: clasificar el cambio

**El error más común al aplicar un modelo como este es aplicarlo plano.** Renombrar una
etiqueta y tocar la autenticación no pueden costar lo mismo, porque entonces el equipo deja
de pedir cambios o empieza a saltarse el proceso.

Antes de trabajar, el Coordinador clasifica el cambio por **radio de daño**: a quién le
duele si esto está mal.

| Nivel | Qué es | Ejemplos |
|---|---|---|
| **N1 — Cosmético** | Si se equivoca, alguien ve algo feo | textos, estilos, orden de bloques, documentación |
| **N2 — Funcional** | Si se equivoca, una función da un resultado erróneo | lógica de negocio, informes, filtros, API interna |
| **N3 — Sensible** | Si se equivoca, hay pérdida, exposición o corte de servicio | autenticación, permisos, datos, migraciones, dinero, cortes a clientes |
| **N4 — Recurso compartido** | Afecta a infraestructura o datos de terceros | routers y firewalls de un cliente, DNS público, sistemas de otra organización |

El nivel decide el proceso (sección 5). **Ante la duda, sube de nivel.**

---

## 3. El Coordinador

Es la autoridad técnica del flujo y responde por el conjunto, no por los módulos.

Sus funciones:

- Clasificar el cambio (sección 2) y dejarlo escrito.
- Dividir el trabajo, identificar dependencias y asignar a los especialistas.
- Detectar **contradicciones entre entregas**, que es lo que nadie ve desde dentro de su
  módulo.
- Exigir evidencia, no afirmaciones (sección 7).
- Ordenar correcciones y **repetir sólo las verificaciones afectadas**.
- Emitir el estado final (sección 10).

**Ningún proyecto está terminado porque los especialistas hayan terminado.** El cierre es
del Coordinador.

Y una obligación que suele faltar: **el Coordinador también se equivoca**. Cuando su propia
decisión resulte errónea, debe corregirla en el informe y dejar dicho qué la causó, no
reescribir la historia.

---

## 4. Especialistas

Se activan **según el nivel y el contenido del cambio**, no todos siempre.

| Agente | Se activa cuando el cambio toca |
|---|---|
| **Arquitectura** | estructura, servicios, contratos, dependencias, flujos |
| **UI/UX** | interfaz, navegación, estados vacíos/carga/error, accesibilidad |
| **Frontend** | cliente, estado, integración con API, permisos en pantalla |
| **Backend** | lógica, endpoints, autenticación, autorización, transacciones |
| **Base de datos** | esquema, índices, migraciones, integridad, retención |
| **Seguridad** | *siempre en N3 y N4*; en N2 si hay entrada de usuario o permisos |
| **DevOps** | despliegue, red, secretos, backups, monitoreo, rollback |
| **QA** | *siempre desde N2* |
| **Dominio** | *siempre que el negocio tenga reglas propias* (ISP, facturación, salud, redes…) |

### El especialista de dominio no es opcional

Es el que detecta que el código **funciona y aun así está mal**. Un sistema puede pasar
todas las pruebas técnicas y seguir siendo incorrecto para el negocio: una regla de
enrutado que no aplica, un impuesto mal interpretado, un umbral que en esa red significa
otra cosa.

### Qué revisa cada uno

Las listas exhaustivas de la primera versión se sustituyen por una regla: **cada
especialista responde por escrito a "¿qué es lo peor que puede pasar en mi área con este
cambio, y cómo he comprobado que no pasa?"**. Si la respuesta no incluye una comprobación,
no es una revisión: es una opinión.

---

## 5. Proceso según nivel

**N1 — Cosmético**
Desarrollo → validación automática → revisión del autor → despliegue.
Sin auditoría formal. Si rompe algo, se revierte.

**N2 — Funcional**
Desarrollo → **prueba de comportamiento que falla antes del arreglo** → validación
automática → revisión cruzada (una, no todas) → despliegue con rollback.

**N3 — Sensible**
Todo lo de N2, más: Seguridad, QA con pruebas negativas, respaldo verificado antes de
tocar, plan de rollback escrito y **autorización humana explícita**.

**N4 — Recurso compartido**
Todo lo de N3, más: respaldo del sistema ajeno (export/snapshot), ventana acordada,
**autorización de quien es dueño del recurso** y un comando de vuelta atrás probado antes
de aplicar.

```text
                 CAMBIO
                    |
              clasificar (N1..N4)
                    |
        +-----------+-----------+
        |                       |
       N1                   N2 / N3 / N4
        |                       |
   validación              especialistas
   automática                   |
        |                 revisión cruzada
        |                       |
        |               QA + Seguridad (N3+)
        |                       |
        +-----------+-----------+
                    |
            AUDITORÍA DEL COORDINADOR
                    |
     +--------+-----+-----+----------+
     |        |           |          |
  APROBADO  CON OBS.  CORRECCIONES  BLOQUEADO
     |
  PRODUCCIÓN → OBSERVACIÓN
```

---

## 6. Lo que de verdad encuentra defectos

Esta sección es la que más cambia respecto a la primera versión, porque los tres
mecanismos siguientes encuentran más problemas que cualquier ronda de revisión — y no
aparecían.

### 6.1 Una validación automática que corre siempre

Un único comando que cualquiera pueda ejecutar y que falle en rojo: sintaxis, linters,
pruebas, y las comprobaciones propias del proyecto. **Si no corre en cada cambio, no
existe.**

Atrapa cosas que ninguna lectura humana ve: una variable fuera de alcance, un operador con
precedencia distinta de la esperada, un nombre mal escrito en una rama poco frecuente.

### 6.2 Pruebas de comportamiento, no de existencia

> Comprobar que el código **está** no es comprobar que **funciona**.

Una prueba debe:

- **Fallar antes del arreglo.** Si pasa igual sin el cambio, no prueba nada.
- **Comprobar el resultado**, no que una función exista o que un texto aparezca.
- **Vivir en el repositorio.** Una prueba en un directorio temporal no protege de nada.
- **Explicar el caso real que la motivó**, para que el siguiente sepa qué se rompió.

Y cubrir explícitamente:

- el **caso vacío** (sin datos, primera ejecución, archivo ausente),
- el **caso degradado** (la consulta falla, el servicio no responde),
- y el **caso de que ya está arreglado** — que un diagnóstico no siga acusando a algo que
  ya se corrigió.

### 6.3 Verificación contra el sistema real

Antes de dar por bueno un cambio que depende del entorno, **medirlo donde corre**. Un
resultado en el portátil del desarrollador no dice nada sobre la máquina de producción.

---

## 7. Evidencia

> **Un hallazgo sin reproducción es una hipótesis. Una corrección sin medición es una
> creencia.**

Para aceptar un hallazgo: qué falla, con qué entrada, qué se esperaba y qué salió.
Para aceptar una corrección: la medición antes y después, o la prueba que fallaba y ahora
pasa.

### Diagnosticar de fuera hacia dentro

Ante un síntoma difuso (“va lento”, “no funciona”), el orden es:

1. **La entrada del sistema** — red, caudal, pérdida, disco, memoria.
2. **El servicio** — ¿responde rápido cuando se le pregunta desde dentro?
3. **El código** — sólo si los dos anteriores están sanos.

Ir directo al código es el error más caro: se encuentran cosas reales, se arreglan, y el
síntoma sigue igual porque la causa estaba en el cable.

### No confiar en el contador acumulado

Una métrica acumulada desde el arranque sigue acusando el problema **días después de
haberlo arreglado**. Para decidir, usar siempre una medición de la ventana actual; el
acumulado sirve de contexto y debe etiquetarse como tal.

---

## 8. Auditoría cruzada

Un agente no valida en solitario su propio trabajo.

**Pero hay que ser honesto sobre cuándo es real.** Si el mismo actor escribe el código y
las pruebas, cambiar de sombrero no añade independencia: es el mismo criterio dos veces.

La independencia es real cuando viene de:

- **otra persona o agente** con criterio distinto,
- **una herramienta** que no comparte los supuestos del autor (linter, analizador,
  revisor automático, escáner de seguridad),
- **el sistema real**, que no negocia,
- o **el usuario**, que ve lo que el autor da por hecho.

Cuando no se pueda conseguir independencia real, **decirlo en el informe** en vez de
aparentarla.

---

## 9. Severidad

| Nivel | Qué provoca | Efecto |
|---|---|---|
| **Crítico** | compromiso de seguridad, pérdida o corrupción de datos, caída total, acceso no autorizado | **bloquea producción** |
| **Alto** | afecta la función principal, la seguridad, la estabilidad o la integridad | corregir antes, salvo excepción escrita y firmada |
| **Medio** | errores parciales, mala experiencia, deuda técnica | se puede desplegar si queda documentado y con tarea creada |
| **Bajo** | mejora sin impacto inmediato | backlog |

Dos precisiones que evitan discusiones:

- **La severidad se calibra por alcance real.** Antes de decir "crítico", comprobar desde
  dónde se alcanza de verdad el problema: algo interno no es lo mismo que algo expuesto a
  internet, aunque la clase de vulnerabilidad sea la misma.
- **Un fallo silencioso sube de severidad.** Un error que se ve es un incidente; uno que
  no deja rastro y da una respuesta falsa —"limpia", "sin amenazas", "actualizado"— es
  peor, porque nadie lo busca.

---

## 10. Estados

- **APROBADO** — controles superados, sin hallazgos críticos ni altos abiertos.
- **APROBADO CON OBSERVACIONES** — sólo hallazgos medios o bajos, documentados y con tarea.
- **REQUIERE CORRECCIONES** — vuelve al especialista; se repiten las verificaciones
  afectadas y **las que dependen de ellas**.
- **BLOQUEADO** — existe al menos una condición crítica.

**Regla de duda razonable:** si hay duda sobre seguridad, pérdida de datos, migraciones,
rollback, autenticación o autorización, el estado es **no aprobado** hasta que haya
evidencia de que el riesgo está resuelto. La duda no se resuelve desplegando.

---

## 11. Criterios de producción

El checklist **se declara por nivel** y lo que no aplica se marca como tal, con el motivo.
Un checklist con ítems inaplicables se firma en bloque sin leerlo, y entonces no protege.

**Siempre (cualquier nivel):**

```text
[ ] Validación automática en verde
[ ] Cambio clasificado (N1..N4) y anotado
[ ] Se sabe cómo revertir
```

**Desde N2:**

```text
[ ] Prueba de comportamiento que falla sin el arreglo
[ ] Revisión cruzada realizada (por quién)
[ ] Caso vacío y caso degradado cubiertos
[ ] Documentación de la propia aplicación actualizada
```

**Desde N3:**

```text
[ ] Seguridad auditada (con alcance real, no teórico)
[ ] Dependencias revisadas
[ ] Respaldo verificado ANTES de tocar
[ ] Restauración probada, no supuesta
[ ] Rollback escrito y ejecutable
[ ] Secretos fuera del código, de los argumentos y del historial
[ ] Logs y alertas cubren el fallo nuevo
[ ] Autorización humana explícita
```

**Desde N4:**

```text
[ ] Respaldo del sistema ajeno (export/snapshot) guardado
[ ] Autorización del dueño del recurso
[ ] Vuelta atrás probada antes de aplicar
[ ] Ventana acordada y aviso enviado
```

---

## 12. Después de desplegar

El modelo no termina en producción. Todo despliegue desde N2 lleva:

- **Qué observar** y durante cuánto (una métrica concreta, no "estar atentos").
- **Qué señal dispara la vuelta atrás.**
- **Quién mira**, y cuándo se da por estabilizado.

Un despliegue que nadie observa es un despliegue que se descubre roto por un usuario.

---

## 13. Cómo fracasa este modelo

Los modos de fallo son tan importantes como las reglas:

- **Teatro de proceso.** Se rellenan los formularios y nadie ejecuta nada. *Antídoto:* cada
  aprobación exige evidencia (sección 7).
- **Sello de goma.** El revisor aprueba porque confía en el autor. *Antídoto:* el revisor
  declara qué comprobó, no que revisó.
- **Fatiga de checklist.** 23 ítems en cada cambio se firman sin leer. *Antídoto:* niveles
  (sección 11).
- **Independencia aparente.** El mismo actor con otro sombrero. *Antídoto:* sección 8.
- **Gate que se salta.** Si el proceso hace imposible entregar, se entrega por fuera.
  *Antídoto:* si un paso estorba y nunca ha encontrado nada, se elimina.
- **Auditar lo fácil.** Se revisa el código nuevo y no la configuración, el dato o el
  entorno, que es donde suelen estar los problemas caros.

---

## 14. Informe final del Coordinador

Sólo para N3 y N4; en N2 basta el registro del cambio con su evidencia.

```markdown
# Auditoría — <proyecto / cambio>

**Nivel:** N3    **Estado:** APROBADO / CON OBSERVACIONES / CORRECCIONES / BLOQUEADO

## Qué cambia y por qué
<en dos frases, en lenguaje del negocio>

## Radio de daño si esto está mal
<a quién le duele, y cuánto>

## Verificación
| Qué | Cómo se comprobó | Resultado |
|---|---|---|

## Hallazgos
| Severidad | Área | Hallazgo | Reproducción | Estado |
|---|---|---|---|---|

## Independencia de la revisión
<quién o qué revisó, distinto del autor; o por qué no se pudo>

## Riesgos que quedan abiertos
## Rollback
<comando o procedimiento concreto, probado>
## Qué observar tras desplegar
## Decisión
```

---

## 15. Directiva permanente

1. Clasificar el cambio antes de trabajar.
2. Aplicar el proceso del nivel, ni más ni menos.
3. Exigir evidencia, no afirmaciones.
4. Buscar independencia real y declararla cuando no exista.
5. Nada a producción sin saber cómo volver atrás.
6. Ante duda razonable en seguridad o datos: no aprobado.
7. Observar después de desplegar.

> **Primero calidad, seguridad y consistencia; después producción.**
> Y antes que todo eso, **saber cuánto vale este cambio**, para no gastar en un texto lo
> que hace falta para una migración.

---

## 16. Qué cambió respecto a la primera versión

| Cambio | Motivo |
|---|---|
| **Niveles N1–N4 por radio de daño** | La versión anterior aplicaba nueve especialistas y dos auditorías a cualquier cambio. El coste del proceso superaba al del cambio y el efecto real era saltárselo. |
| **Sección 6 nueva: validación automática, pruebas de comportamiento, verificación real** | Es lo que más defectos encuentra y no aparecía. Los errores de precedencia, alcance de variables o escapado no los ve ninguna revisión por lectura. |
| **Independencia honesta (sección 8)** | La versión anterior daba por independiente cualquier segundo rol. Si el mismo actor escribe código y pruebas, cambiar de sombrero no añade nada; mejor decirlo. |
| **Evidencia obligatoria y diagnóstico de fuera hacia dentro (sección 7)** | Un hallazgo sin reproducción hace perder el día. Y mirar el código antes que el entorno es el error de diagnóstico más caro. |
| **Checklist por niveles y con "no aplica" justificado** | 23 ítems planos, varios inaplicables, se firman en bloque. |
| **Severidad calibrada por alcance, y fallo silencioso agravado** | Evita el "todo es crítico" y pone el foco donde más duele: lo que falla sin dejar rastro. |
| **Sección 12: observación posterior** | El modelo terminaba en el despliegue; ahí es donde aparecen la mitad de los problemas. |
| **Sección 13: cómo fracasa el modelo** | Un proceso sin antídotos contra el teatro y el sello de goma se convierte en ambas cosas. |
| **Listas exhaustivas sustituidas por una pregunta** | "¿Qué es lo peor que puede pasar en mi área y cómo comprobé que no pasa?" produce revisiones útiles; una lista de 20 ítems produce ticks. |
