# informacion — repositorio de SOLO documentación

Este repo contiene **exclusivamente documentación en Markdown**. No es un directorio
de trabajo, aunque sea el `cwd` por defecto de las sesiones de Claude Code.

## Permitido aquí

- `README.md`
- Documentos `.md` de arquitectura, relevamientos, ingeniería inversa, notas técnicas
- `.gitignore`, `CLAUDE.md`
- `.claude/` (ignorada por git)

## Prohibido aquí

Scripts (`.sh`, `.rsc`, `.ps1`, `.py`), instaladores, dashboards, código de aplicación,
salidas de diagnóstico, carpetas de trabajo, repos anidados, archivos temporales.

## Dónde va cada proyecto

En **su propia carpeta hermana** bajo `C:\Users\Manuel\Documents\GitHub\<nombre-proyecto>\`,
como repo Git independiente.

Antes de crear cualquier archivo que no sea `.md` de documentación:

1. Si la ruta destino incluye `GitHub\informacion` → **DETENERSE** y usar `../<proyecto>/`.
2. Si ya existe una carpeta hermana que es **exactamente ese mismo proyecto** → usarla.
3. Si es un proyecto distinto, aunque el tema sea parecido → **crear carpeta nueva**.
   No agrupar por temática amplia; agrupar por proyecto real.

Ejemplos de carpetas hermanas ya existentes: `mikrotik-firewall/`, `wg-installer/`,
`unbound-vps-installer/`, `dns-appliance/`, `zabbix-installer/`, `genieacs-installer/`,
`proxmox-monitoring/`, `librenms-installer-debian/`.
