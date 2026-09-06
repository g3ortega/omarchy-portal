import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'

const source = fs.readFileSync(new URL('../Service.qml', import.meta.url), 'utf8')
const panel = fs.readFileSync(new URL('../PortalPanel.qml', import.meta.url), 'utf8')
const functions = (text, names) => names.map(name =>
  text.match(new RegExp('^  function ' + name + '\\([^)]*\\) \\{[\\s\\S]*?^  \\}', 'm'))[0]
).join('\n')

const backend = vm.createContext({ providers: [], tunnels: {}, stats: {}, calls: [] })
vm.runInContext(functions(source, [
  'providerFor', 'actionProviderFor', 'validProcessIdentity', 'exposureKey',
  'shareTarget', 'stopTarget', 'expose', 'unexpose'
]), backend)
backend._runAction = (...args) => {
  backend.calls.push(args)
  return true
}
backend.routeFor = () => null
backend.publicTunnelFor = () => null
backend.urlFor = () => 'http://localhost:3000'
backend.canRestart = () => true
const publicBinding = source.match(/readonly property var publicProviders: \{([\s\S]*?)\n  \}/)[1]
Object.defineProperty(backend, 'publicProviders', {
  get: () => vm.runInContext('(function(){' + publicBinding + '})()', backend)
})

const entry = { port: 3000, category: 'dev', process: { pid: 999999, start: '1' } }
const ctx = vm.createContext({
  service: backend,
  entry,
  selectedPort: 3000,
  expandedKind: '',
  shareIndex: 2,
  pendingAction: null,
  Util: { clamp: (n, a, b) => Math.max(a, Math.min(b, n)) },
  keyCatcher: { forceActiveFocus() {} },
  settingsOpen: false,
  stillListed: () => true,
  entryForPort: () => entry,
  collapse() {
    ctx.expandedKind = ''
  },
  expand(p, kind) {
    ctx.expandedKind = kind
  },
  openSettings() {
    ctx.settingsOpen = true
  },
  requestAction(kind, e, extra) {
    ctx.pendingAction = { kind, entry: e, ...extra }
  }
})
ctx.root = ctx
Object.defineProperty(ctx, 'publicProviders', { get: () => backend.publicProviders })
Object.defineProperty(ctx, 'portlessReady', {
  get: () => backend.actionProviderFor('portless')?.status === 'ready'
})
vm.runInContext(functions(panel, [
  'verbsFor', 'activateVerb', 'activateVerbById', 'chooseProvider',
  'pendingStillValid', 'revalidateProviders'
]), ctx)
const ids = () => Array.from(ctx.verbsFor(entry), x => x.id)

backend.providers = [
  { id: 'portless', reach: 'local', status: 'setup', available: false },
  { id: 'cloudflared', reach: 'public', status: 'setup', available: false },
  { id: 'ngrok', reach: 'public', status: 'missing', available: false }
]
assert.deepEqual(ids(), ['pause', 'restart', 'stop'])
assert.equal(backend.providers.length, 3, 'Settings retains the full roster')
ctx.activateVerbById(entry, 'name')
ctx.activateVerbById(entry, 'share')
assert.equal(ctx.expandedKind, '')
assert.equal(ctx.settingsOpen, false)
assert.equal(backend.expose(3000, 'portless', 'app'), false)

backend.providers[0] = { ...backend.providers[0], available: true }
assert.equal(ids()[0], 'name')
ctx.activateVerbById(entry, 'name')
assert.equal(ctx.settingsOpen, true)

backend.providers[0].status = 'ready'
ctx.settingsOpen = false
ctx.activateVerbById(entry, 'name')
assert.equal(ctx.expandedKind, 'naming')
backend.providers[0].available = false
ctx.revalidateProviders()
assert.equal(ctx.expandedKind, '')
assert.equal(backend.unexpose(3000, 'portless'), false)

backend.providers[1] = { ...backend.providers[1], available: true, status: 'ready' }
assert.ok(ids().includes('share'))
ctx.chooseProvider(3000, backend.providers[1])
assert.equal(ctx.pendingAction.kind, 'share')
const stale = backend.providers[1]
backend.providers[1] = { ...stale, available: false }
ctx.revalidateProviders()
assert.equal(ctx.pendingAction, null)
ctx.chooseProvider(3000, stale)
assert.equal(ctx.pendingAction, null)

backend.tunnels = { 'cloudflared:3000': { provider: 'cloudflared' } }
backend.publicTunnelFor = () => backend.tunnels['cloudflared:3000']
ctx.activateVerbById(entry, 'share')
assert.equal(backend.calls.length, 1, 'active public share can stop without its binary')
assert.equal(backend.calls[0][1][0], 'stop')

console.log('Provider availability gates verbs, shortcuts, stale choices, confirmations and starts while preserving active public stops')
