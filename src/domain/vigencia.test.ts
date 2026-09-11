import { describe, expect, it } from 'vitest';
import { clasificarVigencia, diasRestantes, requiereActualizacion } from './vigencia';

const hoy = new Date(2026, 8, 10); // 10-sep-2026
const clave = (fecha: string | null, indicador = '') => clasificarVigencia(fecha, indicador, { hoy }).clave;

describe('clasificarVigencia', () => {
  it('fronteras de la ventana amarilla (90 días)', () => {
    expect(clave('2026-09-09')).toBe('vencido');       // ayer
    expect(clave('2026-09-10')).toBe('actualizacion'); // hoy todavía no vence
    expect(clave('2026-12-09')).toBe('actualizacion'); // día 90
    expect(clave('2026-12-10')).toBe('vigente');       // día 91
  });

  it('la marca Inactivo se decide antes que cualquier fecha', () => {
    expect(clave('2020-01-01', 'Inactivo')).toBe('inactivo');
  });

  it('sin fecha, usa el Indicador heredado (tolerando tildes y mayúsculas)', () => {
    expect(clave(null, 'Vencido')).toBe('vencido');
    expect(clave(null, 'PRÓXIMO A VENCER')).toBe('actualizacion');
    expect(clave(null, 'Documento vigente')).toBe('vigente');
    expect(clave(null, '')).toBe('pendiente');
  });

  it('la fecha manda sobre el Indicador', () => {
    expect(clave('2030-01-01', 'Vencido')).toBe('vigente');
  });

  it('devuelve la etiqueta y los días', () => {
    expect(clasificarVigencia('2026-09-20', '', { hoy })).toEqual({ clave: 'actualizacion', etiqueta: 'Próximo a Vencer', dias: 10 });
  });
});

describe('diasRestantes', () => {
  it('ignora fechas mal formadas', () => {
    expect(diasRestantes('10/09/2026', hoy)).toBeNull();
    expect(diasRestantes(undefined, hoy)).toBeNull();
  });
});

describe('requiereActualizacion', () => {
  it('sólo un soporte aprobado vencido o por vencer se actualiza', () => {
    expect(requiereActualizacion('Aprobado', 'vencido')).toBe(true);
    expect(requiereActualizacion('Aprobado', 'actualizacion')).toBe(true);
    expect(requiereActualizacion('Aprobado', 'vigente')).toBe(false);
    expect(requiereActualizacion('Pendiente', 'vencido')).toBe(false);
  });
});
