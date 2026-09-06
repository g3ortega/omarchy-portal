import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'

const source = fs.readFileSync(new URL('../PortalPanel.qml', import.meta.url), 'utf8')
const names = ['requestAction', 'cancelConfirmation', 'acceptConfirmation', 'confirmAccept',
  'pendingStillValid', 'stillListed', 'showMoment', 'dismissNotice']
const functions = names.map(name => source.match(new RegExp('^  function ' + name + '\\([^)]*\\) \\{[\\s\\S]*?^  \\}', 'm'))?.[0]
  || source.match(new RegExp('^  function ' + name + '\\([^)]*\\) \\{[^\\n]+\\}', 'm'))?.[0]).join('\n')
let current = { port: 3000, name: 'app', process: { pid: 999999, start: '1' } }
const calls = []
const context = vm.createContext({
  selectedPort: 3000, expandedKind: 'sharing', shareIndex: 1,
  detailEntry: current, pendingAction: null, pendingSetup: null,
  feedback: null, dismissedServiceError: '',
  confirmationDialog: { rememberFocus() { calls.push('remember focus') } },
  feedbackTimer: { stop() { calls.push('stop timer') }, restart() { calls.push('start timer') } },
  entryForPort: () => current,
  service: {
    busyAction: '', activeAction: null, lastError: 'status failed',
    actionProviderFor: () => ({ status: 'ready', reach: 'public' }),
    publicTunnelFor: () => null,
    sameProcess: (a, b) => a.pid === b.pid && a.start === b.start,
    expose: () => { calls.push('share'); return false },
    signalProcess: () => { calls.push('signal'); return true }
  }
})
context.root = context
vm.runInContext(functions, context)

context.requestAction('share', current, { provider: 'ngrok' })
assert.equal(context.detailEntry, current, 'confirmation preserves the charts behind it')
context.cancelConfirmation()
assert.equal(context.selectedPort, 3000)
assert.equal(context.expandedKind, 'sharing', 'cancel returns to the same provider picker')
assert.equal(context.shareIndex, 1)

context.requestAction('share', current, { provider: 'ngrok' })
context.confirmAccept()
assert.equal(context.pendingAction.kind, 'share', 'refused queue keeps consent visible')
const beforeBusy = calls.length
context.service.busyAction = 'cloudflared:3001'
context.acceptConfirmation()
assert.equal(calls.length, beforeBusy, 'busy confirmation does not dispatch')
context.service.busyAction = ''
context.service.expose = () => { calls.push('share'); return true }
context.confirmAccept()
assert.equal(context.pendingAction, null)

for (const change of ['process', 'missing', 'provider', 'tunnel', 'start']) {
  current = { port: 3000, name: 'app', process: { pid: 999999, start: '1' } }
  context.service.actionProviderFor = () => ({ status: 'ready', reach: 'public' })
  context.service.publicTunnelFor = () => null
  context.service.activeAction = null
  context.requestAction('share', current, { provider: 'ngrok' })
  if (change === 'process') current = { ...current, process: { pid: 999999, start: '2' } }
  if (change === 'missing') current = null
  if (change === 'provider') context.service.actionProviderFor = () => null
  if (change === 'tunnel') context.service.publicTunnelFor = () => ({ provider: 'cloudflared' })
  if (change === 'start') context.service.activeAction = { shareStartPort: 3000 }
  const before = calls.length
  context.confirmAccept()
  assert.equal(calls.length, before, `${change} invalidates consent without dispatch`)
  assert.equal(context.pendingAction, null)
}

context.showMoment('action failed', true)
assert.equal(context.feedback.kind, 'error')
assert.equal(calls.at(-1), 'stop timer', 'errors stay until dismissed or replaced')
context.dismissNotice()
assert.equal(context.feedback, null)
assert.equal(context.dismissedServiceError, 'status failed', 'one dismissal also suppresses the current backend error')
context.showMoment('Copied')
assert.equal(context.feedback.kind, 'moment')
assert.equal(calls.at(-1), 'start timer')

const settingsErrorChanged = source.match(/    function onSettingsSaveErrorChanged\(\) \{([\s\S]*?)\n    \}/)[1]
const settingsClosed = source.match(/  onSettingsOpenChanged: \{([\s\S]*?)\n  \}/)[1]
context.hostWidget = { settingsSaveError: 'Could not write shell.json' }
context.settingsOpen = true
vm.runInContext('(function(){' + settingsErrorChanged + '})()', context)
assert.equal(context.feedback.text, 'Could not write shell.json', 'async save failure reaches the top notice')
assert.equal(context.feedback.kind, 'error')
assert.equal(calls.at(-1), 'stop timer', 'async save failure does not expire')
context.settingsOpen = false
vm.runInContext('(function(){' + settingsClosed + '})()', context)
assert.equal(context.feedback.text, 'Could not write shell.json', 'leaving Settings preserves the error')
context.hostWidget.settingsSaveError = ''
vm.runInContext('(function(){' + settingsErrorChanged + '})()', context)
assert.equal(context.feedback.kind, 'error', 'clearing the backend field does not silently dismiss the notice')
context.dismissNotice()
assert.equal(context.feedback, null)

for (const kind of ['guidance', 'copy']) {
  context.feedback = { kind, text: 'Settings-only instructions' }
  vm.runInContext('(function(){' + settingsClosed + '})()', context)
  assert.equal(context.feedback, null, `${kind} remains scoped to Settings`)
}

assert.doesNotMatch(source, /case "confirm"|confirmKind:|onConfirmAccepted:/)
assert.match(source, /blocked: root.confirmation !== null/)
assert.match(source, /enabled: root.confirmation === null/)
assert.match(source, /root.expandedKind === "sharing" && root.service.publicTunnelFor\(root.selectedPort\)/)
console.log('Modal consent preserves context, rejects stale targets, retains refused actions, and keeps errors dismissible')
