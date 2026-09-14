import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath, pathToFileURL } from "node:url"
import vm from "node:vm"

const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
const binding = source.match(/readonly property string pluginDir: \{([\s\S]*?)\n  \}/)[1]
const runScript = source.match(/^  function runScript\([^)]*\) \{[\s\S]*?^  \}/m)[0]

for (const path of ["/home/test/portal/", "/home/test/Portal space # % 日本語/"]) {
  for (const manifest of [null, { id: "g3ortega.portal" }, { __sourceDir: "/wrong/location" }]) {
    const base = new URL("Service.qml", pathToFileURL(path))
    const ctx = vm.createContext({
      manifest,
      Qt: { resolvedUrl: relative => new URL(relative, base) },
      alive: true, outputCaps: { scan: 67108864 }, deadlines: { scan: 20 }
    })
    ctx.pluginDir = vm.runInContext("(function() {" + binding + "})()", ctx)
    assert.equal(ctx.pluginDir, fileURLToPath(new URL(".", base)).replace(/\/$/, ""))
    vm.runInContext(runScript, ctx)
    const process = { running: false }
    assert.equal(ctx.runScript(process, "scan-ports.sh", [], "scan"), true)
    assert.equal(process.command[3], path + "scripts/lib/proc.py")
    assert.equal(process.command[9], path + "scripts/scan-ports.sh")
    assert.equal(process.running, true)
  }
}
console.log("service scripts resolve beside their QML file, independent of private host metadata")
