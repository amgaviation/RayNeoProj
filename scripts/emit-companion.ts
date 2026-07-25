/**
 * Emit a reference `RayNeoWorkspaceApplier.cs` into `companion/` from the
 * built-in default profile.
 *
 * The web app generates this file on demand from whatever you have designed; the
 * checked-in copy exists so `BridgeServer.cs` has something to compile against,
 * and so the generated shape is reviewable in a diff rather than only visible at
 * runtime.
 *
 * Run: npm run emit:companion
 */

import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildDefaultProfile } from '../src/lib/presets'
import { unityApplier } from '../src/lib/exporters'

const here = dirname(fileURLToPath(import.meta.url))
const out = join(here, '..', 'companion', 'RayNeoWorkspaceApplier.cs')

const profile = buildDefaultProfile()
// The generator stamps the profile name into a header comment; use a stable one
// so regenerating does not churn the diff.
profile.name = 'Reference profile'

// Panel and view ids are normally random and time-based, which would make every
// regeneration a noisy diff. Rewrite them to deterministic slugs — and remap the
// references in each view so the output stays internally consistent.
const slugify = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')

for (const ws of profile.workspaces) {
  const idMap = new Map<string, string>()
  ws.panels.forEach((p, i) => {
    const id = `panel-${slugify(ws.name)}-${slugify(p.title) || i}`
    idMap.set(p.id, id)
    p.id = id
  })
  ws.views.forEach((v, i) => {
    const id = `view-${slugify(ws.name)}-${slugify(v.name) || i}`
    if (ws.activeViewId === v.id) ws.activeViewId = id
    v.id = id
    v.panelIds = v.panelIds.map((pid) => idMap.get(pid) ?? pid)
    if (v.focusedPanelId) v.focusedPanelId = idMap.get(v.focusedPanelId) ?? v.focusedPanelId
  })
  ws.id = `ws-${slugify(ws.name)}`
}
profile.activeWorkspaceId = profile.workspaces[0]!.id
profile.id = 'profile-reference'
// A fixed timestamp keeps the file byte-identical between runs.
profile.updatedAt = '1970-01-01T00:00:00.000Z'

writeFileSync(out, unityApplier(profile), 'utf8')
console.log(`wrote ${out}`)
