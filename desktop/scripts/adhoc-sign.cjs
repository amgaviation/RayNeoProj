/**
 * electron-builder `afterPack` hook: apply an ad-hoc code signature.
 *
 * Why this is mandatory, not optional polish.
 *
 * On Apple Silicon, macOS refuses to execute arm64 code that carries no
 * signature at all. An unsigned app is not merely "from an unidentified
 * developer" — it fails to load, and the Finder reports it as
 * **"damaged and can't be opened"**. Right-click → Open cannot rescue it,
 * because there is nothing for Gatekeeper to evaluate.
 *
 * `mac.identity: null` tells electron-builder to skip signing entirely, which is
 * exactly what produced that error. The fix is an *ad-hoc* signature
 * (`codesign --sign -`): no certificate, no Apple Developer account, but a valid
 * code directory that the loader accepts. The app is still unnotarised, so a
 * downloaded copy is quarantined and needs one right-click → Open — but it now
 * launches instead of being declared broken.
 *
 * Runs only on macOS. The CI validate job assembles the same bundle on Linux to
 * catch config errors cheaply, and `codesign` does not exist there.
 */

const { execFileSync } = require('node:child_process')
const path = require('node:path')
const fs = require('node:fs')

exports.default = async function adhocSign(context) {
  const { appOutDir, packager, electronPlatformName, arch } = context

  if (electronPlatformName !== 'darwin') return

  if (process.platform !== 'darwin') {
    console.log(
      `  • ad-hoc signing skipped  reason=host is ${process.platform}, codesign is macOS-only`,
    )
    return
  }

  const appPath = path.join(appOutDir, `${packager.appInfo.productFilename}.app`)
  if (!fs.existsSync(appPath)) {
    throw new Error(`ad-hoc signing: no app bundle at ${appPath}`)
  }

  // Nested code has to be signed before the bundle that contains it, or the
  // outer signature seals a stale hash and verification fails. `--deep` walks
  // the tree in the right order; Apple discourages it for real distribution
  // signing, but for an ad-hoc signature it is the standard approach.
  execFileSync(
    'codesign',
    ['--force', '--deep', '--sign', '-', '--timestamp=none', appPath],
    { stdio: 'inherit' },
  )

  // Fail the build rather than shipping something that will not launch. This is
  // the check that would have caught the original bug.
  execFileSync('codesign', ['--verify', '--deep', '--strict', appPath], {
    stdio: 'inherit',
  })

  const info = execFileSync('codesign', ['--display', '--verbose=2', appPath], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const signature = /Signature=(.*)/.exec(info)?.[1]?.trim() ?? 'unknown'
  console.log(`  • ad-hoc signed  arch=${arch} signature=${signature} app=${appPath}`)
}
