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
  broadcasting: true, count: 1, tooltip: "1 public share · 1 named route"
}, "one port with a public share and a local name shows the public share count")
assert.deepEqual(summary(0, 2, 0), {
  broadcasting: false, count: 2, tooltip: "2 named routes"
})
assert.deepEqual(summary(0, 0, 3), {
  broadcasting: false, count: 3, tooltip: "3 dev servers"
})
assert.deepEqual(summary(2, 4, 6), {
  broadcasting: true, count: 2, tooltip: "2 public shares · 4 named routes · 6 dev servers"
})
assert.deepEqual(summary(0, 2, 6), {
  broadcasting: false, count: 2, tooltip: "2 named routes · 6 dev servers"
})
assert.deepEqual(summary(0, 0, 0), {
  broadcasting: false, count: 0, tooltip: "0 dev servers"
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

{
  const save = source.match(/^  function saveSetting\([^)]*\) \{\n[\s\S]*?^  \}/m)
  const timer = source.match(/id: persistTimer[\s\S]*?onTriggered: \{([\s\S]*?)\n    \}/)
  assert.ok(save)
  assert.ok(timer)
  let live = { id: "g3ortega.portal", iconColors: "Brand", barLabel: "Count", refreshSeconds: 5 }
  const writes = []
  const ctx = vm.createContext({
    moduleName: live.id, settings: { ...live }, _pending: null,
    liveEntry: () => live,
    bar: { shell: { updateEntryInline: (id, entry) => {
      assert.equal(id, live.id)
      live = JSON.parse(JSON.stringify(entry))
      writes.push(live)
      return true
    } } },
    persistTimer: { restart() {} }, settingsSaveError: ""
  })
  ctx.root = ctx
  vm.runInContext(source.match(/^  function mergedSettings\([^)]*\) \{\n[\s\S]*?^  \}/m)[0], ctx)
  vm.runInContext(save[0], ctx)
  const flush = () => vm.runInContext(`(function () {${timer[1]}})()`, ctx)
  ctx.saveSetting("iconColors", "Theme")
  ctx.saveSetting("barLabel", "Icon only")
  assert.equal(writes.length, 0, "a burst remains pending until the timer fires")
  flush()
  assert.deepEqual(live, { id: "g3ortega.portal", iconColors: "Theme", barLabel: "Icon only", refreshSeconds: 5 },
    "different preference edits in one burst both persist")
  assert.equal(ctx._pending, null)
  ctx.saveSetting("refreshSeconds", 10)
  ctx.saveSetting("refreshSeconds", 30)
  flush()
  assert.equal(live.refreshSeconds, 30, "repeated edits keep the last value")
  assert.equal(live.iconColors, "Theme")
  live = { ...live, iconColors: "Brand", customSetting: "external" }
  ctx.saveSetting("barLabel", "Count")
  flush()
  assert.equal(live.iconColors, "Brand", "a new burst reads the latest persisted preferences")
  assert.equal(live.customSetting, "external", "unrelated external settings survive")
  assert.equal(live.barLabel, "Count")
  assert.equal(writes.length, 3)
  const acceptedWriter = ctx.bar.shell.updateEntryInline
  ctx.bar.shell.updateEntryInline = () => false
  ctx.saveSetting("refreshSeconds", 10)
  flush()
  assert.ok(ctx._pending, "a rejected write retains the pending edits")
  assert.match(ctx.settingsSaveError, /not saved/i, "a rejected write has visible error state")
  live = { ...live, customSetting: "changed during retry", nested: { options: [1, 2] } }
  ctx.saveSetting("iconColors", "Theme")
  ctx.bar.shell.updateEntryInline = acceptedWriter
  flush()
  assert.deepEqual(live.nested, { options: [1, 2] }, "unknown nested settings survive retries")
  assert.equal(live.customSetting, "changed during retry", "retry preserves unrelated external edits")
  assert.equal(live.refreshSeconds, 10, "retry retains the earlier rejected edit")
  assert.equal(live.iconColors, "Theme")
  assert.equal(ctx._pending, null)
  assert.equal(ctx.settingsSaveError, "")
  ctx.bar.shell.updateEntryInline = () => false
  ctx.saveSetting("iconColors", "Theme")
  flush()
  assert.equal(ctx._pending, null, "an already-saved value is not a rejected write")
  assert.equal(ctx.settingsSaveError, "")
}
console.log("Settings bursts preserve distinct edits and current persisted preferences")
