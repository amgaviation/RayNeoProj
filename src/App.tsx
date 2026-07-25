import { lazy, Suspense, useState } from 'react'
import { useStore, useView, useVisiblePanels, useWorkspace } from './lib/store'
import { useHotkeys } from './hooks/useHotkeys'
import { GlassesView } from './components/GlassesView'
import { PanelInspector } from './components/PanelInspector'
import { PanelList } from './components/PanelList'
import { ViewSwitcher, ViewTabs } from './components/ViewSwitcher'
import { DeviceConsole } from './components/DeviceConsole'
import { Advisories } from './components/Advisories'
import { BindingsEditor } from './components/BindingsEditor'
import { ConnectPanel } from './components/ConnectPanel'
import { ExportPanel } from './components/ExportPanel'
import { WorkspacePicker } from './components/WorkspacePicker'
import { ErrorBoundary } from './components/ErrorBoundary'
import { Segmented } from './components/ui'
import type { PreviewMode } from './lib/store'

/**
 * three.js is the bulk of the bundle and only the 3D preview needs it, so it is
 * split out. The glasses preview is pure SVG and paints immediately.
 */
const SceneView = lazy(() =>
  import('./components/SceneView').then((m) => ({ default: m.SceneView })),
)

function ScenePane() {
  return (
    <ErrorBoundary label="The 3D view">
      <Suspense
        fallback={
          <div className="grid h-full place-items-center text-[12px] text-ink-600">
            loading 3D view…
          </div>
        }
      >
        <SceneView />
      </Suspense>
    </ErrorBoundary>
  )
}

type Tab = 'layout' | 'views' | 'device' | 'keys' | 'connect' | 'export'

const TABS: { value: Tab; label: string }[] = [
  { value: 'layout', label: 'Layout' },
  { value: 'views', label: 'Views' },
  { value: 'device', label: 'Device' },
  { value: 'keys', label: 'Keys' },
  { value: 'connect', label: 'Connect' },
  { value: 'export', label: 'Export' },
]

export default function App() {
  useHotkeys()
  const [tab, setTab] = useState<Tab>('layout')
  const previewMode = useStore((s) => s.previewMode)
  const setPreviewMode = useStore((s) => s.setPreviewMode)
  const focusMode = useStore((s) => s.profile.focusMode)
  const toggleFocusMode = useStore((s) => s.toggleFocusMode)
  const connection = useStore((s) => s.connection)
  const recenter = useStore((s) => s.recenter)
  const workspace = useWorkspace()

  return (
    <div className="flex h-full flex-col bg-ink-950">
      <TopBar />

      <div className="flex min-h-0 flex-1">
        {/* Left rail: what am I editing */}
        <aside className="hidden w-[260px] shrink-0 overflow-y-auto border-r border-ink-850 p-3 lg:block">
          <div className="space-y-3">
            <WorkspacePicker />
            <Advisories />
          </div>
        </aside>

        {/* Centre: previews */}
        <main className="flex min-w-0 flex-1 flex-col">
          <div className="flex flex-wrap items-center gap-2 border-b border-ink-850 px-3 py-2">
            <div className="min-w-0 flex-1">
              <ViewTabs />
            </div>
            <Segmented<PreviewMode>
              value={previewMode}
              options={[
                { value: 'glasses', label: 'Through glasses' },
                { value: 'scene', label: '3D' },
                { value: 'split', label: 'Split' },
              ]}
              onChange={setPreviewMode}
            />
            <button
              className={`btn btn-sm ${focusMode ? 'btn-primary' : ''}`}
              onClick={toggleFocusMode}
              title="Dim everything except the focused panel (F)"
            >
              Focus mode
            </button>
            <button className="btn btn-sm" onClick={recenter} title="Recentre (R)">
              Recentre
            </button>
          </div>

          <div className="min-h-0 flex-1">
            {previewMode === 'glasses' && <GlassesView />}
            {previewMode === 'scene' && <ScenePane />}
            {previewMode === 'split' && (
              <div className="grid h-full grid-rows-2 divide-y divide-ink-850">
                <div className="min-h-0">
                  <GlassesView compact />
                </div>
                <div className="min-h-0">
                  <ScenePane />
                </div>
              </div>
            )}
          </div>

          <div className="flex items-center justify-between gap-3 border-t border-ink-850 px-3 py-1.5 text-[11px] text-ink-600">
            <span className="truncate">
              {workspace.name}
              {workspace.description ? ` — ${workspace.description}` : ''}
            </span>
            <span className="num shrink-0">
              {connection === 'connected' ? 'live device' : 'simulated device'}
            </span>
          </div>
        </main>

        {/* Right rail: controls */}
        <aside className="flex w-full max-w-[380px] shrink-0 flex-col border-l border-ink-850 md:w-[340px] xl:w-[380px]">
          <nav className="flex gap-0.5 overflow-x-auto border-b border-ink-850 px-2 py-1.5">
            {TABS.map((t) => (
              <button
                key={t.value}
                onClick={() => setTab(t.value)}
                className={`shrink-0 rounded-md px-2.5 py-1 text-[12.5px] font-medium transition-colors ${
                  tab === t.value
                    ? 'bg-ink-700 text-ink-100'
                    : 'text-ink-400 hover:bg-ink-850 hover:text-ink-100'
                }`}
              >
                {t.label}
              </button>
            ))}
          </nav>
          <div className="min-h-0 flex-1 overflow-y-auto p-3">
            {tab === 'layout' && (
              <div className="space-y-3">
                <PanelList />
                <PanelInspector />
              </div>
            )}
            {tab === 'views' && <ViewSwitcher />}
            {tab === 'device' && <DeviceConsole />}
            {tab === 'keys' && <BindingsEditor />}
            {tab === 'connect' && <ConnectPanel />}
            {tab === 'export' && <ExportPanel />}
          </div>
        </aside>
      </div>
    </div>
  )
}

function TopBar() {
  const profile = useStore((s) => s.profile)
  const connection = useStore((s) => s.connection)
  const view = useView()
  const visible = useVisiblePanels()

  const dot =
    connection === 'connected'
      ? 'var(--color-good)'
      : connection === 'error'
        ? 'var(--color-danger)'
        : connection === 'connecting'
          ? 'var(--color-warn)'
          : 'var(--color-ink-500)'

  return (
    <header className="flex shrink-0 items-center gap-3 border-b border-ink-850 px-3 py-2">
      <div className="flex items-center gap-2">
        <div className="grid h-6 w-6 place-items-center rounded-md bg-[color-mix(in_oklab,var(--color-accent)_20%,var(--color-ink-800))]">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" aria-hidden>
            <path
              d="M3 9h18M6 9v6a3 3 0 0 0 3 3h1.5L12 15l1.5 3H15a3 3 0 0 0 3-3V9"
              stroke="var(--color-accent-glow)"
              strokeWidth="1.7"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </div>
        <div className="leading-tight">
          <h1 className="text-[13px] font-semibold text-ink-100">
            Air 4 Pro Workspace Configurator
          </h1>
          <p className="num text-[10.5px] text-ink-500">{profile.name}</p>
        </div>
      </div>

      <div className="ml-auto flex items-center gap-2">
        <span className="chip hidden sm:inline-flex">
          {view?.name ?? '—'} · {visible.length} up
        </span>
        <span className="chip">
          <span
            className="h-1.5 w-1.5 rounded-full"
            style={{ background: dot }}
          />
          {connection}
        </span>
      </div>
    </header>
  )
}
