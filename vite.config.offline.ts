import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

/**
 * Build config for the standalone single-file version.
 *
 * Two deliberate departures from the normal build, both required for a page that
 * has to run from a `file://` URL with no server:
 *
 * - `format: 'iife'` — a `<script type="module">` is subject to CORS even when
 *   inlined in some browsers, and module *files* cannot be fetched from
 *   `file://` at all. A classic script sidesteps both.
 * - `inlineDynamicImports` — the lazy three.js chunk has no separate file to
 *   fetch in a single-file build, so it has to be folded into the one bundle.
 *
 * Sourcemaps are off: they would be a second file, which defeats the point.
 */
export default defineConfig({
  plugins: [react(), tailwindcss()],
  base: './',
  // Note: do NOT add `define: { 'import.meta': '{}' }` to silence the
  // EMPTY_IMPORT_META warnings from Vite's module-preload helper. That define
  // also swallows Vite's own `import.meta.env` substitution, so `import.meta.env
  // .MODE` compiles to `{}.env.MODE` and throws before the app can mount. The
  // warnings are harmless — with dynamic imports inlined, the preload helper is
  // never reached.
  build: {
    outDir: 'dist-offline',
    sourcemap: false,
    // Everything ends up inlined by scripts/build-offline.mjs, so let Vite emit
    // one JS file and one CSS file rather than hashing and splitting them.
    assetsInlineLimit: 100_000_000,
    cssCodeSplit: false,
    rollupOptions: {
      output: {
        format: 'iife',
        inlineDynamicImports: true,
        entryFileNames: 'app.js',
        assetFileNames: 'app[extname]',
      },
    },
  },
})
