import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const detail = readFileSync(new URL("../PortDetail.qml", import.meta.url), "utf8")
const card = readFileSync(new URL("../SparkCard.qml", import.meta.url), "utf8")
const panel = readFileSync(new URL("../PortalPanel.qml", import.meta.url), "utf8")
const request = detail.match(/^  function requestRange\([^)]*\) \{\n[\s\S]*?^  \}/m)
const loaded = detail.match(/function onMetricRangeLoaded\(([^)]*)\) \{([\s\S]*?)\n    \}/)
assert.ok(request)
assert.ok(loaded)
const requests = []
const ctx = vm.createContext({
  entry: { port: 3307 }, rangeSeconds: 3600, queryKey: 'plugin:3307:3600',
  service: { metricRequestSequence: 10, loadMetricRange: (...args) => requests.push(args) },
  savedView: null, hoverTime: 7, historyError: '', historyWarning: '', historyStatus: 'idle'
})
ctx.detail = ctx
vm.runInContext(request[0], ctx)
const complete = (port, seconds, id, view, error = '', warning = '') => {
  ctx.result = [port, seconds, id, view, error, warning]
  vm.runInContext(`(function (${loaded[1]}) {${loaded[2]}})(...result)`, ctx)
}
ctx.requestRange(true)
assert.equal(ctx.historyStatus, 'loading')
assert.equal(ctx.hoverTime, -1)
assert.equal(ctx.requestId, 11)
const saved = { count: 500, buckets: [] }
complete(3307, 3600, 10, saved)
assert.equal(ctx.historyStatus, 'loading', 'a completion from a destroyed detail cannot reveal this chart')
complete(3307, 3600, 11, saved)
assert.equal(ctx.savedView, saved)
assert.equal(ctx.historyStatus, 'ready')
ctx.requestRange(false)
assert.equal(ctx.historyStatus, 'ready', 'background refresh retains the visible plot')
assert.equal(ctx.savedView, saved)
complete(3307, 3600, 12, null, 'read failed')
assert.equal(ctx.savedView, saved, 'background failure keeps the last successful view')
assert.equal(ctx.historyError, 'read failed')
ctx.rangeSeconds = 86400
ctx.requestRange(true)
assert.equal(ctx.savedView, null)
assert.equal(ctx.historyStatus, 'loading')
complete(3307, 3600, 12, saved)
assert.equal(ctx.savedView, null, 'a stale range cannot replace the current selection')
complete(3307, 86400, 13, { count: 0, buckets: [] })
assert.equal(ctx.historyStatus, 'ready')
assert.equal(ctx.historyError, '')
ctx.entry = { port: 3308 }
ctx.requestRange(true)
complete(3307, 86400, 13, saved)
assert.equal(ctx.historyStatus, 'loading')
complete(3308, 86400, 14, null, 'unreadable')
assert.equal(ctx.historyStatus, 'error')
assert.equal(ctx.savedView, null, 'initial failure uses bounded live fallback with an error')
const previousService = ctx.service
ctx.service = null
assert.doesNotThrow(() => ctx.requestRange(false), 'a stale query binding cannot dispatch while the service is destroyed')
ctx.service = previousService
ctx.entry = null
assert.doesNotThrow(() => ctx.requestRange(false), 'entry removal can precede query binding invalidation')
assert.doesNotThrow(() => complete(3308, 86400, 14, saved), 'late completion after entry removal is harmless')
assert.match(detail, /last: detail\.stats/, 'heroes remain current independently of historical selection')
assert.match(detail, /onMetricsRevisionChanged\(\)/)
assert.match(detail, /History\.aggregate\(/)
assert.match(detail, /running: detail.active && detail.queryKey !==/)
assert.match(detail, /Saved history unavailable/)
assert.match(card, /HoverHandler \{/)
assert.doesNotMatch(card, /MouseArea|hoverEnabled/)
assert.match(card, /visible: !card\.loading/)
assert.match(card, /enabled: !card\.loading/)
assert.match(card, /History.connected\(previous, bucket, card.field\)/)
const labels = [...card.matchAll(/text: \{\n([\s\S]*?)\n        \}/g)]
const hero = new Function('card', labels[0][1])
const caption = new Function('card', labels[1][1])
const steady = { loading: false, phase: 'steady', hoverTime: -1, hoverIndex: -1, lo: 42, hi: 42, last: null, format: String }
assert.equal(hero(steady), '—')
assert.equal(caption(steady), 'steady at 42')
assert.equal(hero({ ...steady, hoverTime: 90, series: [] }), 'no sample')
assert.equal(caption({ ...steady, loading: true }), '')
const history = vm.createContext({})
vm.runInContext(readFileSync(new URL('../lib/History.js', import.meta.url), 'utf8').replace(/^\.pragma library\s*/m, ''), history)
const keys = vm.createContext({ root: { rangeSeconds: 3600 }, History: history, Util: { clamp: (v, a, b) => Math.max(a, Math.min(b, v)) } })
vm.runInContext(panel.match(/^  function stepRange\([^)]*\) \{\n[\s\S]*?^  \}/m)[0], keys)
keys.stepRange(1)
assert.equal(keys.root.rangeSeconds, 10800)
keys.stepRange(-1)
assert.equal(keys.root.rangeSeconds, 3600)
assert.match(panel, /root.mode === "detail" && \(t === "\[" \|\| t === "\]"\)/)
assert.match(panel, /rangeSeconds: root.rangeSeconds/)
assert.match(panel, /id: settingHover/)
console.log('Range selection, stale completions, background refresh, errors, current heroes and shared hover checks passed')
const paint = card.match(/        onPaint: \{([\s\S]*?)\n        \}\n      \}/)
assert.ok(paint)
const sparseView = history.aggregate([{ t: 0, cpuPct: 1 }, { t: 20, cpuPct: 99 }, { t: 21, cpuPct: 2 }], 40, 40, 4)
const segments = []
let start
const canvasContext = { reset() {}, beginPath() {}, moveTo(x,y) { start=[x,y] }, lineTo(x,y) { segments.push([start,[x,y]]) }, stroke() {}, fillRect() {} }
new Function('card', 'History', 'Util', 'getContext', paint[1])({
  lo: 1, field: 'cpuPct', series: sparseView.buckets, accent: '',
  plotX: t => t, plotY: value => value
}, history, { alpha: () => '' }, () => canvasContext)
assert.ok(segments.some(([a,b]) => a[1] === 2 && b[1] === 99), 'actual paint emits the bucket spike envelope')
assert.ok(segments.every(([a,b]) => a[0] === b[0]), 'actual paint draws no average line across missing bins')
const plotX = card.match(/^  function plotX\(([^)]*)\) \{([\s\S]*?)\n  \}/m)
const x = new Function(plotX[1], 'pad', 'canvas', 'view', plotX[2])
assert.equal(x(25, 2, {width:104}, {start:0,end:100}), 27, 'time position does not depend on sample density')
console.log('Actual Canvas code preserves peak envelopes, leaves missing bins unconnected and positions by time')

assert.doesNotMatch(detail, /model: \[0, 0\.5, 1\]/, 'a shared range is not a spatial axis across two independent chart columns')
assert.match(detail, /horizontalAlignment: Text.AlignHCenter\n      text: Qt\.formatDateTime\(new Date\(detail\.view\.start/, 'the shared time window is stated as one centered interval')
