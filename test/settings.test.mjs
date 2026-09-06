import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../PortalPanel.qml", import.meta.url), "utf8")
const names = ["setupStillValid", "activateProviderSetup", "activateSetting", "openSettings", "activateVerb", "chooseProvider", "verbsFor", "activateVerbById", "activateVerbAtCursor"]
const functions = names.map(name => {
  const found = source.match(new RegExp(`^  function ${name}\\([^)]*\\) \\{\\n[\\s\\S]*?^  \\}`, "m"))
  assert.ok(found, `${name} is defined`)
  return found[0]
}).join("\n")

function session(provider = { id: "portless", status: "setup", fix: "", setupClause: "Starts the proxy" }) {
  provider = { available: true, reach: provider.id === "portless" ? "local" : "public", ...provider }
  const actionProviders = { cloudflared: {id:"cloudflared",label:"Cloudflare",available:true,reach:"public",status:"ready"},
    ngrok: {id:"ngrok",available:true,reach:"public",status:"setup"}, [provider.id]: provider }
  const calls = []
  const ctx = vm.createContext({
    confirmationDialog: { rememberFocus() {} },
    pendingSetup: null, setupProviders: [provider], settingsIndex: 0, settingDefs: [],
    helpOpen: false, pendingAction: null, detailEntry: null, settingsOpen: false,
    portlessReady: false, publicProviders: [actionProviders.cloudflared], selectedPort: -1, expandedKind: "",
    service: {
      busyAction: "", providerFor: id => provider.id === id ? provider : null,
      actionProviderFor: id => actionProviders[id]?.available === true ? actionProviders[id] : null,
      publicProviders: [actionProviders.cloudflared],
      setupProvider: id => calls.push(["setup", id]),
      unexpose: (...args) => calls.push(["unexpose", ...args]),
      copyText: (...args) => calls.push(["copy", ...args]),
      routeFor: () => null, publicTunnelFor: () => null,
      stats: {}, urlFor: () => "http://localhost:3000", canRestart: () => true,
      validProcessIdentity: process => process?.pid > 1
    },
    showMoment: text => calls.push(["moment", text]),
    showGuidance: text => calls.push(["guidance", text]),
    collapse: () => calls.push(["collapse"]),
    keyCatcher: { forceActiveFocus: () => calls.push(["focus"]) },
    cycleSetting: (...args) => calls.push(["cycle", ...args]),
    expand: (...args) => calls.push(["expand", ...args]),
    requestAction: (...args) => calls.push(["confirm", ...args]),
    entryForPort: port => ({ port, name: "app", process: { pid: 999999, start: "1" } })
  })
  vm.runInContext(functions, ctx)
  return { ctx, calls, provider }
}

{
  const { ctx, calls, provider } = session()
  ctx.activateProviderSetup(provider)
  assert.equal(calls.length, 0)
  assert.equal(ctx.pendingSetup.id, "portless")
  ctx.entryForPort = () => null
  ctx.activateProviderSetup(provider)
  assert.deepEqual(calls, [["setup", "portless"]])
  assert.equal(ctx.pendingSetup, null)
}
for (const [field, value] of [["status", "ready"], ["fix", "new command"], ["setupClause", "Different effect"]]) {
  const { ctx, calls, provider } = session()
  ctx.activateProviderSetup(provider)
  provider[field] = value
  ctx.activateProviderSetup(provider)
  assert.equal(calls.some(call => call[0] === "setup" || call[0] === "copy"), false, field)
  assert.equal(ctx.pendingSetup, null)
  assert.equal(calls[0][0], "moment")
}
{
  const { ctx, calls, provider } = session()
  ctx.activateProviderSetup(provider)
  ctx.service.providerFor = () => null
  ctx.activateProviderSetup(provider)
  assert.equal(calls.some(call => call[0] === "setup"), false)
}
{
  const { ctx, calls, provider } = session()
  ctx.service.busyAction = "other:setup"
  ctx.activateProviderSetup(provider)
  assert.equal(ctx.pendingSetup, null)
  assert.equal(calls[0][0], "moment")
}
{
  const { ctx, calls, provider } = session({ id: "portless", status: "setup", fix: "install portless", setupClause: "Starts proxy" })
  ctx.activateProviderSetup(provider)
  assert.deepEqual(calls[0], ["copy", "install portless", true])
  assert.deepEqual(calls[1], ["guidance", "Command copied. Run it in your terminal."])
  assert.equal(ctx.pendingSetup, null)
}
{
  const { ctx, calls, provider } = session({ id: "portless", status: "ready", fix: "", setupClause: "Starts proxy" })
  ctx.activateProviderSetup(provider)
  assert.equal(calls.length, 0)
}
{
  const { ctx } = session()
  ctx.activateVerb({ port: 3000 }, { id: "name" })
  assert.equal(ctx.settingsOpen, true)
  assert.equal(ctx.pendingAction, null)
}
{
  const { ctx, calls } = session()
  ctx.portlessReady = true
  ctx.service.routeFor = () => ({ host: "app.localhost", reach: "local", managed: false, aliasName: "app" })
  ctx.activateVerb({ port: 3000 }, { id: "name" })
  assert.deepEqual(calls, [["expand", 3000, "naming"]])
}
{
  const { ctx, calls } = session()
  ctx.chooseProvider(3000, { id: "cloudflared", label: "Cloudflare", status: "ready" })
  assert.equal(calls[0][0], "confirm")
  assert.equal(calls[0][1], "share")
  ctx.entryForPort = port => ({ port, process: null })
  calls.length = 0
  ctx.chooseProvider(3000, { id: "cloudflared", status: "ready" })
  assert.equal(calls.length, 0)
}
{
  const { ctx } = session()
  ctx.chooseProvider(3000, { id: "ngrok", status: "missing" })
  assert.equal(ctx.settingsOpen, true)
}
{
  const { ctx, calls, provider } = session()
  ctx.activateSetting()
  assert.equal(ctx.pendingSetup.id, provider.id)
  ctx.settingDefs = [{ key: "barLabel" }]
  ctx.settingsIndex = 1
  ctx.activateSetting()
  assert.deepEqual(calls, [["cycle", ctx.settingDefs[0], 1]])
}
{
  const { ctx, calls, provider } = session({ id: "portless", reach: "local", status: "ready", fix: "", setupClause: "Trusts your CA" })
  ctx.activateProviderSetup(provider)
  assert.equal(ctx.pendingSetup.id, "portless")
  assert.equal(calls.length, 0)
  ctx.activateProviderSetup(provider)
  assert.deepEqual(calls, [["setup", "portless"]])
}
{
  const { ctx, calls, provider } = session({ id: "cloudflared", reach: "public", status: "ready", fix: "", setupClause: "Installs binary" })
  ctx.activateProviderSetup(provider)
  assert.equal(ctx.pendingSetup, null)
  assert.equal(calls.length, 0)
}
{
  const { ctx } = session()
  const entry = { port: 3000, category: "dev", process: { pid: 999999, start: "1" } }
  ctx.service.routeFor = () => ({ host: "api.project.localhost", reach: "local", aliasName: "api.project", managed: false })
  assert.equal(ctx.verbsFor(entry)[0].label, "name setup")
  ctx.service.routeFor = () => ({ host: "api.project.localhost", reach: "local", aliasName: "api.project", managed: true })
  assert.deepEqual(Array.from(ctx.verbsFor(entry), verb => verb.id), ["share", "pause", "restart", "stop"])
  for (const route of [{ managed: null, aliasName: "" }, { managed: false, aliasName: "" }, { aliasName: "api.project" }]) {
    ctx.service.routeFor = () => route
    assert.equal(ctx.verbsFor(entry).some(verb => verb.id === "name"), false)
  }
}
{
  const rowSource = readFileSync(new URL("../PortRow.qml", import.meta.url), "utf8")
  const editableBody = rowSource.match(/readonly property bool editable: ([^\n]+\n[^\n]+)/)[1]
  const editable = row => new Function("row", "provider", `return ${editableBody}`)(row, {status:"ready"})
  assert.equal(editable({ route: null }), true)
  assert.equal(editable({ route: { reach: "local", managed: false, aliasName: "api.project" } }), true)
  for (const route of [{ managed: true, aliasName: "api.project" }, { managed: null, aliasName: "" }, { managed: false, aliasName: "" }, {}]) {
    assert.equal(editable({ route }), false)
  }
  assert.equal(editable({ route: { reach: "lan", managed: false, aliasName: "api.project" } }), false)
  const editor = rowSource.slice(rowSource.indexOf("id: nameField"), rowSource.indexOf("id: tldText"))
  const expression = editor.match(/text: (row.named[^\n]+\n[^\n]+)/)[1]
  const name = new Function("row", `return ${expression}`)
  assert.equal(name({ named: true, route: { aliasName: "api.project" } }), "api.project")
  assert.equal(name({ named: true, route: { aliasName: "api.project.branch" } }), "api.project.branch")
  assert.equal(name({ named: false, entry: {}, service: { suggestedName: () => "new-project" } }), "new-project")
  const accepted = new Function("row", "nameEditor", "text",
    editor.match(/onAccepted: \{([\s\S]*?)\n              \}/)[1])
  const calls = []
  const row = { named: true, entry: { port: 3000 }, editorDone: () => calls.push("done"),
    service: { expose: (...args) => { calls.push(args); return true },
      unexpose: (...args) => { calls.push(args); return true } } }
  accepted(row, { editable: true }, "api.project")
  assert.deepEqual(calls, [[3000, "portless", "api.project"], "done"])
  calls.length = 0
  accepted(row, { editable: false }, "replacement")
  accepted(row, { editable: false }, "")
  assert.deepEqual(calls, [], "disabled editing neither queues an action nor closes the editor")
  const remove = rowSource.slice(rowSource.indexOf("id: removeLink"))
  const clicked = new Function("row", "nameEditor",
    remove.match(/onClicked: \{([\s\S]*?)\n              \}/)[1])
  calls.length = 0
  clicked(row, { editable: false })
  assert.deepEqual(calls, [], "disabled removal leaves the editor unchanged")
}
{
  const settingsSource = source.slice(source.indexOf("id: settingsView"))
  const reveal = settingsSource.match(/function reveal\(item, includeHeader\) \{([\s\S]*?)\n            \}/)[0]
  const ctx = vm.createContext({ contentY: 300, height: 420 })
  vm.runInContext(reveal, ctx)
  ctx.reveal({ y: 30, height: 180 }, true)
  assert.equal(ctx.contentY, 0, "first provider keeps section heading visible")
  ctx.reveal({ y: 350, height: 140 }, false)
  assert.equal(ctx.contentY, 70, "later providers scroll into view")
  ctx.reveal({ y: 1000, height: 40 }, false)
  assert.equal(ctx.contentY, 620, "keyboard can reach preferences")
  ctx.reveal({ y: 30, height: 180 }, true)
  assert.equal(ctx.contentY, 0, "returning to first provider restores heading")
}
{
  const rowSource = readFileSync(new URL("../PortRow.qml", import.meta.url), "utf8")
  const body = rowSource.match(/readonly property string statsLine: \{([\s\S]*?)\n  \}/)[1]
  const statsLine = new Function("stats", "route", "paused", "Format", body)
  const stats = { conns: 1 }
  assert.equal(statsLine(stats, { reach: "lan" }, false, {}), "LAN name · 1 conn")
  assert.equal(statsLine(stats, { reach: "local" }, false, {}), "1 conn")
}
{
  const { ctx, calls } = session()
  const orphan = { port: 3000, kind: "orphan", category: "dev", process: null }
  ctx.service.publicTunnelFor = port => port === 3000 ? { provider: "cloudflared", port } : null
  assert.equal(ctx.verbsFor(orphan).some(verb => verb.id === "share"), false)
  ctx.activateVerbById(orphan, "share")
  assert.deepEqual(calls, [["unexpose", 3000, "cloudflared"]])
  calls.length = 0
  ctx.service.publicTunnelFor = port => port === 3000 ? { provider: "ngrok", port } : null
  ctx.activateVerbById({ port: 3000, category: "dev", process: { pid: 999999, start: "1" } }, "share")
  assert.deepEqual(calls, [["unexpose", 3000, "ngrok"]])
  calls.length = 0
  ctx.service.publicTunnelFor = () => null
  ctx.activateVerbById(orphan, "share")
  ctx.activateVerbById(null, "share")
  assert.equal(calls.length, 0, "new shares still require a valid process")
  assert.equal(ctx.settingsOpen, false)
}
console.log("Settings setup, revalidation, routing, and selection checks passed")

{
  const { ctx, calls } = session()
  const entry = { port: 3000, category: "dev", process: { pid: 999999, start: "1" } }
  const route = { reach: "lan", managed: false, aliasName: "api.project" }
  ctx.service.routeFor = () => route
  assert.equal(ctx.verbsFor(entry).find(verb => verb.id === "name").label, "name setup")
  assert.equal(ctx.verbsFor(entry).find(verb => verb.id === "unname").label, "remove name")
  ctx.activateVerbById(entry, "name")
  assert.equal(ctx.settingsOpen, true)
  assert.equal(calls.some(call => call[0] === "expand"), false)
  calls.length = 0
  ctx.selectedEntry = () => entry
  ctx.verbIndex = ctx.verbsFor(entry).findIndex(verb => verb.id === "unname")
  ctx.activateVerbAtCursor()
  assert.deepEqual(calls, [["unexpose", 3000, "portless"]], "Enter on the removal action stops the exact local route")
  calls.length = 0
  ctx.activateVerb(entry, ctx.verbsFor(entry).find(verb => verb.id === "unname"))
  assert.deepEqual(calls, [["unexpose", 3000, "portless"]], "mouse and keyboard use the same removal")
  for (const managed of [true, null]) {
    route.managed = managed
    calls.length = 0
    assert.equal(ctx.verbsFor(entry).some(verb => ["name", "unname"].includes(verb.id)), false)
    ctx.activateVerb(entry, { id: "unname" })
    ctx.activateVerb(entry, { id: "name" })
    assert.deepEqual(calls, [], "stale actions cannot mutate protected routes")
  }
}

{
  const rowSource = readFileSync(new URL("../PortRow.qml", import.meta.url), "utf8")
  const copy = rowSource.match(/PublicAction \{\n          icon: Icons.g\("copy"\)[\s\S]*?\n        \}/)[0]
  const enabled = copy.match(/enabled: ([^\n]+)/)
  assert.ok(enabled, "public Copy has a readiness gate")
  const canCopy = new Function("row", `return ${enabled[1]}`)
  assert.equal(canCopy({ dnsPending: true }), false)
  assert.equal(canCopy({ dnsPending: false }), true)
}
