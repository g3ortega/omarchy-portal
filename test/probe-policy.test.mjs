import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"
import { loadQmlJs, detectPath } from "../scripts/lib/qmljs.mjs"

const { decorate } = loadQmlJs(detectPath)
const entries = [
  [{ port: 3307, comm: "mysqld" }, false],
  [{ port: 8080, comm: "mysqld", deps: ["next"] }, false],
  [{ port: 6381, comm: "redis-server" }, false],
  [{ port: 9300, comm: "java", cmdline: "opensearch" }, false],
  [{ port: 9200, comm: "java", cmdline: "opensearch" }, true],
  [{ port: 1025, cmdline: "mailpit" }, false],
  [{ port: 8025, cmdline: "mailpit" }, true],
  [{ port: 5672, cmdline: "rabbitmq" }, false],
  [{ port: 15672, cmdline: "rabbitmq" }, true],
  [{ port: 8081, comm: "anycable-go" }, false],
  [{ port: 8000, comm: "java", cmdline: "DynamoDBLocal" }, true],
  [{ port: 3000, comm: "node" }, false],
  [{ port: 8080, comm: "unknown" }, false],
  [{ port: 41234, comm: "python", cmdline: "python -m http.server 41234" }, true],
  [{ port: 9000, comm: "php-fpm" }, false],
  [{ port: 8123, comm: "php", cmdline: "php -S localhost:8123" }, true],
  [{ port: 5173, comm: "node", deps: ["vite"] }, true]
]
for (const [entry, expected] of entries)
  assert.equal(decorate(entry).httpProbe, expected, JSON.stringify(entry))

const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
const probeList = source.match(/^  function probeList\([^)]*\) \{[\s\S]*?^  \}/m)[0]
const context = vm.createContext({ ports: entries.map(([e]) => decorate(e)), focusPort: 3307,
  watchedPorts: [3307, 6381, 9200, 9300, 8000, 9999] })
vm.runInContext(probeList, context)
const selected = () => Array.from(context.probeList())
assert.deepEqual(selected(), [9200, 8000, 41234, 8123, 5173])
context.focusPort = 5173
assert.deepEqual(selected(), [5173, 9200, 8000, 41234, 8123])
context.ports = Array.from({ length: 20 }, (_, i) => decorate({ port: 10000 + i, deps: ["vite"] }))
context.focusPort = 10015
context.watchedPorts = [10012, 10010, 10012]
assert.deepEqual(selected(), [10015, 10012, 10010, 10000, 10001, 10002, 10003, 10004])
console.log("ok HTTP inference, database exclusions, focused/watched eligibility and bounded priority")
