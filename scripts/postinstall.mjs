#!/usr/bin/env node
// Published tarballs ship a prebuilt dist/Yap.app. When it is missing (a git checkout, or a
// tarball packed without it) build it from source, without failing the install.

import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import path from 'node:path'

const root = path.resolve(import.meta.dirname, '..')

if (process.platform !== 'darwin' || process.arch !== 'arm64') {
  console.warn('yap: only macOS on Apple Silicon is supported.')
  process.exit(0)
}
if (existsSync(path.join(root, 'dist', 'Yap.app', 'Contents', 'MacOS', 'yap-helper'))) process.exit(0)

console.log('yap: building the native helper (first install only, takes a minute)…')
const build = spawnSync(process.execPath, [path.join(root, 'scripts', 'build-native.mjs')], { stdio: 'inherit' })
if (build.status !== 0) {
  console.warn('yap: the native helper did not build. Fix the error above, then run `npm run build` in', root)
}
