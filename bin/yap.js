#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, userInfo } from 'node:os'
import path from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'
import { sourceHash } from '../scripts/source-hash.mjs'

const root = path.resolve(import.meta.dirname, '..')
const support = path.join(homedir(), 'Library', 'Application Support', 'yap')
const app = path.join(support, 'Yap.app')
const helper = path.join(app, 'Contents', 'MacOS', 'yap-helper')
const buildInfoPath = path.join(support, 'build.json')

const BUNDLE_ID = 'com.yap-dictate.helper'
const configPath = path.join(homedir(), '.config', 'yap', 'config.json')
const statePath = path.join(support, 'state.json')
const historyPath = path.join(support, 'history.jsonl')
const logPath = path.join(homedir(), 'Library', 'Logs', 'yap', 'yap.log')
const agentPath = path.join(homedir(), 'Library', 'LaunchAgents', `${BUNDLE_ID}.plist`)

const DEFAULTS = {
  hotkey: 'fn',
  mode: 'hold',
  model: 'parakeet-v2',
  paste: 'auto',
  format: true,
  restoreClipboard: true,
  trailingSpace: true,
  sounds: true,
  hud: true,
  history: true,
  sendApps: [],
  replacements: {},
}
const CHOICES = {
  mode: ['hold', 'toggle'],
  paste: ['auto', 'always', 'clipboard'],
}

const USAGE = `yap — hold a key, talk, and the text lands where you are typing. Fully local.

Usage: yap <command>

  start                    Start dictation in the background
  stop                     Stop it
  restart                  Restart it (picks up config changes)
  status                   Show whether it is running and which permissions it has
  doctor                   Check the whole setup and say what to fix
  install                  Start automatically at login
  uninstall                Stop starting at login

  hotkey [keys]            Show or set the dictation hotkey, e.g. fn, right_option, ctrl+opt+space
  send                     List apps where Yap presses Return after pasting
  send add|remove <app>    Turn that on or off for an app, e.g. yap send add Slack
  send all|off             Turn it on for every app, or off everywhere
  model [id]               List speech models, or switch to one
  config                   Print the config and where it lives
  config set <key> <value>
  config unset <key>

  transcribe <file>        Transcribe an audio file (--model <id>, --runs <n>, --raw, --json)
  download [model]         Download a model ahead of time
  history [n]              Show the last n dictations (default 10)
  logs [-f]                Show the log
  run                      Run in the foreground (permissions then belong to your terminal)
`

// ---------------------------------------------------------------- helpers

function die(message) {
  console.error(`yap: ${message}`)
  process.exit(1)
}

function isCurrent() {
  return existsSync(helper) && readJSON(buildInfoPath, {}).source === sourceHash()
}

/**
 * Makes sure Yap.app is built from the installed source: on first use, and again after an
 * update. Returns true when it had to build.
 */
function requireHelper() {
  if (process.platform !== 'darwin' || process.arch !== 'arm64') die('only macOS on Apple Silicon is supported.')
  if (isCurrent()) return false
  console.error(
    existsSync(helper)
      ? 'yap: Yap was updated; rebuilding the app…'
      : 'yap: building the Yap app. This takes a few minutes the first time.',
  )
  const build = spawnSync(process.execPath, [path.join(root, 'scripts', 'build-native.mjs')], { stdio: 'inherit' })
  if (build.error || build.status !== 0) die('the build failed. The output above says why.')
  return true
}

function readJSON(file, fallback) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'))
  } catch {
    return fallback
  }
}

function readConfig() {
  return readJSON(configPath, {})
}

function writeConfig(config) {
  mkdirSync(path.dirname(configPath), { recursive: true })
  writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n')
}

/** Runs a helper subcommand that prints JSON on stdout. Progress goes to the terminal via stderr. */
function helperJSON(args, { quiet = false } = {}) {
  requireHelper()
  const result = spawnSync(helper, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', quiet ? 'pipe' : 'inherit'],
    maxBuffer: 64 * 1024 * 1024,
  })
  if (result.status !== 0) {
    if (quiet && result.stderr) console.error(result.stderr.trim().replace(/^yap-helper:/gm, 'yap:'))
    process.exit(result.status ?? 1)
  }
  return JSON.parse(result.stdout)
}

/** PIDs of the background daemon (the helper running with no subcommand). */
function daemonPids() {
  const result = spawnSync('pgrep', ['-f', 'Yap\\.app/Contents/MacOS/yap-helper( daemon)?$'], { encoding: 'utf8' })
  return result.stdout.split('\n').filter(Boolean).map(Number)
}

async function waitFor(condition, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (condition()) return true
    await sleep(100)
  }
  return condition()
}

// ---------------------------------------------------------------- daemon

async function start() {
  const rebuilt = requireHelper()
  if (daemonPids().length > 0) {
    if (!rebuilt) {
      console.log('Yap is already running.')
      return printStatus()
    }
    await stop({ quiet: true })
  }
  rmSync(statePath, { force: true })
  // `open` launches through LaunchServices, so macOS attributes the Microphone and
  // Accessibility permissions to Yap itself rather than to this terminal. Right after a stop,
  // LaunchServices can still consider the old instance alive and refuse (error -600), so retry.
  for (let attempt = 1; ; attempt++) {
    const opened = spawnSync('open', ['-g', app], { encoding: 'utf8' })
    if (opened.status === 0) break
    if (attempt === 10) die(`could not launch Yap: ${opened.stderr.trim()}`)
    await sleep(300)
  }
  if (!(await waitFor(() => existsSync(statePath), 8000))) {
    die(`Yap did not start. See ${logPath}`)
  }
  await sleep(300)
  printStatus()
}

async function stop({ quiet = false } = {}) {
  const pids = daemonPids()
  if (pids.length === 0) {
    if (!quiet) console.log('Yap is not running.')
    return
  }
  for (const pid of pids) process.kill(pid, 'SIGTERM')
  await waitFor(() => daemonPids().length === 0, 3000)
  if (!quiet) console.log('Stopped Yap.')
}

async function restartIfRunning() {
  if (daemonPids().length === 0) return
  await stop({ quiet: true })
  await start()
}

function printStatus() {
  const pids = daemonPids()
  if (pids.length === 0) {
    console.log('Yap is not running. Start it with `yap start`.')
    return false
  }
  const state = readJSON(statePath, {})
  const config = { ...DEFAULTS, ...readConfig() }
  const rows = [
    ['Status', `${state.phase ?? 'starting'} (pid ${pids[0]})`],
    ['Hotkey', `${config.mode === 'hold' ? 'hold' : 'press'} ${state.hotkey ?? config.hotkey}`],
    ['Model', `${state.model ?? config.model}${state.modelReady ? '' : ' (not ready yet)'}`],
    ['Accessibility', state.accessibility ? 'granted' : 'NOT granted'],
    ['Microphone', state.microphone ?? 'unknown'],
  ]
  for (const [label, value] of rows) console.log(`${label.padEnd(14)} ${value}`)

  const settings = 'System Settings → Privacy & Security'
  if (!state.accessibility) {
    console.log(`\nThe hotkey and pasting need Accessibility. Enable "Yap" under ${settings} → Accessibility.`)
  }
  if (state.microphone === 'denied') {
    console.log(`\nMicrophone access was denied. Enable "Yap" under ${settings} → Microphone.`)
  }
  if (state.error) console.log(`\nLast error: ${state.error}`)
  return true
}

function run() {
  requireHelper()
  if (daemonPids().length > 0) die('Yap is already running in the background. Run `yap stop` first.')
  const child = spawn(helper, [], { stdio: 'inherit' })
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal))
  child.on('exit', (code) => process.exit(code ?? 0))
}

// ---------------------------------------------------------------- login item

function install() {
  requireHelper()
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${BUNDLE_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-g</string>
    <string>${app}</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
`
  mkdirSync(path.dirname(agentPath), { recursive: true })
  const domain = `gui/${userInfo().uid}`
  spawnSync('launchctl', ['bootout', `${domain}/${BUNDLE_ID}`], { stdio: 'ignore' })
  writeFileSync(agentPath, plist)
  const loaded = spawnSync('launchctl', ['bootstrap', domain, agentPath], { encoding: 'utf8' })
  if (loaded.status !== 0) die(`launchctl could not load the login item: ${loaded.stderr.trim()}`)
  console.log('Yap will now start at login (and has been started).')
}

function uninstall() {
  spawnSync('launchctl', ['bootout', `gui/${userInfo().uid}/${BUNDLE_ID}`], { stdio: 'ignore' })
  rmSync(agentPath, { force: true })
  console.log('Yap will no longer start at login. It keeps running until you `yap stop`.')
}

// ---------------------------------------------------------------- config

function parseValue(key, raw) {
  if (!(key in DEFAULTS)) die(`unknown config key "${key}". Keys: ${Object.keys(DEFAULTS).join(', ')}`)
  const expected = typeof DEFAULTS[key]
  if (expected === 'boolean') {
    if (raw !== 'true' && raw !== 'false') die(`${key} must be true or false.`)
    return raw === 'true'
  }
  if (Array.isArray(DEFAULTS[key])) {
    try {
      const value = JSON.parse(raw)
      if (Array.isArray(value) && value.every((item) => typeof item === 'string')) return value
    } catch {}
    die(`${key} must be a JSON array of strings, e.g. '["com.tinyspeck.slackmacgap"]'.`)
  }
  if (expected === 'object') {
    try {
      const value = JSON.parse(raw)
      if (value && typeof value === 'object' && !Array.isArray(value)) return value
    } catch {}
    die(`${key} must be a JSON object, e.g. '{"clod code": "Claude Code"}'.`)
  }
  if (CHOICES[key] && !CHOICES[key].includes(raw)) die(`${key} must be one of: ${CHOICES[key].join(', ')}.`)
  if (key === 'hotkey') return helperJSON(['check-hotkey', raw], { quiet: true }).hotkey
  if (key === 'model') {
    const ids = helperJSON(['models']).map((model) => model.id)
    if (!ids.includes(raw)) die(`unknown model "${raw}". Available: ${ids.join(', ')}.`)
  }
  return raw
}

async function setConfig(key, raw) {
  const value = parseValue(key, raw)
  writeConfig({ ...readConfig(), [key]: value })
  console.log(`${key} = ${JSON.stringify(value)}`)
  await restartIfRunning()
}

async function config(args) {
  const [action, key, ...rest] = args
  if (!action) {
    console.log(`# ${configPath}`)
    console.log(JSON.stringify({ ...DEFAULTS, ...readConfig() }, null, 2))
    return
  }
  if (action === 'set' && key && rest.length > 0) return setConfig(key, rest.join(' '))
  if (action === 'unset' && key) {
    const current = readConfig()
    delete current[key]
    writeConfig(current)
    console.log(`${key} reset to ${JSON.stringify(DEFAULTS[key])}`)
    return restartIfRunning()
  }
  die('usage: yap config [set <key> <value> | unset <key>]')
}

async function hotkey(args) {
  if (args.length === 0) {
    console.log({ ...DEFAULTS, ...readConfig() }.hotkey)
    return
  }
  await setConfig('hotkey', args.join('+'))
}

/** Resolves "Slack" or "com.tinyspeck.slackmacgap" to a bundle identifier. */
function bundleID(app) {
  if (/^[\w-]+(\.[\w-]+)+$/.test(app)) return app
  const result = spawnSync('osascript', ['-e', `id of application ${JSON.stringify(app)}`], { encoding: 'utf8' })
  if (result.status !== 0) die(`no app called "${app}" was found.`)
  return result.stdout.trim()
}

function appName(id) {
  const found = spawnSync('mdfind', [`kMDItemCFBundleIdentifier == '${id}'`], { encoding: 'utf8' })
  const path = found.stdout.split('\n').find((line) => line.endsWith('.app'))
  return path ? path.split('/').pop().replace(/\.app$/, '') : id
}

async function send(args) {
  const [action, ...rest] = args
  const current = { ...DEFAULTS, ...readConfig() }.sendApps
  if (!action) {
    const apps = current.filter((id) => id !== '*')
    if (current.includes('*')) console.log('Yap presses Return after pasting in every app.')
    else if (apps.length === 0) {
      return console.log('Auto-send is off. Turn it on for an app with `yap send add <app>`, or from the menu bar.')
    }
    if (apps.length > 0) {
      console.log(current.includes('*') ? 'Apps kept for when that is turned off:' : 'Yap presses Return after pasting in:')
      for (const id of apps) console.log(`  ${appName(id).padEnd(20)} ${id}`)
    }
    return
  }
  let next
  if (action === 'all') next = [...current.filter((id) => id !== '*'), '*']
  else if (action === 'off') next = []
  else if ((action === 'add' || action === 'remove') && rest.length > 0) {
    const id = bundleID(rest.join(' '))
    const without = current.filter((item) => item !== id)
    next = action === 'add' ? [...without, id] : without
  } else {
    die('usage: yap send [add <app> | remove <app> | all | off]')
  }
  writeConfig({ ...readConfig(), sendApps: next })
  await send([])
  await restartIfRunning()
}

async function model(args) {
  if (args.length > 0) return setConfig('model', args[0])
  const current = { ...DEFAULTS, ...readConfig() }.model
  for (const { id, summary } of helperJSON(['models'])) {
    console.log(`${id === current ? '*' : ' '} ${id.padEnd(18)} ${summary}`)
  }
}

// ---------------------------------------------------------------- one-off commands

function transcribe(args) {
  const json = args.includes('--json')
  const rest = args.filter((arg) => arg !== '--json')
  if (rest.length === 0 || rest[0].startsWith('--')) {
    die('usage: yap transcribe <audio-file> [--model <id>] [--runs <n>] [--raw]')
  }
  if (!existsSync(rest[0])) die(`no such file: ${rest[0]}`)

  const result = helperJSON(['transcribe', path.resolve(rest[0]), ...rest.slice(1)], { quiet: json })
  if (json) return console.log(JSON.stringify(result, null, 2))

  const best = Math.min(...result.transcribeMs)
  const speed = Math.round((result.audioSeconds * 1000) / best)
  console.log(result.text)
  console.error(
    `\n${result.audioSeconds.toFixed(1)} s of audio → ${best.toFixed(0)} ms with ${result.model} ` +
      `(${speed}× real time, model load ${Math.round(result.loadMs)} ms)`,
  )
}

function download(args) {
  const result = helperJSON(['download', ...(args[0] ? ['--model', args[0]] : [])])
  console.log(`${result.model} is ready.`)
}

function history(args) {
  const count = Number(args[0] ?? 10)
  if (!Number.isInteger(count) || count < 1) die('usage: yap history [n]')
  if (!existsSync(historyPath)) return console.log('No dictations yet.')
  const entries = readFileSync(historyPath, 'utf8').trim().split('\n').slice(-count)
  for (const line of entries) {
    const entry = JSON.parse(line)
    const text = entry.text.replaceAll('\n', '\n  ')
    console.log(`${new Date(entry.at).toLocaleString()}  (${entry.delivery})\n  ${text}`)
    if (entry.raw) console.log(`  heard: ${entry.raw}`)
    console.log()
  }
}

function logs(args) {
  if (!existsSync(logPath)) return console.log('No log yet.')
  spawn('tail', ['-n', '50', ...(args.includes('-f') ? ['-f'] : []), logPath], { stdio: 'inherit' })
}

function doctor() {
  let healthy = true
  const check = (ok, label, fix) => {
    console.log(`${ok ? '✓' : '✗'} ${label}`)
    if (!ok) {
      healthy = false
      if (fix) console.log(`    ${fix}`)
    }
  }

  check(process.platform === 'darwin' && process.arch === 'arm64', 'macOS on Apple Silicon')
  const built = existsSync(helper)
  check(built, 'The Yap app is built', 'Run `yap start`, which builds it (a few minutes the first time)')
  if (!built) return process.exit(1)
  check(isCurrent(), 'The Yap app matches the installed version', 'Run `yap restart` to rebuild it')

  const signature = spawnSync('codesign', ['-dvv', app], { encoding: 'utf8' }).stderr ?? ''
  const authority = signature.match(/^Authority=(.+)$/m)?.[1]
  check(true, `Signed: ${authority ?? 'ad-hoc (permissions are asked again after every rebuild)'}`)

  const running = daemonPids().length > 0
  check(running, 'Yap is running', 'Run `yap start`')
  const state = running ? readJSON(statePath, {}) : {}
  const settings = 'System Settings → Privacy & Security'
  if (running) {
    check(state.accessibility === true, 'Accessibility permission', `Enable "Yap" under ${settings} → Accessibility`)
    check(state.hotkeyActive === true, `Hotkey "${state.hotkey}" is active`, 'Needs the Accessibility permission')
    check(state.microphone === 'granted', 'Microphone permission', `Enable "Yap" under ${settings} → Microphone`)
    check(state.modelReady === true, `Model ${state.model} is loaded`, `Currently: ${state.phase}. See \`yap logs\``)
  }

  const config = { ...DEFAULTS, ...readConfig() }
  if (config.hotkey.split('+').includes('fn')) {
    // 0 = do nothing, 1 = change input source, 2 = emoji picker, 3 = dictation
    const usage = spawnSync('defaults', ['read', 'com.apple.HIToolbox', 'AppleFnUsageType'], { encoding: 'utf8' })
    const value = usage.status === 0 ? usage.stdout.trim() : '0'
    check(
      value === '0',
      'The fn/🌐 key is free for Yap',
      'System Settings → Keyboard → "Press 🌐 key to" → Do Nothing, or pick another key: `yap hotkey right_option`',
    )
  }
  const launchAgent = existsSync(agentPath)
  console.log(`${launchAgent ? '✓' : '·'} Starts at login${launchAgent ? '' : ': off (`yap install` to enable)'}`)
  process.exit(healthy ? 0 : 1)
}

// ---------------------------------------------------------------- main

const [command, ...args] = process.argv.slice(2)

switch (command) {
  case 'start':
    await start()
    break
  case 'stop':
    await stop()
    break
  case 'restart':
    await stop({ quiet: true })
    await start()
    break
  case 'status':
    process.exit(printStatus() ? 0 : 1)
    break
  case 'run':
    run()
    break
  case 'install':
    install()
    break
  case 'uninstall':
    uninstall()
    break
  case 'config':
    await config(args)
    break
  case 'hotkey':
    await hotkey(args)
    break
  case 'send':
    await send(args)
    break
  case 'model':
  case 'models':
    await model(args)
    break
  case 'transcribe':
    transcribe(args)
    break
  case 'download':
    download(args)
    break
  case 'history':
    history(args)
    break
  case 'logs':
    logs(args)
    break
  case 'doctor':
    doctor()
    break
  case undefined:
  case 'help':
  case '--help':
  case '-h':
    console.log(USAGE)
    break
  case '--version':
  case '-v':
    console.log(readJSON(path.join(root, 'package.json'), {}).version)
    break
  default:
    console.error(`yap: unknown command "${command}"\n`)
    console.log(USAGE)
    process.exit(1)
}
