import { ETIQUETAS_VIGENCIA, PARAMETROS, type ClaveVigencia, type EstadoAuditoria } from './config';

/**
 * Espejo en TypeScript de `public.clasificar_vigencia` (0002_logica.sql), para
 * clasificar en el navegador lo que el usuario está editando antes de guardar.
 */

const DIA_MS = 86_400_000;

export interface Vigencia {
  clave: ClaveVigencia;
  etiqueta: string;
  /** Días hasta el vencimiento (negativo = vencido). Nulo si no hay fecha. */
  dias: number | null;
}

interface Opciones {
  hoy?: Date;
  diasAlertaAmarilla?: number;
}

/** Días entre hoy y una fecha 'yyyy-mm-dd', comparando fechas de calendario. */
export function diasRestantes(fecha: string | null | undefined, hoy: Date = new Date()): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(fecha ?? '');
  if (!m) return null;
  const objetivo = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  const base = Date.UTC(hoy.getFullYear(), hoy.getMonth(), hoy.getDate());
  return Math.round((objetivo - base) / DIA_MS);
}

const normalizar = (t: string | null | undefined) =>
  (t ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').trim().toLowerCase().replace(/\s+/g, ' ');

const resultado = (clave: ClaveVigencia, dias: number | null = null): Vigencia =>
  ({ clave, etiqueta: ETIQUETAS_VIGENCIA[clave], dias });

export function clasificarVigencia(
  fechaVencimiento: string | null | undefined,
  indicador: string | null | undefined = '',
  { hoy = new Date(), diasAlertaAmarilla = PARAMETROS.diasAlertaAmarilla }: Opciones = {}
): Vigencia {
  const ind = normalizar(indicador);
  if (ind === 'inactivo') return resultado('inactivo');

  const dias = diasRestantes(fechaVencimiento, hoy);
  if (dias !== null) {
    if (dias < 0) return resultado('vencido', dias);
    if (dias <= diasAlertaAmarilla) return resultado('actualizacion', dias);
    return resultado('vigente', dias);
  }

  if (ind === 'vencido') return resultado('vencido');
  if (ind === 'proximo a vencer') return resultado('actualizacion');
  if (ind === 'documento vigente') return resultado('vigente');
  return resultado('pendiente');
}

/**
 * ¿El soporte debe reemplazarse? Regla única del botón «Actualizar» del
 * Portal: un soporte APROBADO cuya vigencia expiró o está por expirar.
 */
export function requiereActualizacion(estadoAuditoria: EstadoAuditoria, vigencia: ClaveVigencia): boolean {
  return estadoAuditoria === 'Aprobado' && (vigencia === 'vencido' || vigencia === 'actualizacion');
}
