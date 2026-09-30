#!/usr/bin/env node
// Builds the Swift helper and wraps it in dist/Yap.app.
//
// The helper has to be a signed app bundle: macOS ties the Microphone and Accessibility
// grants to the bundle's code signature, and the microphone prompt needs an Info.plist.

import { execFileSync, spawnSync } from 'node:child_process'
import { chmodSync, cpSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'

const root = path.resolve(import.meta.dirname, '..')
const native = path.join(root, 'native')
const dist = path.join(root, 'dist')
const target = path.join(dist, 'Yap.app')
// Assemble and sign in a staging folder, then swap it into place, so anything reading
// dist/Yap.app (npm packing it, a running copy of Yap) always sees a complete build.
const staging = path.join(dist, `.staging-${process.pid}`)
const app = path.join(staging, 'Yap.app')
const { version } = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'))

const BUNDLE_ID = 'com.yap-dictate.helper'

const buildArgs = ['build', '-c', 'release', '--arch', 'arm64']
const build = spawnSync('swift', buildArgs, { cwd: native, stdio: 'inherit' })
if (build.error?.code === 'ENOENT') {
  console.error('yap: `swift` was not found. Install the Xcode Command Line Tools: xcode-select --install')
  process.exit(1)
}
if (build.status !== 0) process.exit(build.status ?? 1)
const binDir = execFileSync('swift', [...buildArgs, '--show-bin-path'], { cwd: native, encoding: 'utf8' }).trim()

rmSync(staging, { recursive: true, force: true })
const contents = path.join(app, 'Contents')
mkdirSync(path.join(contents, 'MacOS'), { recursive: true })
mkdirSync(path.join(contents, 'Resources'), { recursive: true })
// Regenerate with `swift scripts/make-icon.swift`.
cpSync(path.join(native, 'Resources', 'AppIcon.icns'), path.join(contents, 'Resources', 'AppIcon.icns'))

// FluidAudio's resource bundle is deliberately left out: it only holds a text-to-speech
// lexicon, which dictation never loads.
const executable = path.join(contents, 'MacOS', 'yap-helper')
cpSync(path.join(binDir, 'yap-helper'), executable)
chmodSync(executable, 0o755)

writeFileSync(
  path.join(contents, 'Info.plist'),
  `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Yap</string>
  <key>CFBundleDisplayName</key><string>Yap</string>
  <key>CFBundleExecutable</key><string>yap-helper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Yap records while you hold the dictation hotkey and transcribes the audio on this Mac.</string>
</dict>
</plist>
`,
)

// A real signing identity keeps the permission grants across rebuilds. Ad-hoc signatures
// change with every build, so macOS asks for Microphone and Accessibility again each time.
function signingIdentity() {
  if (process.env.YAP_CODESIGN_IDENTITY) return process.env.YAP_CODESIGN_IDENTITY
  const found = spawnSync('security', ['find-identity', '-v', '-p', 'codesigning'], { encoding: 'utf8' })
  const names = [...(found.stdout ?? '').matchAll(/"([^"]+)"/g)].map((match) => match[1])
  return (
    names.find((name) => name.startsWith('Developer ID Application')) ??
    names.find((name) => name.startsWith('Apple Development')) ??
    '-'
  )
}

function sign(identity) {
  return spawnSync('codesign', ['--force', '--sign', identity, '--identifier', BUNDLE_ID, app], {
    encoding: 'utf8',
    timeout: 60_000,
  })
}

let identity = signingIdentity()
let signed = sign(identity)
if (signed.status !== 0 && identity !== '-') {
  console.warn(`yap: signing with "${identity}" failed; falling back to an ad-hoc signature.`)
  console.warn((signed.stderr ?? '').trim())
  identity = '-'
  signed = sign(identity)
}
if (signed.status !== 0) {
  console.error((signed.stderr ?? '').trim())
  rmSync(staging, { recursive: true, force: true })
  process.exit(1)
}

const previous = path.join(staging, 'previous')
if (existsSync(target)) renameSync(target, previous)
renameSync(app, target)
rmSync(staging, { recursive: true, force: true })

console.log(`Built ${path.relative(root, target)} (signed: ${identity === '-' ? 'ad-hoc' : identity})`)
