-- =============================================================================
-- RedDoc 360 · 0001 · Esquema
--
-- Traducción a PostgreSQL del libro de Google Sheets que usaba la versión
-- Apps Script. Cada tabla indica la pestaña de origen.
--
-- Lo que NO se almacena: las columnas derivadas del libro (Llave_Matriz,
-- ID_Estado, el nombre de la IPS repetido en cada hoja, el Indicador calculado
-- a partir de la fecha). En Sheets había que escribirlas porque no existían
-- las vistas; aquí salen de 0002_logica.
-- =============================================================================

create schema if not exists private;

-- Regionales de la red y su buzón compartido (antes CONFIG.CORREOS_REGIONAL).
-- Se notifica a buzones, no a personas, para que el aviso sobreviva a
-- vacaciones y cambios de equipo.
create table public.regionales (
  nombre        text primary key,
  correo_buzon  text not null
);

-- BDDIPS ----------------------------------------------------------------------
create table public.ips (
  id_ips        text primary key
                check (id_ips ~ '^[A-Z]{3}-[A-HJ-NP-Z2-9]{6}$'),
  nombre        text not null unique,
  ciudad        text not null,
  regional      text not null references public.regionales (nombre) on update cascade,
  correo        text,
  correo_lider  text,
  creado_en     timestamptz not null default now()
);

comment on column public.ips.id_ips is
  '{3 letras de la ciudad}-{6 caracteres sin 0/O ni 1/I}. No es consecutivo: '
  'la IPS entra al portal sólo con este identificador, y uno consecutivo '
  'permitía adivinar el de otra sede.';

-- BDDDocumentos: catálogo de requisitos ---------------------------------------
create table public.documentos (
  id_documento  text primary key check (id_documento ~ '^DOC_[0-9]{3}$'),
  nombre        text not null,
  categoria     text not null check (categoria in (
                  'Administrativa y normativa', 'Mantenimiento', 'Calibración',
                  'Vinculación', 'No auditable')),
  especialidad  text not null default '',
  -- Frontera de confidencialidad: sólo 'Externa' puede salir a la vitrina
  -- comercial. Todo lo demás es interno (regla fail-closed).
  consulta      text not null default 'Interno' check (consulta in ('Externa', 'Interno')),
  -- Excepciones a la norma PDF (antes CONFIG.FORMATOS_POR_DOCUMENTO).
  formato       text not null default 'PDF' check (formato in ('PDF', 'IMAGEN', 'HOJA_CALCULO'))
);

-- BDD_Matriz: a qué IPS aplica cada requisito ---------------------------------
-- Un requisito SIN filas en la matriz aplica a todas las IPS.
create table public.matriz (
  id_documento  text not null references public.documentos (id_documento) on delete cascade,
  id_ips        text not null references public.ips (id_ips) on delete cascade,
  primary key (id_documento, id_ips)
);

-- Log_Cargas: cada soporte cargado y su estado de auditoría --------------------
create table public.cargues (
  id                        bigint generated always as identity primary key,
  id_ips                    text not null references public.ips (id_ips) on delete cascade,
  -- Nulo = cargue sin clasificar: la IPS dejó el archivo sin decir a qué
  -- requisito corresponde y el auditor lo clasifica en la bandeja.
  id_documento              text references public.documentos (id_documento),
  id_archivo                text,
  -- Ruta del objeto en Storage (bucket 'soportes').
  enlace                    text,
  nombre_archivo            text,
  fecha_cargue              timestamptz not null default now(),
  fecha_documento           date,
  fecha_vencimiento         date,
  observaciones             text not null default '',
  -- Heredado del libro: estado de vigencia escrito a mano en cargues antiguos
  -- sin fecha. También lleva la marca 'Inactivo'. Ver clasificar_vigencia().
  indicador                 text not null default '',
  estado_auditoria          text not null default 'Pendiente' check (estado_auditoria in (
                              'Pendiente', 'Aprobado', 'Rechazado', 'Historico', 'Duplicado', 'Inactivo')),
  fecha_auditoria           timestamptz,
  -- Serial o placa de la unidad de equipo: distingue las 22 básculas de una sede.
  identificador_equipo      text not null default '',
  -- Datos del médico acreditado (sólo Licencia Médicos Especialistas, DOC_007).
  medico_nombre             text,
  medico_documento          text,
  medico_rm_tp              text,
  medico_numero_resolucion  text,
  medico_fecha_resolucion   date,
  cargado_por               uuid
);

create index cargues_par_idx    on public.cargues (id_ips, id_documento);
create index cargues_estado_idx on public.cargues (estado_auditoria);
create index cargues_enlace_idx on public.cargues (enlace);

-- Auditoria_Estados: traza inmutable de cada decisión -------------------------
-- id_cargue queda en NULL cuando un rechazo purga el cargue: la traza es la
-- evidencia del rechazo y sobrevive a él.
create table public.auditoria_estados (
  id                       bigint generated always as identity primary key,
  id_cargue                bigint references public.cargues (id) on delete set null,
  id_ips                   text not null references public.ips (id_ips) on delete cascade,
  id_documento             text,
  estado_anterior          text,
  estado_nuevo             text not null,
  fecha_cambio             timestamptz not null default now(),
  usuario_auditor          text not null,
  observaciones            text not null default '',
  fecha_vencimiento_nueva  date,
  accion                   text not null check (accion in ('APROBACION', 'RECHAZO', 'SEGUIMIENTO'))
);

create index auditoria_estados_cargue_idx on public.auditoria_estados (id_cargue);

-- Log_Modificaciones: lo que la sede hace en su portal ------------------------
-- No es un log técnico: alimenta el resumen diario que se envía a la regional.
create table public.modificaciones (
  id            bigint generated always as identity primary key,
  fecha         timestamptz not null default now(),
  id_ips        text not null references public.ips (id_ips) on delete cascade,
  modulo        text not null,
  accion        text not null check (accion in (
                  'Cargue de soporte', 'Actualización de soporte', 'Eliminación de soporte',
                  'Requisito marcado inactivo', 'Requisito reactivado')),
  id_documento  text,
  documento     text,
  id_cargue     bigint,
  usuario       text not null,
  detalle       text not null default '',
  notificado    boolean not null default false
);

-- SeguimientoNotificaciones ---------------------------------------------------
-- En la demo los correos no salen: se registran aquí con confirmación
-- 'Simulado' y su contenido en `detalle`.
create table public.notificaciones (
  id            bigint generated always as identity primary key,
  fecha_envio   timestamptz not null default now(),
  id_ips        text references public.ips (id_ips) on delete cascade,
  tipo          text not null check (tipo in (
                  'Auditoría', 'Cargue', 'Estado general', 'Licencias', 'Modificaciones')),
  id_documento  text,
  asunto        text not null,
  destino       text not null,
  con_copia     text not null default '',
  enviado_por   text not null,
  disparo       text not null check (disparo in ('Manual', 'Automático')),
  confirmacion  text not null default 'Simulado',
  detalle       jsonb not null default '{}'::jsonb
);

-- Configuracion_Roles ---------------------------------------------------------
-- La contraseña ya no vive en una celda: la custodia Supabase Auth. Esta tabla
-- conserva lo que decide el acceso: roles, regionales y estado.
create table public.perfiles (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  nombre      text not null,
  email       text not null unique,
  -- Un usuario puede acumular varios roles ("Auditor, Administrador").
  roles       text[] not null check (
                cardinality(roles) > 0
                and roles <@ array['PROVEEDOR', 'AUDITOR', 'ADMINISTRADOR', 'USUARIO_UNIVERSAL']),
  -- Acceso_Regional. '*' o 'Todas' = todas las regionales. Vacío = ninguna.
  regionales  text[] not null default '{}',
  id_ips      text references public.ips (id_ips) on delete cascade,
  activo      boolean not null default true,
  creado_en   timestamptz not null default now(),
  constraint perfiles_proveedor_con_ips check (not ('PROVEEDOR' = any (roles)) or id_ips is not null)
);

-- Propiedades del script → parámetros de negocio editables sin redesplegar ----
create table public.parametros (
  clave        text primary key,
  valor        numeric not null,
  descripcion  text not null default ''
);

insert into public.parametros (clave, valor, descripcion) values
  ('DIAS_ALERTA_AMARILLA',      90, 'Días antes del vencimiento en que un soporte pasa a «Próximo a Vencer».'),
  ('DIAS_ALERTA_ROJA',          30, 'Días antes del vencimiento para la alerta roja.'),
  ('VIGENCIA_DEFECTO_MESES',    12, 'Vigencia asignada al aprobar un soporte que no trae fecha de vencimiento.'),
  ('DIAS_AVISO_LICENCIA',       90, 'Ventana de seguimiento de licencias médicas (Módulo 7).'),
  ('HORAS_GUARDA_NOTIFICACION', 24, 'Ventana anti-reenvío de los botones de notificación manual.');
