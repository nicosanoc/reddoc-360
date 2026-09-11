import type { PGlite, Transaction } from '@electric-sql/pglite';
import { beforeAll, describe, expect, it } from 'vitest';
import { USUARIOS, como, crearBase, valor } from './base';

let db: PGlite;

beforeAll(async () => {
  db = await crearBase();
});

// Sede de pruebas en la regional del auditor de Remotas, sin cargues previos.
const SEDE = 'TST-ABCDEF';
const crearSede = (tx: Transaction) => tx.exec(`
  insert into public.ips (id_ips, nombre, ciudad, regional, correo)
  values ('${SEDE}', 'Sede de pruebas', 'Leticia', 'Remotas', 'pruebas@ips.reddoc.demo');
`);

/** Inserta un cargue de la sede de pruebas. `fv` en días desde hoy. */
const cargue = (doc: string, estado: string, opciones: { fv?: number; fc?: number; indicador?: string; enlace?: string | null } = {}) => `
  insert into public.cargues (id_ips, id_documento, estado_auditoria, fecha_vencimiento, fecha_cargue, indicador, enlace)
  values ('${SEDE}', '${doc}', '${estado}',
          ${opciones.fv === undefined ? 'null' : `private.hoy() + ${opciones.fv}`},
          now() - interval '${opciones.fc ?? 1} days',
          '${opciones.indicador ?? ''}',
          ${opciones.enlace === null ? 'null' : `'${opciones.enlace ?? 'demo/soporte-ejemplo.pdf'}'`});`;

const soporte = (tx: Transaction, doc: string) =>
  tx.query<Record<string, unknown>>(
    `select s.*, c.fecha_vencimiento - private.hoy() as fv
       from public.v_soportes s join public.cargues c on c.id = s.id_cargue
      where s.id_ips = '${SEDE}' and s.id_documento = '${doc}'`).then((r) => r.rows[0]);

describe('v_soportes · el soporte que representa a un requisito', () => {
  it('requisito de UN soporte: gana el vencimiento más lejano, no el último cargado', async () => {
    const s = await como(db, USUARIOS.universal, (tx) => soporte(tx, 'DOC_001'), async (tx) => {
      await crearSede(tx);
      await tx.exec(cargue('DOC_001', 'Aprobado', { fv: 200, fc: 30 }) + cargue('DOC_001', 'Aprobado', { fv: 50, fc: 1 }));
    });
    expect(s.fv).toBe(200);
    expect(s.estado).toBe('vigente');
  });

  it('requisito de VARIAS unidades: representa la peor, con el conteo por estado', async () => {
    const s = await como(db, USUARIOS.universal, (tx) => soporte(tx, 'DOC_030'), async (tx) => {
      await crearSede(tx);
      await tx.exec(cargue('DOC_030', 'Aprobado', { fv: 300 }) + cargue('DOC_030', 'Aprobado', { fv: -10 })
        + cargue('DOC_030', 'Aprobado', { fv: 40 }) + cargue('DOC_030', 'Pendiente'));
    });
    expect(s).toMatchObject({
      estado: 'vencido', fv: -10, multiple: true,
      unidades_total: 4, unidades_vencidas: 1, unidades_por_vencer: 1, unidades_vigentes: 1, unidades_en_auditoria: 1
    });
  });

  it('un soporte en auditoría no tapa a uno vencido', async () => {
    const s = await como(db, USUARIOS.universal, (tx) => soporte(tx, 'DOC_002'), async (tx) => {
      await crearSede(tx);
      await tx.exec(cargue('DOC_002', 'Aprobado', { fv: -5, fc: 40 }) + cargue('DOC_002', 'Pendiente', { fc: 1 }));
    });
    expect(s.estado).toBe('vencido');
  });

  it('si lo último fue marcar el requisito inactivo, manda la marca', async () => {
    const s = await como(db, USUARIOS.universal, (tx) => soporte(tx, 'DOC_031'), async (tx) => {
      await crearSede(tx);
      await tx.exec(cargue('DOC_031', 'Aprobado', { fv: -100, fc: 60 })
        + cargue('DOC_031', 'Inactivo', { fc: 2, indicador: 'Inactivo', enlace: null }));
    });
    expect(s.estado).toBe('inactivo');
  });

  it('un rechazado sólo representa si no queda nada más, y no acredita', async () => {
    const s = await como(db, USUARIOS.universal, (tx) => soporte(tx, 'DOC_003'), async (tx) => {
      await crearSede(tx);
      await tx.exec(cargue('DOC_003', 'Rechazado', { fc: 1 }));
    });
    expect(s).toMatchObject({ estado: 'pendiente', estado_auditoria: 'Rechazado' });
  });
});

describe('v_cumplimiento_ips', () => {
  it('un requisito inactivo sale del numerador Y del denominador', async () => {
    const r = await como(db, USUARIOS.universal, (tx) =>
      tx.query<{ aplican: number; inactivo: number; vigente: number }>(
        `select aplican, inactivo, vigente from public.v_cumplimiento_ips where id_ips = '${SEDE}'`).then((x) => x.rows[0]),
      async (tx) => {
        await crearSede(tx);
        await tx.exec(cargue('DOC_031', 'Inactivo', { indicador: 'Inactivo', enlace: null }) + cargue('DOC_001', 'Aprobado', { fv: 300 }));
      });
    const requisitos = await como(db, USUARIOS.universal, (tx) =>
      valor<number>(tx, `select count(*)::int from public.v_requisitos_ips where id_ips = '${SEDE}'`), crearSede);
    expect(r.inactivo).toBe(1);
    expect(r.aplican).toBe(requisitos - 1);
    expect(r.vigente).toBe(1);
  });

  it('los requisitos de especialidad sólo se exigen a las sedes de la matriz', async () => {
    // La sede de pruebas no está en la matriz: no se le exige ningún requisito de especialidad.
    const deEspecialidad = await como(db, USUARIOS.universal, (tx) =>
      valor<number>(tx, `select count(*)::int from public.v_requisitos_ips where id_ips = '${SEDE}' and especialidad <> ''`), crearSede);
    expect(deEspecialidad).toBe(0);
  });
});

describe('auditar_lote', () => {
  const auditar = (tx: Transaction, decisiones: object[]) =>
    valor<Record<string, any>>(tx, 'select public.auditar_lote($1::jsonb)', [JSON.stringify(decisiones)]);
  const idDe = (tx: Transaction, doc: string) =>
    valor<number>(tx, `select id::int from public.cargues where id_ips = '${SEDE}' and id_documento = '${doc}' order by id desc limit 1`);

  it('aprobar sin fecha asigna la vigencia por defecto (12 meses) y deja traza', async () => {
    const r = await como(db, USUARIOS.auditorRemotas, async (tx) => {
      const id = await idDe(tx, 'DOC_004');
      const res = await auditar(tx, [{ idCargue: id, nuevoEstado: 'Aprobado' }]);
      const fila = await tx.query<{ estado_auditoria: string; meses: number }>(
        `select estado_auditoria, (extract(year from age(fecha_vencimiento, private.hoy())) * 12
                                   + extract(month from age(fecha_vencimiento, private.hoy())))::int as meses
           from public.cargues where id = $1`, [id]);
      const trazas = await valor<number>(tx, 'select count(*)::int from public.auditoria_estados where id_cargue = $1', [id]);
      return { res, fila: fila.rows[0], trazas };
    }, async (tx) => { await crearSede(tx); await tx.exec(cargue('DOC_004', 'Pendiente')); });

    expect(r.res.aplicados).toBe(1);
    expect(r.fila).toEqual({ estado_auditoria: 'Aprobado', meses: 12 });
    expect(r.trazas).toBe(1);
  });

  it('rechazar exige motivo', async () => {
    const r = await como(db, USUARIOS.auditorRemotas, async (tx) =>
      auditar(tx, [{ idCargue: await idDe(tx, 'DOC_004'), nuevoEstado: 'Rechazado' }]),
    async (tx) => { await crearSede(tx); await tx.exec(cargue('DOC_004', 'Pendiente')); });
    expect(r.aplicados).toBe(0);
    expect(r.fallidos[0].motivo).toMatch(/motivo del rechazo/);
  });

  it('un rechazo purga el cargue, conserva la traza y notifica una vez por sede', async () => {
    const r = await como(db, USUARIOS.auditorRemotas, async (tx) => {
      const a = await idDe(tx, 'DOC_004');
      const b = await idDe(tx, 'DOC_005');
      const res = await auditar(tx, [
        { idCargue: a, nuevoEstado: 'Rechazado', observaciones: 'Ilegible' },
        { idCargue: b, nuevoEstado: 'Aprobado', fechaVencimiento: '2030-01-01' }
      ]);
      return {
        res,
        existe: await valor<number>(tx, 'select count(*)::int from public.cargues where id = $1', [a]),
        traza: await valor<string>(tx, `select accion from public.auditoria_estados
                                         where id_ips = '${SEDE}' and id_documento = 'DOC_004' and id_cargue is null`),
        correos: await valor<number>(tx, `select count(*)::int from public.notificaciones where id_ips = '${SEDE}'`)
      };
    }, async (tx) => {
      await crearSede(tx);
      await tx.exec(cargue('DOC_004', 'Pendiente', { enlace: 'TST-ABCDEF/DOC_004/a.pdf' }) + cargue('DOC_005', 'Pendiente'));
    });

    expect(r.res).toMatchObject({ aplicados: 2, purgados: 1, correos: 1, archivosAEliminar: ['TST-ABCDEF/DOC_004/a.pdf'] });
    expect(r.existe).toBe(0);
    expect(r.traza).toBe('RECHAZO');
    expect(r.correos).toBe(1);
  });

  it('no permite auditar fuera del alcance regional', async () => {
    const r = await como(db, USUARIOS.auditorRemotas, async (tx) => {
      // Visto como superusuario sería cualquier cargue; el auditor no puede verlo,
      // así que el id se toma de la tabla sin RLS antes de cambiar de rol.
      const id = await valor<number>(tx, `select current_setting('prueba.id_ajeno')::int`);
      return auditar(tx, [{ idCargue: id, nuevoEstado: 'Aprobado' }]);
    }, async (tx) => {
      const id = await valor<number>(tx, `select c.id::int from public.cargues c join public.ips i using (id_ips)
                                           where i.regional = 'Principales' and c.estado_auditoria = 'Pendiente'
                                             and c.id_documento is not null limit 1`);
      await tx.query(`select set_config('prueba.id_ajeno', $1, true)`, [String(id)]);
    });
    expect(r.aplicados).toBe(0);
    expect(r.fallidos[0].motivo).toMatch(/fuera de su alcance regional/);
  });

  it('la Licencia Médicos Especialistas exige los datos del médico para aprobar', async () => {
    const r = await como(db, USUARIOS.auditorRemotas, async (tx) => {
      const id = await idDe(tx, 'DOC_007');
      const sinDatos = await auditar(tx, [{ idCargue: id, nuevoEstado: 'Aprobado' }]);
      const conDatos = await auditar(tx, [{
        idCargue: id, nuevoEstado: 'Aprobado', fechaVencimiento: '2030-01-01',
        medico: { nombreHallado: 'Laura Pardo', documentoHallado: '1020304050', rmtp: 'RM-12345',
                  numeroResolucion: '4455-2024', fechaResolucion: '2024-03-01' }
      }]);
      return { sinDatos, conDatos };
    }, async (tx) => { await crearSede(tx); await tx.exec(cargue('DOC_007', 'Pendiente')); });

    expect(r.sinDatos.fallidos[0].motivo).toMatch(/Falta: Nombre del médico/);
    expect(r.conDatos.aplicados).toBe(1);
  });

  it('un cargue sin clasificar no se aprueba hasta asignarle requisito', async () => {
    const r = await como(db, USUARIOS.auditorRemotas, async (tx) => {
      const id = await valor<number>(tx, `select id::int from public.cargues where id_ips = '${SEDE}'`);
      const sinRequisito = await auditar(tx, [{ idCargue: id, nuevoEstado: 'Aprobado' }]);
      const clasificado = await auditar(tx, [{ idCargue: id, nuevoEstado: 'Aprobado', idDocumento: 'DOC_010' }]);
      return { sinRequisito, clasificado };
    }, async (tx) => {
      await crearSede(tx);
      await tx.exec(`insert into public.cargues (id_ips, estado_auditoria, enlace) values ('${SEDE}', 'Pendiente', 'demo/x.pdf');`);
    });
    expect(r.sinRequisito.fallidos[0].motivo).toMatch(/no tiene requisito asociado/);
    expect(r.clasificado.aplicados).toBe(1);
  });

  it('la IPS aliada no puede auditar', async () => {
    await expect(como(db, USUARIOS.proveedor, (tx) => auditar(tx, [{ idCargue: 1, nuevoEstado: 'Aprobado' }])))
      .rejects.toThrow(/no tiene permiso/);
  });
});
