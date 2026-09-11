import type { PGlite } from '@electric-sql/pglite';
import { beforeAll, describe, expect, it } from 'vitest';
import { USUARIOS, como, crearBase, valor } from './base';

let db: PGlite;
const total = async (sql: string) => Number((await db.query<{ n: number }>(sql)).rows[0].n);

beforeAll(async () => {
  db = await crearBase();
});

describe('alcance regional (RLS)', () => {
  it('USUARIO_UNIVERSAL ve todas las IPS', async () => {
    const esperado = await total('select count(*)::int n from public.ips');
    const visto = await como(db, USUARIOS.universal, (tx) => valor<number>(tx, 'select count(*)::int from public.ips'));
    expect(visto).toBe(esperado);
  });

  it('un auditor sólo ve las IPS de su regional (sin importar mayúsculas)', async () => {
    const esperado = await total(`select count(*)::int n from public.ips where regional = 'Remotas'`);
    const regionales = await como(db, USUARIOS.auditorRemotas, async (tx) =>
      (await tx.query<{ regional: string }>('select distinct regional from public.ips')).rows.map((r) => r.regional));
    const visto = await como(db, USUARIOS.auditorRemotas, (tx) => valor<number>(tx, 'select count(*)::int from public.ips'));
    expect(regionales).toEqual(['Remotas']);
    expect(visto).toBe(esperado);
  });

  it('un interno sin regionales asignadas no ve ninguna IPS', async () => {
    const visto = await como(db, USUARIOS.auditorSinRegiones, (tx) => valor<number>(tx, 'select count(*)::int from public.ips'));
    expect(visto).toBe(0);
  });

  it('el PROVEEDOR ve únicamente su propia IPS y sus cargues', async () => {
    const r = await como(db, USUARIOS.proveedor, async (tx) => ({
      ips: await valor<number>(tx, 'select count(*)::int from public.ips'),
      ajenos: await valor<number>(tx, `select count(*)::int from public.cargues
                                        where id_ips <> (select id_ips from public.perfiles limit 1)`)
    }));
    expect(r).toEqual({ ips: 1, ajenos: 0 });
  });

  it('el anónimo no ve IPS ni cargues, pero sí el catálogo de requisitos', async () => {
    const r = await como(db, null, async (tx) => ({
      documentos: await valor<number>(tx, 'select count(*)::int from public.documentos')
    }));
    expect(r.documentos).toBeGreaterThan(0);
    await expect(como(db, null, (tx) => tx.query('select count(*) from public.ips'))).rejects.toThrow(/permission denied/);
  });
});

describe('expediente de vinculación', () => {
  const vinculacion = `select count(*)::int from public.cargues c join public.documentos d using (id_documento)
                       where d.categoria = 'Vinculación'`;

  it('el administrador lo ve dentro de su regional', async () => {
    expect(await como(db, USUARIOS.adminPrincipales, (tx) => valor<number>(tx, vinculacion))).toBeGreaterThan(0);
  });

  it('el auditor y la propia IPS no lo ven', async () => {
    expect(await como(db, USUARIOS.auditorRemotas, (tx) => valor<number>(tx, vinculacion))).toBe(0);
    expect(await como(db, USUARIOS.proveedor, (tx) => valor<number>(tx, vinculacion))).toBe(0);
  });
});

describe('escritura sólo por RPC', () => {
  it('nadie actualiza ni borra cargues directamente', async () => {
    await expect(como(db, USUARIOS.universal, (tx) =>
      tx.query(`update public.cargues set estado_auditoria = 'Aprobado'`))).rejects.toThrow(/permission denied/);
    await expect(como(db, USUARIOS.proveedor, (tx) =>
      tx.query('delete from public.cargues'))).rejects.toThrow(/permission denied/);
  });
});

describe('dashboard_macro', () => {
  it('calcula los KPI sólo sobre la regional del administrador', async () => {
    const esperado = await total(`select count(*)::int n from public.ips where regional = 'Principales'`);
    const tablero = await como(db, USUARIOS.adminPrincipales, (tx) =>
      valor<Record<string, unknown>>(tx, 'select public.dashboard_macro()'));
    expect(tablero.totalIps).toBe(esperado);
    expect(tablero.regionales).toHaveLength(1);
    expect(tablero.cumplimientoGlobal).toBeGreaterThan(0);
  });

  it('un rol combinado "Auditor, Administrador" hereda el permiso del administrador', async () => {
    const tablero = await como(db, USUARIOS.auditorAdminInter, (tx) =>
      valor<Record<string, unknown>>(tx, 'select public.dashboard_macro()'));
    expect(tablero.totalIps).toBeGreaterThan(0);
  });

  it('el auditor no tiene acceso', async () => {
    await expect(como(db, USUARIOS.auditorRemotas, (tx) => tx.query('select public.dashboard_macro()')))
      .rejects.toThrow(/no tiene permiso/);
  });
});

describe('mi_sesion', () => {
  it('hidrata rol principal, alcance y permiso de cargue', async () => {
    const s = await como(db, USUARIOS.auditorAdminInter, (tx) => valor<Record<string, unknown>>(tx, 'select public.mi_sesion()'));
    expect(s).toMatchObject({ autenticado: true, rol: 'ADMINISTRADOR', alcanceTotal: false, puedeCargar: false, sinAlcance: false });
  });

  it('marca al interno sin regionales', async () => {
    const s = await como(db, USUARIOS.auditorSinRegiones, (tx) => valor<Record<string, unknown>>(tx, 'select public.mi_sesion()'));
    expect(s).toMatchObject({ sinAlcance: true });
  });
});
