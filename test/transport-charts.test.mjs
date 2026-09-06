import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
const detail = readFileSync(new URL('../PortDetail.qml', import.meta.url), 'utf8')
const history = vm.createContext({})
vm.runInContext(readFileSync(new URL('../lib/History.js', import.meta.url), 'utf8').replace(/^\.pragma library\s*/m, ''), history)
const mixed = history.aggregate([
  {t: 1, latMs: 200}, {t: 2, tcpRttMs: 0.017}, {t: 3, latMs: 400, tcpRttMs: 0.023}, {t: 4, latMs: null, tcpRttMs: null}
], 10, 10, 1)
assert.equal(mixed.stats.tcpRttMs.lo, 0.017)
assert.equal(mixed.stats.tcpRttMs.hi, 0.023)
assert.equal(mixed.stats.latMs.lo, 200)
assert.equal(mixed.buckets[0].latMs.avg, 300)
assert.equal(mixed.buckets[0].tcpRttMs.avg, 0.02)
assert.equal(mixed.buckets[0].tcpRttMs.count, 2)
assert.equal(history.aggregate([{t: 1, latMs: 99}], 10, 10).stats.tcpRttMs.lo, null, 'old HTTP samples do not become TCP history')
const ctx = vm.createContext({ entry: {port:3307,httpProbe:false}, latencyChoice:'', stats:null })
ctx.detail = ctx
for (const name of ['formatLatency', 'emptyReasonFor', 'toggleLatency']) {
 const fn = detail.match(new RegExp('^  function '+name+'\\([^)]*\\) \\{\\n[\\s\\S]*?^  \\}', 'm'))
 assert.ok(fn)
 vm.runInContext(fn[0],ctx)
}
const field = detail.match(/readonly property string latencyField: ([^\n]+)/)
assert.ok(field)
const selected = () => vm.runInContext(field[1],ctx)
assert.equal(selected(), 'tcpRttMs')
ctx.entry = {port:8080,httpProbe:true}
assert.equal(selected(), 'latMs')
ctx.stats = {latMs:null,tcpRttMs:0.017}
assert.equal(selected(), 'latMs', 'missing HTTP readings do not switch measurement kind')
ctx.latencyChoice = 'tcpRttMs'
assert.equal(selected(), 'tcpRttMs')
ctx.stats = {latMs:200,tcpRttMs:null}
assert.equal(selected(), 'tcpRttMs', 'explicit TCP choice survives missing TCP readings')
vm.runInContext(detail.match(/onLatencyPortChanged: ([^\n]+)/)[1],ctx)
assert.equal(ctx.latencyChoice, '')
assert.equal(ctx.formatLatency(0.017), '0.017ms')
assert.equal(ctx.formatLatency(0), '0ms')
assert.equal(ctx.formatLatency(0.0001), '<0.001ms')
assert.equal(ctx.formatLatency(12.345), '12.3ms')
ctx.stats = {conns:0,tcpRttCount:0}
assert.equal(ctx.emptyReasonFor('tcpRttMs'), 'No active connections')
ctx.stats = {conns:3,tcpRttCount:0}
assert.equal(ctx.emptyReasonFor('tcpRttMs'), 'No RTT samples in this range')
assert.match(detail, /modeOptions:/)
assert.match(detail, /Kernel round-trip estimate/)
assert.match(detail, /stay unchanged while idle/)
console.log('HTTP/TCP history isolation, stable selection, port reset, fractional RTT and missing-data states passed')

const card = readFileSync(new URL('../SparkCard.qml', import.meta.url), 'utf8')
const span = new Function('phase', 'zeroAnchored', 'hi', 'lo', card.match(/readonly property real plotSpan: \{([\s\S]*?)\n  \}/)[1])
assert.ok(0.023 / span('active', true, 0.023, 0.017) > 0.9, 'fractional RTT uses the plotted range instead of an artificial 1ms floor')

ctx.entry = {port:8080,httpProbe:true}
ctx.latencyField = 'latMs'
ctx.toggleLatency()
assert.equal(ctx.latencyChoice, 'tcpRttMs')
ctx.latencyField = 'tcpRttMs'
ctx.toggleLatency()
assert.equal(ctx.latencyChoice, 'latMs')
ctx.entry = {port:3307,httpProbe:false}
ctx.latencyChoice = ''
ctx.toggleLatency()
assert.equal(ctx.latencyChoice, '', 'TCP-only services have no HTTP selection')
const panel = readFileSync(new URL('../PortalPanel.qml', import.meta.url), 'utf8')
assert.match(panel, /root.mode === "detail" && t === "t"/)
assert.match(panel, /detailLoader.item.toggleLatency\(\)/)
assert.match(detail, /text: "Kernel RTT · may stay unchanged while idle"/)
assert.match(detail, /Controls.ToolTip/)

assert.equal(ctx.formatLatency(null), '—')
assert.equal(ctx.formatLatency(undefined), '—')
const phase = new Function('lo', 'hi', 'format', card.match(/readonly property string phase: \{([\s\S]*?)\n  \}/)[1])
assert.equal(phase(2, null, ctx.formatLatency), 'collecting', 'a mode switch can update bounds separately')
assert.match(card, /model: card.modeOptions/)
assert.match(card, /onClicked: card.modeRequested\(modelData.value\)/)
assert.doesNotMatch(detail, /text: "Latency"/, 'the selector belongs inside the latency card')

let repaints = 0
const fieldChanged = card.match(/^  onFieldChanged: (.+)$/m)
assert.ok(fieldChanged, 'metric selection invalidates Canvas even when range and bounds are unchanged')
vm.runInNewContext(fieldChanged[1], { canvas: { requestPaint() { repaints++ } } })
assert.equal(repaints, 1)
