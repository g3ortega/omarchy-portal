import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const detail = readFileSync(new URL("../PortDetail.qml", import.meta.url), "utf8")
const card = readFileSync(new URL("../SparkCard.qml", import.meta.url), "utf8")
const binding = detail.match(/readonly property int historyPort: ([^\n]+)/)
assert.ok(binding, "history loading follows port, watch state and service readiness")
const changed = detail.match(/onHistoryPortChanged: \{([\s\S]*?)\n  \}/)
const loaded = detail.match(/function onDiskHistoryLoaded\(([^)]*)\) \{([\s\S]*?)\n    \}/)
assert.ok(changed)
assert.ok(loaded)
const requests = []
const ctx = vm.createContext({
  entry: { port: 3307 }, watched: true, service: null,
  historyPort: 0, historyStatus: "idle", diskPrefix: [], hoverIndex: 7
})
ctx.detail = ctx
const refresh = () => {
  const port = vm.runInContext(binding[1], ctx)
  if (port === ctx.historyPort) return
  ctx.historyPort = port
  vm.runInContext(changed[1], ctx)
}
const complete = (...args) => {
  ctx.result = args
  vm.runInContext(`(function (${loaded[1]}) {${loaded[2]}})(...result)`, ctx)
}
refresh()
assert.equal(ctx.historyStatus, "idle")
ctx.service = { pluginDir: "", history: { 3307: [{ t: 100, rssKb: 800000 }] }, loadDiskHistory: port => requests.push(port) }
refresh()
assert.equal(requests.length, 0, "an unready service cannot strand a loading chart")
ctx.service.pluginDir = "/plugin"
refresh()
assert.equal(ctx.historyStatus, "loading")
assert.equal(ctx.hoverIndex, -1)
assert.deepEqual(requests, [3307])
complete(3307, [{ t: 90, rssKb: 700000 }, { t: 100, rssKb: 800000 }], "")
assert.equal(ctx.historyStatus, "ready")
assert.equal(ctx.diskPrefix.length, 1, "saved history overlaps the ring only once")
ctx.entry = { port: 3308 }
refresh()
assert.equal(ctx.historyStatus, "loading")
assert.equal(ctx.diskPrefix.length, 0)
complete(3307, [{ t: 1 }], "")
assert.equal(ctx.historyStatus, "loading", "a prior port cannot reveal the new chart")
complete(3308, [], "could not read saved samples")
assert.equal(ctx.historyStatus, "error", "a failed read reveals the live-ring fallback")
ctx.watched = false
refresh()
assert.equal(ctx.historyStatus, "idle")
assert.equal(ctx.diskPrefix.length, 0)
complete(3308, [{ t: 2 }], "")
assert.equal(ctx.historyStatus, "idle", "unwatched charts ignore outstanding saved-history responses")
ctx.watched = true
refresh()
complete(3308, [], "")
assert.equal(ctx.historyStatus, "ready", "an empty saved history is a successful completion")
assert.match(detail, /last: detail\.stats/, "hero readings use current vitals independently of loaded history")
assert.match(detail, /Saved history unavailable/, "read failure has visible live fallback text")
assert.match(card, /visible: !card\.loading/, "saved-history loading hides the changing plot")
assert.match(card, /enabled: !card\.loading && card\.series\.length > 1/, "loading cannot select historical samples")
assert.match(card, /Loading…/, "loading is explicit")
assert.match(card, /if \(card\.loading\) return ""/, "loading hides the changing scale")
const labels = [...card.matchAll(/text: \{\n([\s\S]*?)\n        \}/g)]
assert.equal(labels.length, 2)
const hero = new Function("card", labels[0][1])
const caption = new Function("card", labels[1][1])
const steady = { loading: false, phase: "steady", hoverIndex: -1, lo: 42, hi: 42, last: null, format: String }
assert.equal(hero(steady), "—", "a missing current reading never falls back to an old saved value")
assert.equal(caption(steady), "steady at 42", "a steady historical series reports its measured level even when current data is missing")
assert.equal(caption({ ...steady, loading: true }), "", "history loading keeps its unfinished scale hidden")
console.log("Chart history readiness, completion, failure, navigation and loading presentation checks passed")
