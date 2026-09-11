-- =============================================================================
-- RedDoc 360 · 0003 · Seguridad
--
-- En Apps Script la frontera de seguridad era el mapa ACCIONES de Code.gs:
-- toda llamada pasaba por un router que comprobaba rol y veto. Aquí la
-- frontera es la propia base de datos:
--   · LECTURA  → Row Level Security. Cada fila se filtra por rol y por
--                alcance regional, sin importar qué pantalla la pida.
--   · ESCRITURA → sólo por funciones RPC (SECURITY DEFINER) que validan la
--                operación. Nadie escribe directamente en las tablas.
-- =============================================================================

-- ------------------------------------------------------------------- permisos

revoke all on all tables in schema public from anon, authenticated;

grant select on
  public.regionales, public.ips, public.documentos, public.matriz, public.cargues,
  public.auditoria_estados, public.modificaciones, public.notificaciones,
  public.perfiles, public.parametros,
  public.v_soportes, public.v_requisitos_ips, public.v_cumplimiento_ips, public.v_bandeja
to authenticated;

-- El catálogo de requisitos no es sensible: lo necesita la vitrina pública.
grant select on public.documentos to anon;

-- Las políticas RLS invocan funciones de `private`. El esquema no se expone
-- por la API REST, así que conceder EXECUTE no lo hace invocable desde fuera.
grant usage on schema private to anon, authenticated;
grant execute on all functions in schema private to anon, authenticated;

revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.clasificar_vigencia(date, text),
  public.etiqueta_vigencia(text),
  public.mi_sesion(),
  public.dashboard_macro(),
  public.auditar_lote(jsonb)
to authenticated;

-- ----------------------------------------------------------------------- RLS

alter table public.regionales        enable row level security;
alter table public.ips               enable row level security;
alter table public.documentos        enable row level security;
alter table public.matriz            enable row level security;
alter table public.cargues           enable row level security;
alter table public.auditoria_estados enable row level security;
alter table public.modificaciones    enable row level security;
alter table public.notificaciones    enable row level security;
alter table public.perfiles          enable row level security;
alter table public.parametros        enable row level security;

create policy regionales_lectura on public.regionales
  for select to authenticated using (true);

create policy parametros_lectura on public.parametros
  for select to authenticated using (true);

create policy documentos_lectura on public.documentos
  for select to anon, authenticated using (true);

-- `(select private.ips_visibles())` se evalúa una vez por consulta, no por fila.
create policy ips_lectura on public.ips
  for select to authenticated
  using (id_ips in (select private.ips_visibles()));

create policy matriz_lectura on public.matriz
  for select to authenticated
  using (id_ips in (select private.ips_visibles()));

-- Soportes: los de las IPS del alcance. El expediente de vinculación
-- (contrato, certificación bancaria, SARLAFT) sólo lo ven ADMINISTRADOR y
-- USUARIO_UNIVERSAL: ni el auditor ni la propia IPS desde el portal.
create policy cargues_lectura on public.cargues
  for select to authenticated
  using (
    id_ips in (select private.ips_visibles())
    and (
      id_documento is null
      or id_documento not in (select private.documentos_vinculacion())
      or private.tiene_rol(array['ADMINISTRADOR', 'USUARIO_UNIVERSAL'])
    )
  );

create policy auditoria_estados_lectura on public.auditoria_estados
  for select to authenticated
  using (
    private.tiene_rol(array['AUDITOR', 'ADMINISTRADOR', 'USUARIO_UNIVERSAL'])
    and id_ips in (select private.ips_visibles())
  );

create policy modificaciones_lectura on public.modificaciones
  for select to authenticated
  using (
    private.tiene_rol(array['AUDITOR', 'ADMINISTRADOR', 'USUARIO_UNIVERSAL'])
    and id_ips in (select private.ips_visibles())
  );

-- El auditor ve qué se le notificó a la IPS; no dispara envíos manuales.
create policy notificaciones_lectura on public.notificaciones
  for select to authenticated
  using (
    private.tiene_rol(array['AUDITOR', 'ADMINISTRADOR', 'USUARIO_UNIVERSAL'])
    and id_ips in (select private.ips_visibles())
  );

create policy perfiles_propio on public.perfiles
  for select to authenticated
  using (user_id = auth.uid());

-- ------------------------------------------------------------------- Storage
-- Los soportes viven en el bucket privado 'soportes' con la ruta
-- {id_ips}/{id_documento}/{archivo}. El primer segmento de la ruta es la IPS,
-- así que la misma función de alcance protege los archivos.
-- (Se omite en entornos sin Supabase Storage, como las pruebas con PGlite.)
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'Sin esquema storage: se omiten el bucket y sus políticas.';
    return;
  end if;

  insert into storage.buckets (id, name, public)
  values ('soportes', 'soportes', false)
  on conflict (id) do nothing;

  execute $p$
    create policy soportes_lectura on storage.objects
      for select to authenticated
      using (bucket_id = 'soportes'
             and ((storage.foldername(name))[1] = 'demo'
                  or (storage.foldername(name))[1] in (select private.ips_visibles())))
  $p$;

  execute $p$
    create policy soportes_cargue on storage.objects
      for insert to authenticated
      with check (bucket_id = 'soportes'
                  and private.tiene_rol(array['PROVEEDOR', 'USUARIO_UNIVERSAL'])
                  and (storage.foldername(name))[1] in (select private.ips_visibles()))
  $p$;

  execute $p$
    create policy soportes_retiro on storage.objects
      for delete to authenticated
      using (bucket_id = 'soportes'
             and (storage.foldername(name))[1] in (select private.ips_visibles()))
  $p$;
end
$$;
