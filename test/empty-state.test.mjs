import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../PortalPanel.qml", import.meta.url), "utf8")
let refreshed = 0, focused = 0, settings = null
const context = vm.createContext({
  service: null, query: "", showSystem: false,
  search: { forceActiveFocus() { focused++ } },
  openSettings(provider) { settings = provider }
})
for (const name of ["emptyPresentation", "activateEmptyAction"]) {
  const fn = source.match(new RegExp(`^  function ${name}\\(\\) \\{\\n[\\s\\S]*?^  \\}`, "m"))
  assert.ok(fn)
  vm.runInContext(fn[0], context)
}
const state = () => context.emptyPresentation()
assert.equal(state().title, "Looking for listening ports")
context.service = { everScanned: false, scanError: "failed", ports: [], refresh() { refreshed++ } }
assert.equal(state().title, "Could not scan ports", "first-scan failure is not loading forever")
context.service.everScanned = true
context.query = "missing"
assert.equal(state().action, "Refresh", "scan errors take precedence over filter misses")
context.emptyView = state()
context.activateEmptyAction()
assert.equal(refreshed, 1)
context.service.scanError = ""
assert.equal(state().title, "No matching ports")
context.emptyView = state()
context.activateEmptyAction()
assert.equal(context.query, "")
assert.equal(focused, 1)
assert.equal(state().title, "No ports listening")
assert.equal(state().action, "")
assert.match(state().body, /automatically/)
assert.doesNotMatch(state().body, /hidden/)
context.service.ports = [{ category: "system" }]
assert.equal(state().title, "No apps listening")
assert.match(state().body, /System ports are hidden/)
context.emptyView = state()
context.activateEmptyAction()
assert.equal(settings, "")
context.showSystem = true
assert.doesNotMatch(state().body, /hidden/)
context.query = "   "
assert.equal(state().title, "No ports listening")
context.query = " CAKE "
assert.equal(state().body, "The cake is a lie.")
console.log("Empty-state loading, failure, filtering, hidden ports, and actions passed")
