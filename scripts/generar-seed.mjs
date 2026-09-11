/**
 * Genera supabase/seed.sql con datos 100 % ficticios.
 *
 * - Determinista: la semilla del generador es fija, así que dos ejecuciones
 *   producen exactamente el mismo archivo (diffs limpios, pruebas estables).
 * - Fechas relativas: todas se expresan como `private.hoy() + N`, de modo que
 *   el tablero se ve igual de vivo el día que se cargue el seed, no el día en
 *   que se generó.
 * - Nombres de IPS, personas, correos y seriales son inventados. Las ciudades
 *   son reales porque la regla de negocio de los IDs depende de ellas.
 *
 * Uso: npm run seed:generar
 */
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..');

// ------------------------------------------------------------------ azar fijo
function mulberry32(semilla) {
  let a = semilla;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rnd = mulberry32(360);
const entre = (min, max) => Math.floor(rnd() * (max - min + 1)) + min;
const elegir = (lista) => lista[Math.floor(rnd() * lista.length)];

// ---------------------------------------------------------------- SQL helpers
const q = (v) => (v === null || v === undefined ? 'null' : `'${String(v).replace(/'/g, "''")}'`);
const dia = (n) => (n === null ? 'null' : `private.hoy() + ${n}`);
const instante = (n, horas) => `(private.hoy() + ${n})::timestamptz + interval '${horas} hours'`;
const bloquesDe = (filas, tam = 200) =>
  Array.from({ length: Math.ceil(filas.length / tam) }, (_, i) => filas.slice(i * tam, (i + 1) * tam));

// ---------------------------------------------------------------- catálogos
const ALFABETO = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

const REGIONALES = [
  {
    nombre: 'Principales', buzon: 'red.principales@reddoc.demo', ips: 14,
    ciudades: [['Bogotá', 'BOG'], ['Medellín', 'MED'], ['Cali', 'CAL'], ['Barranquilla', 'BAQ']]
  },
  {
    nombre: 'Intermedias', buzon: 'red.intermedias@reddoc.demo', ips: 16,
    ciudades: [['Bucaramanga', 'BUC'], ['Pereira', 'PER'], ['Manizales', 'MAN'], ['Ibagué', 'IBA'],
               ['Neiva', 'NEI'], ['Villavicencio', 'VIL']]
  },
  {
    nombre: 'Remotas', buzon: 'red.remotas@reddoc.demo', ips: 12,
    ciudades: [['Arauca', 'ARA'], ['Leticia', 'LET'], ['Quibdó', 'QUI'], ['Riohacha', 'RIO'],
               ['Yopal', 'YOP'], ['Mocoa', 'MOC'], ['Inírida', 'INI']]
  }
];

const PREFIJOS = ['IPS', 'Centro Médico', 'Clínica', 'Unidad Médica', 'Centro de Salud Ocupacional'];
const NUCLEOS = ['Horizonte', 'Aurora', 'Los Andes', 'Nueva Esperanza', 'Del Río', 'Alianza', 'Sinergia',
  'Prevenir', 'Vital', 'Integral', 'Cordillera', 'Brisas', 'El Roble', 'Pacífico', 'Altamira',
  'Candelaria', 'La Sabana', 'Orinoquía', 'Mirador', 'Bienestar Laboral'];
const ESPECIALIDADES = ['Audiología', 'Espirometría', 'Optometría', 'Radiología'];

// [id, nombre, categoria, especialidad, consulta, formato]
const DOCUMENTOS = [
  ['DOC_001', 'Certificado de habilitación (REPS)', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_002', 'Certificado de existencia y representación legal', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_003', 'Registro único tributario (RUT)', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_004', 'Póliza de responsabilidad civil', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_005', 'Concepto sanitario', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_006', 'Licencia Salud Ocupacional IPS', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_007', 'Licencia Médicos Especialistas', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_008', 'RETHUS del talento humano', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_009', 'Plan de gestión integral de residuos', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_010', 'Plan de emergencias', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_011', 'Protocolo de bioseguridad', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_012', 'Certificado de fumigación', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_013', 'Certificado de lavado de tanques', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_014', 'Política de tratamiento de datos', 'Administrativa y normativa', '', 'Externa', 'PDF'],
  ['DOC_015', 'Licencia de práctica de rayos X', 'Administrativa y normativa', 'Radiología', 'Externa', 'PDF'],
  ['DOC_016', 'Protocolo de audiometría', 'Administrativa y normativa', 'Audiología', 'Externa', 'PDF'],
  ['DOC_017', 'Protocolo de optometría', 'Administrativa y normativa', 'Optometría', 'Externa', 'PDF'],
  ['DOC_030', 'Báscula · mantenimiento preventivo', 'Mantenimiento', '', 'Externa', 'PDF'],
  ['DOC_031', 'Tensiómetro · mantenimiento preventivo', 'Mantenimiento', '', 'Externa', 'PDF'],
  ['DOC_032', 'Audiómetro · mantenimiento preventivo', 'Mantenimiento', 'Audiología', 'Externa', 'PDF'],
  ['DOC_033', 'Cabina audiométrica · mantenimiento', 'Mantenimiento', 'Audiología', 'Externa', 'PDF'],
  ['DOC_034', 'Espirómetro · mantenimiento preventivo', 'Mantenimiento', 'Espirometría', 'Externa', 'PDF'],
  ['DOC_035', 'Electrocardiógrafo · mantenimiento preventivo', 'Mantenimiento', '', 'Externa', 'PDF'],
  ['DOC_036', 'Visiómetro · mantenimiento preventivo', 'Mantenimiento', 'Optometría', 'Externa', 'PDF'],
  ['DOC_037', 'Equipo de rayos X · mantenimiento', 'Mantenimiento', 'Radiología', 'Externa', 'PDF'],
  ['DOC_040', 'Báscula · certificado de calibración', 'Calibración', '', 'Externa', 'PDF'],
  ['DOC_041', 'Tensiómetro · certificado de calibración', 'Calibración', '', 'Externa', 'PDF'],
  ['DOC_042', 'Audiómetro · certificado de calibración', 'Calibración', 'Audiología', 'Externa', 'PDF'],
  ['DOC_043', 'Espirómetro · certificado de calibración', 'Calibración', 'Espirometría', 'Externa', 'PDF'],
  ['DOC_044', 'Termohigrómetro · certificado de calibración', 'Calibración', '', 'Externa', 'PDF'],
  ['DOC_060', 'Contrato de prestación de servicios', 'Vinculación', '', 'Interno', 'PDF'],
  ['DOC_061', 'Certificación bancaria', 'Vinculación', '', 'Interno', 'PDF'],
  ['DOC_062', 'Formulario de conocimiento del aliado (SARLAFT)', 'Vinculación', '', 'Interno', 'PDF'],
  ['DOC_063', 'Acuerdo de confidencialidad', 'Vinculación', '', 'Interno', 'PDF'],
  ['DOC_068', 'Portafolio y tarifas de servicios', 'Vinculación', '', 'Interno', 'HOJA_CALCULO'],
  ['DOC_069', 'Fotos de las instalaciones', 'Vinculación', '', 'Interno', 'IMAGEN'],
  ['DOC_070', 'Acta de visita de supervisión', 'No auditable', '', 'Interno', 'PDF']
].map(([id, nombre, categoria, especialidad, consulta, formato]) =>
  ({ id, nombre, categoria, especialidad, consulta, formato }));

const NOMBRES = ['Andrea', 'Camilo', 'Daniela', 'Felipe', 'Juliana', 'Mateo', 'Laura', 'Santiago',
  'Valentina', 'Sebastián', 'Carolina', 'Andrés', 'Paula', 'Julián', 'Natalia', 'Diego'];
const APELLIDOS = ['Rojas', 'Gómez', 'Herrera', 'Castaño', 'Mejía', 'Salazar', 'Ospina', 'Quintero',
  'Cárdenas', 'Villamil', 'Rincón', 'Pardo', 'Arango', 'Montoya', 'Cifuentes', 'Beltrán'];
const MOTIVOS_RECHAZO = ['El documento está ilegible.', 'La fecha de expedición no es visible.',
  'El soporte corresponde a otra sede.', 'Falta la firma del responsable.'];
const MOTIVOS_INACTIVO = ['La sede dejó de prestar el servicio.', 'Equipo dado de baja.',
  'Servicio trasladado a otra sede.'];

const esEquipo = (doc) => doc.categoria === 'Mantenimiento' || doc.categoria === 'Calibración';
const esMultiple = (doc) => esEquipo(doc) || doc.id === 'DOC_007' || doc.id === 'DOC_008';
const PREFIJO_SERIAL = { DOC_030: 'BAS', DOC_031: 'TEN', DOC_032: 'AUD', DOC_033: 'CAB', DOC_034: 'ESP',
  DOC_035: 'ECG', DOC_036: 'VIS', DOC_037: 'RX', DOC_040: 'BAS', DOC_041: 'TEN', DOC_042: 'AUD',
  DOC_043: 'ESP', DOC_044: 'THG' };

// --------------------------------------------------------------------- IPS
const ips = [];
const nombresUsados = new Set();
const idsUsados = new Set();
for (const regional of REGIONALES) {
  for (let n = 0; n < regional.ips; n++) {
    const [ciudad, codigo] = regional.ciudades[n % regional.ciudades.length];
    let id;
    do {
      id = codigo + '-' + Array.from({ length: 6 }, () => elegir(ALFABETO)).join('');
    } while (idsUsados.has(id));
    idsUsados.add(id);

    let nombre;
    do {
      nombre = `${elegir(PREFIJOS)} ${elegir(NUCLEOS)} ${ciudad}`;
    } while (nombresUsados.has(nombre));
    nombresUsados.add(nombre);

    ips.push({
      id, nombre, ciudad, regional: regional.nombre,
      correo: `sede.${id.toLowerCase()}@ips.reddoc.demo`,
      correoLider: `lider.${id.toLowerCase()}@ips.reddoc.demo`,
      especialidades: ESPECIALIDADES.filter(() => rnd() < 0.55),
      // Qué tan al día tiene la sede sus documentos: da variedad al tablero.
      calidad: 0.3 + rnd() * 0.65
    });
  }
}

// -------------------------------------------------------------------- matriz
// Los requisitos de especialidad sólo aplican a las sedes que la prestan. Los
// demás no llevan filas: sin filas en la matriz, el requisito aplica a todas.
const matriz = [];
for (const doc of DOCUMENTOS) {
  if (!doc.especialidad) continue;
  for (const sede of ips) {
    if (sede.especialidades.includes(doc.especialidad)) matriz.push([doc.id, sede.id]);
  }
}
const aplica = (doc, sede) => !doc.especialidad || sede.especialidades.includes(doc.especialidad);

// ------------------------------------------------------------------- cargues
const cargues = [];
let consecutivo = 0;
const nuevoArchivo = () => `ARC-${String(++consecutivo).padStart(5, '0')}`;
const slug = (t) => t.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
  .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

function cargue(sede, doc, campos) {
  const fc = Math.min(-1, campos.fc ?? -entre(1, 30));
  cargues.push({
    id_ips: sede.id,
    id_documento: doc ? doc.id : null,
    id_archivo: campos.sinArchivo ? null : nuevoArchivo(),
    enlace: campos.sinArchivo ? null : 'demo/soporte-ejemplo.pdf',
    nombre_archivo: campos.sinArchivo ? null : (campos.nombreArchivo ?? `${slug(doc.nombre)}.pdf`),
    fecha_cargue: instante(fc, entre(7, 17)),
    fecha_documento: dia(campos.fd ?? null),
    fecha_vencimiento: dia(campos.fv ?? null),
    observaciones: campos.obs ?? '',
    indicador: campos.indicador ?? '',
    estado_auditoria: campos.estado,
    fecha_auditoria: ['Aprobado', 'Rechazado'].includes(campos.estado) ? instante(Math.min(-1, fc + 2), 10) : null,
    identificador_equipo: campos.serial ?? '',
    medico: campos.medico ?? null
  });
}

function medicoFicticio() {
  return {
    nombre: `${elegir(NOMBRES)} ${elegir(APELLIDOS)} ${elegir(APELLIDOS)}`,
    documento: String(entre(10_000_000, 1_099_999_999)),
    rmtp: `RM-${entre(10000, 99999)}`,
    resolucion: `${entre(1000, 9999)}-${entre(2015, 2025)}`,
    fechaResolucion: -entre(400, 3000)
  };
}

// Vencimiento de una unidad aprobada según la calidad de la sede.
function vencimiento(calidad) {
  const x = rnd();
  if (x < calidad) return entre(91, 540);                        // vigente
  if (x < calidad + (1 - calidad) / 2) return entre(0, 90);       // próximo a vencer
  return -entre(1, 240);                                          // vencido
}

for (const sede of ips) {
  for (const doc of DOCUMENTOS) {
    if (!aplica(doc, sede) || doc.categoria === 'No auditable') continue;

    // Vinculación: lo carga la dirección de red; casi siempre completo.
    if (doc.categoria === 'Vinculación') {
      if (rnd() < 0.85) {
        const fd = -entre(30, 700);
        cargue(sede, doc, { estado: 'Aprobado', fd, fc: fd + entre(1, 10), fv: fd + 730 });
      }
      continue;
    }

    // Sin soporte: el requisito queda pendiente.
    if (rnd() > sede.calidad + 0.2) {
      if (rnd() < 0.35) cargue(sede, doc, { estado: 'Pendiente', fc: -entre(1, 20) });
      continue;
    }

    // La sede declaró que el requisito ya no le aplica.
    if ((doc.especialidad || esEquipo(doc)) && rnd() < 0.04) {
      cargue(sede, doc, {
        estado: 'Inactivo', indicador: 'Inactivo', sinArchivo: true,
        obs: elegir(MOTIVOS_INACTIVO), fc: -entre(5, 90)
      });
      continue;
    }

    const unidades = esMultiple(doc) ? entre(1, esEquipo(doc) ? 4 : 3) : 1;
    for (let u = 1; u <= unidades; u++) {
      const serial = esEquipo(doc) ? `${PREFIJO_SERIAL[doc.id]}-${entre(2019, 2025)}-${String(entre(1, 999)).padStart(3, '0')}` : '';
      const medico = doc.id === 'DOC_007' ? medicoFicticio() : null;
      if (rnd() < 0.12) {
        // Recién cargado, esperando al auditor: aún sin fecha de vencimiento.
        cargue(sede, doc, { estado: 'Pendiente', fc: -entre(1, 25), serial });
        continue;
      }
      const fv = vencimiento(sede.calidad);
      const fd = fv - 365;
      cargue(sede, doc, { estado: 'Aprobado', fv, fd, fc: fd + entre(1, 20), serial, medico });
    }

    // Soporte anterior, ya reemplazado.
    if (!esMultiple(doc) && rnd() < 0.25) {
      const fv = -entre(200, 500);
      cargue(sede, doc, { estado: 'Historico', fv, fd: fv - 365, fc: fv - 350 });
    }

    // Rechazo heredado, anterior a la purga automática de rechazados.
    if (rnd() < 0.03) {
      cargue(sede, doc, { estado: 'Rechazado', obs: elegir(MOTIVOS_RECHAZO), fc: -entre(1, 15) });
    }
  }
}

// Cargues sin clasificar: la sede dejó el archivo sin decir a qué requisito
// corresponde. El auditor los clasifica desde la bandeja.
for (let n = 1; n <= 6; n++) {
  cargue(elegir(ips), null, {
    estado: 'Pendiente', fc: -entre(1, 10),
    nombreArchivo: `escaneo_${String(n).padStart(3, '0')}.pdf`,
    obs: 'Cargado directamente en la carpeta de la sede.'
  });
}

// ------------------------------------------------------------------ salida
const sql = [];
sql.push(`-- =============================================================================
-- RedDoc 360 · Datos de demostración
-- GENERADO por scripts/generar-seed.mjs — no editar a mano.
-- Todos los nombres, correos, documentos de identidad y seriales son ficticios.
-- Resumen: ${ips.length} IPS · ${DOCUMENTOS.length} requisitos · ${matriz.length} filas de matriz · ${cargues.length} cargues
-- =============================================================================

truncate public.notificaciones, public.modificaciones, public.auditoria_estados,
         public.cargues, public.matriz, public.documentos, public.ips, public.regionales
  restart identity cascade;
`);

sql.push('insert into public.regionales (nombre, correo_buzon) values\n' +
  REGIONALES.map((r) => `  (${q(r.nombre)}, ${q(r.buzon)})`).join(',\n') + ';\n');

sql.push('insert into public.ips (id_ips, nombre, ciudad, regional, correo, correo_lider) values\n' +
  ips.map((s) => `  (${[s.id, s.nombre, s.ciudad, s.regional, s.correo, s.correoLider].map(q).join(', ')})`).join(',\n') + ';\n');

sql.push('insert into public.documentos (id_documento, nombre, categoria, especialidad, consulta, formato) values\n' +
  DOCUMENTOS.map((d) => `  (${[d.id, d.nombre, d.categoria, d.especialidad, d.consulta, d.formato].map(q).join(', ')})`).join(',\n') + ';\n');

for (const bloque of bloquesDe(matriz)) {
  sql.push('insert into public.matriz (id_documento, id_ips) values\n' +
    bloque.map(([d, i]) => `  (${q(d)}, ${q(i)})`).join(',\n') + ';\n');
}

const columnas = 'id_ips, id_documento, id_archivo, enlace, nombre_archivo, fecha_cargue, fecha_documento, ' +
  'fecha_vencimiento, observaciones, indicador, estado_auditoria, fecha_auditoria, identificador_equipo, ' +
  'medico_nombre, medico_documento, medico_rm_tp, medico_numero_resolucion, medico_fecha_resolucion';
for (const bloque of bloquesDe(cargues)) {
  sql.push(`insert into public.cargues (${columnas}) values\n` + bloque.map((c) => '  (' + [
    q(c.id_ips), q(c.id_documento), q(c.id_archivo), q(c.enlace), q(c.nombre_archivo),
    c.fecha_cargue, c.fecha_documento, c.fecha_vencimiento, q(c.observaciones), q(c.indicador),
    q(c.estado_auditoria), c.fecha_auditoria ?? 'null', q(c.identificador_equipo),
    q(c.medico?.nombre), q(c.medico?.documento), q(c.medico?.rmtp), q(c.medico?.resolucion),
    c.medico ? dia(c.medico.fechaResolucion) : 'null'
  ].join(', ') + ')').join(',\n') + ';\n');
}

sql.push(`-- Traza de auditoría de los soportes ya revisados.
insert into public.auditoria_estados
  (id_cargue, id_ips, id_documento, estado_anterior, estado_nuevo, fecha_cambio,
   usuario_auditor, observaciones, fecha_vencimiento_nueva, accion)
select c.id, c.id_ips, c.id_documento, 'Pendiente', c.estado_auditoria, c.fecha_auditoria,
       'auditor.' || lower(i.regional) || '@reddoc.demo', c.observaciones, c.fecha_vencimiento,
       case c.estado_auditoria when 'Aprobado' then 'APROBACION' else 'RECHAZO' end
from public.cargues c
join public.ips i on i.id_ips = c.id_ips
where c.estado_auditoria in ('Aprobado', 'Rechazado') and c.fecha_auditoria is not null;

-- Bitácora del portal: lo que las sedes hicieron en los últimos 30 días.
insert into public.modificaciones
  (fecha, id_ips, modulo, accion, id_documento, documento, id_cargue, usuario, detalle, notificado)
select c.fecha_cargue, c.id_ips, 'Portal IPS',
       case when c.estado_auditoria = 'Inactivo' then 'Requisito marcado inactivo' else 'Cargue de soporte' end,
       c.id_documento, coalesce(d.nombre, c.nombre_archivo), c.id, i.correo,
       case when c.estado_auditoria = 'Inactivo' then c.observaciones
            else 'Guardado desde el portal. Queda en auditoría.' end,
       c.fecha_cargue < now() - interval '1 day'
from public.cargues c
join public.ips i on i.id_ips = c.id_ips
left join public.documentos d on d.id_documento = c.id_documento
where c.fecha_cargue > now() - interval '30 days' and c.estado_auditoria <> 'Historico';

-- Correos (simulados) del resultado de auditoría: uno por sede y día.
insert into public.notificaciones
  (fecha_envio, id_ips, tipo, asunto, destino, con_copia, enviado_por, disparo, detalle)
select min(a.fecha_cambio), a.id_ips, 'Auditoría',
       'Resultado de auditoría documental · ' || count(*) || ' documento(s)',
       i.correo, r.correo_buzon, min(a.usuario_auditor), 'Manual',
       jsonb_build_object('documentos', count(*))
from public.auditoria_estados a
join public.ips i on i.id_ips = a.id_ips
join public.regionales r on r.nombre = i.regional
where a.fecha_cambio > now() - interval '60 days'
group by a.id_ips, i.correo, r.correo_buzon, a.fecha_cambio::date;
`);

writeFileSync(join(raiz, 'supabase', 'seed.sql'), sql.join('\n'), 'utf8');
console.log(`seed.sql generado: ${ips.length} IPS, ${DOCUMENTOS.length} requisitos, ` +
  `${matriz.length} filas de matriz, ${cargues.length} cargues.`);
