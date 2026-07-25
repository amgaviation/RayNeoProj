import { useEffect, useRef } from 'react'
import * as THREE from 'three'
import { useStore, useView, useVisiblePanels } from '../lib/store'
import { getDevice } from '../lib/device'
import { devicePpd } from '../lib/optics'
import { panelOutline } from '../lib/project'
import { rad } from '../lib/optics'
import type { Panel } from '../lib/types'

/**
 * Orbital view of the workspace.
 *
 * The through-the-glasses preview answers "what will I see"; this answers "where
 * did I put everything". Being able to swing around the arrangement is the
 * fastest way to understand a layout's spread and spot panels stacked behind
 * each other.
 *
 * Hand-rolled orbit controls rather than the three.js example module: it is
 * about thirty lines, and it avoids depending on an `examples/jsm` path that
 * moves between three releases.
 */
export function SceneView() {
  const mountRef = useRef<HTMLDivElement>(null)
  const stateRef = useRef<{
    renderer: THREE.WebGLRenderer
    scene: THREE.Scene
    camera: THREE.PerspectiveCamera
    panelGroup: THREE.Group
    headGroup: THREE.Group
    frustum: THREE.LineSegments
    dispose: () => void
  } | null>(null)

  // Kept in refs so the animation loop reads fresh values without being torn
  // down and rebuilt on every store change.
  const dataRef = useRef({
    panels: [] as Panel[],
    pose: { yawDeg: 0, pitchDeg: 0, rollDeg: 0 },
    selectedId: undefined as string | undefined,
    focusedId: undefined as string | undefined,
    fov: { horizontalDeg: 41.5, verticalDeg: 24.1 },
    fovDiagonalDeg: 47,
  })

  const panels = useVisiblePanels()
  const pose = useStore((s) => s.pose)
  const selectedId = useStore((s) => s.selectedPanelId)
  const view = useView()
  const deviceId = useStore((s) => s.profile.deviceId)
  const selectPanel = useStore((s) => s.selectPanel)

  const device = getDevice(deviceId)
  const fov = devicePpd(device).fov

  dataRef.current = {
    panels,
    pose,
    selectedId,
    focusedId: view?.focusedPanelId,
    fov,
    fovDiagonalDeg: device.fovDiagonalDeg,
  }

  // ---- one-time scene setup ----
  useEffect(() => {
    const mount = mountRef.current
    if (!mount) return

    const scene = new THREE.Scene()
    scene.background = new THREE.Color('#06080c')
    scene.fog = new THREE.Fog('#06080c', 14, 34)

    const camera = new THREE.PerspectiveCamera(45, 1, 0.05, 200)
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false })
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
    mount.appendChild(renderer.domElement)
    renderer.domElement.style.display = 'block'
    renderer.domElement.style.touchAction = 'none'

    // Ground grid gives the distances something to read against.
    const grid = new THREE.GridHelper(24, 24, 0x1a212c, 0x121821)
    grid.position.y = -1.35
    scene.add(grid)

    // Range rings every 2 m, so "4 m away" is legible at a glance.
    for (const r of [2, 4, 6, 8]) {
      const pts: number[] = []
      for (let i = 0; i <= 96; i++) {
        const a = (i / 96) * Math.PI * 2
        pts.push(Math.cos(a) * r, -1.34, Math.sin(a) * r)
      }
      const g = new THREE.BufferGeometry()
      g.setAttribute('position', new THREE.Float32BufferAttribute(pts, 3))
      scene.add(
        new THREE.Line(
          g,
          new THREE.LineBasicMaterial({ color: 0x232c39, transparent: true, opacity: 0.7 }),
        ),
      )
    }

    // The wearer's head, and the FOV cone attached to it.
    const headGroup = new THREE.Group()
    scene.add(headGroup)

    const head = new THREE.Mesh(
      new THREE.SphereGeometry(0.11, 20, 14),
      new THREE.MeshBasicMaterial({ color: 0x22d3ee }),
    )
    headGroup.add(head)

    const frustum = new THREE.LineSegments(
      new THREE.BufferGeometry(),
      new THREE.LineBasicMaterial({ color: 0x22d3ee, transparent: true, opacity: 0.45 }),
    )
    headGroup.add(frustum)

    const panelGroup = new THREE.Group()
    scene.add(panelGroup)

    // ---- orbit controls ----
    // Spherical camera around the head: drag to orbit, wheel to zoom.
    let camYaw = 0.55
    let camPitch = 0.32
    let camDist = 11
    let dragging = false
    let lastX = 0
    let lastY = 0

    // Orbit a point out in front of the wearer rather than the head itself, so
    // the head and the panels both stay framed instead of the panels drifting
    // off to one side.
    const target = new THREE.Vector3(0, 0, -2.2)

    const applyCamera = () => {
      camPitch = Math.max(-1.3, Math.min(1.45, camPitch))
      camDist = Math.max(1.6, Math.min(30, camDist))
      camera.position.set(
        target.x + camDist * Math.cos(camPitch) * Math.sin(camYaw),
        target.y + camDist * Math.sin(camPitch),
        target.z + camDist * Math.cos(camPitch) * Math.cos(camYaw),
      )
      camera.lookAt(target)
    }
    applyCamera()

    const onPointerDown = (e: PointerEvent) => {
      dragging = true
      lastX = e.clientX
      lastY = e.clientY
      renderer.domElement.setPointerCapture(e.pointerId)
    }
    const onPointerMove = (e: PointerEvent) => {
      if (!dragging) return
      camYaw -= (e.clientX - lastX) * 0.006
      camPitch += (e.clientY - lastY) * 0.005
      lastX = e.clientX
      lastY = e.clientY
      applyCamera()
    }
    const onPointerUp = (e: PointerEvent) => {
      dragging = false
      if (renderer.domElement.hasPointerCapture(e.pointerId)) {
        renderer.domElement.releasePointerCapture(e.pointerId)
      }
    }
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      camDist *= e.deltaY > 0 ? 1.09 : 0.92
      applyCamera()
    }

    // Click-to-select via raycast against the panel quads.
    const raycaster = new THREE.Raycaster()
    const onClick = (e: MouseEvent) => {
      const rect = renderer.domElement.getBoundingClientRect()
      const ndc = new THREE.Vector2(
        ((e.clientX - rect.left) / rect.width) * 2 - 1,
        -((e.clientY - rect.top) / rect.height) * 2 + 1,
      )
      raycaster.setFromCamera(ndc, camera)
      const hits = raycaster.intersectObjects(panelGroup.children, true)
      const hit = hits.find((h) => h.object.userData.panelId)
      if (hit) selectPanel(String(hit.object.userData.panelId))
    }

    const el = renderer.domElement
    el.addEventListener('pointerdown', onPointerDown)
    el.addEventListener('pointermove', onPointerMove)
    el.addEventListener('pointerup', onPointerUp)
    el.addEventListener('pointercancel', onPointerUp)
    el.addEventListener('wheel', onWheel, { passive: false })
    el.addEventListener('click', onClick)

    const resize = () => {
      const w = mount.clientWidth
      const h = mount.clientHeight
      if (w === 0 || h === 0) return
      renderer.setSize(w, h, false)
      camera.aspect = w / h
      camera.updateProjectionMatrix()
    }
    resize()
    const ro = new ResizeObserver(resize)
    ro.observe(mount)

    let raf = 0
    const tick = () => {
      raf = requestAnimationFrame(tick)
      const d = dataRef.current
      headGroup.rotation.set(rad(d.pose.pitchDeg), rad(-d.pose.yawDeg), rad(d.pose.rollDeg))
      renderer.render(scene, camera)
    }
    tick()

    stateRef.current = {
      renderer,
      scene,
      camera,
      panelGroup,
      headGroup,
      frustum,
      dispose: () => {
        cancelAnimationFrame(raf)
        ro.disconnect()
        el.removeEventListener('pointerdown', onPointerDown)
        el.removeEventListener('pointermove', onPointerMove)
        el.removeEventListener('pointerup', onPointerUp)
        el.removeEventListener('pointercancel', onPointerUp)
        el.removeEventListener('wheel', onWheel)
        el.removeEventListener('click', onClick)
        scene.traverse((o) => {
          const m = o as THREE.Mesh
          m.geometry?.dispose?.()
          const mat = m.material
          if (Array.isArray(mat)) mat.forEach((x) => x.dispose())
          else mat?.dispose?.()
        })
        renderer.dispose()
        if (el.parentNode) el.parentNode.removeChild(el)
      },
    }

    return () => {
      stateRef.current?.dispose()
      stateRef.current = null
    }
  }, [selectPanel])

  // ---- rebuild the FOV cone when the device changes ----
  useEffect(() => {
    const st = stateRef.current
    if (!st) return
    const L = 7
    const tw = Math.tan(rad(fov.horizontalDeg) / 2) * L
    const th = Math.tan(rad(fov.verticalDeg) / 2) * L
    const corners = [
      [-tw, th, -L],
      [tw, th, -L],
      [tw, -th, -L],
      [-tw, -th, -L],
    ]
    const verts: number[] = []
    for (const c of corners) verts.push(0, 0, 0, c[0]!, c[1]!, c[2]!)
    for (let i = 0; i < 4; i++) {
      const a = corners[i]!
      const b = corners[(i + 1) % 4]!
      verts.push(a[0]!, a[1]!, a[2]!, b[0]!, b[1]!, b[2]!)
    }
    const g = new THREE.BufferGeometry()
    g.setAttribute('position', new THREE.Float32BufferAttribute(verts, 3))
    st.frustum.geometry.dispose()
    st.frustum.geometry = g
  }, [fov.horizontalDeg, fov.verticalDeg])

  // ---- rebuild panel meshes when the layout changes ----
  useEffect(() => {
    const st = stateRef.current
    if (!st) return
    const group = st.panelGroup

    while (group.children.length) {
      const c = group.children.pop()!
      const m = c as THREE.Mesh
      m.geometry?.dispose?.()
      const mat = m.material
      if (Array.isArray(mat)) mat.forEach((x) => x.dispose())
      else mat?.dispose?.()
    }

    for (const panel of panels) {
      // Reuse the same outline generator as the glasses preview so the two views
      // can never disagree about where a panel is or how it curves.
      const outline = panelOutline(panel, panel.curvatureDeg > 0 ? 16 : 2)
      const half = outline.length / 2
      const top = outline.slice(0, half)
      const bottom = outline.slice(half).reverse()

      const positions: number[] = []
      const indices: number[] = []
      for (let i = 0; i < half; i++) {
        positions.push(top[i]!.x, top[i]!.y, top[i]!.z)
        positions.push(bottom[i]!.x, bottom[i]!.y, bottom[i]!.z)
      }
      for (let i = 0; i < half - 1; i++) {
        const a = i * 2
        indices.push(a, a + 1, a + 2, a + 1, a + 3, a + 2)
      }

      const geo = new THREE.BufferGeometry()
      geo.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3))
      geo.setIndex(indices)
      geo.computeVertexNormals()

      const isSelected = panel.id === selectedId
      const isFocused = panel.id === view?.focusedPanelId
      const mesh = new THREE.Mesh(
        geo,
        new THREE.MeshBasicMaterial({
          color: new THREE.Color(panel.color),
          transparent: true,
          opacity: panel.opacity * (isFocused ? 0.42 : 0.2),
          side: THREE.DoubleSide,
          depthWrite: false,
        }),
      )
      mesh.userData.panelId = panel.id
      group.add(mesh)

      // Outline: much easier to read the arrangement than fills alone.
      const loop: number[] = []
      for (const p of outline) loop.push(p.x, p.y, p.z)
      loop.push(outline[0]!.x, outline[0]!.y, outline[0]!.z)
      const lg = new THREE.BufferGeometry()
      lg.setAttribute('position', new THREE.Float32BufferAttribute(loop, 3))
      const line = new THREE.Line(
        lg,
        new THREE.LineBasicMaterial({
          color: new THREE.Color(panel.color),
          transparent: true,
          opacity: isSelected || isFocused ? 1 : 0.65,
        }),
      )
      line.userData.panelId = panel.id
      group.add(line)

      // A leader line back to the head makes distance and bearing readable.
      const centre = new THREE.Vector3()
      for (const p of outline) centre.add(new THREE.Vector3(p.x, p.y, p.z))
      centre.multiplyScalar(1 / outline.length)
      const rayGeo = new THREE.BufferGeometry()
      rayGeo.setAttribute(
        'position',
        new THREE.Float32BufferAttribute([0, 0, 0, centre.x, centre.y, centre.z], 3),
      )
      group.add(
        new THREE.Line(
          rayGeo,
          new THREE.LineBasicMaterial({
            color: new THREE.Color(panel.color),
            transparent: true,
            opacity: isSelected ? 0.4 : 0.12,
          }),
        ),
      )

      const label = makeLabel(panel, isSelected)
      if (label) {
        label.position.copy(centre)
        label.userData.panelId = panel.id
        group.add(label)
      }
    }
  }, [panels, selectedId, view?.focusedPanelId])

  return (
    <div className="relative h-full w-full">
      <div ref={mountRef} className="h-full w-full" />
      <div className="pointer-events-none absolute bottom-2 left-3 text-[11px] text-ink-600">
        drag to orbit · wheel to zoom · click a panel to select · rings every 2 m
      </div>
    </div>
  )
}

/** Billboard label rendered from a canvas texture. */
function makeLabel(panel: Panel, bright: boolean): THREE.Sprite | null {
  const canvas = document.createElement('canvas')
  canvas.width = 512
  canvas.height = 128
  const ctx = canvas.getContext('2d')
  if (!ctx) return null

  ctx.clearRect(0, 0, 512, 128)
  ctx.font = '600 46px ui-sans-serif, system-ui, sans-serif'
  ctx.fillStyle = bright ? '#ffffff' : '#c3ccd8'
  ctx.textAlign = 'center'
  ctx.fillText(panel.title, 256, 52)
  ctx.font = '32px ui-monospace, monospace'
  ctx.fillStyle = panel.color
  ctx.fillText(
    `${panel.distanceM.toFixed(1)}m · ${panel.diagonalIn.toFixed(0)}"`,
    256,
    98,
  )

  const tex = new THREE.CanvasTexture(canvas)
  tex.colorSpace = THREE.SRGBColorSpace
  const sprite = new THREE.Sprite(
    new THREE.SpriteMaterial({ map: tex, transparent: true, depthWrite: false }),
  )
  // Scaled in world metres; roughly a readable plaque at typical orbit distance.
  sprite.scale.set(1.4, 0.35, 1)
  return sprite
}
