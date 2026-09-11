import { VISTAS, type Vista } from './domain/config';
import { supabaseConfigurado } from './lib/supabase';

// Shell provisional: la interfaz de los módulos llega en la Fase B.
export default function App() {
  return (
    <main className="min-h-screen bg-slate-50 font-sans text-slate-800">
      <div className="mx-auto max-w-3xl px-6 py-16">
        <p className="text-sm font-semibold tracking-widest text-marca-500 uppercase">RedDoc 360</p>
        <h1 className="mt-2 text-3xl font-bold text-marca-900">Gestión documental de red de IPS aliadas</h1>
        <p className="mt-4 text-slate-600">
          Portal de cargue, auditoría y tableros de cumplimiento con control de acceso por rol y regional,
          aplicado en PostgreSQL con Row Level Security.
        </p>

        <ol className="mt-10 grid gap-3 sm:grid-cols-2">
          {(Object.keys(VISTAS) as Vista[]).map((v) => (
            <li key={v} className="rounded-xl border border-slate-200 bg-white p-4">
              <span className="text-xs font-semibold text-slate-400">Módulo {VISTAS[v].modulo}</span>
              <p className="font-medium">{VISTAS[v].titulo}</p>
            </li>
          ))}
        </ol>

        {!supabaseConfigurado && (
          <p className="mt-10 rounded-lg bg-amber-50 p-4 text-sm text-amber-800">
            Falta configurar Supabase: copie <code>.env.example</code> como <code>.env</code> y complete la URL y la anon key.
          </p>
        )}
      </div>
    </main>
  );
}
