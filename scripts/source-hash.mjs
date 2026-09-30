// Fingerprints everything that goes into Yap.app, so `yap` can tell when the installed
// source has changed (after an update) and the app needs rebuilding.

import { createHash } from 'node:crypto'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import path from 'node:path'

const root = path.resolve(import.meta.dirname, '..')
const inputs = [
  'package.json',
  'scripts/build-native.mjs',
  'native/Package.swift',
  'native/Package.resolved',
  'native/Sources',
  'native/Resources',
]

function files(relative) {
  const absolute = path.join(root, relative)
  if (!statSync(absolute, { throwIfNoEntry: false })) return []
  if (!statSync(absolute).isDirectory()) return [relative]
  return readdirSync(absolute)
    .sort()
    .flatMap((entry) => files(path.join(relative, entry)))
}

export function sourceHash() {
  const hash = createHash('sha256')
  for (const file of inputs.flatMap(files)) {
    hash.update(file)
    hash.update(readFileSync(path.join(root, file)))
  }
  return hash.digest('hex').slice(0, 16)
}
