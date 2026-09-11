import { PGlite, type Transaction } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Postgres embebido (PGlite, WebAssembly) con las migraciones y el seed reales.
 * Permite probar la RLS y las funciones RPC sin Docker ni un proyecto Supabase.
 *
 * Lo único simulado es lo que Supabase aporta por fuera de las migraciones:
 * los roles `anon`/`authenticated` y `auth.uid()`, que en Supabase también
 * lee el `sub` del JWT desde una variable de la sesión.
 */

const raiz = join(import.meta.dirname, '..', '..');

const ENTORNO_SUPABASE = `
  create role anon nologin;
  create role authenticated nologin;
  create schema auth;
  create table auth.users (id uuid primary key, email text);
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  grant usage on schema auth to anon, authenticated;
  grant execute on function auth.uid() to anon, authenticated;
`;

export const USUARIOS = {
  universal:          '00000000-0000-4000-8000-000000000001',
  adminPrincipales:   '00000000-0000-4000-8000-000000000002',
  auditorRemotas:     '00000000-0000-4000-8000-000000000003',
  auditorSinRegiones: '00000000-0000-4000-8000-000000000004',
  proveedor:          '00000000-0000-4000-8000-000000000005',
  auditorAdminInter:  '00000000-0000-4000-8000-000000000006'
} as const;

const PERFILES = `
  insert into auth.users (id, email) values
    ('${USUARIOS.universal}', 'universal@reddoc.demo'),
    ('${USUARIOS.adminPrincipales}', 'admin.principales@reddoc.demo'),
    ('${USUARIOS.auditorRemotas}', 'auditor.remotas@reddoc.demo'),
    ('${USUARIOS.auditorSinRegiones}', 'auditor.nuevo@reddoc.demo'),
    ('${USUARIOS.proveedor}', 'proveedor@reddoc.demo'),
    ('${USUARIOS.auditorAdminInter}', 'mixto.intermedias@reddoc.demo');

  insert into public.perfiles (user_id, nombre, email, roles, regionales, id_ips) values
    ('${USUARIOS.universal}', 'Universal', 'universal@reddoc.demo', '{USUARIO_UNIVERSAL}', '{}', null),
    ('${USUARIOS.adminPrincipales}', 'Admin Principales', 'admin.principales@reddoc.demo', '{ADMINISTRADOR}', '{Principales}', null),
    ('${USUARIOS.auditorRemotas}', 'Auditor Remotas', 'auditor.remotas@reddoc.demo', '{AUDITOR}', '{remotas}', null),
    ('${USUARIOS.auditorSinRegiones}', 'Auditor sin regionales', 'auditor.nuevo@reddoc.demo', '{AUDITOR}', '{}', null),
    ('${USUARIOS.proveedor}', 'Sede Remotas', 'proveedor@reddoc.demo', '{PROVEEDOR}', '{}',
       (select id_ips from public.ips where regional = 'Remotas' order by id_ips limit 1)),
    ('${USUARIOS.auditorAdminInter}', 'Mixto Intermedias', 'mixto.intermedias@reddoc.demo', '{AUDITOR,ADMINISTRADOR}', '{Intermedias}', null);
`;

export async function crearBase(): Promise<PGlite> {
  const db = new PGlite();
  await db.exec(ENTORNO_SUPABASE);
  const migraciones = join(raiz, 'supabase', 'migrations');
  for (const archivo of readdirSync(migraciones).filter((f) => f.endsWith('.sql')).sort()) {
    await db.exec(readFileSync(join(migraciones, archivo), 'utf8'));
  }
  await db.exec(readFileSync(join(raiz, 'supabase', 'seed.sql'), 'utf8'));
  await db.exec(PERFILES);
  return db;
}

/**
 * Ejecuta `fn` con la identidad de un usuario (o como anónimo) dentro de una
 * transacción que SIEMPRE se revierte: cada prueba parte del seed intacto.
 */
export async function como<T>(
  db: PGlite,
  usuario: string | null,
  fn: (tx: Transaction) => Promise<T>,
  preparar?: (tx: Transaction) => Promise<unknown>
): Promise<T> {
  let resultado!: T;
  await db.transaction(async (tx) => {
    // Lo que se prepara como superusuario (datos de un caso) va antes del cambio de rol.
    if (preparar) await preparar(tx);
    await tx.exec(`set local role ${usuario ? 'authenticated' : 'anon'}`);
    await tx.query(`select set_config('request.jwt.claim.sub', $1, true)`, [usuario ?? '']);
    resultado = await fn(tx);
    await tx.rollback();
  });
  return resultado;
}

/** Primer valor de la primera fila. */
export async function valor<T = unknown>(tx: Transaction, sql: string, params: unknown[] = []): Promise<T> {
  const r = await tx.query<Record<string, T>>(sql, params);
  const fila = r.rows[0];
  return (fila ? Object.values(fila)[0] : undefined) as T;
}
