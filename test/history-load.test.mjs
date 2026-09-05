import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
const load = source.match(/^  function loadMetricRange\([^)]*\) \{[\s\S]*?^  \}/m)[0]
const handler = source.slice(source.indexOf("    id: diskReadProcess")).match(/onExited: function \(([^)]*)\) \{([\s\S]*?)\n    \}/)
const plain = value => JSON.parse(JSON.stringify(value))
const first = { port: 3307, seconds: 3600, end: 10000, id: 1 }
const next = { port: 3307, seconds: 172800, end: 10002, id: 2 }
function session(text, queued = next, accepted = true) {
  const events = []
  const ctx = vm.createContext({
    alive: true, _metricRead: first, _metricReadQueued: queued,
    diskOut: { text }, diskReadProcess: { running: false }, metricsAppendProcess: { running: false },
    _metricBatches: [], metricsRetry: { running: false }, flushMetricBatch() {},
    parseJson: value => { try { return JSON.parse(value) } catch { return null } },
    metricRangeLoaded: (...args) => events.push(["complete", ...args]),
    runScript: (process, _script, args) => { events.push(["start", ...args]); process.running = accepted; return accepted }
  })
  ctx.root = ctx
  vm.runInContext(load, ctx)
  vm.runInContext(`function exitHandler(${handler[1]}) {${handler[2]}}`, ctx)
  return { ctx, events }
}
for (const [text, code] of [["", 0], ["not-json", 0], ['{"ok":false,"error":"refused"}', 0],
  ['{"ok":true}', 0], ['{"ok":false,"view":{"buckets":[]}}', 0], ['{"ok":true,"view":{"buckets":[]}}', 1]]) {
  const { ctx, events } = session(text)
  ctx.exitHandler(code)
  assert.equal(events.length, 2)
  assert.deepEqual(events[0], ["start", "query", "3307", "172800", "10002", "400"])
  assert.deepEqual(plain(events[1].slice(0, 5)), ["complete", 3307, 3600, 1, null])
  assert.ok(events[1][5])
  assert.equal(ctx._metricReadQueued, null)
}
console.log("ok failed range reads complete and dispatch the newest range on the same port")
{
  const { ctx, events } = session('{"ok":true,"view":{"buckets":[]},"warning":"legacy partial line retained"}')
  ctx.exitHandler(0)
  assert.deepEqual(plain(events[1]), ["complete", 3307, 3600, 1, { buckets: [] }, "", "legacy partial line retained"])
}
{
  const { ctx, events } = session("", null, false)
  ctx.loadMetricRange(3307, 3600, 10000, 1)
  assert.equal(events[1][0], "complete")
  assert.ok(events[1][5])
}
{
  const { ctx, events } = session("", null)
  ctx.diskReadProcess.running = true
  ctx.loadMetricRange(6381, 3600, 10000, 3)
  ctx.loadMetricRange(9200, 1800, 10001, 4)
  assert.deepEqual(plain(ctx._metricReadQueued), { port: 9200, seconds: 1800, end: 10001, id: 4 })
  assert.equal(events.length, 0)
}
{
  const { ctx } = session('{"ok":true,"view":{"buckets":[]}}')
  ctx.metricRangeLoaded = () => ctx.loadMetricRange(9200, 1800, 10005, 5)
  ctx.exitHandler(0)
  assert.equal(ctx._metricRead.id, 2)
  assert.equal(ctx._metricReadQueued.id, 5)
}
{
  const { ctx, events } = session('{"ok":true,"view":{"buckets":[]}}')
  ctx.alive = false
  ctx.exitHandler(0)
  assert.deepEqual(events, [])
}
console.log("ok read completion preserves request identity, navigation, warnings, and shutdown")
