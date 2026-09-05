import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"
const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
const names = ["saveMetricBatch", "flushMetricBatch"]
const functions = names.map(name => source.match(new RegExp(`^  function ${name}\\([^)]*\\) \\{[\\s\\S]*?^  \\}`, "m"))[0]).join("\n")
const handler = source.slice(source.indexOf("    id: metricsAppendProcess")).match(/onExited: function \(([^)]*)\) \{([\s\S]*?)\n    \}/)
const calls = []
const ctx = vm.createContext({ alive: true, _metricBatches: [], _metricQueuedBytes: 0, _metricDropped: 0,
  _metricSession: "session", _metricBatchSequence: 0, metricsError: "", metricsRevision: 0,
  _metricReadQueued: null, diskReadProcess: { running: false },
  metricsAppendProcess: { running: false }, metricsAppendOut: { text: "" },
  metricsRetry: { running: false, restart() { this.running = true } }, parseJson: JSON.parse,
  runScript: (process, script, args) => { calls.push(args); process.running = true; return true }
})
ctx.root = ctx
vm.runInContext(functions, ctx)
vm.runInContext(`function exitHandler(${handler[1]}) {${handler[2]}}`, ctx)
ctx.saveMetricBatch({ 3307: { t: 1, cpuPct: 9 } })
ctx.saveMetricBatch({ 3307: { t: 2, cpuPct: 99 } })
assert.equal(calls.length, 1)
ctx.metricsAppendProcess.running = false
ctx.metricsAppendOut.text = '{"ok":false,"error":"locked"}'
ctx.exitHandler(0)
assert.equal(ctx._metricBatches.length, 2)
assert.match(ctx.metricsError, /locked.*retrying/)
ctx.metricsRetry.running = false
ctx.flushMetricBatch()
assert.deepEqual(calls[1], calls[0], "uncertain writes retry with the same stable id")
ctx.metricsAppendProcess.running = false
ctx.metricsAppendOut.text = '{"ok":true}'
ctx.exitHandler(0)
assert.equal(ctx._metricBatches.length, 1)
assert.equal(ctx.metricsRevision, 1)
assert.notEqual(calls[2][2], calls[0][2])
ctx.metricsAppendProcess.running = false
ctx.exitHandler(0)
assert.equal(ctx._metricQueuedBytes, 0)
assert.equal(ctx.metricsError, "")
for (let i = 0; i < 121; i++) ctx.saveMetricBatch({ 3307: { t: i } })
assert.equal(ctx._metricBatches.length, 120)
assert.equal(ctx._metricDropped, 1)
assert.match(ctx.metricsError, /Recording gap/)
console.log("ok metric writes retain every queued batch, retry idempotently, and report bounded overflow")

{
  const batch = Object.fromEntries(Array.from({ length: 1025 }, (_, i) => [String(10000 + i), { t: 7, conns: i }]))
  const chunkContext = vm.createContext({ _metricBatches: [], _metricQueuedBytes: 0, _metricDropped: 0,
    _metricSession: "chunks", _metricBatchSequence: 0, metricsError: "", metricsRetry: { running: true } })
  vm.runInContext(functions, chunkContext)
  chunkContext.saveMetricBatch(batch)
  assert.equal(chunkContext._metricBatches.length, 3)
  const combined = {}, ids = new Set()
  for (const queued of chunkContext._metricBatches) {
    const part = JSON.parse(queued.text)
    assert.ok(Object.keys(part).length <= 512)
    assert.equal(ids.has(queued.id), false)
    ids.add(queued.id)
    for (const [port, sample] of Object.entries(part)) {
      assert.equal(Object.hasOwn(combined, port), false, "each sample is queued once")
      combined[port] = sample
    }
  }
  assert.deepEqual(combined, batch)
  assert.equal(chunkContext._metricQueuedBytes, chunkContext._metricBatches.reduce((sum, part) => sum + part.text.length, 0))
  assert.equal(chunkContext._metricDropped, 0)
  console.log("ok large watched sets split into bounded batches without changing or duplicating samples")
}

{
  const sequence = [], queueContext = vm.createContext({ alive: true, _metricBatches: [], _metricQueuedBytes: 0,
    _metricDropped: 0, _metricSession: "drain", _metricBatchSequence: 0, metricsError: "", metricsRevision: 0,
    _metricRead: null, _metricReadQueued: null,
    metricsAppendProcess: { running: false }, metricsAppendOut: { text: '{"ok":true}' },
    diskReadProcess: { running: false }, diskOut: { text: '{"ok":true,"view":{"buckets":[]}}' },
    metricsRetry: { running: false, restart() { this.running = true } },
    parseJson: JSON.parse, metricRangeLoaded() {}
  })
  queueContext.root = queueContext
  queueContext.runScript = (process, script, args) => {
    assert.equal(queueContext.metricsAppendProcess.running || queueContext.diskReadProcess.running, false,
      "read and write helpers cannot compete for the same storage lock")
    sequence.push(args[0]); process.running = true; return true
  }
  const load = source.match(/^  function loadMetricRange\([^)]*\) \{[\s\S]*?^  \}/m)[0]
  const readHandler = source.slice(source.indexOf("    id: diskReadProcess")).match(/onExited: function \(([^)]*)\) \{([\s\S]*?)\n    \}/)
  vm.runInContext(functions + "\n" + load, queueContext)
  vm.runInContext(`function writeExited(${handler[1]}) {${handler[2]}}`, queueContext)
  vm.runInContext(`function readExited(${readHandler[1]}) {${readHandler[2]}}`, queueContext)
  let revision = 0
  Object.defineProperty(queueContext, "metricsRevision", { get: () => revision, set(value) {
    revision = value
    queueContext.loadMetricRange(3307, 3600, 10000, revision)
  } })
  for (let i = 0; i < 6; i++) queueContext.saveMetricBatch({ 3307: { t: i } })
  queueContext.loadMetricRange(3307, 1800, 10000, 0)
  for (let i = 0; i < 6; i++) {
    assert.equal(queueContext.metricsAppendProcess.running, true)
    queueContext.metricsAppendProcess.running = false
    queueContext.writeExited(0)
  }
  assert.deepEqual(sequence, [...Array(6).fill("append-batch"), "query"])
  assert.equal(queueContext._metricQueuedBytes, 0)
  queueContext.saveMetricBatch({ 3307: { t: 7 } })
  assert.equal(queueContext.metricsAppendProcess.running, false)
  queueContext.diskReadProcess.running = false
  queueContext.readExited(0)
  assert.equal(queueContext.metricsAppendProcess.running, true)
  console.log("ok queued writes drain before chart refreshes; writes arriving during a read wait for its completion")

  queueContext.metricsAppendProcess.running = false
  queueContext.writeExited(0)
  queueContext.diskReadProcess.running = false
  queueContext.readExited(0)
  queueContext.saveMetricBatch({ 3307: { t: 8 } })
  queueContext.loadMetricRange(3307, 1800, 10000, 100)
  queueContext.loadMetricRange(3307, 3600, 10000, 101)
  queueContext.metricsAppendOut.text = '{"ok":false,"error":"invalid metric batch"}'
  queueContext.metricsAppendProcess.running = false
  queueContext.writeExited(0)
  assert.equal(queueContext.metricsRetry.running, true)
  assert.equal(queueContext.diskReadProcess.running, true, "failed writes allow queued history reads during backoff")
  assert.equal(queueContext._metricRead.id, 101, "only the latest queued range starts")
  queueContext.loadMetricRange(3307, 1800, 10000, 102)
  queueContext.loadMetricRange(3307, 3600, 10000, 103)
  queueContext.diskReadProcess.running = false
  queueContext.readExited(0)
  assert.equal(queueContext.metricsAppendProcess.running, false, "read completion cannot bypass retry backoff")
  assert.equal(queueContext._metricRead.id, 103)
  queueContext.diskReadProcess.running = false
  queueContext.readExited(0)
  assert.equal(queueContext.metricsAppendProcess.running, false)
  queueContext.loadMetricRange(3307, 3600, 10000, 104)
  queueContext.metricsRetry.running = false
  queueContext.flushMetricBatch()
  assert.equal(queueContext.metricsAppendProcess.running, false, "retry expiry waits for the running read")
  queueContext.diskReadProcess.running = false
  queueContext.readExited(0)
  assert.equal(queueContext.metricsAppendProcess.running, true, "read completion resumes an expired retry")
  queueContext.metricsAppendOut.text = '{"ok":true}'
  queueContext.metricsAppendProcess.running = false
  queueContext.writeExited(0)
  assert.equal(queueContext._metricBatches.length, 0)
  assert.equal(queueContext._metricQueuedBytes, 0)
  assert.equal(queueContext.metricsError, "")
  console.log("ok failed writes permit latest history reads without bypassing backoff or losing the pending retry")
}
