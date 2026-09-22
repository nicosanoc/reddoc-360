-- =============================================================================
-- RedDoc 360 · 0002 · Endurecer seguridad
--
-- Cierra los avisos del linter de Supabase sobre el baseline 0001: los 4
-- helpers de sesión eran SECURITY DEFINER y quedaban expuestos como endpoints
-- REST (/rest/v1/rpc/...). Se mueven a un esquema `private` que PostgREST no
-- publica; siguen usándose desde las políticas RLS.
--
-- (Mantener 0001 + 0002 por separado documenta la evolución real: el baseline
-- reproduce el estado que se construyó primero, y esta migración lo endurece.)
-- =============================================================================

create schema if not exists private;
grant usage on schema private to authenticated;

-- Mismos cuerpos que en 0001, pero en `private` y con las llamadas internas
-- entre helpers también apuntando a `private`.
create or replace function private.tiene_rol(p_rol public.rol_usuario)
  returns boolean language sql stable security definer set search_path to ''
as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and activo and p_rol = any(roles));
$$;

create or replace function private.es_universal()
  returns boolean language sql stable security definer set search_path to ''
as $$ select private.tiene_rol('USUARIO_UNIVERSAL'); $$;

create or replace function private.mi_ips()
  returns uuid language sql stable security definer set search_path to ''
as $$ select ips_id from public.perfiles where id = auth.uid() and activo; $$;

create or replace function private.mis_regionales()
  returns setof smallint language plpgsql stable security definer set search_path to ''
as $$
begin
  if private.es_universal() then
    return query select id from public.regionales;
  else
    return query select regional_id from public.perfil_regionales where perfil_id = auth.uid();
  end if;
end;
$$;

grant execute on function
  private.tiene_rol(public.rol_usuario), private.es_universal(),
  private.mi_ips(), private.mis_regionales()
to authenticated;

-- Recrear las políticas que usaban los helpers, ahora apuntando a private.*
-- (mismo criterio de acceso, solo cambia el esquema de las funciones).
drop policy "ver ips segun alcance" on public.ips;
create policy "ver ips segun alcance" on public.ips for select to authenticated
  using (private.es_universal() or (regional_id in (select private.mis_regionales())) or (id = private.mi_ips()));

drop policy "ver mi perfil" on public.perfiles;
create policy "ver mi perfil" on public.perfiles for select to authenticated
  using ((id = (select auth.uid())) or private.es_universal() or private.tiene_rol('ADMINISTRADOR'));

drop policy "ver mis regionales" on public.perfil_regionales;
create policy "ver mis regionales" on public.perfil_regionales for select to authenticated
  using ((perfil_id = (select auth.uid())) or private.es_universal() or private.tiene_rol('ADMINISTRADOR'));

drop policy "ver soportes" on public.soportes;
create policy "ver soportes" on public.soportes for select to authenticated
  using (private.es_universal() or (ips_id = private.mi_ips())
    or (ips_id in (select ips.id from public.ips where ips.regional_id in (select private.mis_regionales()))));

drop policy "cargar soporte" on public.soportes;
create policy "cargar soporte" on public.soportes for insert to authenticated
  with check ((private.tiene_rol('PROVEEDOR') and (ips_id = private.mi_ips()) and (estado = 'Pendiente')) or private.es_universal());

drop policy "auditar soporte" on public.soportes;
create policy "auditar soporte" on public.soportes for update to authenticated
  using (private.es_universal() or ((private.tiene_rol('AUDITOR') or private.tiene_rol('ADMINISTRADOR'))
    and (ips_id in (select ips.id from public.ips where ips.regional_id in (select private.mis_regionales())))))
  with check (private.es_universal() or ((private.tiene_rol('AUDITOR') or private.tiene_rol('ADMINISTRADOR'))
    and (ips_id in (select ips.id from public.ips where ips.regional_id in (select private.mis_regionales())))));

drop policy "inactivar requisito" on public.requisitos_inactivos;
create policy "inactivar requisito" on public.requisitos_inactivos for insert to authenticated
  with check ((private.tiene_rol('PROVEEDOR') and (ips_id = private.mi_ips())) or private.es_universal());

drop policy "reactivar requisito" on public.requisitos_inactivos;
create policy "reactivar requisito" on public.requisitos_inactivos for delete to authenticated
  using ((private.tiene_rol('PROVEEDOR') and (ips_id = private.mi_ips())) or private.es_universal());

drop policy "insertar modificaciones" on public.modificaciones;
create policy "insertar modificaciones" on public.modificaciones for insert to authenticated
  with check ((ips_id = private.mi_ips()) or private.es_universal());

-- Ya sin dependencias: retirar los helpers del esquema expuesto.
drop function public.mis_regionales();
drop function public.es_universal();
drop function public.mi_ips();
drop function public.tiene_rol(public.rol_usuario);
