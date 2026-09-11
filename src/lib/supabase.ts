import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const claveAnonima = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const supabaseConfigurado = Boolean(url && claveAnonima);

/**
 * Cliente único. La anon key es pública por diseño: lo que cada usuario puede
 * leer o escribir lo decide la RLS de la base, no el frontend.
 */
export const supabase = supabaseConfigurado ? createClient(url!, claveAnonima!) : null;
