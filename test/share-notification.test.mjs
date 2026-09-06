import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"
const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
const apply = source.match(/^  function applyTunnels\(text\) \{[\s\S]*?^  \}/m)[0]
const handler = source.slice(source.indexOf("    id: actionProcess")).match(/onExited: function \(([^)]*)\) \{([\s\S]*?)\n    \}/)
const notices = []
const ctx = vm.createContext({ alive: true, parseJson: JSON.parse, tunnelError: "", _lastTunnelsKey: "", tunnels: {},
  _stoppingShare: "", activeAction: { key: "cloudflared:8081" }, _startedShareUrls: {},
  actionOut: { text: '{"ok":true,"url":"https://new.trycloudflare.com","reach":"public"}' },
  notify: (...args) => notices.push(args), refreshTunnels() {}, refreshProviders() {}
})
ctx.root = ctx
vm.runInContext(apply, ctx)
vm.runInContext(`function exitHandler(${handler[1]}) {${handler[2]}}`, ctx)
ctx.exitHandler()
const row = (port, host) => ({ provider: "cloudflared", port, url: "https://" + host + ".trycloudflare.com", reach: "public" })
ctx.applyTunnels(JSON.stringify({ tunnels: [row(8080, "old"), row(8081, "new")] }))
assert.equal(notices.length, 1, "initial poll announces the explicitly started share, not existing reload state")
assert.equal(notices[0][0], "Port 8081 is public")
ctx.applyTunnels(JSON.stringify({ tunnels: [row(8080, "old"), row(8081, "new")] }))
assert.equal(notices.length, 1)
ctx.applyTunnels(JSON.stringify({ tunnels: [row(8080, "old"), row(8081, "changed")] }))
assert.equal(notices.length, 3)
assert.equal(notices[2][0], "Port 8081 is public")
console.log("ok starts before the initial tunnel poll are announced once and reload state stays quiet")
