/**
 * Reglas de acceso y de negocio que la interfaz necesita conocer.
 *
 * La autoridad es la base de datos: la RLS y las funciones RPC de
 * supabase/migrations aplican estas mismas reglas en el servidor. Este módulo
 * sólo evita un viaje al servidor para decidir qué pintar (menú, botones), y
 * sus pruebas fijan que ambos lados digan lo mismo.
 */

export const ROLES = {
  PROVEEDOR: 'PROVEEDOR',
  AUDITOR: 'AUDITOR',
  ADMINISTRADOR: 'ADMINISTRADOR',
  UNIVERSAL: 'USUARIO_UNIVERSAL'
} as const;

export type Rol = (typeof ROLES)[keyof typeof ROLES];
export type RolAutorizado = Rol | '*';

/** Precedencia para elegir el rol principal cuando el usuario tiene varios. */
export const PRECEDENCIA_ROLES: readonly Rol[] = ['USUARIO_UNIVERSAL', 'ADMINISTRADOR', 'AUDITOR', 'PROVEEDOR'];

/** Únicos roles que suben o eliminan soportes en el Portal; el resto entra en solo lectura. */
export const ROLES_ESCRITURA_PORTAL: readonly Rol[] = ['PROVEEDOR', 'USUARIO_UNIVERSAL'];

/** Expediente de vinculación: el auditor queda fuera a propósito (contrato, datos bancarios). */
export const ROLES_VINCULACION: readonly Rol[] = ['ADMINISTRADOR', 'USUARIO_UNIVERSAL'];

/** Panel de licencias: lectura de red, no de sede. */
export const ROLES_LICENCIAS: readonly Rol[] = ['AUDITOR', 'ADMINISTRADOR', 'USUARIO_UNIVERSAL'];
export const ROLES_VETADOS_LICENCIAS: readonly Rol[] = ['PROVEEDOR'];

/** La vitrina comercial es pública, pero la IPS aliada no debe ver el estado de las demás sedes. */
export const ROLES_VETADOS_COMERCIAL: readonly Rol[] = ['PROVEEDOR'];

/** Quién puede sacar un correo a nombre de la red. */
export const ROLES_NOTIFICAN: readonly Rol[] = ['ADMINISTRADOR', 'USUARIO_UNIVERSAL'];

export type Vista = 'portal' | 'auditoria' | 'dashboard' | 'documentos' | 'comercial' | 'vinculacion' | 'licencias';

export interface DefinicionVista {
  titulo: string;
  modulo: number;
  roles: readonly RolAutorizado[];
  /** Roles con la vista prohibida. Se evalúa primero y gana siempre, incluso sobre '*'. */
  vetados?: readonly Rol[];
}

export const VISTAS: Record<Vista, DefinicionVista> = {
  portal:      { modulo: 1, titulo: 'Portal de la IPS', roles: ['PROVEEDOR', 'AUDITOR', 'ADMINISTRADOR', 'USUARIO_UNIVERSAL'] },
  auditoria:   { modulo: 2, titulo: 'Panel de auditoría', roles: ['AUDITOR', 'ADMINISTRADOR', 'USUARIO_UNIVERSAL'] },
  dashboard:   { modulo: 3, titulo: 'Dashboard ejecutivo', roles: ['ADMINISTRADOR', 'USUARIO_UNIVERSAL'] },
  documentos:  { modulo: 4, titulo: 'Dashboard por documento', roles: ['ADMINISTRADOR', 'USUARIO_UNIVERSAL'] },
  comercial:   { modulo: 5, titulo: 'Panel comercial', roles: ['*'], vetados: ROLES_VETADOS_COMERCIAL },
  vinculacion: { modulo: 6, titulo: 'Panel de vinculación', roles: ROLES_VINCULACION },
  licencias:   { modulo: 7, titulo: 'Licencias médicas', roles: ROLES_LICENCIAS, vetados: ROLES_VETADOS_LICENCIAS }
};

/** Vista de aterrizaje tras el login, según el rol principal. */
export const VISTA_INICIAL_POR_ROL: Record<Rol, Vista> = {
  USUARIO_UNIVERSAL: 'dashboard',
  ADMINISTRADOR: 'dashboard',
  AUDITOR: 'auditoria',
  PROVEEDOR: 'portal'
};

/** Valores por defecto de la tabla `parametros`. */
export const PARAMETROS = {
  diasAlertaAmarilla: 90,
  diasAlertaRoja: 30,
  vigenciaPorDefectoMeses: 12
} as const;

export const ETIQUETAS_VIGENCIA = {
  vigente: 'Documento vigente',
  actualizacion: 'Próximo a Vencer',
  vencido: 'Vencido',
  pendiente: 'Pendiente',
  inactivo: 'Inactivo'
} as const;

export type ClaveVigencia = keyof typeof ETIQUETAS_VIGENCIA;

export type EstadoAuditoria = 'Pendiente' | 'Aprobado' | 'Rechazado' | 'Historico' | 'Duplicado' | 'Inactivo';
