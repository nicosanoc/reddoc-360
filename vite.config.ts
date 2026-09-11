import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts', 'test/**/*.test.ts'],
    // Cada archivo de pruebas de base de datos levanta su propio Postgres
    // embebido (PGlite) y aplica migraciones + seed: tarda unos segundos.
    testTimeout: 60_000,
    hookTimeout: 120_000
  }
});
