import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
const load = ["loadMetricRange", "dispatchMetricRead", "cancelMetricRanges"].map(name =>
  source.match(new RegExp(`^  function ${name}\\([^)]*\\) \\{[\\s\\S]*?^  \\}`, "m"))[0]
).join("\n")
const handler = source.slice(source.indexOf("    id: diskReadProcess")).match(/onExited: function \(([^)]*)\) \{([\s\S]*?)\n    \}/)
const plain = value => JSON.parse(JSON.stringify(value))
const first = { port: 3307, seconds: 3600, end: 10000, id: 1 }
const next = { port: 3307, seconds: 172800, end: 10002, id: 2 }
function session(text, queued = next, accepted = true) {
  const events = []
  const ctx = vm.createContext({
    alive: true, _metricRead: first, _metricReadQueue: queued ? [queued] : [],
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
  assert.equal(ctx._metricReadQueue.length, 0)
}
console.log("ok failed range reads complete and dispatch the newest range on the same port")
{
  const { ctx, events } = session('{"ok":true,"view":{"buckets":[]}}')
  ctx.exitHandler(0)
  assert.deepEqual(plain(events[1]), ["complete", 3307, 3600, 1, { buckets: [] }, ""])
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
  assert.deepEqual(plain(ctx._metricReadQueue[0]), { port: 9200, seconds: 1800, end: 10001, id: 4 })
  assert.equal(events.length, 0)
}
{
  const { ctx } = session('{"ok":true,"view":{"buckets":[]}}')
  ctx.metricRangeLoaded = () => ctx.loadMetricRange(9200, 1800, 10005, 5)
  ctx.exitHandler(0)
  assert.equal(ctx._metricRead.id, 2)
  assert.equal(ctx._metricReadQueue[0].id, 5)
}
{
  const { ctx, events } = session('{"ok":true,"view":{"buckets":[]}}')
  ctx.alive = false
  ctx.exitHandler(0)
  assert.deepEqual(events, [])
}
console.log("ok read completion preserves request identity, navigation, and shutdown")

{
  const { ctx, events } = session('{"ok":true,"view":{"buckets":[]}}', null)
  const ownerA = {}, ownerB = {}
  ctx.diskReadProcess.running = true
  ctx.loadMetricRange(3307, 3600, 10000, 2, ownerB)
  ctx.loadMetricRange(3307, 1800, 10001, 3, ownerA)
  ctx.loadMetricRange(3307, 21600, 10002, 4, ownerA)
  assert.deepEqual(Array.from(ctx._metricReadQueue, request => request.id), [2, 4])
  ctx.diskReadProcess.running = false
  ctx.exitHandler(0)
  assert.equal(ctx._metricRead.id, 2)
  ctx.diskReadProcess.running = false
  ctx.exitHandler(0)
  assert.equal(ctx._metricRead.id, 4)
  ctx.diskReadProcess.running = false
  ctx.exitHandler(0)
  assert.deepEqual(events.filter(event => event[0] === "complete").map(event => event[3]), [1, 2, 4])
  assert.equal(ctx._metricReadQueue.length, 0)
}

{
  const { ctx } = session("", null)
  const ownerA = {}, ownerB = {}
  ctx.diskReadProcess.running = true
  ctx.loadMetricRange(3307, 3600, 10000, 2, ownerA)
  ctx.loadMetricRange(6381, 3600, 10000, 3, ownerB)
  ctx.cancelMetricRanges(ownerA)
  assert.deepEqual(Array.from(ctx._metricReadQueue, request => request.id), [3])
  ctx.cancelMetricRanges(ownerA)
  assert.equal(ctx._metricReadQueue.length, 1)
  ctx.diskReadProcess.running = false
  ctx.dispatchMetricRead()
  assert.equal(ctx._metricRead.id, 3)
}

{
  const { ctx, events } = session("", null, false)
  const owners = Array.from({ length: 33 }, () => ({}))
  ctx.diskReadProcess.running = true
  owners.forEach((owner, i) => ctx.loadMetricRange(3307, 3600, 10000, i + 2, owner))
  assert.equal(ctx._metricReadQueue.length, 32)
  assert.equal(events[0][3], 34)
  assert.match(events[0][5], /busy/)
  ctx.loadMetricRange(3307, 1800, 10000, 35, owners[0])
  assert.equal(ctx._metricReadQueue[0].id, 35)
  assert.equal(ctx._metricReadQueue.length, 32)
  ctx.diskReadProcess.running = false
  ctx.dispatchMetricRead()
  assert.equal(ctx._metricReadQueue.length, 0)
  assert.equal(ctx._metricRead, null)
  assert.equal(events.filter(event => event[0] === "complete").length, 33,
    "every retained request completes even when all launches are refused")
}
console.log("ok independent detail owners retain FIFO reads, coalesce, cancel and receive bounded-queue failures")
