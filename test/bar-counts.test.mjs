import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../BarWidget.qml", import.meta.url), "utf8")
const fn = source.match(/^  function summarizeCounts\(counts, devCount\) \{\n[\s\S]*?^  \}/m)
assert.ok(fn, "bar count summary exists")
const context = vm.createContext({})
vm.runInContext(fn[0], context)
const summary = (pub, named, dev) => JSON.parse(JSON.stringify(context.summarizeCounts({ pub, named }, dev)))

assert.deepEqual(summary(1, 1, 0), {
  icon: "broadcast", count: 1, tooltip: "1 public share · 1 named route"
}, "one port with a public share and a local name shows the public share count")
assert.deepEqual(summary(0, 2, 0), {
  icon: "localRoute", count: 2, tooltip: "2 named routes"
})
assert.deepEqual(summary(0, 0, 3), {
  icon: "portal", count: 3, tooltip: "3 dev servers"
})
assert.deepEqual(summary(2, 4, 6), {
  icon: "broadcast", count: 2, tooltip: "2 public shares · 4 named routes · 6 dev servers"
})
assert.deepEqual(summary(0, 2, 6), {
  icon: "localRoute", count: 2, tooltip: "2 named routes · 6 dev servers"
})
assert.deepEqual(summary(0, 0, 0), {
  icon: "portal", count: 0, tooltip: "0 dev servers"
})
assert.equal(summary(0, 0, 1).tooltip, "1 dev server")

const label = source.match(/^    text: (root\.vertical[^\n]+)$/m)
assert.ok(label, "widget label binding exists")
const render = new Function("root", "glyph", `return ${label[1]}`)
const root = { indicator: summary(2, 4, 6), vertical: false, showCount: true }
assert.equal(render(root, "glyph"), "glyph 2")
assert.equal(render({ ...root, showCount: false }, "glyph"), "glyph")
assert.equal(render({ ...root, vertical: true }, "glyph"), "glyph")
console.log("Bar counts, glyph state, tooltip, and hidden-label checks passed")
