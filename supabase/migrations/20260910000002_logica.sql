-- =============================================================================
-- RedDoc 360 · 0002 · Lógica de negocio
--
-- En la versión Apps Script esta lógica vivía en EstadoService,
-- CatalogoService y DashboardService, y se recalculaba en cada petición
-- recorriendo la hoja entera (con cachés fragmentadas para no pasar el límite
-- de 100 KB). Aquí es SQL: vistas que cualquier módulo consulta y que siempre
-- dan la misma respuesta.
--
-- Esquema `private`: funciones de apoyo. No se expone por la API REST.
-- =============================================================================

-- ------------------------------------------------------------------ utilidades

-- Normaliza texto para comparar: minúsculas, sin tildes ni espacios sobrantes.
-- (Las regionales y los estados los escribían personas en una hoja.)
create or replace function private.norm(p_texto text)
returns text
language sql immutable parallel safe
set search_path = ''
as $$
  select regexp_replace(
           translate(lower(btrim(coalesce(p_texto, ''))),
                     'áàäâéèëêíìïîóòöôúùüûñ', 'aaaaeeeeiiiioooouuuun'),
           '\s+', ' ', 'g')
$$;

-- Hoy en la zona horaria del negocio: los vencimientos se comparan por fecha.
create or replace function private.hoy()
returns date
language sql stable
set search_path = ''
as $$
  select (now() at time zone 'America/Bogota')::date
$$;

create or replace function private.param(p_clave text, p_defecto numeric)
returns numeric
language sql stable security definer
set search_path = ''
as $$
  select coalesce((select valor from public.parametros where clave = p_clave), p_defecto)
$$;

-- ------------------------------------------------------ reglas del catálogo

-- Mantenimiento y Calibración: soportes por unidad de equipo.
create or replace function private.es_equipo(p_categoria text)
returns boolean
language sql immutable
set search_path = ''
as $$
  select coalesce(p_categoria in ('Mantenimiento', 'Calibración'), false)
$$;

-- ¿El requisito admite varios soportes vigentes a la vez? Los equipos (22
-- básculas son 22 soportes) y los que se acreditan por profesional:
-- DOC_007 Licencia Médicos Especialistas y DOC_008 RETHUS.
create or replace function private.es_multiple(p_id_documento text, p_categoria text)
returns boolean
language sql immutable
set search_path = ''
as $$
  select private.es_equipo(p_categoria)
      or coalesce(p_id_documento in ('DOC_007', 'DOC_008'), false)
$$;

-- Bloque operativo del Portal. Nulo = el requisito no es del portal
-- (Vinculación y No auditable).
create or replace function private.bloque(p_categoria text)
returns text
language sql immutable
set search_path = ''
as $$
  select case p_categoria
           when 'Administrativa y normativa' then 'normativos'
           when 'Mantenimiento'              then 'mantenimiento'
           when 'Calibración'                then 'calibracion'
         end
$$;

-- Menor = peor. Sirve para elegir el «peor caso» de un requisito de varias unidades.
create or replace function private.gravedad(p_clave text)
returns int
language sql immutable
set search_path = ''
as $$
  select case p_clave when 'vencido' then 0 when 'actualizacion' then 1 when 'vigente' then 2 else 3 end
$$;

-- --------------------------------------------------------------- vigencia

-- Clasificación canónica de vigencia (antes EstadoService.clasificarVigencia).
-- Devuelve: vencido | actualizacion | vigente | pendiente | inactivo.
--   1. La marca 'Inactivo' se decide antes que cualquier fecha: si la sede
--      declaró que el requisito ya no le aplica, no hay nada que renovar.
--   2. Con fecha de vencimiento, manda la fecha.
--   3. Sin fecha, el Indicador heredado de los cargues antiguos.
create or replace function public.clasificar_vigencia(p_vencimiento date, p_indicador text default '')
returns text
language sql stable
set search_path = ''
as $$
  select case
    when private.norm(p_indicador) = 'inactivo' then 'inactivo'
    when p_vencimiento is not null then
      case
        when p_vencimiento < private.hoy() then 'vencido'
        when p_vencimiento - private.hoy() <= private.param('DIAS_ALERTA_AMARILLA', 90) then 'actualizacion'
        else 'vigente'
      end
    when private.norm(p_indicador) = 'vencido'           then 'vencido'
    when private.norm(p_indicador) = 'proximo a vencer'  then 'actualizacion'
    when private.norm(p_indicador) = 'documento vigente' then 'vigente'
    else 'pendiente'
  end
$$;

create or replace function public.etiqueta_vigencia(p_clave text)
returns text
language sql immutable
set search_path = ''
as $$
  select case p_clave
           when 'vigente'       then 'Documento vigente'
           when 'actualizacion' then 'Próximo a Vencer'
           when 'vencido'       then 'Vencido'
           when 'inactivo'      then 'Inactivo'
           else 'Pendiente'
         end
$$;

-- ------------------------------------------------------ sesión y alcance

-- Perfil del usuario autenticado, con su rol principal y su alcance ya
-- resueltos. SECURITY DEFINER: lee `perfiles` sin pasar por su RLS (que a su
-- vez dependería de esta función).
create or replace function private.perfil_actual()
returns table (
  user_id        uuid,
  nombre         text,
  email          text,
  roles          text[],
  rol_principal  text,
  regionales     text[],
  alcance_total  boolean,
  id_ips         text
)
language sql stable security definer
set search_path = ''
as $$
  select
    p.user_id, p.nombre, p.email, p.roles,
    -- Precedencia para elegir el rol principal cuando el usuario tiene varios.
    (select r from unnest(array['USUARIO_UNIVERSAL', 'ADMINISTRADOR', 'AUDITOR', 'PROVEEDOR'])
                   with ordinality as o (r, orden)
      where r = any (p.roles) order by orden limit 1),
    p.regionales,
    'USUARIO_UNIVERSAL' = any (p.roles)
      or exists (select 1 from unnest(p.regionales) g
                  where private.norm(g) in ('*', 'todas', 'todas las regionales',
                                            'todas las regionales.', 'all', 'n/a')),
    p.id_ips
  from public.perfiles p
  where p.user_id = auth.uid() and p.activo
$$;

create or replace function private.mis_roles()
returns text[]
language sql stable
set search_path = ''
as $$
  select coalesce((select roles from private.perfil_actual()), '{}'::text[])
$$;

-- ¿Alguno de los roles de la sesión está autorizado? '*' = cualquiera.
create or replace function private.tiene_rol(p_autorizados text[])
returns boolean
language sql stable
set search_path = ''
as $$
  select '*' = any (p_autorizados) or private.mis_roles() && p_autorizados
$$;

-- El veto se evalúa antes que la autorización y gana siempre, incluso sobre '*'.
create or replace function private.esta_vetado(p_vetados text[])
returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce(private.mis_roles() && p_vetados, false)
$$;

-- IPS sobre las que la sesión tiene alcance. Es el segundo eje de la
-- autorización, independiente del rol:
--   · PROVEEDOR           → únicamente la suya.
--   · alcance total       → todas (USUARIO_UNIVERSAL o comodín en regionales).
--   · resto de internos   → las de sus regionales. Sin regionales: ninguna.
create or replace function private.ips_visibles()
returns setof text
language sql stable security definer
set search_path = ''
as $$
  select i.id_ips
  from public.ips i
  cross join private.perfil_actual() p
  where case
          when p.rol_principal = 'PROVEEDOR' then i.id_ips = p.id_ips
          when p.alcance_total then true
          else private.norm(i.regional) in (select private.norm(g) from unnest(p.regionales) g)
        end
$$;

create or replace function private.puede_ver_ips(p_id_ips text)
returns boolean
language sql stable
set search_path = ''
as $$
  select p_id_ips in (select private.ips_visibles())
$$;

-- Requisitos con filas en la matriz. SECURITY DEFINER a propósito: la regla
-- «sin filas en la matriz = aplica a todas» debe mirar la matriz COMPLETA. Con
-- RLS, un documento cuyas filas son todas de otra regional parecería no tener
-- matriz y se exigiría a todas las IPS visibles.
create or replace function private.documentos_con_matriz()
returns setof text
language sql stable security definer
set search_path = ''
as $$
  select distinct id_documento from public.matriz
$$;

create or replace function private.documentos_vinculacion()
returns setof text
language sql stable security definer
set search_path = ''
as $$
  select id_documento from public.documentos where categoria = 'Vinculación'
$$;

-- ======================================================================= VISTAS
-- Todas con security_invoker: se evalúan con los permisos (y la RLS) de quien
-- consulta, de modo que cada usuario sólo ve lo de su alcance.

-- EL SOPORTE QUE REPRESENTA A UN REQUISITO EN UNA SEDE
-- (antes CatalogoService._consolidar). Todos los módulos leen el estado de un
-- requisito de aquí, así que la regla de negocio vive entera en esta vista:
--
--  1. Si lo último que pasó en el par fue marcarlo INACTIVO, manda la marca.
--  2. Un RECHAZADO no acredita nada: sólo representa al requisito si no hay
--     ningún otro soporte en pie.
--  3. Un soporte en auditoría, sin fecha, no define el estado mientras haya
--     alguno con fecha. Si todos están en auditoría, representa el más reciente.
--  4. Requisito de UN soporte: gana el de vencimiento más lejano —el más
--     vigente—, no el último que se subió.
--  5. Requisito de VARIOS soportes: representa el PEOR de sus unidades, con el
--     conteo por estado para que la pantalla diga «Vencido · 3 de 22».
create or replace view public.v_soportes
with (security_invoker = true) as
with base as (
  select c.id, c.id_ips, c.id_documento, c.estado_auditoria, c.fecha_cargue,
         c.fecha_vencimiento, c.indicador,
         coalesce(c.enlace, '') <> '' as con_enlace,
         private.es_multiple(c.id_documento, d.categoria) as multiple,
         public.clasificar_vigencia(c.fecha_vencimiento, c.indicador) as clave
  from public.cargues c
  join public.documentos d on d.id_documento = c.id_documento
  -- Histórico y Duplicado son ruido del pasado: no compiten.
  where c.estado_auditoria not in ('Historico', 'Duplicado')
),
-- Lo último que pasó en cada par. A igualdad de fecha gana el que tiene
-- archivo y, por último, el registro más nuevo.
ultimo as (
  select distinct on (id_ips, id_documento) id_ips, id_documento, id, estado_auditoria
  from base
  order by id_ips, id_documento, fecha_cargue desc, con_enlace desc, id desc
),
evaluadas as (
  select b.*,
         case when b.estado_auditoria = 'Rechazado' then 2   -- regla 2
              when b.clave = 'pendiente'            then 1   -- regla 3
              else 0 end as nivel,
         private.gravedad(b.clave) as gravedad
  from base b
  where b.estado_auditoria <> 'Inactivo'
),
elegido as (
  select distinct on (id_ips, id_documento) id_ips, id_documento, id, nivel, multiple
  from evaluadas
  order by id_ips, id_documento, nivel,
    -- regla 5: el peor; entre iguales, el que vence antes
    case when nivel = 0 and multiple     then gravedad          end asc  nulls last,
    case when nivel = 0 and multiple     then fecha_vencimiento end asc  nulls last,
    -- regla 4: el más vigente; a igualdad, el de mejor estado y el aprobado
    case when nivel = 0 and not multiple then fecha_vencimiento end desc nulls last,
    case when nivel = 0 and not multiple then gravedad          end desc nulls last,
    case when nivel = 0 and not multiple then estado_auditoria = 'Aprobado' end desc nulls last,
    fecha_cargue desc, con_enlace desc, id desc
),
unidades as (
  select id_ips, id_documento,
         count(*)::int                                                        as total,
         count(*) filter (where clave = 'vencido')::int                       as vencidas,
         count(*) filter (where clave = 'actualizacion')::int                 as por_vencer,
         count(*) filter (where clave = 'vigente')::int                       as vigentes,
         count(*) filter (where clave not in ('vencido', 'actualizacion', 'vigente'))::int as en_auditoria
  from evaluadas
  where nivel < 2
  group by id_ips, id_documento
)
select
  u.id_ips,
  u.id_documento,
  c.id                    as id_cargue,
  c.estado_auditoria,
  c.fecha_cargue,
  c.fecha_vencimiento,
  c.enlace,
  c.observaciones,
  c.identificador_equipo,
  -- Estado del requisito tal como lo cuentan el Portal y los tableros: un
  -- rechazado o una fila sin archivo no acreditan nada.
  case
    when c.estado_auditoria = 'Inactivo' then 'inactivo'
    when c.estado_auditoria = 'Rechazado' or coalesce(c.enlace, '') = '' then 'pendiente'
    else public.clasificar_vigencia(c.fecha_vencimiento, c.indicador)
  end                     as estado,
  coalesce(e.multiple, false) as multiple,
  case when e.multiple and e.nivel = 0 and u.estado_auditoria <> 'Inactivo' then k.total        end as unidades_total,
  case when e.multiple and e.nivel = 0 and u.estado_auditoria <> 'Inactivo' then k.vencidas     end as unidades_vencidas,
  case when e.multiple and e.nivel = 0 and u.estado_auditoria <> 'Inactivo' then k.por_vencer   end as unidades_por_vencer,
  case when e.multiple and e.nivel = 0 and u.estado_auditoria <> 'Inactivo' then k.vigentes     end as unidades_vigentes,
  case when e.multiple and e.nivel = 0 and u.estado_auditoria <> 'Inactivo' then k.en_auditoria end as unidades_en_auditoria
from ultimo u
left join elegido e  on e.id_ips = u.id_ips and e.id_documento = u.id_documento
left join unidades k on k.id_ips = u.id_ips and k.id_documento = u.id_documento
join public.cargues c
  on c.id = case when u.estado_auditoria = 'Inactivo' then u.id else e.id end;

-- Cada requisito exigible a cada IPS, con su estado. Es el universo sobre el
-- que se calcula el cumplimiento: «78 %» significa «78 % de lo exigido está
-- vigente», no «78 % de lo subido fue aprobado».
create or replace view public.v_requisitos_ips
with (security_invoker = true) as
select
  i.id_ips, i.nombre as nombre_ips, i.ciudad, i.regional,
  d.id_documento, d.nombre as documento, d.categoria, d.especialidad,
  private.bloque(d.categoria) as bloque,
  coalesce(s.estado, 'pendiente') as estado,
  s.id_cargue, s.estado_auditoria, s.fecha_vencimiento, coalesce(s.multiple, false) as multiple,
  s.unidades_total, s.unidades_vencidas, s.unidades_por_vencer, s.unidades_vigentes, s.unidades_en_auditoria
from public.ips i
cross join public.documentos d
left join public.v_soportes s on s.id_ips = i.id_ips and s.id_documento = d.id_documento
where private.bloque(d.categoria) is not null
  and (d.id_documento not in (select private.documentos_con_matriz())
       or exists (select 1 from public.matriz m
                   where m.id_documento = d.id_documento and m.id_ips = i.id_ips));

-- Cumplimiento por IPS con desglose por bloque (antes DashboardService._matrizCumplimiento).
-- Un requisito inactivo no se exige: sale del numerador Y del denominador. Si
-- sólo saliera del numerador, marcar un servicio que la sede ya no presta le
-- bajaría el cumplimiento, justo lo contrario de lo que significa la marca.
create or replace view public.v_cumplimiento_ips
with (security_invoker = true) as
select t.*,
       case when t.cumplimiento >= 80 then 'verde'
            when t.cumplimiento >= 50 then 'amarillo'
            else 'rojo' end as semaforo
from (
  select
    id_ips, nombre_ips, ciudad, regional,
    count(*) filter (where estado <> 'inactivo')::int      as aplican,
    count(*) filter (where estado = 'vigente')::int        as vigente,
    count(*) filter (where estado = 'actualizacion')::int  as actualizacion,
    count(*) filter (where estado = 'vencido')::int        as vencido,
    count(*) filter (where estado = 'pendiente')::int      as pendiente,
    count(*) filter (where estado = 'inactivo')::int       as inactivo,
    coalesce(round(100.0 * count(*) filter (where estado = 'vigente')
                   / nullif(count(*) filter (where estado <> 'inactivo'), 0))::int, 0) as cumplimiento,
    count(*) filter (where bloque = 'normativos'    and estado <> 'inactivo')::int as normativos_aplican,
    count(*) filter (where bloque = 'normativos'    and estado = 'vigente')::int   as normativos_vigente,
    count(*) filter (where bloque = 'mantenimiento' and estado <> 'inactivo')::int as mantenimiento_aplican,
    count(*) filter (where bloque = 'mantenimiento' and estado = 'vigente')::int   as mantenimiento_vigente,
    count(*) filter (where bloque = 'calibracion'   and estado <> 'inactivo')::int as calibracion_aplican,
    count(*) filter (where bloque = 'calibracion'   and estado = 'vigente')::int   as calibracion_vigente
  from public.v_requisitos_ips
  group by id_ips, nombre_ips, ciudad, regional
) t;

-- Bandeja del auditor (Módulo 2): soportes en pie, sin el expediente de
-- vinculación (lo carga la dirección de red y el auditor no debe abrirlo).
create or replace view public.v_bandeja
with (security_invoker = true) as
select
  c.id as id_cargue, c.id_archivo, c.id_ips,
  i.nombre as nombre_ips, i.ciudad, i.regional,
  c.id_documento, d.nombre as documento, d.categoria, d.especialidad,
  c.id_documento is null as sin_clasificar,
  c.estado_auditoria,
  public.clasificar_vigencia(c.fecha_vencimiento, c.indicador) as estado_vigencia,
  c.fecha_cargue, c.fecha_documento, c.fecha_vencimiento,
  c.enlace, c.nombre_archivo, c.observaciones, c.identificador_equipo,
  c.medico_nombre, c.medico_documento, c.medico_rm_tp,
  c.medico_numero_resolucion, c.medico_fecha_resolucion
from public.cargues c
join public.ips i on i.id_ips = c.id_ips
left join public.documentos d on d.id_documento = c.id_documento
where c.estado_auditoria not in ('Historico', 'Duplicado', 'Inactivo')
  and coalesce(d.categoria, '') <> 'Vinculación';

-- ========================================================================= RPC

-- Sesión hidratada: lo que el cliente necesita para pintar menú y permisos.
create or replace function public.mi_sesion()
returns jsonb
language sql stable
set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object(
              'autenticado', true,
              'nombre', p.nombre,
              'email', p.email,
              'rol', p.rol_principal,
              'roles', to_jsonb(p.roles),
              'regionales', to_jsonb(p.regionales),
              'alcanceTotal', p.alcance_total,
              'idIps', p.id_ips,
              'puedeCargar', p.roles && array['PROVEEDOR', 'USUARIO_UNIVERSAL'],
              'sinAlcance', p.rol_principal <> 'PROVEEDOR' and not p.alcance_total
                            and cardinality(p.regionales) = 0)
       from private.perfil_actual() p),
    '{"autenticado": false}'::jsonb)
$$;

-- Módulo 3 · Dashboard Ejecutivo: KPIs, alertas y comparativo por regional,
-- calculados sólo sobre las IPS del alcance de la sesión (lo garantiza la RLS
-- de las vistas: la función corre con los permisos de quien llama).
create or replace function public.dashboard_macro()
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_resultado jsonb;
begin
  if not private.tiene_rol(array['ADMINISTRADOR', 'USUARIO_UNIVERSAL']) then
    raise exception 'Su perfil no tiene permiso para ejecutar esta operación.' using errcode = '42501';
  end if;

  with filas as (
    select * from public.v_cumplimiento_ips
  ),
  total as (
    select count(*)::int                        as ips,
           coalesce(sum(aplican), 0)::int       as aplican,
           coalesce(sum(vigente), 0)::int       as vigente,
           coalesce(sum(actualizacion), 0)::int as actualizacion,
           coalesce(sum(vencido), 0)::int       as vencido,
           coalesce(sum(pendiente), 0)::int     as pendiente
    from filas
  ),
  bandeja as (
    select count(*) filter (where estado_auditoria = 'Pendiente')::int as pendiente,
           count(*) filter (where estado_auditoria = 'Aprobado')::int  as aprobado,
           count(*) filter (where estado_auditoria = 'Rechazado')::int as rechazado
    from public.cargues
    where estado_auditoria not in ('Historico', 'Duplicado', 'Inactivo')
  ),
  alertas as (
    (select 'roja' as nivel, nombre_ips as titulo, id_ips, 1 as orden, vencido as peso,
            vencido || ' documento(s) vencido(s) — ' || ciudad || ' · ' || regional as mensaje
       from filas where vencido > 0 order by vencido desc, nombre_ips limit 5)
    union all
    (select 'amarilla', nombre_ips, id_ips, 2, actualizacion,
            actualizacion || ' documento(s) por vencer en los próximos '
              || private.param('DIAS_ALERTA_AMARILLA', 90) || ' días'
       from filas where actualizacion > 0 order by actualizacion desc, nombre_ips limit 5)
  ),
  por_regional as (
    select regional,
           count(*)::int           as ips,
           sum(vigente)::int       as vigente,
           sum(aplican)::int       as aplican,
           sum(vencido)::int       as vencido,
           sum(actualizacion)::int as actualizacion,
           sum(pendiente)::int     as pendiente,
           coalesce(round(100.0 * sum(vigente) / nullif(sum(aplican), 0))::int, 0) as cumplimiento
    from filas
    group by regional
  )
  select jsonb_build_object(
           'totalIps',           t.ips,
           'totalRequisitos',    t.aplican,
           'vigentes',           t.vigente,
           'porVencer',          t.actualizacion,
           'vencidos',           t.vencido,
           'pendientes',         t.pendiente,
           'aprobados',          b.aprobado,
           'enRevision',         b.pendiente,
           'rechazados',         b.rechazado,
           'cumplimientoGlobal', coalesce(round(100.0 * t.vigente / nullif(t.aplican, 0))::int, 0),
           'alertas',    coalesce((select jsonb_agg(jsonb_build_object(
                                     'nivel', a.nivel, 'titulo', a.titulo,
                                     'idIps', a.id_ips, 'mensaje', a.mensaje)
                                     order by a.orden, a.peso desc) from alertas a), '[]'::jsonb),
           'regionales', coalesce((select jsonb_agg(to_jsonb(r) order by r.cumplimiento desc)
                                     from por_regional r), '[]'::jsonb),
           'alcanceTotal', coalesce((select p.alcance_total from private.perfil_actual() p), false),
           'generado',   now())
    into v_resultado
    from total t cross join bandeja b;

  return v_resultado;
end
$$;

-- Módulo 2 · Auditoría por lotes (antes AuditService.actualizarEstadosAuditoriaLote).
--
-- Aplica N decisiones en una sola transacción. Cada decisión se valida por
-- separado: una decisión inválida se reporta en `fallidos` y no tumba las
-- demás. SECURITY DEFINER porque escribe en tablas sin permiso de escritura
-- directa; por eso cada comprobación de rol y de alcance es explícita.
--
-- Decisión: { idCargue, nuevoEstado, observaciones, fechaDocumento,
--             fechaVencimiento, idDocumento, medico: {...}, notificar }
create or replace function public.auditar_lote(p_decisiones jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_perfil     record;
  v_auditor    text;
  d            jsonb;
  v_c          public.cargues%rowtype;
  v_doc        public.documentos%rowtype;
  v_ips        public.ips%rowtype;
  v_estado     text;
  v_anterior   text;
  v_obs        text;
  v_motivo     text;
  v_id_doc     text;
  v_fdoc       date;
  v_fven       date;
  v_medico     jsonb;
  v_faltan     text[];
  v_aplicados  int     := 0;
  v_correos    int     := 0;
  v_fallidos   jsonb   := '[]'::jsonb;
  v_purgar     bigint[] := '{}';
  v_archivos   text[]  := '{}';
  v_notificar  jsonb   := '{}'::jsonb;
  v_ips_id     text;
  v_items      jsonb;
begin
  if not private.tiene_rol(array['AUDITOR', 'ADMINISTRADOR', 'USUARIO_UNIVERSAL']) then
    raise exception 'Su perfil no tiene permiso para ejecutar esta operación.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_decisiones) is distinct from 'array' or jsonb_array_length(p_decisiones) = 0 then
    raise exception 'No se recibieron decisiones de auditoría.' using errcode = '22023';
  end if;

  select * into v_perfil from private.perfil_actual();
  v_auditor := coalesce(nullif(v_perfil.email, ''), v_perfil.nombre, 'sistema');

  for d in select value from jsonb_array_elements(p_decisiones) loop
    begin
      v_motivo := null;
      v_obs    := btrim(coalesce(d ->> 'observaciones', ''));
      v_estado := case private.norm(d ->> 'nuevoEstado')
                    when 'aprobado'  then 'Aprobado'
                    when 'rechazado' then 'Rechazado'
                    when 'pendiente' then 'Pendiente'
                  end;

      if v_estado is null then
        v_motivo := 'Estado de auditoría no permitido: ' || coalesce(d ->> 'nuevoEstado', '(vacío)') || '.';
      elsif v_estado = 'Rechazado' and v_obs = '' then
        v_motivo := 'Debe registrar el motivo del rechazo en las observaciones.';
      end if;

      -- Registro y alcance regional.
      if v_motivo is null then
        select * into v_c from public.cargues where id = (d ->> 'idCargue')::bigint for update;
        if not found then
          v_motivo := 'No fue posible identificar el registro a auditar.';
        elsif v_c.estado_auditoria in ('Historico', 'Duplicado', 'Inactivo') then
          v_motivo := 'El registro ya no forma parte de la bandeja (' || v_c.estado_auditoria || ').';
        elsif not private.puede_ver_ips(v_c.id_ips) then
          select * into v_ips from public.ips where id_ips = v_c.id_ips;
          v_motivo := case
            when not exists (select 1 from private.ips_visibles())
              then 'Su usuario no tiene regionales asignadas. Solicite su asignación al administrador.'
            else 'El registro pertenece a ' || v_ips.nombre || ' (' || v_ips.regional
                 || '), fuera de su alcance regional.'
          end;
        end if;
      end if;

      -- Clasificación: el auditor puede completar (o corregir) el requisito
      -- al que corresponde un cargue. Manda el catálogo, no el cliente.
      if v_motivo is null then
        v_id_doc := nullif(btrim(coalesce(d ->> 'idDocumento', '')), '');
        if v_id_doc is not null then
          select * into v_doc from public.documentos where id_documento = v_id_doc;
          if not found then
            v_motivo := 'El requisito ' || v_id_doc || ' no existe en el catálogo.';
          elsif v_doc.categoria = 'Vinculación' then
            v_motivo := 'El expediente de vinculación no se clasifica desde esta bandeja: se carga en el Módulo 6.';
          else
            v_c.id_documento := v_id_doc;
          end if;
        elsif v_c.id_documento is null and v_estado = 'Aprobado' then
          -- Sin requisito no cruza con la matriz: quedaría fuera de todos los tableros.
          v_motivo := 'El cargue no tiene requisito asociado. Seleccione el bloque y el documento antes de aprobarlo.';
        elsif v_c.id_documento in (select private.documentos_vinculacion()) then
          v_motivo := 'El expediente de vinculación no se audita en esta bandeja.';
        end if;
      end if;

      -- Fechas.
      if v_motivo is null then
        v_fdoc := nullif(d ->> 'fechaDocumento', '')::date;
        if v_fdoc is not null then
          v_c.fecha_documento := v_fdoc;
        end if;

        v_fven := nullif(d ->> 'fechaVencimiento', '')::date;
        -- Aprobar sin fecha: el cargue no inventa vencimiento, así que la
        -- vigencia por defecto se asigna aquí, cuando alguien validó el
        -- documento. Sólo si la fila no tiene nada con qué clasificarse.
        if v_fven is null and v_estado = 'Aprobado' and v_c.fecha_vencimiento is null
           and private.norm(v_c.indicador) in ('', 'pendiente') then
          v_fven := (coalesce(v_c.fecha_documento, private.hoy())
                     + make_interval(months => private.param('VIGENCIA_DEFECTO_MESES', 12)::int))::date;
        end if;
        if v_fven is not null then
          v_c.fecha_vencimiento := v_fven;
          v_c.indicador := '';
        end if;
      end if;

      -- Licencia Médicos Especialistas: cada soporte acredita a UN médico y el
      -- archivo por sí solo no dice a quién. Obligatorio para aprobar.
      if v_motivo is null and v_c.id_documento = 'DOC_007' then
        v_medico := coalesce(d -> 'medico', '{}'::jsonb);
        v_c.medico_nombre            := coalesce(nullif(btrim(v_medico ->> 'nombreHallado'), ''),    v_c.medico_nombre);
        v_c.medico_documento         := coalesce(nullif(btrim(v_medico ->> 'documentoHallado'), ''), v_c.medico_documento);
        v_c.medico_rm_tp             := coalesce(nullif(btrim(v_medico ->> 'rmtp'), ''),             v_c.medico_rm_tp);
        v_c.medico_numero_resolucion := coalesce(nullif(btrim(v_medico ->> 'numeroResolucion'), ''), v_c.medico_numero_resolucion);
        v_c.medico_fecha_resolucion  := coalesce(nullif(v_medico ->> 'fechaResolucion', '')::date,   v_c.medico_fecha_resolucion);

        if v_estado = 'Aprobado' then
          v_faltan := array_remove(array[
            case when coalesce(v_c.medico_nombre, '') = ''            then 'Nombre del médico' end,
            case when coalesce(v_c.medico_documento, '') = ''         then 'Documento de identidad' end,
            case when coalesce(v_c.medico_rm_tp, '') = ''             then 'RM / TP' end,
            case when coalesce(v_c.medico_numero_resolucion, '') = '' then 'Número de resolución' end,
            case when v_c.medico_fecha_resolucion is null             then 'Fecha de resolución' end
          ], null);
          if cardinality(v_faltan) > 0 then
            v_motivo := 'Para aprobar una Licencia Médicos Especialistas registre los datos del médico. Falta: '
                        || array_to_string(v_faltan, ', ') || '.';
          end if;
        end if;
      end if;

      if v_motivo is not null then
        v_fallidos := v_fallidos || jsonb_build_object('idCargue', d -> 'idCargue', 'motivo', v_motivo);
        continue;
      end if;

      v_anterior := v_c.estado_auditoria;
      update public.cargues set
        estado_auditoria         = v_estado,
        fecha_auditoria          = now(),
        observaciones            = case when v_obs <> '' then v_obs else observaciones end,
        id_documento             = v_c.id_documento,
        fecha_documento          = v_c.fecha_documento,
        fecha_vencimiento        = v_c.fecha_vencimiento,
        indicador                = v_c.indicador,
        medico_nombre            = v_c.medico_nombre,
        medico_documento         = v_c.medico_documento,
        medico_rm_tp             = v_c.medico_rm_tp,
        medico_numero_resolucion = v_c.medico_numero_resolucion,
        medico_fecha_resolucion  = v_c.medico_fecha_resolucion
      where id = v_c.id;

      insert into public.auditoria_estados
        (id_cargue, id_ips, id_documento, estado_anterior, estado_nuevo, usuario_auditor,
         observaciones, fecha_vencimiento_nueva, accion)
      values
        (v_c.id, v_c.id_ips, v_c.id_documento, v_anterior, v_estado, v_auditor, v_obs, v_fven,
         case v_estado when 'Aprobado' then 'APROBACION' when 'Rechazado' then 'RECHAZO' else 'SEGUIMIENTO' end);

      v_aplicados := v_aplicados + 1;
      if v_estado = 'Rechazado' then
        v_purgar := v_purgar || v_c.id;
      end if;

      if coalesce((d ->> 'notificar')::boolean, true) then
        v_notificar := jsonb_set(v_notificar, array[v_c.id_ips],
          coalesce(v_notificar -> v_c.id_ips, '[]'::jsonb) || jsonb_build_object(
            'documento', coalesce((select nombre from public.documentos where id_documento = v_c.id_documento),
                                  v_c.nombre_archivo, 'Documento'),
            'estado', v_estado,
            'fechaVencimiento', v_c.fecha_vencimiento,
            'observaciones', v_obs));
      end if;
    exception when others then
      v_fallidos := v_fallidos || jsonb_build_object('idCargue', d -> 'idCargue', 'motivo', sqlerrm);
    end;
  end loop;

  -- Un único correo por IPS con todo lo auditado, no uno por documento.
  for v_ips_id, v_items in select key, value from jsonb_each(v_notificar) loop
    select * into v_ips from public.ips where id_ips = v_ips_id;
    continue when coalesce(v_ips.correo, '') = '';
    insert into public.notificaciones
      (id_ips, tipo, asunto, destino, con_copia, enviado_por, disparo, detalle)
    values
      (v_ips_id, 'Auditoría',
       'Resultado de auditoría documental · ' || jsonb_array_length(v_items) || ' documento(s)',
       v_ips.correo,
       coalesce((select correo_buzon from public.regionales where nombre = v_ips.regional), ''),
       v_auditor, 'Manual', jsonb_build_object('resultados', v_items));
    v_correos := v_correos + 1;
  end loop;

  -- PURGA DE RECHAZADOS: un soporte rechazado sale del expediente. La traza
  -- (ya escrita) conserva el motivo, el auditor y la fecha. El mismo archivo
  -- puede dar soporte a varios requisitos: sólo se devuelve para borrar de
  -- Storage si ninguna fila superviviente lo referencia.
  if cardinality(v_purgar) > 0 then
    select coalesce(array_agg(distinct c.enlace), '{}') into v_archivos
      from public.cargues c
     where c.id = any (v_purgar)
       and coalesce(c.enlace, '') <> ''
       and not exists (select 1 from public.cargues o
                        where o.enlace = c.enlace and o.id <> all (v_purgar));
    delete from public.cargues where id = any (v_purgar);
  end if;

  return jsonb_build_object(
    'aplicados', v_aplicados,
    'fallidos', v_fallidos,
    'purgados', cardinality(v_purgar),
    'archivosAEliminar', to_jsonb(v_archivos),
    'correos', v_correos,
    'mensaje', case when v_aplicados > 0 then v_aplicados || ' documento(s) auditado(s)'
                    else 'No se aplicó ninguna decisión' end
               || case when cardinality(v_purgar) > 0
                       then '; ' || cardinality(v_purgar) || ' rechazado(s) retirado(s) del expediente' else '' end
               || case when jsonb_array_length(v_fallidos) > 0
                       then '; ' || jsonb_array_length(v_fallidos) || ' con error.' else '.' end);
end
$$;
