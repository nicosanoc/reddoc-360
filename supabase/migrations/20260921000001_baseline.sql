-- =============================================================================
-- PPCOL Documentación · 0001 · Baseline del esquema
--
-- Reconstrucción fiel del estado actual del proyecto Supabase
-- `ppcol-documentacion` (extraído del catálogo el 2026-09-21). Hasta ahora la
-- base se construyó a mano en el SQL Editor por fases y NO estaba versionada:
-- este archivo la vuelve reproducible. De aquí en adelante, todo cambio nace
-- como un archivo nuevo en esta carpeta y se aplica como migración.
--
-- Nota: la base viva tiene índices duplicados en `soportes` (creados al correr
-- una fase varias veces). Aquí se declara UNO de cada uno; la limpieza de los
-- sobrantes va en 0002.
-- =============================================================================

-- ------------------------------------------------------------------- ENUMS
create type public.rol_usuario         as enum ('PROVEEDOR', 'AUDITOR', 'ADMINISTRADOR', 'USUARIO_UNIVERSAL');
create type public.estado_auditoria    as enum ('Pendiente', 'Aprobado', 'Rechazado', 'Historico', 'Duplicado', 'Inactivo');
create type public.estado_vigencia     as enum ('Documento vigente', 'Próximo a Vencer', 'Vencido', 'Pendiente', 'Inactivo');
create type public.categoria_documento as enum ('Administrativa y normativa', 'Mantenimiento', 'Calibración', 'Vinculación', 'No auditable');
create type public.clasificacion       as enum ('Externa', 'Interno');
create type public.tipo_notificacion   as enum ('Resumen diario', 'Vencimiento', 'Rechazo', 'Bienvenida', 'Manual');
create type public.accion_modificacion as enum ('Cargue de soporte', 'Actualización de soporte', 'Eliminación de soporte', 'Requisito marcado inactivo', 'Requisito reactivado');

-- ------------------------------------------------------------------- TABLAS

-- Regionales de la red (Principales, Intermedias, Remotas…).
create table public.regionales (
  id     smallint generated always as identity primary key,
  nombre text not null unique,
  activa boolean not null default true
);

-- Sedes aliadas. `codigo` es el identificador con que la IPS entra al portal.
create table public.ips (
  id              uuid primary key default gen_random_uuid(),
  codigo          text not null unique,
  nombre          text not null,
  ciudad          text,
  regional_id     smallint not null references public.regionales (id),
  correo_ips      text,
  correo_lider    text,
  carpeta_publica text,
  carpeta_privada text,
  activa          boolean not null default true,
  creado_en       timestamptz not null default now()
);
create index ips_regional_id_idx on public.ips (regional_id);

-- Catálogo de requisitos documentales.
create table public.documentos (
  id            uuid primary key default gen_random_uuid(),
  codigo        text not null unique,
  nombre        text not null,
  categoria     public.categoria_documento not null,
  especialidad  text,
  clasificacion public.clasificacion not null default 'Interno',
  -- Requisito que admite varias unidades vigentes a la vez (equipos, licencias por profesional).
  multiple      boolean not null default false,
  activo        boolean not null default true
);
create index documentos_categoria_idx on public.documentos (categoria);

-- Usuarios internos y proveedores. PK = auth.users.id (Supabase Auth custodia la contraseña).
create table public.perfiles (
  id              uuid primary key references auth.users (id) on delete cascade,
  nombre_completo text not null default '',
  email           text,
  roles           public.rol_usuario[] not null default '{}',
  ips_id          uuid references public.ips (id),
  activo          boolean not null default true,
  creado_en       timestamptz not null default now(),
  constraint proveedor_requiere_ips
    check ((not ('PROVEEDOR' = any (roles))) or ips_id is not null)
);
create index perfiles_ips_id_idx on public.perfiles (ips_id);

-- Alcance regional de cada perfil interno (un perfil, varias regionales).
create table public.perfil_regionales (
  perfil_id   uuid not null references public.perfiles (id) on delete cascade,
  regional_id smallint not null references public.regionales (id) on delete cascade,
  primary key (perfil_id, regional_id)
);

-- Cada soporte cargado y su estado de auditoría. `drive_file_id` es la fase
-- intermedia (enlace a Google Drive); storage_bucket/path quedan listos para migrar a Storage.
create table public.soportes (
  id                   uuid primary key default gen_random_uuid(),
  ips_id               uuid not null references public.ips (id) on delete restrict,
  documento_id         uuid not null references public.documentos (id) on delete restrict,
  drive_file_id        text unique,
  enlace               text,
  storage_bucket       text,
  storage_path         text,
  fecha_cargue         timestamptz not null default now(),
  cargado_por          uuid references public.perfiles (id) on delete set null,
  fecha_documento      date,
  fecha_vencimiento    date,
  observaciones        text,
  estado               public.estado_auditoria not null default 'Pendiente',
  fecha_auditoria      timestamptz,
  auditado_por         uuid references public.perfiles (id) on delete set null,
  identificador_equipo text,
  nombre_hallado       text,
  documento_hallado    text,
  rm_tp                text,
  numero_resolucion    text,
  fecha_resolucion     date,
  creado_en            timestamptz not null default now(),
  actualizado_en       timestamptz not null default now(),
  constraint auditoria_completa
    check (estado = 'Pendiente' or fecha_auditoria is not null),
  constraint bucket_coherente_con_clasificacion
    check (storage_bucket is null or storage_bucket = any (array['soportes', 'vitrina']))
);
create index soportes_ips_id_documento_id_idx on public.soportes (ips_id, documento_id);
create index soportes_fecha_cargue_idx on public.soportes (fecha_cargue) where (estado = 'Pendiente');
create index soportes_fecha_vencimiento_idx on public.soportes (fecha_vencimiento)
  where (estado <> all (array['Historico'::public.estado_auditoria, 'Duplicado', 'Inactivo']));

-- La sede declara que un requisito ya no le aplica.
create table public.requisitos_inactivos (
  ips_id         uuid not null references public.ips (id) on delete cascade,
  documento_id   uuid not null references public.documentos (id) on delete cascade,
  motivo         text,
  inactivado_en  timestamptz not null default now(),
  inactivado_por uuid references public.perfiles (id) on delete set null,
  primary key (ips_id, documento_id)
);

-- Traza inmutable de cambios de estado (la escribe un trigger).
create table public.auditoria_estados (
  id                      bigint generated always as identity primary key,
  soporte_id              uuid not null references public.soportes (id) on delete cascade,
  estado_anterior         public.estado_auditoria,
  estado_nuevo            public.estado_auditoria not null,
  fecha_cambio            timestamptz not null default now(),
  auditor_id              uuid references public.perfiles (id) on delete set null,
  observaciones           text,
  fecha_vencimiento_nueva date,
  accion_realizada        text
);
create index auditoria_estados_soporte_id_fecha_cambio_idx
  on public.auditoria_estados (soporte_id, fecha_cambio desc);

-- Bitácora del portal que alimenta el resumen diario a la regional.
create table public.modificaciones (
  id           bigint generated always as identity primary key,
  fecha        timestamptz not null default now(),
  ips_id       uuid not null references public.ips (id) on delete restrict,
  documento_id uuid references public.documentos (id) on delete set null,
  soporte_id   uuid references public.soportes (id) on delete set null,
  perfil_id    uuid references public.perfiles (id) on delete set null,
  modulo       text,
  accion       public.accion_modificacion not null,
  detalle      text,
  notificado   boolean not null default false
);
create index modificaciones_fecha_idx on public.modificaciones (fecha) where (not notificado);

-- Registro de correos (simulados en la demo).
create table public.notificaciones (
  id           bigint generated always as identity primary key,
  ips_id       uuid not null references public.ips (id) on delete restrict,
  documento_id uuid references public.documentos (id) on delete set null,
  tipo         public.tipo_notificacion not null,
  asunto       text,
  destino      text[] not null default '{}',
  con_copia    text[] not null default '{}',
  fecha_envio  timestamptz not null default now(),
  enviado_por  uuid references public.perfiles (id) on delete set null,
  enlace_html  text,
  disparo      text,
  confirmacion boolean not null default false
);
create index notificaciones_ips_id_fecha_envio_idx on public.notificaciones (ips_id, fecha_envio desc);

-- Parámetros de negocio editables sin redesplegar.
create table public.parametros (
  clave text primary key,
  valor text not null,
  nota  text
);

-- ---------------------------------------------------------------- FUNCIONES

create or replace function public.param_num(p_clave text, p_default integer)
  returns integer language sql stable set search_path to ''
as $$ select coalesce((select valor::int from public.parametros where clave = p_clave), p_default); $$;

create or replace function public.peso_vigencia(v public.estado_vigencia)
  returns integer language sql immutable set search_path to ''
as $$
  select case v
    when 'Vencido' then 4 when 'Próximo a Vencer' then 3 when 'Pendiente' then 2
    when 'Documento vigente' then 1 else 0 end;
$$;

create or replace function public.vigencia(p_estado public.estado_auditoria, p_vencimiento date)
  returns public.estado_vigencia language sql stable set search_path to ''
as $$
  select case
    when p_estado in ('Historico','Duplicado','Inactivo') then 'Inactivo'
    when p_estado = 'Pendiente'                           then 'Pendiente'
    when p_vencimiento is null                            then 'Documento vigente'
    when p_vencimiento <  current_date                    then 'Vencido'
    when p_vencimiento <= current_date + (public.param_num('DIAS_ALERTA_AMARILLA', 90) || ' days')::interval
                                                          then 'Próximo a Vencer'
    else 'Documento vigente'
  end::public.estado_vigencia;
$$;

-- Helpers de sesión. SECURITY DEFINER para leer perfiles sin recursión de RLS.
-- (0002 los mueve a un esquema privado: hoy quedan expuestos como RPC.)
create or replace function public.tiene_rol(p_rol public.rol_usuario)
  returns boolean language sql stable security definer set search_path to ''
as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and activo and p_rol = any(roles));
$$;

create or replace function public.es_universal()
  returns boolean language sql stable security definer set search_path to ''
as $$ select public.tiene_rol('USUARIO_UNIVERSAL'); $$;

create or replace function public.mi_ips()
  returns uuid language sql stable security definer set search_path to ''
as $$ select ips_id from public.perfiles where id = auth.uid() and activo; $$;

create or replace function public.mis_regionales()
  returns setof smallint language plpgsql stable security definer set search_path to ''
as $$
begin
  if public.es_universal() then
    return query select id from public.regionales;
  else
    return query select regional_id from public.perfil_regionales where perfil_id = auth.uid();
  end if;
end;
$$;

-- Alta de perfil al registrarse un usuario en Auth.
create or replace function public.handle_new_user()
  returns trigger language plpgsql security definer set search_path to ''
as $$
begin
  insert into public.perfiles (id, email, nombre_completo)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'nombre_completo', ''));
  return new;
end;
$$;

-- Traza automática al cambiar el estado de un soporte.
create or replace function public.registrar_cambio_estado()
  returns trigger language plpgsql security definer set search_path to ''
as $$
begin
  if new.estado is distinct from old.estado then
    insert into public.auditoria_estados (soporte_id, estado_anterior, estado_nuevo, auditor_id, fecha_vencimiento_nueva)
    values (new.id, old.estado, new.estado, coalesce(new.auditado_por, auth.uid()), new.fecha_vencimiento);
  end if;
  return new;
end;
$$;

create or replace function public.touch_actualizado_en()
  returns trigger language plpgsql set search_path to ''
as $$ begin new.actualizado_en = now(); return new; end; $$;

-- La vitrina pública sólo admite documentos clasificados como Externa.
create or replace function public.validar_bucket()
  returns trigger language plpgsql set search_path to ''
as $$
begin
  if new.storage_bucket = 'vitrina' then
    if not exists (select 1 from public.documentos where id = new.documento_id and clasificacion = 'Externa') then
      raise exception 'DOC no clasificado como Externa: no puede ir a la vitrina';
    end if;
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------------ TRIGGERS
create trigger soportes_touch          before update on public.soportes for each row execute function public.touch_actualizado_en();
create trigger soportes_validar_bucket before insert or update on public.soportes for each row execute function public.validar_bucket();
create trigger soportes_auditar_estado after update on public.soportes for each row execute function public.registrar_cambio_estado();
-- El trigger de alta de perfil cuelga de auth.users:
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ------------------------------------------------------------------- VISTAS

create view public.v_soportes as
  select s.*,
    i.codigo as ips_codigo, i.nombre as ips_nombre, i.ciudad, i.regional_id, r.nombre as regional,
    d.codigo as documento_codigo, d.nombre as documento_nombre, d.categoria, d.especialidad,
    d.clasificacion, d.multiple,
    public.vigencia(s.estado, s.fecha_vencimiento) as indicador
  from public.soportes s
    join public.ips i on i.id = s.ips_id
    join public.regionales r on r.id = i.regional_id
    join public.documentos d on d.id = s.documento_id;

-- Un soporte vigente por par (IPS, documento): el peor de las unidades múltiples,
-- luego el de vencimiento más lejano y cargue más reciente.
create view public.v_soporte_vigente as
  select distinct on (ips_id, documento_id) v.*,
    count(*) over (partition by ips_id, documento_id) as unidades
  from public.v_soportes v
  where estado <> all (array['Historico'::public.estado_auditoria, 'Duplicado', 'Inactivo'])
  order by ips_id, documento_id,
    case when multiple then public.peso_vigencia(indicador) else null::integer end desc nulls last,
    fecha_vencimiento desc, fecha_cargue desc;

-- Cada requisito exigible a cada IPS con su estado (Pendiente si no hay soporte).
create view public.v_matriz as
  select i.id as ips_id, i.codigo as ips_codigo, i.nombre as ips_nombre, i.ciudad,
    i.regional_id, r.nombre as regional,
    d.id as documento_id, d.codigo as documento_codigo, d.nombre as documento_nombre, d.categoria,
    coalesce(sv.estado, 'Pendiente'::public.estado_auditoria) as estado,
    coalesce(sv.indicador, 'Pendiente'::public.estado_vigencia) as indicador,
    sv.fecha_vencimiento, sv.enlace, sv.observaciones,
    coalesce(sv.unidades, 0::bigint) as unidades,
    (ri.ips_id is not null) as requisito_inactivo
  from public.ips i
    join public.regionales r on r.id = i.regional_id
    cross join public.documentos d
    left join public.v_soporte_vigente sv on sv.ips_id = i.id and sv.documento_id = d.id
    left join public.requisitos_inactivos ri on ri.ips_id = i.id and ri.documento_id = d.id
  where i.activa and d.activo and d.categoria <> 'No auditable';

-- Cumplimiento por IPS: exigido vs. aprobado-y-vigente. Un requisito inactivo no se exige.
create view public.v_cumplimiento as
  select ips_id, ips_codigo, ips_nombre, ciudad, regional_id, regional,
    count(*) filter (where not requisito_inactivo) as exigidos,
    count(*) filter (where not requisito_inactivo and estado = 'Aprobado' and indicador = 'Documento vigente') as cumplidos,
    count(*) filter (where indicador = 'Vencido') as vencidos,
    count(*) filter (where indicador = 'Próximo a Vencer') as por_vencer,
    count(*) filter (where estado = 'Pendiente') as pendientes,
    round(100.0 * count(*) filter (where not requisito_inactivo and estado = 'Aprobado' and indicador = 'Documento vigente')
          / nullif(count(*) filter (where not requisito_inactivo), 0), 1) as porcentaje
  from public.v_matriz
  group by ips_id, ips_codigo, ips_nombre, ciudad, regional_id, regional;

-- ------------------------------------------------------------- RLS Y POLÍTICAS

alter table public.regionales           enable row level security;
alter table public.ips                  enable row level security;
alter table public.documentos           enable row level security;
alter table public.perfiles             enable row level security;
alter table public.perfil_regionales    enable row level security;
alter table public.soportes             enable row level security;
alter table public.requisitos_inactivos enable row level security;
alter table public.auditoria_estados    enable row level security;
alter table public.modificaciones       enable row level security;
alter table public.notificaciones       enable row level security;
alter table public.parametros           enable row level security;

create policy "leer regionales"  on public.regionales for select to authenticated using (true);
create policy "leer documentos"  on public.documentos for select to authenticated using (true);
create policy "leer parametros"  on public.parametros for select to authenticated using (true);

create policy "ver ips segun alcance" on public.ips for select to authenticated
  using (es_universal() or (regional_id in (select mis_regionales())) or (id = mi_ips()));

create policy "ver mi perfil" on public.perfiles for select to authenticated
  using ((id = (select auth.uid())) or es_universal() or tiene_rol('ADMINISTRADOR'));
create policy "editar mi nombre" on public.perfiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "ver mis regionales" on public.perfil_regionales for select to authenticated
  using ((perfil_id = (select auth.uid())) or es_universal() or tiene_rol('ADMINISTRADOR'));

create policy "ver soportes" on public.soportes for select to authenticated
  using (es_universal() or (ips_id = mi_ips())
    or (ips_id in (select ips.id from public.ips where ips.regional_id in (select mis_regionales()))));
create policy "cargar soporte" on public.soportes for insert to authenticated
  with check ((tiene_rol('PROVEEDOR') and (ips_id = mi_ips()) and (estado = 'Pendiente')) or es_universal());
create policy "auditar soporte" on public.soportes for update to authenticated
  using (es_universal() or ((tiene_rol('AUDITOR') or tiene_rol('ADMINISTRADOR'))
    and (ips_id in (select ips.id from public.ips where ips.regional_id in (select mis_regionales())))))
  with check (es_universal() or ((tiene_rol('AUDITOR') or tiene_rol('ADMINISTRADOR'))
    and (ips_id in (select ips.id from public.ips where ips.regional_id in (select mis_regionales())))));

create policy "ver requisitos inactivos" on public.requisitos_inactivos for select to authenticated
  using (ips_id in (select ips.id from public.ips));
create policy "inactivar requisito" on public.requisitos_inactivos for insert to authenticated
  with check ((tiene_rol('PROVEEDOR') and (ips_id = mi_ips())) or es_universal());
create policy "reactivar requisito" on public.requisitos_inactivos for delete to authenticated
  using ((tiene_rol('PROVEEDOR') and (ips_id = mi_ips())) or es_universal());

create policy "ver auditoria" on public.auditoria_estados for select to authenticated
  using (soporte_id in (select soportes.id from public.soportes));

create policy "ver modificaciones" on public.modificaciones for select to authenticated
  using (ips_id in (select ips.id from public.ips));
create policy "insertar modificaciones" on public.modificaciones for insert to authenticated
  with check ((ips_id = mi_ips()) or es_universal());

create policy "ver notificaciones" on public.notificaciones for select to authenticated
  using (ips_id in (select ips.id from public.ips));
