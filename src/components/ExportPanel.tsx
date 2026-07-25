import { useMemo, useRef, useState } from 'react'
import { useStore, useWorkspace } from '../lib/store'
import {
  androidIntent,
  bridgeSnippet,
  download,
  parseProfile,
  profileJson,
  slug,
  unityApplier,
  workspaceReport,
} from '../lib/exporters'
import { copyText } from '../lib/clipboard'
import { Card, Segmented } from './ui'

type Target = 'json' | 'unity' | 'bridge' | 'report' | 'adb'

const TARGETS: { value: Target; label: string; file: (s: string) => string; mime: string }[] = [
  { value: 'json', label: 'Profile JSON', file: (s) => `${s}.json`, mime: 'application/json' },
  {
    value: 'unity',
    label: 'Unity C#',
    file: () => 'RayNeoWorkspaceApplier.cs',
    mime: 'text/plain',
  },
  { value: 'bridge', label: 'Bridge ops', file: (s) => `${s}-bridge.md`, mime: 'text/markdown' },
  { value: 'report', label: 'Report', file: (s) => `${s}-report.md`, mime: 'text/markdown' },
  { value: 'adb', label: 'adb', file: (s) => `${s}-push.sh`, mime: 'text/x-shellscript' },
]

/**
 * Export and import.
 *
 * The Unity target is the one that closes the loop: it emits a `MonoBehaviour`
 * that makes the real `NativeModule` calls and rebuilds the panels as world-space
 * quads, so a workspace designed here actually renders on the glasses rather
 * than staying a diagram.
 */
export function ExportPanel() {
  const profile = useStore((s) => s.profile)
  const ws = useWorkspace()
  const importProfile = useStore((s) => s.importProfile)
  const resetProfile = useStore((s) => s.resetProfile)
  const setProfileName = useStore((s) => s.setProfileName)
  const [target, setTarget] = useState<Target>('json')
  const [copied, setCopied] = useState(false)
  const [error, setError] = useState<string>()
  const fileRef = useRef<HTMLInputElement>(null)

  const content = useMemo(() => {
    switch (target) {
      case 'json':
        return profileJson(profile)
      case 'unity':
        return unityApplier(profile)
      case 'bridge':
        return bridgeSnippet(profile)
      case 'report':
        return workspaceReport(profile, ws)
      case 'adb':
        return androidIntent(profile)
    }
  }, [target, profile, ws])

  const spec = TARGETS.find((t) => t.value === target)!
  const filename = spec.file(slug(profile.name))

  const onImport = async (file: File) => {
    setError(undefined)
    try {
      const text = await file.text()
      importProfile(parseProfile(text))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  return (
    <div className="space-y-3">
      <Card title="Profile">
        <div className="space-y-2">
          <label className="block">
            <span className="label">Name</span>
            <input
              className="input mt-1"
              value={profile.name}
              onChange={(e) => setProfileName(e.target.value)}
            />
          </label>
          <p className="num text-[11px] text-ink-500">
            {profile.workspaces.length} workspaces ·{' '}
            {profile.workspaces.reduce((n, w) => n + w.panels.length, 0)} panels ·{' '}
            {profile.workspaces.reduce((n, w) => n + w.views.length, 0)} views · saved{' '}
            {new Date(profile.updatedAt).toLocaleTimeString()}
          </p>
          <div className="flex gap-1.5">
            <button className="btn flex-1" onClick={() => fileRef.current?.click()}>
              Import JSON
            </button>
            <button
              className="btn btn-danger"
              onClick={() => {
                if (
                  confirm(
                    'Replace everything with the built-in workspaces? Your current profile will be lost.',
                  )
                ) {
                  resetProfile()
                }
              }}
            >
              Reset to defaults
            </button>
          </div>
          <input
            ref={fileRef}
            type="file"
            accept=".json,application/json"
            className="hidden"
            onChange={(e) => {
              const f = e.target.files?.[0]
              if (f) void onImport(f)
              e.target.value = ''
            }}
          />
          {error && (
            <p className="text-[11px] text-[var(--color-danger)]">Import failed: {error}</p>
          )}
          <p className="text-[11px] leading-snug text-ink-600">
            Everything is stored in this browser only — nothing is uploaded anywhere.
            Export the JSON if you want a copy you can keep or move to another machine.
          </p>
        </div>
      </Card>

      <Card
        title="Export"
        right={
          <div className="flex gap-1.5">
            <button
              className="btn btn-sm"
              onClick={async () => {
                const result = await copyText(content)
                if (result.ok) {
                  setCopied(true)
                  setError(undefined)
                  setTimeout(() => setCopied(false), 1400)
                  return
                }
                // Clipboard access can be blocked for reasons the user cannot
                // act on — a file:// origin, an unfocused document, a denied
                // permission. Saving the file is always available, so do that
                // rather than leaving them with a dead end.
                download(filename, content, spec.mime)
                setError(
                  `Clipboard was blocked (${result.reason}) so ${filename} was downloaded instead.`,
                )
              }}
            >
              {copied ? 'Copied' : 'Copy'}
            </button>
            <button
              className="btn btn-sm btn-primary"
              onClick={() => download(filename, content, spec.mime)}
            >
              Download
            </button>
          </div>
        }
      >
        <div className="space-y-2">
          <Segmented
            value={target}
            options={TARGETS.map((t) => ({ value: t.value, label: t.label }))}
            onChange={setTarget}
          />
          <p className="text-[11px] leading-snug text-ink-500">{describe(target)}</p>
          <pre className="num max-h-[46vh] overflow-auto rounded-md border border-ink-800 bg-ink-950 p-2.5 text-[10.5px] leading-relaxed text-ink-300">
            {content}
          </pre>
          <p className="num text-[10.5px] text-ink-600">
            {filename} · {content.length.toLocaleString()} bytes
          </p>
        </div>
      </Card>
    </div>
  )
}

function describe(t: Target) {
  switch (t) {
    case 'json':
      return 'The whole profile, re-importable here. This is the portable source of truth.'
    case 'unity':
      return 'A MonoBehaviour for a Unity project with the RayNeo Air SDK imported. Device settings go out as real NativeModule calls; each panel becomes a world-space quad at the baked position and size. Geometry is pre-converted to Unity’s left-handed, +Z-forward space.'
    case 'bridge':
      return 'The exact JSON frames this profile would send over the companion bridge, alongside the SDK call each one resolves to. Useful when writing or debugging a companion.'
    case 'report':
      return 'A readable summary of the active workspace with the analysis figures — for sharing a layout or keeping a record of what changed.'
    case 'adb':
      return 'A shell snippet for pushing the profile to an Android companion over adb.'
  }
}
