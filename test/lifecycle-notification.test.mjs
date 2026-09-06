import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
const handler = source.slice(source.indexOf("    id: actionProcess")).match(/onExited: function \(([^)]*)\) \{([\s\S]*?)\n    \}/)
for (const [ok, effect, forget] of [[true, "none", true], [true, "stopped", false],
  [true, "restarted", false], [false, "none", true], [false, "stopped", false], [false, "restarted", false]]) {
  const target = { pid: 999999, start: 1 }
  const forgotten = []
  const ctx = vm.createContext({ alive: true, parseJson: JSON.parse, _lastTunnelsKey: "loaded",
    activeAction: { key: "stop:3307", lifecycle: true, expectsGone: true, target },
    actionOut: { text: JSON.stringify({ ok, effect }) },
    _forgetGone: value => forgotten.push(value), actionFailed() {},
    refreshTunnels() {}, refreshProviders() {}, restartDelay: { restart() {} }
  })
  ctx.root = ctx
  vm.runInContext(`function exitHandler(${handler[1]}) {${handler[2]}}`, ctx)
  ctx.exitHandler()
  assert.equal(forgotten.length, forget ? 1 : 0, JSON.stringify({ ok, effect }))
  if (forget) assert.equal(forgotten[0], target)
}
console.log("ok disappearance suppression requires a confirmed stop effect, independent of action success")
