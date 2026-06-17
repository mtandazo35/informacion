"""
Patch 1: agregar metodos publicos en GrafanaService para propagar cambios
de cliente (password, login, orgname) hacia Grafana.

Patch 2: refactorizar ClientesService.update() para detectar cambios
relevantes y llamar a Grafana antes de commitear BD (saga simple).
"""

# ============================================================================
# PATCH 1: GrafanaService — agregar metodos publicos
# ============================================================================
p1 = '/home/HippoCentinelaBack/src/grafana/grafana.service.ts'
with open(p1) as f:
    c = f.read()

# Anclar despues de rotatePassword (metodo existente) para mantener orden logico.
anchor = '''  /** Reenvía credenciales: genera password nuevo y retorna las credenciales. */
  async rotatePassword(grafanaUserId: number): Promise<{ username: string; password: string }> {
    const cfg = await this.configService.getResolved()
    if (!cfg) throw new Error('Grafana no configurado')
    const http = this.http(cfg)

    const password = this.generatePassword()
    // PUT /api/admin/users/{id}/password
    await http.put(`/api/admin/users/${grafanaUserId}/password`, { password })

    // Obtener username
    const { data: user } = await http.get(`/api/users/${grafanaUserId}`)
    return { username: user.login, password }
  }'''

new_section = anchor + '''

  /**
   * Setea una password explicita en Grafana para un user. Usado por la
   * propagacion de cambios desde el form de edicion de cliente.
   * Throws si Grafana rechaza (policy violation, user inexistente, etc.).
   */
  async updateUserPassword(grafanaUserId: number, newPassword: string): Promise<void> {
    const cfg = await this.configService.getResolved()
    if (!cfg) throw new Error('Grafana no configurado')
    await this.http(cfg).put(`/api/admin/users/${grafanaUserId}/password`, { password: newPassword })
    this.logger.log(`Password actualizado para user Grafana ${grafanaUserId}`)
  }

  /**
   * Cambia el login (username) de un user. Grafana exige email+name en el body
   * para evitar nulificarlos accidentalmente, asi que los leemos antes.
   */
  async updateUserLogin(grafanaUserId: number, newLogin: string): Promise<void> {
    const cfg = await this.configService.getResolved()
    if (!cfg) throw new Error('Grafana no configurado')
    const http = this.http(cfg)
    const { data: user } = await http.get(`/api/users/${grafanaUserId}`)
    await http.put(`/api/users/${grafanaUserId}`, {
      login: newLogin,
      email: user.email,
      name: user.name,
    })
    this.logger.log(`Login actualizado a '${newLogin}' para user Grafana ${grafanaUserId}`)
  }

  /** Renombra una Org (cosmetico — no afecta UIDs ni dashboards) */
  async renameOrg(orgId: number, newName: string): Promise<void> {
    const cfg = await this.configService.getResolved()
    if (!cfg) throw new Error('Grafana no configurado')
    await this.http(cfg).put(`/api/orgs/${orgId}`, { name: newName })
    this.logger.log(`Org ${orgId} renombrada a '${newName}'`)
  }

  /** Pre-check: existe ya un user con ese login? Devuelve {id} o null */
  async lookupUserByLogin(login: string): Promise<{ id: number } | null> {
    const cfg = await this.configService.getResolved()
    if (!cfg) throw new Error('Grafana no configurado')
    try {
      const { data } = await this.http(cfg).get(
        `/api/users/lookup?loginOrEmail=${encodeURIComponent(login)}`,
      )
      return data?.id ? { id: data.id } : null
    } catch (e: any) {
      if (e?.response?.status === 404) return null
      throw e
    }
  }'''

assert c.count(anchor) == 1, 'rotatePassword anchor not found'
c = c.replace(anchor, new_section, 1)
with open(p1, 'w') as f:
    f.write(c)
print('grafana.service.ts OK')

# ============================================================================
# PATCH 2: ClientesService.update() — propagacion antes de commit BD
# ============================================================================
p2 = '/home/HippoCentinelaBack/src/clientes/clientes.service.ts'
with open(p2) as f:
    c = f.read()

old_update = '''  async update(id: string, dto: any) {
    this.validate(dto);
    const c = await this.repo.findOne({ where: { id } });
    if (!c) throw new NotFoundException('Cliente no encontrado');
    if (dto.cedula && dto.cedula !== c.cedula) {
      const exists = await this.repo.findOne({ where: { cedula: dto.cedula } });
      if (exists) throw new BadRequestException('Ya existe un cliente con esa cedula');
    }
    const { grafanaPassword, diaSuspension, ...rest } = dto;
    Object.assign(c, rest);
    if (grafanaPassword !== undefined && grafanaPassword !== null && grafanaPassword !== '') {
      c.grafanaPassword = encryptSecret(String(grafanaPassword));
    }
    if (diaSuspension !== undefined) {
      c.diaSuspension = diaSuspension === null || diaSuspension === '' ? null : Number(diaSuspension);
    }
    const saved = await this.repo.save(c);
    return this.mask(saved);
  }'''

new_update = '''  async update(id: string, dto: any) {
    this.validate(dto);
    const c = await this.repo.findOne({ where: { id } });
    if (!c) throw new NotFoundException('Cliente no encontrado');
    if (dto.cedula && dto.cedula !== c.cedula) {
      const exists = await this.repo.findOne({ where: { cedula: dto.cedula } });
      if (exists) throw new BadRequestException('Ya existe un cliente con esa cedula');
    }

    // SNAPSHOT ANTES de aplicar — necesario para detectar cambios y propagar
    // a Grafana antes de commitear BD (evita desync si Grafana rechaza).
    const before = {
      grafanaUsuario: c.grafanaUsuario,
      empresa: c.empresa,
      nombre: c.nombre,
      apellido: c.apellido,
    };
    const buildOrgName = (n?: string | null, a?: string | null, e?: string | null) =>
      (e && e.trim()) ? e.trim() : `${(n || '').trim()} ${(a || '').trim()}`.trim();
    const oldOrgName = buildOrgName(before.nombre, before.apellido, before.empresa);

    const { grafanaPassword, diaSuspension, ...rest } = dto;
    Object.assign(c, rest);
    if (grafanaPassword !== undefined && grafanaPassword !== null && grafanaPassword !== '') {
      c.grafanaPassword = encryptSecret(String(grafanaPassword));
    }
    if (diaSuspension !== undefined) {
      c.diaSuspension = diaSuspension === null || diaSuspension === '' ? null : Number(diaSuspension);
    }

    // ============ PROPAGACION A GRAFANA ============
    const newOrgName = buildOrgName(c.nombre, c.apellido, c.empresa);
    const usernameChanged = !!(c.grafanaUsuario && c.grafanaUsuario !== before.grafanaUsuario);
    const orgNameChanged = !!newOrgName && newOrgName !== oldOrgName;
    const passwordChanged = grafanaPassword !== undefined && grafanaPassword !== null && grafanaPassword !== '';

    const warnings: string[] = [];

    if (passwordChanged || usernameChanged || orgNameChanged) {
      const tokens = await this.tokenRepo.find({ where: { clienteId: id } });
      const tokensWithGrafana = tokens.filter((t) => t.grafanaUserId && t.grafanaOrgId);

      if (tokensWithGrafana.length) {
        // Dedupe: un cliente puede tener N tokens pero idealmente UN solo user
        // global en Grafana (con N memberships). Lo mismo para orgs: cada token
        // tiene su Org, pero algunas pueden compartirla.
        const userIds = [...new Set(tokensWithGrafana.map((t) => t.grafanaUserId as number).filter(Boolean))];
        const orgIds = [...new Set(tokensWithGrafana.map((t) => t.grafanaOrgId as number).filter(Boolean))];

        // Pre-check uniqueness de username (anti P0: colision)
        if (usernameChanged) {
          try {
            const existing = await this.grafanaService.lookupUserByLogin(c.grafanaUsuario as string);
            if (existing && !userIds.includes(existing.id)) {
              throw new BadRequestException(
                `El username '${c.grafanaUsuario}' ya existe en Grafana (id=${existing.id}). Elige otro.`,
              );
            }
          } catch (e: any) {
            if (e instanceof BadRequestException) throw e;
            warnings.push(`No pude verificar uniqueness de username: ${e?.message}`);
          }
        }

        // CRITICAL: password + username — si fallan, ABORT antes de tocar BD.
        for (const uid of userIds) {
          if (passwordChanged) {
            try {
              await this.grafanaService.updateUserPassword(uid, String(grafanaPassword));
            } catch (e: any) {
              throw new BadRequestException(
                `Error al cambiar password en Grafana (user ${uid}): ${e?.response?.data?.message || e?.message}`,
              );
            }
          }
          if (usernameChanged) {
            try {
              await this.grafanaService.updateUserLogin(uid, c.grafanaUsuario as string);
            } catch (e: any) {
              throw new BadRequestException(
                `Error al cambiar username en Grafana (user ${uid}): ${e?.response?.data?.message || e?.message}`,
              );
            }
          }
        }

        // BEST-EFFORT: org rename (cosmetico, no rompe el login)
        if (orgNameChanged) {
          for (const orgId of orgIds) {
            try {
              await this.grafanaService.renameOrg(orgId, newOrgName);
            } catch (e: any) {
              warnings.push(`Org ${orgId} no renombrada: ${e?.response?.data?.message || e?.message}`);
            }
          }
        }

        // Sincronizar las columnas espejo en token tambien.
        if (usernameChanged || passwordChanged) {
          const updates: any = {};
          if (usernameChanged) updates.grafanaUsername = c.grafanaUsuario;
          if (passwordChanged) updates.grafanaPassword = c.grafanaPassword;
          for (const t of tokensWithGrafana) {
            await this.tokenRepo.update(t.id, updates);
          }
        }
      }
    }

    const saved = await this.repo.save(c);
    const result: any = this.mask(saved);
    if (warnings.length) result.grafanaWarnings = warnings;
    return result;
  }'''

assert c.count(old_update) == 1, 'update() anchor not found'
c = c.replace(old_update, new_update, 1)
with open(p2, 'w') as f:
    f.write(c)
print('clientes.service.ts OK')
