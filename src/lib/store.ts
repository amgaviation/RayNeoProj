import { useMemo } from 'react'
import { create } from 'zustand'
import type {
  ActionId,
  Binding,
  DeviceSettings,
  Panel,
  Profile,
  View,
  Workspace,
} from './types'
import { buildDefaultProfile, makePanel, uid } from './presets'
import { getDevice } from './device'
import { COMFORT, clamp, rescaleForDistance } from './optics'
import { applyLayout, DEFAULT_LAYOUT_OPTIONS, pullToComfort } from './layouts'
import type { LayoutId, LayoutOptions } from './layouts'
import { DeviceBridge } from './bridge'
import type { ConnectionState, Pose } from './bridge'

const STORAGE_KEY = 'rayneo.air4pro.profile.v2'

function loadProfile(): Profile {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return buildDefaultProfile()
    const parsed = JSON.parse(raw) as Profile
    if (parsed.schemaVersion !== 2) return buildDefaultProfile()
    // Tolerate profiles written before `faceWearer` existed rather than
    // discarding someone's whole workspace over one missing field.
    for (const ws of parsed.workspaces ?? []) {
      for (const p of ws.panels ?? []) {
        if (typeof p.faceWearer !== 'boolean') p.faceWearer = true
      }
    }
    return parsed
  } catch {
    return buildDefaultProfile()
  }
}

let saveTimer: ReturnType<typeof setTimeout> | undefined
function persist(profile: Profile) {
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(profile))
    } catch {
      // Quota or a private-browsing block. Losing autosave is survivable;
      // breaking every edit is not, so this stays silent.
    }
  }, 250)
}

export type PreviewMode = 'scene' | 'glasses' | 'split'

interface StoreState {
  profile: Profile
  selectedPanelId?: string
  previewMode: PreviewMode
  layoutOptions: LayoutOptions
  /** Live head orientation, from the bridge. */
  pose: Pose
  /** Mirror real (or simulated) head motion in the previews. */
  followPose: boolean
  connection: ConnectionState
  connectionDetail?: string
  log: string[]
  bridge: DeviceBridge

  // derived helpers
  workspace(): Workspace
  view(): View
  panels(): Panel[]
  visiblePanels(): Panel[]

  // profile
  setProfileName(name: string): void
  resetProfile(): void
  importProfile(p: Profile): void
  setDeviceId(id: string): void

  // device
  setDevice(patch: Partial<DeviceSettings>): void
  recenter(): void

  // workspaces
  selectWorkspace(id: string): void
  addWorkspace(name?: string): void
  renameWorkspace(id: string, name: string): void
  deleteWorkspace(id: string): void
  duplicateWorkspace(id: string): void

  // views
  selectView(id: string): void
  selectViewByIndex(i: number): void
  nextView(): void
  prevView(): void
  addView(name?: string): void
  updateView(id: string, patch: Partial<View>): void
  deleteView(id: string): void
  duplicateView(id: string): void
  togglePanelInView(viewId: string, panelId: string): void

  // panels
  selectPanel(id?: string): void
  addPanel(seed?: Partial<Panel>): void
  updatePanel(id: string, patch: Partial<Panel>): void
  /** Move a panel, keeping its apparent size constant. */
  setPanelDistance(id: string, distanceM: number, lockApparentSize: boolean): void
  deletePanel(id: string): void
  duplicatePanel(id: string): void
  focusPanel(id: string): void
  focusNextPanel(dir?: 1 | -1): void

  // layout
  setLayoutOptions(patch: Partial<LayoutOptions>): void
  runLayout(id: LayoutId): void
  pullVisibleToComfort(): void

  // bindings
  addBinding(b?: Partial<Binding>): void
  updateBinding(id: string, patch: Partial<Binding>): void
  deleteBinding(id: string): void
  runAction(action: ActionId, arg?: string | number): void

  // ui
  setPreviewMode(m: PreviewMode): void
  setFollowPose(v: boolean): void
  toggleFocusMode(): void

  // bridge
  connect(host: string, port?: number): void
  disconnect(): void
  pushAll(): void
}

/** Mutate the profile, stamp it, persist it. */
function commit(
  set: (fn: (s: StoreState) => Partial<StoreState>) => void,
  mutate: (p: Profile) => Profile,
) {
  set((s) => {
    const next = mutate(structuredClone(s.profile))
    next.updatedAt = new Date().toISOString()
    persist(next)
    return { profile: next }
  })
}

function mapWorkspace(p: Profile, fn: (ws: Workspace) => Workspace): Profile {
  return {
    ...p,
    workspaces: p.workspaces.map((ws) =>
      ws.id === p.activeWorkspaceId ? fn(ws) : ws,
    ),
  }
}

export const useStore = create<StoreState>((set, get) => {
  const bridge = new DeviceBridge({
    onState: (state, detail) => set({ connection: state, connectionDetail: detail }),
    onPose: (pose) => {
      if (get().followPose) set({ pose })
    },
    onLog: (line) =>
      set((s) => ({ log: [...s.log.slice(-199), line] })),
  })

  return {
    profile: loadProfile(),
    previewMode: 'split',
    layoutOptions: { ...DEFAULT_LAYOUT_OPTIONS },
    pose: { yawDeg: 0, pitchDeg: 0, rollDeg: 0 },
    followPose: true,
    connection: 'simulated',
    log: [],
    bridge,

    workspace() {
      const p = get().profile
      return (
        p.workspaces.find((w) => w.id === p.activeWorkspaceId) ?? p.workspaces[0]!
      )
    },
    view() {
      const ws = get().workspace()
      return ws.views.find((v) => v.id === ws.activeViewId) ?? ws.views[0]!
    },
    panels() {
      return get().workspace().panels
    },
    visiblePanels() {
      return computeVisiblePanels(get().workspace(), get().view())
    },

    // ---------------- profile ----------------
    setProfileName(name) {
      commit(set, (p) => ({ ...p, name }))
    },
    resetProfile() {
      const next = buildDefaultProfile()
      persist(next)
      set({ profile: next, selectedPanelId: undefined })
    },
    importProfile(imported) {
      const next = { ...imported, updatedAt: new Date().toISOString() }
      persist(next)
      set({ profile: next, selectedPanelId: undefined })
    },
    setDeviceId(id) {
      commit(set, (p) => ({ ...p, deviceId: id }))
    },

    // ---------------- device ----------------
    setDevice(patch) {
      const range = getDevice(get().profile.deviceId).ipdRangeMm
      commit(set, (p) => {
        const device = { ...p.device, ...patch }
        // The SDK clamps IPD to the hardware range; do it here too so the UI
        // never shows a value the device would silently reject.
        if (patch.ipdMm !== undefined) {
          device.ipdMm = Number(clamp(patch.ipdMm, range[0], range[1]).toFixed(1))
        }
        if (patch.shade !== undefined) device.shade = clamp(patch.shade, 0, 1)
        if (patch.fovScale !== undefined) {
          device.fovScale = Math.round(clamp(patch.fovScale, -10, 10))
        }
        return { ...p, device }
      })
      const d = get().profile.device
      if (patch.luminanceMode !== undefined)
        bridge.send({ op: 'device.setLuminance', mode: d.luminanceMode })
      if (patch.ipdMm !== undefined) bridge.send({ op: 'device.setIpd', ipdMm: d.ipdMm })
      if (patch.fovScale !== undefined)
        bridge.send({ op: 'device.changeFov', scale: d.fovScale })
      if (patch.fovControlView !== undefined)
        bridge.send({ op: 'device.fovControlView', active: d.fovControlView })
      if (patch.shade !== undefined) bridge.send({ op: 'device.setShade', shade: d.shade })
      if (patch.stereo !== undefined) bridge.send({ op: 'device.setStereo', mode: d.stereo })
      if (patch.refreshRateHz !== undefined)
        bridge.send({ op: 'device.setRefreshRate', hz: d.refreshRateHz })
    },
    recenter() {
      bridge.send({ op: 'device.recenter' })
      // Recentring makes the current heading the new straight-ahead, so the
      // preview's pose returns to zero.
      set({ pose: { yawDeg: 0, pitchDeg: 0, rollDeg: 0 } })
    },

    // ---------------- workspaces ----------------
    selectWorkspace(id) {
      commit(set, (p) => ({ ...p, activeWorkspaceId: id }))
      set({ selectedPanelId: undefined })
    },
    addWorkspace(name) {
      commit(set, (p) => {
        const panel = makePanel({ title: 'Main', angularWidthDeg: 32 }, 0)
        const v: View = {
          id: uid('view'),
          name: 'Default',
          panelIds: [panel.id],
          focusedPanelId: panel.id,
          recenterOnEnter: false,
          hotkey: '1',
        }
        const ws: Workspace = {
          id: uid('ws'),
          name: name ?? `Workspace ${p.workspaces.length + 1}`,
          panels: [panel],
          views: [v],
          activeViewId: v.id,
        }
        return { ...p, workspaces: [...p.workspaces, ws], activeWorkspaceId: ws.id }
      })
    },
    renameWorkspace(id, name) {
      commit(set, (p) => ({
        ...p,
        workspaces: p.workspaces.map((w) => (w.id === id ? { ...w, name } : w)),
      }))
    },
    deleteWorkspace(id) {
      commit(set, (p) => {
        if (p.workspaces.length <= 1) return p
        const workspaces = p.workspaces.filter((w) => w.id !== id)
        return {
          ...p,
          workspaces,
          activeWorkspaceId:
            p.activeWorkspaceId === id ? workspaces[0]!.id : p.activeWorkspaceId,
        }
      })
    },
    duplicateWorkspace(id) {
      commit(set, (p) => {
        const src = p.workspaces.find((w) => w.id === id)
        if (!src) return p
        // Panels and views get fresh ids, and view.panelIds is remapped through
        // the same table so the copy is fully independent of the original.
        const idMap = new Map<string, string>()
        const panels = src.panels.map((pan) => {
          const nid = uid('pan')
          idMap.set(pan.id, nid)
          return { ...pan, id: nid }
        })
        const views = src.views.map((v) => ({
          ...v,
          id: uid('view'),
          panelIds: v.panelIds.map((pid) => idMap.get(pid) ?? pid),
          focusedPanelId: v.focusedPanelId
            ? idMap.get(v.focusedPanelId) ?? v.focusedPanelId
            : undefined,
          overrides: v.overrides
            ? Object.fromEntries(
                Object.entries(v.overrides).map(([k, val]) => [idMap.get(k) ?? k, val]),
              )
            : undefined,
        }))
        const copy: Workspace = {
          ...src,
          id: uid('ws'),
          name: `${src.name} copy`,
          panels,
          views,
          activeViewId: views[0]?.id ?? '',
        }
        return {
          ...p,
          workspaces: [...p.workspaces, copy],
          activeWorkspaceId: copy.id,
        }
      })
    },

    // ---------------- views ----------------
    selectView(id) {
      commit(set, (p) => mapWorkspace(p, (ws) => ({ ...ws, activeViewId: id })))
      const v = get().workspace().views.find((x) => x.id === id)
      bridge.send({ op: 'view.activate', viewId: id })
      if (v?.recenterOnEnter) get().recenter()
    },
    selectViewByIndex(i) {
      const views = get().workspace().views
      const v = views[i]
      if (v) get().selectView(v.id)
    },
    nextView() {
      const ws = get().workspace()
      const i = ws.views.findIndex((v) => v.id === ws.activeViewId)
      const next = ws.views[(i + 1) % ws.views.length]
      if (next) get().selectView(next.id)
    },
    prevView() {
      const ws = get().workspace()
      const i = ws.views.findIndex((v) => v.id === ws.activeViewId)
      const prev = ws.views[(i - 1 + ws.views.length) % ws.views.length]
      if (prev) get().selectView(prev.id)
    },
    addView(name) {
      commit(set, (p) =>
        mapWorkspace(p, (ws) => {
          const v: View = {
            id: uid('view'),
            name: name ?? `View ${ws.views.length + 1}`,
            panelIds: ws.panels.filter((x) => x.visible).map((x) => x.id),
            focusedPanelId: ws.panels[0]?.id,
            recenterOnEnter: false,
            hotkey: String(ws.views.length + 1).slice(0, 1),
          }
          return { ...ws, views: [...ws.views, v], activeViewId: v.id }
        }),
      )
    },
    updateView(id, patch) {
      commit(set, (p) =>
        mapWorkspace(p, (ws) => ({
          ...ws,
          views: ws.views.map((v) => (v.id === id ? { ...v, ...patch } : v)),
        })),
      )
    },
    deleteView(id) {
      commit(set, (p) =>
        mapWorkspace(p, (ws) => {
          if (ws.views.length <= 1) return ws
          const views = ws.views.filter((v) => v.id !== id)
          return {
            ...ws,
            views,
            activeViewId: ws.activeViewId === id ? views[0]!.id : ws.activeViewId,
          }
        }),
      )
    },
    duplicateView(id) {
      commit(set, (p) =>
        mapWorkspace(p, (ws) => {
          const src = ws.views.find((v) => v.id === id)
          if (!src) return ws
          const copy: View = { ...src, id: uid('view'), name: `${src.name} copy` }
          delete copy.hotkey
          return { ...ws, views: [...ws.views, copy], activeViewId: copy.id }
        }),
      )
    },
    togglePanelInView(viewId, panelId) {
      commit(set, (p) =>
        mapWorkspace(p, (ws) => ({
          ...ws,
          views: ws.views.map((v) => {
            if (v.id !== viewId) return v
            const has = v.panelIds.includes(panelId)
            const panelIds = has
              ? v.panelIds.filter((x) => x !== panelId)
              : [...v.panelIds, panelId]
            return {
              ...v,
              panelIds,
              focusedPanelId:
                v.focusedPanelId === panelId && has ? panelIds[0] : v.focusedPanelId,
            }
          }),
        })),
      )
    },

    // ---------------- panels ----------------
    selectPanel(id) {
      set({ selectedPanelId: id })
    },
    addPanel(seed) {
      const idx = get().panels().length
      const panel = makePanel({ title: seed?.title ?? `Panel ${idx + 1}`, ...seed }, idx)
      commit(set, (p) =>
        mapWorkspace(p, (ws) => ({
          ...ws,
          panels: [...ws.panels, panel],
          // A new panel joins the view you are looking at, otherwise it appears
          // to do nothing at all.
          views: ws.views.map((v) =>
            v.id === ws.activeViewId ? { ...v, panelIds: [...v.panelIds, panel.id] } : v,
          ),
        })),
      )
      set({ selectedPanelId: panel.id })
    },
    updatePanel(id, patch) {
      commit(set, (p) =>
        mapWorkspace(p, (ws) => ({
          ...ws,
          panels: ws.panels.map((pan) => (pan.id === id ? { ...pan, ...patch } : pan)),
        })),
      )
    },
    setPanelDistance(id, distanceM, lockApparentSize) {
      const d = clamp(distanceM, 0.4, COMFORT.maxDistanceM)
      commit(set, (p) =>
        mapWorkspace(p, (ws) => ({
          ...ws,
          panels: ws.panels.map((pan) => {
            if (pan.id !== id) return pan
            const diagonalIn = lockApparentSize
              ? Number(rescaleForDistance(pan, d).toFixed(1))
              : pan.diagonalIn
            return { ...pan, distanceM: Number(d.toFixed(2)), diagonalIn }
          }),
        })),
      )
    },
    deletePanel(id) {
      commit(set, (p) =>
        mapWorkspace(p, (ws) => ({
          ...ws,
          panels: ws.panels.filter((pan) => pan.id !== id),
          views: ws.views.map((v) => ({
            ...v,
            panelIds: v.panelIds.filter((x) => x !== id),
            focusedPanelId:
              v.focusedPanelId === id
                ? v.panelIds.find((x) => x !== id)
                : v.focusedPanelId,
          })),
        })),
      )
      if (get().selectedPanelId === id) set({ selectedPanelId: undefined })
    },
    duplicatePanel(id) {
      const src = get().panels().find((p) => p.id === id)
      if (!src) return
      const copy: Panel = {
        ...src,
        id: uid('pan'),
        title: `${src.title} copy`,
        // Offset so the copy is not hidden exactly behind the original.
        yawDeg: src.yawDeg + 8,
        zOrder: src.zOrder + 1,
        locked: false,
      }
      commit(set, (p) =>
        mapWorkspace(p, (ws) => ({
          ...ws,
          panels: [...ws.panels, copy],
          views: ws.views.map((v) =>
            v.id === ws.activeViewId ? { ...v, panelIds: [...v.panelIds, copy.id] } : v,
          ),
        })),
      )
      set({ selectedPanelId: copy.id })
    },
    focusPanel(id) {
      const view = get().view()
      get().updateView(view.id, { focusedPanelId: id })
      set({ selectedPanelId: id })
      bridge.send({ op: 'panel.focus', panelId: id })
    },
    focusNextPanel(dir = 1) {
      const visible = get().visiblePanels()
      if (visible.length === 0) return
      const cur = get().view().focusedPanelId
      const i = visible.findIndex((p) => p.id === cur)
      const next = visible[(i + dir + visible.length) % visible.length]
      if (next) get().focusPanel(next.id)
    },

    // ---------------- layout ----------------
    setLayoutOptions(patch) {
      set((s) => ({ layoutOptions: { ...s.layoutOptions, ...patch } }))
    },
    runLayout(id) {
      const device = getDevice(get().profile.deviceId)
      const opts = get().layoutOptions
      const viewPanelIds = new Set(get().view().panelIds)
      commit(set, (p) =>
        mapWorkspace(p, (ws) => {
          // Only re-flow panels that are actually in this view — laying out
          // hidden panels would scramble the other views.
          const inView = ws.panels.filter((pan) => viewPanelIds.has(pan.id))
          const laid = applyLayout(id, inView, opts, device)
          const byId = new Map(laid.map((pan) => [pan.id, pan]))
          return {
            ...ws,
            panels: ws.panels.map((pan) => byId.get(pan.id) ?? pan),
          }
        }),
      )
    },
    pullVisibleToComfort() {
      commit(set, (p) =>
        mapWorkspace(p, (ws) => ({ ...ws, panels: pullToComfort(ws.panels) })),
      )
    },

    // ---------------- bindings ----------------
    addBinding(b) {
      commit(set, (p) => ({
        ...p,
        bindings: [
          ...p.bindings,
          {
            id: uid('bind'),
            kind: b?.kind ?? 'key',
            trigger: b?.trigger ?? '',
            action: b?.action ?? 'view.next',
            arg: b?.arg,
            enabled: b?.enabled ?? true,
          },
        ],
      }))
    },
    updateBinding(id, patch) {
      commit(set, (p) => ({
        ...p,
        bindings: p.bindings.map((b) => (b.id === id ? { ...b, ...patch } : b)),
      }))
    },
    deleteBinding(id) {
      commit(set, (p) => ({ ...p, bindings: p.bindings.filter((b) => b.id !== id) }))
    },
    runAction(action, arg) {
      const s = get()
      switch (action) {
        case 'view.next':
          return s.nextView()
        case 'view.prev':
          return s.prevView()
        case 'view.byIndex':
          return s.selectViewByIndex(Number(arg ?? 0))
        case 'panel.focusNext':
          return s.focusNextPanel(1)
        case 'panel.focusPrev':
          return s.focusNextPanel(-1)
        case 'panel.toggleVisible': {
          const id = String(arg ?? s.view().focusedPanelId ?? '')
          const panel = s.panels().find((p) => p.id === id)
          if (panel) s.updatePanel(id, { visible: !panel.visible })
          return
        }
        case 'panel.pullToComfort':
          return s.pullVisibleToComfort()
        case 'device.recenter':
          return s.recenter()
        case 'device.brightnessUp':
          return s.setDevice({
            luminanceMode: clamp(s.profile.device.luminanceMode + 1, 0, 3) as 0 | 1 | 2 | 3,
          })
        case 'device.brightnessDown':
          return s.setDevice({
            luminanceMode: clamp(s.profile.device.luminanceMode - 1, 0, 3) as 0 | 1 | 2 | 3,
          })
        case 'device.toggleShade':
          return s.setDevice({ shade: s.profile.device.shade > 0.5 ? 0 : 0.85 })
        case 'workspace.toggleFocusMode':
          return s.toggleFocusMode()
      }
    },

    // ---------------- ui ----------------
    setPreviewMode(m) {
      set({ previewMode: m })
    },
    setFollowPose(v) {
      set({ followPose: v })
      if (!v) set({ pose: { yawDeg: 0, pitchDeg: 0, rollDeg: 0 } })
    },
    toggleFocusMode() {
      commit(set, (p) => ({ ...p, focusMode: !p.focusMode }))
    },

    // ---------------- bridge ----------------
    connect(host, port) {
      bridge.connect(host, port)
      // Give the companion the whole picture as soon as it answers rather than
      // waiting for the next edit.
      setTimeout(() => get().pushAll(), 600)
    },
    disconnect() {
      bridge.disconnect()
    },
    pushAll() {
      const p = get().profile
      bridge.pushDeviceSettings(p.device)
      bridge.send({ op: 'profile.apply', profile: p })
    },
  }
})

/**
 * Panels the current view actually shows, in draw order, with any view-level
 * overrides folded in.
 */
export function computeVisiblePanels(ws: Workspace, v: View | undefined): Panel[] {
  if (!v) return ws.panels.filter((p) => p.visible)
  const inView = new Set(v.panelIds)
  return ws.panels
    .filter((p) => inView.has(p.id))
    .map((p) => {
      const o = v.overrides?.[p.id]
      return o ? { ...p, ...o } : p
    })
    .filter((p) => p.visible)
    .sort((a, b) => a.zOrder - b.zOrder)
}

// ---------------------------------------------------------------------------
// Derived hooks
//
// zustand compares selector results by reference, so a selector must never
// build a new object. `computeVisiblePanels` filters and maps into a fresh
// array, which as a raw selector re-renders forever. Selecting the stable
// pieces and deriving under `useMemo` is the fix.
// ---------------------------------------------------------------------------

export const useWorkspace = () => useStore((s) => s.workspace())
export const useView = () => useStore((s) => s.view())
export const usePanels = () => useStore((s) => s.workspace().panels)

export function useVisiblePanels(): Panel[] {
  const ws = useWorkspace()
  const view = useView()
  return useMemo(() => computeVisiblePanels(ws, view), [ws, view])
}

/** Resolve a keyboard event to a binding trigger string. */
export function eventToTrigger(e: KeyboardEvent): string {
  const parts: string[] = []
  if (e.ctrlKey) parts.push('Ctrl')
  if (e.altKey) parts.push('Alt')
  if (e.shiftKey && e.key.length > 1) parts.push('Shift')
  if (e.metaKey) parts.push('Meta')
  parts.push(e.key)
  return parts.join('+')
}
