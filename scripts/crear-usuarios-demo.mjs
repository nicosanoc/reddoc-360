/**
 * Crea (o actualiza) los usuarios de demostración en un proyecto Supabase.
 *
 * Requiere en .env: VITE_SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY.
 * La service role key salta la RLS: este script corre sólo en local y la
 * clave nunca debe llegar al frontend ni al repositorio.
 *
 * Uso: npm run usuarios:demo   (después de aplicar migraciones y seed)
 */
import { createClient } from '@supabase/supabase-js';

const url = process.env.VITE_SUPABASE_URL;
const claveServicio = process.env.SUPABASE_SERVICE_ROLE_KEY;
const password = process.env.DEMO_PASSWORD || 'RedDoc360-demo';

if (!url || !claveServicio) {
  console.error('Defina VITE_SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY en el archivo .env');
  process.exit(1);
}

const admin = createClient(url, claveServicio, { auth: { persistSession: false, autoRefreshToken: false } });

const INTERNOS = [
  { email: 'universal@reddoc.demo', nombre: 'Usuario Universal', roles: ['USUARIO_UNIVERSAL'], regionales: ['*'] },
  { email: 'admin.principales@reddoc.demo', nombre: 'Dirección Regional Principales', roles: ['ADMINISTRADOR'], regionales: ['Principales'] },
  { email: 'auditor.remotas@reddoc.demo', nombre: 'Auditoría Remotas', roles: ['AUDITOR'], regionales: ['Remotas'] },
  { email: 'auditor.intermedias@reddoc.demo', nombre: 'Auditoría y Dirección Intermedias', roles: ['AUDITOR', 'ADMINISTRADOR'], regionales: ['Intermedias'] }
];

async function asegurarUsuario(email) {
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (!error) return data.user.id;

  // Ya existía: se busca y se le restablece la contraseña de demo.
  const { data: lista, error: errorLista } = await admin.auth.admin.listUsers({ perPage: 1000 });
  if (errorLista) throw errorLista;
  const existente = lista.users.find((u) => u.email === email);
  if (!existente) throw error;
  await admin.auth.admin.updateUserById(existente.id, { password });
  return existente.id;
}

const { data: sedes, error: errorSedes } = await admin
  .from('ips').select('id_ips, nombre, regional').order('regional').order('id_ips');
if (errorSedes) throw errorSedes;
if (!sedes.length) {
  console.error('No hay IPS cargadas. Aplique primero las migraciones y supabase/seed.sql.');
  process.exit(1);
}

// Un proveedor por regional: la primera sede de cada una.
const proveedores = [...new Map(sedes.map((s) => [s.regional, s])).values()].map((s) => ({
  email: `sede.${s.id_ips.toLowerCase()}@ips.reddoc.demo`,
  nombre: s.nombre,
  roles: ['PROVEEDOR'],
  regionales: [],
  id_ips: s.id_ips
}));

const filas = [];
for (const u of [...INTERNOS, ...proveedores]) {
  const userId = await asegurarUsuario(u.email);
  const { error } = await admin.from('perfiles').upsert({
    user_id: userId, nombre: u.nombre, email: u.email,
    roles: u.roles, regionales: u.regionales, id_ips: u.id_ips ?? null, activo: true
  });
  if (error) throw error;
  filas.push({ email: u.email, roles: u.roles.join(', '), alcance: u.id_ips ?? u.regionales.join(', ') });
}

console.table(filas);
console.log(`Contraseña de todos los usuarios de demostración: ${password}`);
