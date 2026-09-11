import {
  PRECEDENCIA_ROLES,
  ROLES_ESCRITURA_PORTAL,
  VISTA_INICIAL_POR_ROL,
  VISTAS,
  type Rol,
  type RolAutorizado,
  type Vista
} from './config';

/** Lo mínimo de la sesión (RPC `mi_sesion`) que deciden los permisos. */
export interface SesionAcceso {
  rol: Rol | '';
  roles: readonly Rol[];
}

const rolesDe = (sesion: SesionAcceso | null | undefined): readonly Rol[] =>
  sesion?.roles?.length ? sesion.roles : sesion?.rol ? [sesion.rol] : [];

/** ¿Alguno de los roles de la sesión está autorizado? '*' = cualquiera, incluso anónimo. */
export function tieneAlguno(sesion: SesionAcceso | null | undefined, autorizados: readonly RolAutorizado[]): boolean {
  if (autorizados.includes('*')) return true;
  return rolesDe(sesion).some((r) => autorizados.includes(r));
}

/** El veto gana siempre: basta con que UNO de los roles esté vetado. */
export function estaVetado(sesion: SesionAcceso | null | undefined, vetados: readonly Rol[] = []): boolean {
  return rolesDe(sesion).some((r) => vetados.includes(r));
}

export function puedeVer(sesion: SesionAcceso | null | undefined, vista: Vista): boolean {
  const def = VISTAS[vista];
  if (estaVetado(sesion, def.vetados)) return false;
  if (def.roles.includes('*')) return true;
  if (!sesion?.rol) return false;
  return tieneAlguno(sesion, def.roles);
}

/** Vistas visibles en el menú, en el orden de los módulos. */
export function vistasPermitidas(sesion: SesionAcceso | null | undefined): Vista[] {
  return (Object.keys(VISTAS) as Vista[])
    .filter((v) => puedeVer(sesion, v))
    .sort((a, b) => VISTAS[a].modulo - VISTAS[b].modulo);
}

/** Vista de aterrizaje. Si la del rol no le corresponde, la primera permitida. */
export function vistaInicial(sesion: SesionAcceso | null | undefined): Vista | null {
  if (!sesion?.rol) return null;
  const destino = VISTA_INICIAL_POR_ROL[sesion.rol];
  return puedeVer(sesion, destino) ? destino : vistasPermitidas(sesion)[0] ?? null;
}

/** Rol de mayor alcance entre los del usuario. */
export function rolPrincipal(roles: readonly Rol[]): Rol | '' {
  return PRECEDENCIA_ROLES.find((r) => roles.includes(r)) ?? roles[0] ?? '';
}

/** Auditor y administrador entran al portal en SOLO LECTURA. */
export function puedeCargar(sesion: SesionAcceso | null | undefined): boolean {
  return tieneAlguno(sesion, ROLES_ESCRITURA_PORTAL);
}
