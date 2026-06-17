<template>
  <div class="recibo">
    <header class="recibo__header">
      <div class="recibo__logo">
        <img v-if="logo" :src="logo" alt="Logotipo" />
        <span v-else class="recibo__logo-placeholder">Logotipo</span>
      </div>
      <h1 class="recibo__empresa">{{ empresa }}</h1>
      <p class="recibo__servicio">{{ servicio }}</p>
    </header>

    <section class="recibo__info">
      <p><strong>SUCURSAL:</strong> {{ sucursal }}</p>
      <h2 class="recibo__numero">{{ numero }}</h2>

      <div class="recibo__datos">
        <p><strong>Fecha:</strong> {{ fecha }}</p>
        <p><strong>RUC/CI:</strong> {{ rucCi }}</p>
        <p><strong>Nombre:</strong> {{ nombre }}</p>
        <p><strong>Direc:</strong> {{ direccion }}</p>
      </div>

      <p class="recibo__aviso">ESTE DOCUMENTO NO TIENE VALOR TRIBUTARIO</p>
    </section>

    <table class="recibo__tabla">
      <thead>
        <tr>
          <th>#</th>
          <th class="text-left">Detalle</th>
          <th>pvp</th>
          <th>Descto</th>
          <th>Total</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="(item, i) in items" :key="i">
          <td>{{ i + 1 }}</td>
          <td class="text-left">
            <div>{{ item.detalle }}</div>
            <div class="recibo__subdetalle"><em>{{ item.periodo }}</em></div>
          </td>
          <td>{{ item.pvp }}</td>
          <td>{{ item.descuento }}</td>
          <td>{{ item.total }}</td>
        </tr>
      </tbody>
      <tfoot>
        <tr>
          <td colspan="4" class="text-right"><strong>Total:</strong></td>
          <td>{{ totalGeneral }}</td>
        </tr>
      </tfoot>
    </table>

    <p class="recibo__son"><strong>SON:</strong> {{ totalLetras }}</p>

    <footer class="recibo__footer">
      <p class="recibo__gracias">¡Agradecemos su confianza!</p>
      <p>Recuerde realizar sus pagos puntualmente para evitar interrupciones en el servicio.</p>
      <p>
        Ante cualquier duda, contáctenos al
        <strong>{{ telefono }}</strong> o en
        <a :href="`mailto:${email}`">{{ email }}</a>.
      </p>
    </footer>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  logo: { type: String, default: '' },
  empresa: { type: String, default: 'RED NUEVA CONEXIÓN' },
  servicio: { type: String, default: 'INTERNET' },
  sucursal: { type: String, default: 'HUMBERTO MOREIRA Y ALBERTO NICOLA' },
  numero: { type: String, default: '001009 - 00001803' },
  fecha: { type: String, default: '17/04/2026 11:27am' },
  rucCi: { type: String, default: '1205937210' },
  nombre: { type: String, default: 'GUILLEN CHAGUAY DIANA KATIUSKA' },
  direccion: { type: String, default: 'Altolfo Guerra' },
  items: {
    type: Array,
    default: () => [
      { detalle: 'PLAN 3ERA EDAD', periodo: 'MES MAYO', pvp: 10, descuento: 0, total: 10 }
    ]
  },
  totalLetras: { type: String, default: 'DIEZ DÓLARES' },
  telefono: { type: String, default: '(04) 375-5230' },
  email: { type: String, default: 'info@rednuevaconexion.net' }
})

const totalGeneral = computed(() =>
  props.items.reduce((sum, it) => sum + Number(it.total || 0), 0)
)
</script>

<style scoped>
.recibo {
  max-width: 360px;
  margin: 0 auto;
  padding: 16px;
  font-family: 'Segoe UI', Arial, sans-serif;
  font-size: 13px;
  color: #1a1a1a;
  background: #fff;
  border: 1px solid #e5e5e5;
}

.recibo__header { text-align: center; margin-bottom: 12px; }
.recibo__logo img { max-width: 60px; height: auto; }
.recibo__logo-placeholder {
  display: inline-block;
  padding: 16px;
  border: 1px dashed #ccc;
  color: #888;
  font-size: 11px;
}
.recibo__empresa { font-size: 16px; margin: 6px 0 2px; }
.recibo__servicio { margin: 0 0 8px; font-size: 13px; }

.recibo__info p { margin: 2px 0; }
.recibo__numero { text-align: center; font-size: 15px; margin: 10px 0; }
.recibo__datos { margin: 8px 0; }
.recibo__aviso {
  text-align: center;
  font-size: 11px;
  margin: 10px 0;
  color: #444;
}

.recibo__tabla {
  width: 100%;
  border-collapse: collapse;
  margin: 8px 0;
}
.recibo__tabla th,
.recibo__tabla td {
  padding: 6px 4px;
  border-bottom: 1px solid #eee;
  text-align: center;
  vertical-align: top;
}
.recibo__tabla thead th {
  border-bottom: 1px solid #333;
  font-weight: bold;
}
.recibo__tabla tfoot td {
  border-bottom: none;
  border-top: 1px solid #333;
  font-weight: bold;
}
.recibo__subdetalle { font-size: 11px; color: #555; }

.text-left { text-align: left; }
.text-right { text-align: right; }

.recibo__son { margin: 10px 0; }

.recibo__footer {
  text-align: center;
  font-size: 11px;
  margin-top: 14px;
  border-top: 1px dashed #ccc;
  padding-top: 10px;
}
.recibo__gracias { font-weight: bold; margin-bottom: 6px; }
.recibo__footer a { color: inherit; text-decoration: underline; }

@media print {
  .recibo { border: none; max-width: 100%; }
}
</style>
