/**
 * Electron main process for the macOS app.
 *
 * Loads the single-file offline build (`download/…​.html`) rather than the
 * normal `dist/`. Two reasons: the standard build uses absolute `/assets/…`
 * paths that do not resolve under `file://`, and one self-contained file means
 * there is nothing to get out of sync between the web and desktop versions.
 *
 * The renderer is a plain web page — no Node integration, no preload bridge. It
 * has no need for either, and leaving them off is the safe default.
 */

const { app, BrowserWindow, Menu, dialog, shell, screen } = require('electron')
const path = require('node:path')
const fs = require('node:fs')

const APP_HTML = 'RayNeo-Air4Pro-Configurator.html'

/** USB ids read better as hex, which is how every datasheet quotes them. */
const hex4 = (n) => `0x${Number(n).toString(16).padStart(4, '0').toUpperCase()}`

// A packaged build takes this from Info.plist, but running from source it would
// otherwise fall back to the package name — and this string is the first item in
// the macOS menu bar, so it is user-visible either way.
app.setName('RayNeo Air 4 Pro Configurator')

/** Where the bundled page lives, packaged or run from source. */
function resolveIndex() {
  const candidates = [
    // Packaged: copied in via electron-builder's extraResources.
    path.join(process.resourcesPath || '', 'app', APP_HTML),
    // Running from source with `npm start`.
    path.join(__dirname, '..', 'download', APP_HTML),
    path.join(__dirname, 'app', APP_HTML),
  ]
  return candidates.find((p) => p && fs.existsSync(p))
}

// -- window bounds persistence ---------------------------------------------
// Small nicety, but a desktop app that forgets its size every launch feels
// broken. Stored in userData so it survives reinstalls of the app bundle.
const boundsFile = () => path.join(app.getPath('userData'), 'window-state.json')

function loadBounds() {
  try {
    const saved = JSON.parse(fs.readFileSync(boundsFile(), 'utf8'))
    if (!Number.isFinite(saved.width) || !Number.isFinite(saved.height)) return null
    // Reject bounds that would land off-screen — monitors get unplugged.
    const visible = screen.getAllDisplays().some((d) => {
      const a = d.workArea
      return (
        Number.isFinite(saved.x) &&
        Number.isFinite(saved.y) &&
        saved.x < a.x + a.width &&
        saved.x + saved.width > a.x &&
        saved.y < a.y + a.height &&
        saved.y + saved.height > a.y
      )
    })
    return visible ? saved : { width: saved.width, height: saved.height }
  } catch {
    return null
  }
}

function saveBounds(win) {
  if (!win || win.isDestroyed() || win.isMinimized()) return
  try {
    fs.writeFileSync(boundsFile(), JSON.stringify(win.getNormalBounds()), 'utf8')
  } catch {
    // Losing the remembered size is not worth surfacing an error for.
  }
}

let mainWindow = null

function createWindow() {
  const saved = loadBounds()

  mainWindow = new BrowserWindow({
    width: saved?.width ?? 1500,
    height: saved?.height ?? 950,
    x: saved?.x,
    y: saved?.y,
    minWidth: 1024,
    minHeight: 680,
    // Matches --color-ink-950, so resizing does not flash white.
    backgroundColor: '#06080c',
    title: 'RayNeo Air 4 Pro Configurator',
    titleBarStyle: 'hiddenInset',
    show: false,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      spellcheck: false,
    },
  })

  const index = resolveIndex()
  if (!index) {
    // Better than a blank window with no explanation.
    mainWindow.loadURL(
      'data:text/html;charset=utf-8,' +
        encodeURIComponent(`<body style="background:#06080c;color:#e6ebf1;
          font:14px/1.6 -apple-system,system-ui,sans-serif;padding:40px">
          <h2 style="color:#22d3ee">Bundled page missing</h2>
          <p>Could not find <code>${APP_HTML}</code>.</p>
          <p>Build it first, from the repository root:</p>
          <pre style="background:#0e131b;padding:12px;border-radius:8px">npm install
npm run build:offline</pre></body>`),
    )
  } else {
    mainWindow.loadFile(index)
  }

  mainWindow.once('ready-to-show', () => mainWindow.show())

  // Persist on a debounce; resize fires continuously while dragging.
  let saveTimer
  const scheduleSave = () => {
    clearTimeout(saveTimer)
    saveTimer = setTimeout(() => saveBounds(mainWindow), 400)
  }
  mainWindow.on('resize', scheduleSave)
  mainWindow.on('move', scheduleSave)
  mainWindow.on('close', () => {
    clearTimeout(saveTimer)
    saveBounds(mainWindow)
  })
  mainWindow.on('closed', () => {
    mainWindow = null
  })

  /*
   * WebHID plumbing, so the USB probe works in the desktop app.
   *
   * Electron does not wire this up for you: without a `select-hid-device`
   * handler, `navigator.hid.requestDevice()` resolves to an empty array and the
   * probe silently finds nothing — which looks exactly like "the glasses expose
   * no HID interface". Since the whole point of the probe is to distinguish
   * those two cases, the difference matters.
   *
   * Electron ships no chooser UI either, so this presents a native dialog.
   */
  const wc = mainWindow.webContents

  // Narrow allow-list rather than a blanket grant. Note that clipboard writes
  // must be included: denying everything but 'hid' made every Copy button in the
  // app fail with "clipboard access denied", which is how the USB probe report
  // became impossible to get out of the desktop build.
  const ALLOWED_PERMISSIONS = new Set([
    'hid',
    'clipboard-write',
    'clipboard-sanitized-write',
  ])

  wc.session.setPermissionRequestHandler((_contents, permission, callback) => {
    callback(ALLOWED_PERMISSIONS.has(permission))
  })

  wc.session.setPermissionCheckHandler((_contents, permission) =>
    ALLOWED_PERMISSIONS.has(permission),
  )

  wc.session.setDevicePermissionHandler(({ deviceType }) => deviceType === 'hid')

  wc.on('select-hid-device', (event, details, callback) => {
    event.preventDefault()
    const list = details.deviceList ?? []

    if (list.length === 0) {
      callback(undefined)
      return
    }

    // A native dialog rather than a renderer-side picker: the page is a single
    // self-contained HTML file with no preload and no IPC channel, so there is
    // nothing on the other side to ask.
    const labels = list
      .slice(0, 8)
      .map(
        (d) =>
          `${d.name || 'Unnamed device'}  (${hex4(d.vendorId)}:${hex4(d.productId)})`,
      )

    const choice = dialog.showMessageBoxSync(mainWindow, {
      type: 'question',
      title: 'Choose a device to probe',
      message: 'Which USB device are your glasses?',
      detail:
        'Glasses usually present several interfaces — audio, display control, sensors. Probe each in turn to find the one carrying sensor data. This is read-only.',
      buttons: [...labels, 'Cancel'],
      cancelId: labels.length,
      defaultId: 0,
      noLink: true,
    })

    callback(choice >= 0 && choice < labels.length ? list[choice].deviceId : undefined)
  })

  // External links belong in the user's browser, not in a chromeless app window.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) shell.openExternal(url)
    return { action: 'deny' }
  })
  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith('file://')) {
      event.preventDefault()
      if (/^https?:/i.test(url)) shell.openExternal(url)
    }
  })
}

/**
 * Application menu.
 *
 * Not optional on macOS: without an Edit menu carrying the standard roles, the
 * system copy/paste/select-all shortcuts do not reach the renderer and every
 * text field in the app becomes read-only to the keyboard.
 */
function buildMenu() {
  const template = [
    {
      label: app.name,
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
      ],
    },
    {
      label: 'View',
      submenu: [
        { role: 'reload' },
        { role: 'forceReload' },
        { role: 'toggleDevTools' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
      ],
    },
    { role: 'windowMenu' },
    {
      role: 'help',
      submenu: [
        {
          label: 'Optics & Comfort Notes',
          click: () =>
            shell.openExternal(
              'https://github.com/amgaviation/RayNeoProj/blob/main/docs/OPTICS.md',
            ),
        },
        {
          label: 'Companion App Setup',
          click: () =>
            shell.openExternal(
              'https://github.com/amgaviation/RayNeoProj/blob/main/companion/README.md',
            ),
        },
        {
          label: 'RayNeo Air SDK Documentation',
          click: () =>
            shell.openExternal(
              'https://rayneo-en.gitbook.io/rayneo-devdoc/air-series/unity-sdk/quick-start/overview',
            ),
        },
      ],
    },
  ]
  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}

// Second instances would fight over the same window-state file.
if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.focus()
    }
  })

  app.whenReady().then(() => {
    app.setAboutPanelOptions({
      applicationName: 'RayNeo Air 4 Pro Configurator',
      applicationVersion: app.getVersion(),
      credits: 'Workspace designer and device console for RayNeo Air 4 Pro glasses.',
    })
    buildMenu()
    createWindow()

    // macOS convention: clicking the dock icon with no windows opens one.
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow()
    })
  })

  // On macOS the app normally stays running with no windows; quitting on close
  // is the more expected behaviour for a single-window utility like this.
  app.on('window-all-closed', () => app.quit())
}
