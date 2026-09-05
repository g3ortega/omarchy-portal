import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
const load = source.match(/^  function loadDiskHistory\(port\) \{[\s\S]*?^  \}/m)[0]
const processSource = source.slice(source.indexOf("    id: diskReadProcess"))
const handler = processSource.match(/onExited: function \(([^)]*)\) \{([\s\S]*?)\n    \}/)
const plain = value => JSON.parse(JSON.stringify(value))

function session(text, queued = 6381, accepted = true) {
  const events = []
  const ctx = vm.createContext({
    alive: true, _diskPort: 3307, _diskQueued: queued,
    diskOut: { text }, diskReadProcess: { running: false },
    parseJson: value => { try { return JSON.parse(value) } catch { return null } },
    diskHistoryLoaded: (...args) => events.push(["complete", ...args]),
    runScript: (process, _script, args) => {
      events.push(["start", ...args])
      process.running = accepted
      return accepted
    }
  })
  ctx.root = ctx
  vm.runInContext(load, ctx)
  vm.runInContext(`function exitHandler(${handler[1]}) {${handler[2]}}`, ctx)
  return { ctx, events }
}

for (const [text, code] of [["", 0], ["not-json", 0], ['{"ok":false,"error":"refused"}', 0],
  ['{"ok":true}', 0], ['{"ok":false,"samples":[{"t":1}]}', 0], ['{"ok":true,"samples":[]}', 1]]) {
  const { ctx, events } = session(text)
  ctx.exitHandler(code)
  assert.equal(events.length, 2, "failed read must finish and start the queued port")
  assert.deepEqual(events[0], ["start", "read", "6381"])
  assert.equal(events[1][0], "complete")
  assert.equal(events[1][1], 3307, "completion keeps the old port after next dispatch")
  assert.deepEqual(plain(events[1][2]), [])
  assert.ok(events[1][3], "failure has an error instead of success-shaped empty data")
  assert.equal(ctx._diskQueued, 0)
}
console.log("ok every failed disk read completes and advances the latest queued port")

{
  const { ctx, events } = session('{"ok":true,"samples":[{"t":1}]}')
  ctx.exitHandler(0)
  assert.deepEqual(plain(events), [["start", "read", "6381"], ["complete", 3307, [{ t: 1 }], ""]])
}
for (const text of ['{"ok":true,"samples":[]}', 'invalid']) {
  const { ctx, events } = session(text, 3307)
  ctx.exitHandler(0)
  assert.equal(events.length, 1)
  assert.equal(events[0][0], "complete")
  assert.equal(events[0][1], 3307)
  assert.equal(ctx._diskQueued, 0)
}
console.log("ok success preserves samples and same-port repeats share one terminal result")

{
  const { ctx, events } = session("", 0, false)
  ctx.loadDiskHistory(3307)
  assert.equal(events.length, 2)
  assert.equal(events[1][0], "complete")
  assert.equal(events[1][1], 3307)
  assert.ok(events[1][3])
}
{
  const { ctx, events } = session("", 0)
  ctx.diskReadProcess.running = true
  ctx.loadDiskHistory(6381)
  ctx.loadDiskHistory(9200)
  assert.equal(ctx._diskQueued, 9200)
  assert.equal(events.length, 0)
}
console.log("ok refused dispatch completes and rapid navigation retains only the latest request")

{
  const { ctx, events } = session('{"ok":true,"samples":[]}')
  ctx.diskHistoryLoaded = (port, samples, error) => {
    events.push(["complete", port, samples, error])
    if (port === 3307) ctx.loadDiskHistory(9200)
  }
  ctx.exitHandler(0)
  assert.equal(ctx._diskPort, 6381)
  assert.equal(ctx._diskQueued, 9200, "completion callbacks cannot lose newer navigation")
}
{
  const { ctx, events } = session('{"ok":true,"samples":[]}')
  ctx.alive = false
  ctx.exitHandler(0)
  assert.deepEqual(events, [])
}
console.log("ok terminal callbacks preserve newer requests and shutdown does no work")
