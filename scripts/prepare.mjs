#!/usr/bin/env node
// npm runs `prepare` in a git checkout and when installing from GitHub, before the package is
// packed. Build dist/Yap.app there, once, unless a build already exists.

import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import path from 'node:path'

const root = path.resolve(import.meta.dirname, '..')

if (process.platform !== 'darwin' || process.arch !== 'arm64') {
  console.warn('yap: only macOS on Apple Silicon is supported; skipping the native build.')
  process.exit(0)
}
if (existsSync(path.join(root, 'dist', 'Yap.app', 'Contents', 'MacOS', 'yap-helper'))) process.exit(0)

console.log('yap: building the native app (takes a few minutes the first time)…')
const build = spawnSync(process.execPath, [path.join(root, 'scripts', 'build-native.mjs')], { stdio: 'inherit' })
process.exit(build.status ?? 1)
