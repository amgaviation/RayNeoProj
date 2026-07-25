/**
 * Fold the offline build into one self-contained HTML file.
 *
 * Produces `download/RayNeo-Air4Pro-Configurator.html`: no server, no network,
 * no sibling files. Download it, double-click it, and it runs.
 *
 * Vite's intermediates go to `dist-offline/` (ignored by git); only the finished
 * single file lands in `download/`, which is committed so it can be grabbed
 * straight from the repository without a build step.
 *
 * Run after `vite build --config vite.config.offline.ts`, or just use
 * `npm run build:offline`.
 */

import { readFileSync, writeFileSync, rmSync, mkdirSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const outDir = join(here, '..', 'dist-offline')
const downloadDir = join(here, '..', 'download')
const OUT_NAME = 'RayNeo-Air4Pro-Configurator.html'

const htmlPath = join(outDir, 'index.html')
if (!existsSync(htmlPath)) {
  console.error(
    'dist-offline/index.html not found. Run: vite build --config vite.config.offline.ts',
  )
  process.exit(1)
}

let html = readFileSync(htmlPath, 'utf8')

/**
 * A closing script tag inside the bundle would terminate the inline block early.
 * The sequence can legitimately appear inside a JS string literal, so it is
 * split rather than removed — `<\/script` is identical to `</script` to a JS
 * parser but invisible to the HTML tokenizer.
 */
const safeForInlineScript = (js) => js.replace(/<\/script/gi, '<\\/script')

let inlinedJs = 0
let inlinedCss = 0

// Inline stylesheets.
html = html.replace(
  /<link[^>]+rel=["']stylesheet["'][^>]*href=["']([^"']+)["'][^>]*>/gi,
  (whole, href) => {
    const file = join(outDir, href.replace(/^\.?\//, ''))
    if (!existsSync(file)) return whole
    inlinedCss++
    return `<style>\n${readFileSync(file, 'utf8')}\n</style>`
  },
)

/*
 * Inline scripts, and move them to the end of <body>.
 *
 * Both parts matter. `type="module"` is dropped because the offline config emits
 * an IIFE and a classic script is what works from file://. But a classic inline
 * script executes the moment it is parsed, and `defer` does nothing for inline
 * code — so left in <head> where Vite puts it, the bundle would run before
 * #root exists and the app would never mount. Relocating restores the
 * after-the-DOM ordering a module script gave us for free.
 */
const bodies = []
html = html.replace(
  /<script[^>]*src=["']([^"']+)["'][^>]*><\/script>/gi,
  (whole, src) => {
    const file = join(outDir, src.replace(/^\.?\//, ''))
    if (!existsSync(file)) return whole
    inlinedJs++
    bodies.push(safeForInlineScript(readFileSync(file, 'utf8')))
    return ''
  },
)

if (bodies.length > 0) {
  const block = bodies.map((js) => `<script>\n${js}\n</script>`).join('\n')
  const closing = '</body>'
  const at = html.lastIndexOf(closing)
  // Spliced by index rather than String.replace on purpose. In a replacement
  // *string*, `$&`, `` $` ``, `$'` and `$1` are substitution patterns — and
  // minified JavaScript is full of those sequences. Passing the bundle as a
  // replacement silently re-injected the whole preceding document (via `` $` ``)
  // and corrupted the script into a syntax error.
  html =
    at === -1
      ? `${html}\n${block}`
      : `${html.slice(0, at)}${block}\n${html.slice(at)}`
}

if (inlinedJs === 0) {
  console.error('No script tag was inlined — the build output is not what was expected.')
  process.exit(1)
}

// A page opened from file:// has no server to consult about crossorigin, and
// leftover attributes only cause warnings.
html = html.replace(/\s+crossorigin(=["'][^"']*["'])?/gi, '')

// Fail loudly rather than shipping a "single" file that still needs siblings.
//
// The scan has to ignore the inlined script and style bodies. Bundled
// JavaScript is full of strings that look like markup — three.js alone builds
// several `src="..."` fragments at runtime — and matching those produced false
// positives that failed the build on a perfectly good file.
const markupOnly = html
  .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '<script></script>')
  .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '<style></style>')

const leftovers = [...markupOnly.matchAll(/(?:src|href)=["']([^"']+)["']/gi)]
  .map((m) => m[1])
  .filter((u) => !/^(data:|https?:|#|mailto:)/i.test(u))
if (leftovers.length > 0) {
  console.error(`Unresolved external references remain: ${leftovers.join(', ')}`)
  process.exit(1)
}

mkdirSync(downloadDir, { recursive: true })
const outPath = join(downloadDir, OUT_NAME)
writeFileSync(outPath, html, 'utf8')

// Drop the intermediates; the finished file is the only thing worth keeping.
for (const f of ['index.html', 'app.js', 'app.css']) {
  const p = join(outDir, f)
  if (existsSync(p)) rmSync(p)
}

const kb = (readFileSync(outPath).byteLength / 1024).toFixed(0)
console.log(`wrote ${outPath}`)
console.log(`  ${kb} kB · ${inlinedJs} script(s) and ${inlinedCss} stylesheet(s) inlined`)
