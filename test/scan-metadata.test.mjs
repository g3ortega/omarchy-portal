import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"
import { loadQmlJs, detectPath } from "../scripts/lib/qmljs.mjs"

const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
const handler = source.match(/  function applyScan\(text\) \{([\s\S]*?)\n  \}/)
const context = vm.createContext({
  parseJson: JSON.parse, Detect: loadQmlJs(detectPath),
  _cpuPrev: {}, history: {}, maxSamples: 20, watchedPorts: [],
  pluginDir: "", historyRevision: 0, _lastScanKey: "", ports: [],
  _notifyVanishedDev() {}
})
vm.runInContext(`function applyScan(text) {${handler[1]}}`, context)

const row = {
  port: 4000, addresses: ["0.0.0.0"], pid: null, start: null,
  comm: "", cmdline: "", argv: [], argvTruncated: false, cwd: "",
  projectRoot: "", projectName: "", markers: [], deps: [], exclusiveOwner: false
}
const container = { name: "gateway", image: "ghcr.io/berriai/litellm:latest" }
for (const [metadata, kind, name, http] of [
  [undefined, "unknown", "port 4000", false],
  [container, "litellm", "gateway", true],
  [{ ...container, name: "renamed" }, "litellm", "renamed", true],
  [{ name: "renamed", image: "postgres:latest" }, "docker", "renamed", false],
  [undefined, "unknown", "port 4000", false]
]) {
  context.applyScan(JSON.stringify({ version: 1, ports: [{ ...row, container: metadata }] }))
  const actual = context.ports[0]
  assert.equal(actual.kind, kind, "metadata alone updates classification")
  assert.equal(actual.name, name, "metadata alone updates the displayed name")
  assert.equal(actual.httpProbe, http, "metadata alone updates probe eligibility")
  assert.equal(actual.process, null)
}
console.log("ok Docker metadata arrival, rename, image change and removal refresh the service snapshot")
