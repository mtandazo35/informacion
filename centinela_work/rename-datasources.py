"""
Extiende la propagacion del rename de empresa: ademas de renombrar la Org,
renombrar el datasource Prometheus DENTRO de esa Org y el datasource ESPEJO
en MAAT (que se usa en el dashboard agregado MONITOREO CLIENTES).

Match por URL (`http://{ip}:9090`) para identificar exactamente cual ds renombrar
en cada org, sin depender del nombre viejo.
"""

# =====================================================================
# PATCH 1: GrafanaService — agregar helper renameDatasourceByUrl
# =====================================================================
p1 = '/home/HippoCentinelaBack/src/grafana/grafana.service.ts'
with open(p1) as f:
    c = f.read()

# Anclamos despues de renameOrg (metodo existente)
anchor = '''  /** Renombra una Org (cosmetico — no afecta UIDs ni dashboards) */
  async renameOrg(orgId: number, newName: string): Promise<void> {
    const cfg = await this.configService.getResolved()
    if (!cfg) throw new Error('Grafana no configurado')
    await this.http(cfg).put(`/api/orgs/${orgId}`, { name: newName })
    this.logger.log(`Org ${orgId} renombrada a '${newName}'`)
  }'''

new_block = anchor + '''

  /**
   * Renombra el datasource que apunta a una URL especifica dentro de una org.
   * Usado cuando se renombra la empresa del cliente: ademas de la Org, hay que
   * renombrar el datasource en su propia org Y el datasource espejo en MAAT
   * (los dos siguen el mismo nombre que la Org).
   *
   * Match por URL (no por name) para identificar el ds correcto sin ambiguedad:
   * cada cliente tiene un solo ds apuntando a `http://{ip}:9090`.
   *
   * No throws — log warn si falla, devuelve true/false. Es cosmetico.
   */
  async renameDatasourceByUrl(orgId: number, url: string, newName: string): Promise<boolean> {
    const cfg = await this.configService.getResolved()
    if (!cfg) return false
    const http = this.http(cfg)
    try {
      // Switch a la org target — los endpoints /api/datasources son org-scoped.
      await http.post(`/api/user/using/${orgId}`)
      const { data: list } = await http.get('/api/datasources')
      const ds = (list || []).find((d: any) => (d.url || '') === url)
      if (!ds) {
        this.logger.warn(`Datasource con url '${url}' no encontrado en org ${orgId}`)
        return false
      }
      // PUT requiere casi todo el body — preservamos lo existente y solo cambiamos name.
      await http.put(`/api/datasources/uid/${ds.uid}`, {
        ...ds,
        name: newName,
      })
      this.logger.log(`Datasource ${ds.uid} en org ${orgId} renombrado a '${newName}'`)
      return true
    } catch (e: any) {
      this.logger.warn(`renameDatasourceByUrl org=${orgId} url=${url}: ${e?.response?.data?.message || e?.message}`)
      return false
    }
  }'''

assert c.count(anchor) == 1, 'renameOrg anchor not found'
c = c.replace(anchor, new_block, 1)
with open(p1, 'w') as f:
    f.write(c)
print('grafana.service.ts OK')

# =====================================================================
# PATCH 2: ClientesService.update() — invocar renameDatasourceByUrl
# tras renameOrg, en la propia org del token y en MAAT.
# =====================================================================
p2 = '/home/HippoCentinelaBack/src/clientes/clientes.service.ts'
with open(p2) as f:
    c = f.read()

old = '''        // BEST-EFFORT: org rename (cosmetico, no rompe el login)
        if (orgNameChanged) {
          for (const orgId of orgIds) {
            try {
              await this.grafanaService.renameOrg(orgId, newOrgName);
            } catch (e: any) {
              warnings.push(`Org ${orgId} no renombrada: ${e?.response?.data?.message || e?.message}`);
            }
          }
        }'''

new = '''        // BEST-EFFORT: org rename (cosmetico, no rompe el login)
        if (orgNameChanged) {
          // Computar slug minusculo del nuevo nombre para el ds DENTRO de la org del cliente
          // (sigue la convencion del provisioning: el ds local usa slug, el de MAAT usa orgName).
          const slug = newOrgName.toLowerCase().replace(/\\s+/g, '-').replace(/[^a-z0-9-]/g, '').slice(0, 40) || 'cliente';
          for (const t of tokensWithGrafana) {
            const orgId = t.grafanaOrgId as number;
            const dsUrl = t.ip ? `http://${t.ip}:9090` : null;
            // 1) Renombrar la Org
            try {
              await this.grafanaService.renameOrg(orgId, newOrgName);
            } catch (e: any) {
              warnings.push(`Org ${orgId} no renombrada: ${e?.response?.data?.message || e?.message}`);
              continue;
            }
            // 2) Renombrar el datasource dentro de la org del cliente (matching por URL)
            if (dsUrl) {
              const okClient = await this.grafanaService.renameDatasourceByUrl(orgId, dsUrl, slug);
              if (!okClient) warnings.push(`Datasource en org ${orgId} no renombrado`);
              // 3) Renombrar el datasource ESPEJO en MAAT (org 1) — es el que aparece
              //    en el dropdown del dashboard "MAAT · MONITOREO CLIENTES".
              const okMaat = await this.grafanaService.renameDatasourceByUrl(1, dsUrl, newOrgName);
              if (!okMaat) warnings.push(`Datasource en MAAT no renombrado (${dsUrl})`);
            }
          }
        }'''

assert c.count(old) == 1, 'orgRename block anchor not found'
c = c.replace(old, new, 1)
with open(p2, 'w') as f:
    f.write(c)
print('clientes.service.ts OK')
