path = '/opt/centinela/CentinelaFrom/src/pages/administration/clientes/IndexPage.vue'
with open(path) as f:
    c = f.read()

# ============================================================================
# 1) Replace progress section with hero + better stages
# ============================================================================
old_progress = '''            <div v-if="deployProgress" class="q-mt-md">
              <div class="row items-center q-mb-sm">
                <q-icon v-if="!deployBusy && deployPercent === 100" name="check_circle" color="green-7" size="24px" class="q-mr-sm" />
                <q-spinner v-else color="purple-7" size="24px" class="q-mr-sm" />
                <div class="col">
                  <div class="text-subtitle2 text-weight-medium">{{ deployProgress }}</div>
                  <q-linear-progress :value="deployPercent / 100" :color="deployPercent === 100 ? 'green-7' : 'purple-7'" rounded class="q-mt-xs" size="6px" />
                </div>
                <div class="q-ml-sm text-weight-bold" :class="deployPercent === 100 ? 'text-green-8' : 'text-purple-8'">{{ deployPercent }}%</div>
              </div>
              <q-list separator bordered class="q-mt-md" style="border-radius: 8px">
                <q-item v-for="st in deployStages" :key="st.key" dense>
                  <q-item-section side><q-icon :name="deployStageIcon(st.key)" :color="deployStageColor(st.key)" size="22px" /></q-item-section>
                  <q-item-section>
                    <q-item-label class="text-weight-medium">{{ st.label }}</q-item-label>
                    <q-item-label caption class="text-grey-7">{{ deployStageDetail(st.key) }}</q-item-label>
                  </q-item-section>
                  <q-item-section side>
                    <q-spinner v-if="deployStageStatus[st.key] === 'running'" color="purple-7" size="18px" />
                    <q-chip v-else-if="deployStageStatus[st.key] === 'ok'" dense square color="green-1" text-color="green-9">OK</q-chip>
                    <q-chip v-else-if="deployStageStatus[st.key] === 'skipped'" dense square color="grey-3" text-color="grey-8">Skip</q-chip>
                    <q-chip v-else-if="deployStageStatus[st.key] === 'error'" dense square color="red-1" text-color="red-9">Error</q-chip>
                    <q-chip v-else dense square color="grey-2" text-color="grey-7">Pendiente</q-chip>
                  </q-item-section>
                </q-item>
              </q-list>
              <q-expansion-item dense expand-separator class="q-mt-md" icon="terminal" label="Ver log detallado">
                <pre class="ssh-log">{{ deployLog || 'Sin logs todavia...' }}</pre>
              </q-expansion-item>
            </div>'''

new_progress = '''            <div v-if="deployProgress" class="q-mt-md">
              <!-- HERO state: deploy completado con exito -->
              <div v-if="deployDone && !deployError" class="hero-success q-pa-lg">
                <div class="hero-check">
                  <q-circular-progress :value="100" size="92px" :thickness="0.14" color="positive" track-color="green-2" class="hero-ring">
                    <q-icon name="check" size="46px" color="positive" />
                  </q-circular-progress>
                </div>
                <div class="text-h6 text-weight-bold q-mt-md text-center">
                  {{ form.nombre }} {{ form.apellido }}
                </div>
                <div class="text-caption text-grey-7 text-center q-mb-md">Cliente listo para usar</div>

                <div class="hero-meta-grid">
                  <div v-if="sshForm.host" class="meta-card">
                    <div class="meta-label"><q-icon name="dns" size="14px" color="indigo-6" /> Servidor DNS</div>
                    <div class="meta-row">
                      <code class="meta-value">{{ sshForm.host }}</code>
                      <q-btn flat dense size="sm" icon="content_copy" color="grey-7" @click="copy(sshForm.host)">
                        <q-tooltip>Copiar IP</q-tooltip>
                      </q-btn>
                    </div>
                  </div>
                  <div v-if="grafanaPublicUrl" class="meta-card">
                    <div class="meta-label"><q-icon name="insights" size="14px" color="orange-7" /> Dashboard Grafana</div>
                    <div class="meta-row">
                      <a :href="grafanaPublicUrl" target="_blank" class="meta-value link">{{ grafanaPublicUrl.replace(/^https?:\\/\\//, '') }}</a>
                      <q-btn flat dense size="sm" icon="open_in_new" color="grey-7" :href="grafanaPublicUrl" target="_blank">
                        <q-tooltip>Abrir Grafana</q-tooltip>
                      </q-btn>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Progress bar + label (oculto cuando hero esta visible) -->
              <div v-else class="row items-center q-mb-sm">
                <q-icon v-if="deployError" name="error" color="negative" size="24px" class="q-mr-sm" />
                <q-spinner v-else color="purple-7" size="24px" class="q-mr-sm" />
                <div class="col">
                  <div class="text-subtitle2 text-weight-medium">{{ deployProgress }}</div>
                  <q-linear-progress
                    :value="deployPercent / 100"
                    :color="deployError ? 'negative' : 'purple-7'"
                    rounded class="q-mt-xs" size="6px"
                  />
                </div>
                <div class="q-ml-sm text-weight-bold" :class="deployError ? 'text-negative' : 'text-purple-8'">
                  {{ deployPercent }}%
                </div>
              </div>

              <!-- Stages timeline-like (compactado cuando hero visible) -->
              <q-list :separator="!deployDone || deployError" bordered class="q-mt-md stages-list" :class="{ 'stages-list--compact': deployDone && !deployError }" style="border-radius: 10px">
                <q-item v-for="st in deployStages" :key="st.key" dense class="stage-item" :class="`stage-item--${deployStageStatus[st.key]}`">
                  <q-item-section side>
                    <q-icon :name="deployStageIcon(st.key)" :color="deployStageColor(st.key)" size="22px" />
                  </q-item-section>
                  <q-item-section>
                    <q-item-label class="text-weight-medium">{{ st.label }}</q-item-label>
                    <q-item-label caption class="text-grey-7">{{ deployStageDetail(st.key) }}</q-item-label>
                  </q-item-section>
                  <q-item-section side>
                    <q-spinner v-if="deployStageStatus[st.key] === 'running'" color="purple-7" size="18px" />
                    <q-chip v-else-if="deployStageStatus[st.key] === 'ok'" dense square color="green-1" text-color="green-9" icon="check">OK</q-chip>
                    <q-chip v-else-if="deployStageStatus[st.key] === 'skipped'" dense square color="grey-3" text-color="grey-8">Omitido</q-chip>
                    <q-chip v-else-if="deployStageStatus[st.key] === 'error'" dense square color="red-1" text-color="red-9" icon="error">Error</q-chip>
                    <q-chip v-else dense square color="grey-2" text-color="grey-7">Pendiente</q-chip>
                  </q-item-section>
                </q-item>
              </q-list>

              <q-expansion-item dense expand-separator class="q-mt-md log-expander" icon="terminal" label="Log detallado">
                <pre class="ssh-log">{{ deployLog || 'Sin logs todavia...' }}</pre>
              </q-expansion-item>
            </div>'''

assert c.count(old_progress) == 1, 'progress section anchor not found'
c = c.replace(old_progress, new_progress, 1)

# ============================================================================
# 2) Replace footer with state-adaptive buttons
# ============================================================================
old_footer = '''        <q-card-actions align="right" class="q-pa-md bg-grey-1">
          <q-btn flat label="Cancelar" v-close-popup />
          <q-btn unelevated color="indigo-7" :label="editing ? 'Guardar cambios' : 'Crear cliente'" :icon="editing ? 'save' : 'check'" :loading="saving" @click="save" />
        </q-card-actions>'''

new_footer = '''        <q-card-actions align="right" class="q-pa-md bg-grey-1 footer-adaptive">
          <template v-if="editing">
            <q-btn flat label="Cancelar" v-close-popup />
            <q-btn unelevated color="indigo-7" label="Guardar cambios" icon="save" :loading="saving" @click="save" />
          </template>
          <template v-else>
            <template v-if="!deployProgress">
              <q-btn flat label="Cancelar" v-close-popup />
              <q-btn unelevated color="indigo-7" label="Crear cliente" icon="check" :loading="saving" @click="save" />
            </template>
            <template v-else-if="deployBusy">
              <q-btn flat icon="picture_in_picture_alt" label="Minimizar" color="grey-7" @click="deployFloating = true" />
            </template>
            <template v-else-if="deployDone && !deployError">
              <q-btn v-if="grafanaPublicUrl" flat label="Abrir Grafana" icon-right="open_in_new" :href="grafanaPublicUrl" target="_blank" color="grey-7" />
              <q-btn unelevated color="positive" label="Cerrar" icon="check" autofocus @click="cerrarYLimpiarDeploy" />
            </template>
            <template v-else>
              <q-btn flat label="Cerrar" color="grey-7" @click="cerrarYLimpiarDeploy" />
              <q-btn unelevated color="negative" label="Reintentar" icon="refresh" :loading="saving" @click="save" />
            </template>
          </template>
        </q-card-actions>'''

assert c.count(old_footer) == 1, 'footer anchor not found'
c = c.replace(old_footer, new_footer, 1)

# ============================================================================
# 3) Add computeds deployDone / deployError + helper cerrarYLimpiarDeploy
# ============================================================================
old_floating = '''const deployFloating = ref(false)
const cerrarFlotante = () => {'''
new_with_helpers = '''const deployFloating = ref(false)

// Estado derivado del deploy
const deployError = computed(() =>
  Object.values(deployStageStatus).some((s) => s === 'error')
)
const deployDone = computed(
  () => !deployBusy.value && deployPercent.value === 100 && !deployError.value
)

// Cerrar el modal post-deploy y limpiar el estado para que el proximo
// "Nuevo cliente" arranque limpio (sin progreso viejo flasheando).
const cerrarYLimpiarDeploy = () => {
  formOpen.value = false
  deployFloating.value = false
  deployBusy.value = false
  deployProgress.value = ''
  deployLog.value = ''
  for (const k of Object.keys(deployStageStatus)) deployStageStatus[k] = 'pending'
}

const cerrarFlotante = () => {'''
assert c.count(old_floating) == 1, 'deployFloating anchor not found'
c = c.replace(old_floating, new_with_helpers, 1)

# ============================================================================
# 4) Remove auto-close on completion + better microcopy
# ============================================================================
old_close = '''          deployProgress.value = 'Cliente y servidor creados correctamente'
          await load()
          setTimeout(() => {
            formOpen.value = false
            deployProgress.value = ''
            deployLog.value = ''
          }, 1500)'''
new_close = '''          // NO auto-close — el usuario necesita ver/copiar credenciales.
          // El cierre lo hace via el boton "Cerrar" del footer adaptativo.
          deployProgress.value = `${form.nombre || 'Cliente'} listo. Servidor en ${sshForm.host || ''}`.trim()
          await load()'''
assert c.count(old_close) == 1, 'auto-close block not found'
c = c.replace(old_close, new_close, 1)

# ============================================================================
# 5) Inject CSS in the existing <style scoped>
# ============================================================================
import re
style_match = re.search(r'(\.cli-modal--floating[^}]*\})', c)
if style_match:
    insert_at = style_match.end()
    css_block = """

/* === Modal deploy: hero + meta cards + stages === */
.hero-success {
  text-align: center;
  background: linear-gradient(180deg, rgba(34,197,94,0.06) 0%, transparent 100%);
  border-radius: 12px;
}
.hero-ring { animation: hero-pop 0.5s cubic-bezier(0.34, 1.56, 0.64, 1); }
@keyframes hero-pop { 0%{transform:scale(0.3);opacity:0} 100%{transform:scale(1);opacity:1} }
.hero-meta-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
  margin-top: 16px;
}
@media (max-width: 600px) { .hero-meta-grid { grid-template-columns: 1fr; } }
.meta-card {
  background: #f5f7fa;
  border: 1px solid #e5e9f0;
  border-radius: 10px;
  padding: 10px 12px;
  text-align: left;
}
.meta-label {
  font-size: 10px;
  text-transform: uppercase;
  color: #6b7280;
  letter-spacing: 0.5px;
  margin-bottom: 4px;
  display: flex;
  align-items: center;
  gap: 4px;
}
.meta-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 4px;
}
.meta-value {
  font-family: Consolas, monospace;
  font-weight: 600;
  font-size: 13px;
  word-break: break-all;
  color: #1f2937;
}
.meta-value.link { color: #4338ca; text-decoration: none; }
.meta-value.link:hover { text-decoration: underline; }

.stages-list--compact .stage-item { opacity: 0.7; min-height: 32px; padding-top: 4px; padding-bottom: 4px; }
.stage-item--running { background: linear-gradient(90deg, rgba(108, 99, 255, 0.05), transparent); }
.stage-item--error { background: rgba(239,68,68,0.05); }

.footer-adaptive { min-height: 56px; }
"""
    c = c[:insert_at] + css_block + c[insert_at:]

with open(path, 'w') as f:
    f.write(c)
print('OK')
