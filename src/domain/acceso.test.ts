import { describe, expect, it } from 'vitest';
import { puedeCargar, puedeVer, rolPrincipal, vistaInicial, vistasPermitidas, type SesionAcceso } from './acceso';

const sesion = (...roles: SesionAcceso['roles'][number][]): SesionAcceso => ({ rol: rolPrincipal(roles), roles });
const anonimo: SesionAcceso = { rol: '', roles: [] };

describe('vistas por rol', () => {
  it('PROVEEDOR sólo ve su portal', () => {
    expect(vistasPermitidas(sesion('PROVEEDOR'))).toEqual(['portal']);
  });

  it('AUDITOR: portal, auditoría, vitrina comercial y licencias', () => {
    expect(vistasPermitidas(sesion('AUDITOR'))).toEqual(['portal', 'auditoria', 'comercial', 'licencias']);
  });

  it('ADMINISTRADOR y USUARIO_UNIVERSAL ven los 7 módulos', () => {
    expect(vistasPermitidas(sesion('ADMINISTRADOR'))).toHaveLength(7);
    expect(vistasPermitidas(sesion('USUARIO_UNIVERSAL'))).toHaveLength(7);
  });

  it('el anónimo sólo ve la vitrina comercial', () => {
    expect(vistasPermitidas(anonimo)).toEqual(['comercial']);
  });
});

describe('vetos', () => {
  it('la vitrina es de acceso libre, pero la IPS aliada queda vetada', () => {
    expect(puedeVer(anonimo, 'comercial')).toBe(true);
    expect(puedeVer(sesion('PROVEEDOR'), 'comercial')).toBe(false);
  });

  it('el veto gana aunque otro rol del usuario autorice la vista', () => {
    expect(puedeVer(sesion('PROVEEDOR', 'AUDITOR'), 'licencias')).toBe(false);
  });

  it('el auditor no entra al expediente de vinculación', () => {
    expect(puedeVer(sesion('AUDITOR'), 'vinculacion')).toBe(false);
  });
});

describe('roles combinados', () => {
  it('"Auditor, Administrador" toma el rol de mayor alcance', () => {
    const s = sesion('AUDITOR', 'ADMINISTRADOR');
    expect(s.rol).toBe('ADMINISTRADOR');
    expect(vistaInicial(s)).toBe('dashboard');
  });

  it('vista inicial por rol', () => {
    expect(vistaInicial(sesion('AUDITOR'))).toBe('auditoria');
    expect(vistaInicial(sesion('PROVEEDOR'))).toBe('portal');
    expect(vistaInicial(anonimo)).toBeNull();
  });
});

describe('escritura en el portal', () => {
  it('sólo PROVEEDOR y USUARIO_UNIVERSAL cargan; el resto entra en solo lectura', () => {
    expect(puedeCargar(sesion('PROVEEDOR'))).toBe(true);
    expect(puedeCargar(sesion('USUARIO_UNIVERSAL'))).toBe(true);
    expect(puedeCargar(sesion('AUDITOR'))).toBe(false);
    expect(puedeCargar(sesion('ADMINISTRADOR'))).toBe(false);
  });
});
