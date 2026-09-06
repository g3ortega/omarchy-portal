// Unit tests runnable with plain node: node test/detect.test.mjs
//
// QML-side JS is loaded through scripts/lib/qmljs.mjs, which owns the
// QML-JS-under-node dance.

import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs, detectPath, formatPath, colorsPath } from "../scripts/lib/qmljs.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const { decorate } = loadQmlJs(detectPath)

let pass = 0, fail = 0
function check(name, entry, expect) {
  const got = decorate(entry)
  const bad = Object.keys(expect).filter((k) => got[k] !== expect[k])
  if (bad.length === 0) {
    pass++
    console.log(`  ok   ${name}`)
  } else {
    fail++
    console.log(`  FAIL ${name}`)
    for (const k of bad) console.log(`         ${k}: expected ${JSON.stringify(expect[k])}, got ${JSON.stringify(got[k])}`)
  }
}

const base = { addresses: ["127.0.0.1"], scope: "local", markers: [], deps: [], cmdline: "", comm: "", cwd: "", projectRoot: "", projectName: "", exclusiveOwner: true }
const e = (o) => ({ ...base, ...o })

console.log("Detect.js")

// --- JS frameworks are identified by dependency, not by the "node" cmdline.
check("Next.js via dependency", e({
  port: 3000, comm: "node", cmdline: "node /p/web/node_modules/.bin/next dev",
  deps: ["next", "react"], markers: ["package.json", "next.config.ts"],
  projectRoot: "/p/web", projectName: "acme-web"
}), { kind: "next", label: "Next.js", category: "dev", web: true, name: "acme-web", url: "http://localhost:3000" })

check("Next.js via next-server cmdline only", e({
  port: 3000, comm: "node", cmdline: "next-server (v15.0.0)"
}), { kind: "next", category: "dev" })

check("Vite dev server", e({
  port: 5173, comm: "node", deps: ["vite", "vue"], projectName: "dash"
}), { kind: "vite", label: "Vite", url: "http://localhost:5173" })

check("Nuxt beats vite when both present", e({
  port: 3000, comm: "node", deps: ["nuxt", "vite"]
}), { kind: "nuxt" })

check("Angular via angular.json marker", e({
  port: 4200, comm: "node", markers: ["package.json", "angular.json"]
}), { kind: "angular", label: "Angular" })

check("plain Node with a package.json", e({
  port: 3001, comm: "node", markers: ["package.json"]
}), { kind: "node", label: "Node", category: "dev" })

// --- Ruby
check("Puma is a Rack server, not proof of Rails", e({
  port: 3000, comm: "ruby", cmdline: "puma 6.4.2 (tcp://0.0.0.0:3000) [acme]",
  markers: ["Gemfile", "config.ru"], projectName: "acme"
}), { kind: "puma", label: "Puma", category: "dev", name: "acme" })

check("Generic Rack project", e({
  port: 3000, comm: "ruby", markers: ["Gemfile", "config.ru"]
}), { kind: "rack" })

check("Rack with a package.json stays Rack", e({
  port: 3000, comm: "ruby", markers: ["Gemfile", "config.ru", "package.json"]
}), { kind: "rack" })
check("Laravel with a package.json is still Laravel", e({
  port: 8000, comm: "php", markers: ["artisan", "package.json"]
}), { kind: "laravel" })

const mixedProject = ["package.json", "Gemfile", "config.ru", "bin/rails"]
check("live Puma Rails listener with React assets is Rails", e({
  port: 3000, comm: "ruby", cmdline: "puma 7.2.1 (tcp://127.0.0.1:3000) [platform]",
  markers: mixedProject, deps: ["react"]
}), { kind: "rails", httpProbe: true })
check("Vite listener in the same Rails project stays Vite", e({
  port: 5173, comm: "node", cmdline: "node node_modules/vite/bin/vite.js",
  markers: mixedProject, deps: ["vite", "react"]
}), { kind: "vite", httpProbe: true })
for (const [name, fields, kind] of [
  ["Rack", { comm: "ruby", markers: ["Gemfile", "config.ru"] }, "rack"],
  ["Laravel", { comm: "php", markers: ["artisan"] }, "laravel"],
  ["Django", { comm: "python3.12", markers: ["manage.py"] }, "django"],
  ["Uvicorn", { comm: "python3", cmdline: "uvicorn app:app" }, "uvicorn"],
  ["Redis", { comm: "redis-server" }, "redis"],
  ["Java", { comm: "java", markers: ["pom.xml"] }, "javadev"],
  ["Go", { comm: "main", markers: ["go.mod"], argv: ["/p/app/main"], projectRoot: "/p/app" }, "go"],
  ["Rust", { comm: "app", markers: ["Cargo.toml"], argv: ["./target/debug/app"], cwd: "/p/app", projectRoot: "/p/app" }, "rust"]
]) {
  check(`${name} listener ignores frontend dependencies and markers`, e({
    port: 41000, ...fields, deps: ["next", "vite", "react"],
    markers: [...(fields.markers || []), "package.json", "angular.json"]
  }), { kind })
}
for (const runtime of ["node", "node-MainThread", "bun", "deno"]) {
  check(`${runtime} retains framework evidence in mixed project`, e({
    port: 41000, comm: runtime, markers: mixedProject, deps: ["react"]
  }), { kind: "react" })
}
check("rewritten Next.js title retains framework classification", e({
  port: 3000, comm: "next-server (v1", cmdline: "next-server (v15.0.0)", deps: ["next"]
}), { kind: "next" })
check("Nuxt process title retains framework classification", e({
  port: 3000, comm: "nuxt dev", cmdline: "nuxt dev", deps: ["nuxt", "vite"]
}), { kind: "nuxt" })
check("missing process information retains project dependency fallback", e({
  port: 3000, markers: ["package.json"], deps: ["react"]
}), { kind: "react" })

for (const comm of ["chrome", "agent-browser-l"]) {
  for (const markers of [mixedProject, ["manage.py"], ["artisan"], ["mix.exs"], ["go.mod"], ["Cargo.toml"]]) {
    check(`${comm} does not inherit project stack ${markers.join(",")}`, e({
      port: 35713, comm, markers, deps: ["react"],
      argv: ["/home/x/.cache/tools/" + comm], projectRoot: "/p/app", cwd: "/p/app"
    }), { kind: "unknown", httpProbe: false })
  }
}
for (const argv of [["./target/debug/server"], ["../app/target/debug/server"], ["/p/app/target/debug/server"]]) {
  check(`Rust project executable ${argv[0]} keeps marker evidence`, e({
    port: 41000, comm: "server", argv, markers: ["Cargo.toml"], projectRoot: "/p/app", cwd: "/p/app"
  }), { kind: "rust" })
}
check("relative executable outside project does not inherit Rust", e({
  port: 41000, comm: "server", argv: ["../other/server"], markers: ["Cargo.toml"],
  projectRoot: "/p/app", cwd: "/p/app"
}), { kind: "unknown" })
check("Go temporary build traversal does not imply a Go executable", e({
  port: 41000, comm: "server", argv: ["/tmp/go-build12345/b001/exe/../../../tool"],
  markers: ["go.mod"], projectRoot: "/p/app"
}), { kind: "unknown" })
check("missing executable is not proof of a compiled project", e({
  port: 41000, comm: "server", markers: ["Cargo.toml"], projectRoot: "/p/app"
}), { kind: "unknown" })
check("Go temporary build executable keeps marker evidence", e({
  port: 41000, comm: "main", argv: ["/tmp/go-build12345/b001/exe/main"], markers: ["go.mod"], projectRoot: "/p/app"
}), { kind: "go" })

check("Sidekiq is a service, not a dev server", e({
  port: 7433, comm: "ruby", cmdline: "sidekiq 7.2.0 acme [0 of 5 busy]"
}), { kind: "sidekiq", category: "service" })

check("AnyCable by binary name", e({
  port: 8080, comm: "anycable-go", cmdline: "/opt/anycable-go"
}), { kind: "anycable", label: "AnyCable", category: "service" })

// --- Python
check("Django via manage.py", e({
  port: 8000, comm: "python3", markers: ["manage.py", "requirements.txt"]
}), { kind: "django", label: "Django", category: "dev" })

for (const role of ["master", "worker"]) {
  const title = `gunicorn: ${role} [app:app]`
  check(`Gunicorn ${role} process title retains HTTP classification`, e({
    port: 41000, comm: title.slice(0, 15), cmdline: title
  }), { kind: "gunicorn", httpProbe: true })
}
check("Gunicorn helper name is not a Python runtime", e({
  port: 41000, comm: "gunicorn-helper", cmdline: "gunicorn-helper", markers: ["manage.py"]
}), { kind: "unknown", httpProbe: false })

check("Uvicorn is not proof of FastAPI", e({
  port: 8000, comm: "python3", cmdline: "uvicorn app.main:app --reload"
}), { kind: "uvicorn", label: "Uvicorn" })

// --- Other stacks
check("Elixir via mix.exs", e({ port: 4000, comm: "beam.smp", markers: ["mix.exs"] }), { kind: "elixir" })
check("RabbitMQ is not Phoenix", e({ port: 5672, comm: "beam.smp", cmdline: "beam.smp -s rabbit boot" }), { kind: "rabbit" })
check("Storybook beats vite in the same project", e({ port: 6006, comm: "node", deps: ["storybook", "vite"] }), { kind: "storybook" })
check("Elixir gets its brand color", e({ port: 4000, comm: "beam.smp", markers: ["mix.exs"] }), { color: "#4b275f" })
check("Laravel via artisan", e({ port: 8000, comm: "php", markers: ["artisan", "composer.json"] }), { kind: "laravel" })
check("Go via go.mod", e({ port: 8080, comm: "main", markers: ["go.mod"], argv: ["/p/app/main"], projectRoot: "/p/app" }), { kind: "go", label: "Go" })
check("Rust via Cargo.toml", e({ port: 8080, comm: "server", markers: ["Cargo.toml"], argv: ["./target/debug/server"], cwd: "/p/app", projectRoot: "/p/app" }), { kind: "rust" })

// --- Backing services identified by well-known port with no process info
check("PostgreSQL by port", e({ port: 5432 }), { kind: "postgres", category: "service", web: false })
check("MySQL by comm", e({ port: 3307, comm: "mysqld" }), { kind: "mysql", category: "service" })
check("Redis by comm", e({ port: 6381, comm: "redis-server" }), { kind: "redis", category: "service" })
check("OpenSearch by port", e({ port: 9200, comm: "java" }), { kind: "elastic", label: "OpenSearch" })
check("DynamoDB Local via cmdline", e({
  port: 8000, comm: "java", cmdline: "java -jar DynamoDBLocal.jar -sharedDb"
}), { kind: "dynamodb", category: "service" })

// --- System ports are grouped away from your work
check("DNS is system", e({ port: 53 }), { kind: "dns", category: "system" })
check("CUPS is system", e({ port: 631 }), { kind: "cups", category: "system" })

for (const image of ["ghcr.io/berriai/litellm:main-stable", "ghcr.io/berriai/litellm-database@sha256:abcd"]) {
  check(`LiteLLM container ${image} exposes its HTTP interface`, e({
    port: 43127, container: { name: "llm-proxy", image }, exclusiveOwner: false,
    markers: ["package.json", "bin/rails"], deps: ["react"]
  }), { kind: "litellm", label: "LiteLLM", name: "llm-proxy", comm: "Docker",
    category: "service", icon: "docker", httpProbe: true, url: "http://localhost:43127", process: null })
}
for (const image of ["acme/my-litellm-helper:latest", "registry.local:5000/team/other:litellm", "acme/litellm-tools:latest"]) {
  check(`generic Docker image ${image} does not imply HTTP`, e({
    port: 43127, container: { name: "worker", image }, exclusiveOwner: false,
    markers: ["package.json", "bin/rails"], deps: ["next"]
  }), { kind: "docker", label: "Docker", name: "worker", comm: "Docker",
    category: "service", httpProbe: false, url: "", process: null })
}

// --- Fallbacks
check("unknown process on a web port still offers a URL", e({
  port: 8888, comm: "mystery"
}), { kind: "unknown", web: true, url: "http://localhost:8888", name: "mystery" })

check("unknown process on a random port offers no URL", e({
  port: 41234, comm: "mystery"
}), { kind: "unknown", web: false, url: "" })

check("443 uses https", e({ port: 443, comm: "caddy" }), { url: "https://localhost:443" })

// --- Scope is passed through for the UI badge
check("all-interfaces scope preserved", e({
  port: 8000, comm: "java", addresses: ["*"], scope: "all"
}), { scope: "all" })

check("a shared listener keeps identity without process authority", e({
  port: 8000, pid: 10, start: 20, exclusiveOwner: false
}), { pid: 10, start: 20, process: null })

// --- displayName fallback chain lives in Detect.js, not the scanner
check("directory basename names the row when package.json has no name", e({
  port: 3000, comm: "node", deps: ["next"], projectRoot: "/home/x/proj/acme-web"
}), { name: "acme-web" })

check("package name beats directory basename", e({
  port: 3000, comm: "node", deps: ["next"], projectRoot: "/home/x/proj/dir", projectName: "real-name"
}), { name: "real-name" })

// --- Runtimes and Python tools
check("Hono via dependency", e({ port: 3000, comm: "node", deps: ["hono"] }), { kind: "hono" })
check("SolidStart via dependency", e({ port: 3000, comm: "node", deps: ["@solidjs/start"] }), { kind: "solidstart" })
check("Deno by comm, labeled as itself", e({ port: 8000, comm: "deno" }), { kind: "deno", label: "Deno" })
check("Bun by comm", e({ port: 3000, comm: "bun" }), { kind: "bun", label: "Bun" })
check("Jupyter via cmdline", e({ port: 8888, comm: "python3", cmdline: "python3 -m jupyter lab" }), { kind: "jupyter" })
check("Streamlit via cmdline", e({ port: 8501, comm: "python3", cmdline: "streamlit run app.py" }), { kind: "streamlit" })
check("Java with build markers is a dev app", e({
  port: 8080, comm: "java", markers: ["pom.xml"], projectRoot: "/x/app"
}), { kind: "javadev", category: "dev" })
check("bare Java stays a service", e({ port: 8081, comm: "java" }), { kind: "java", category: "service" })

// --- Portal's own tooling must not masquerade as a dev server
check("portless proxy is system, not a Node app", e({
  port: 1355, comm: "node-MainThread",
  cmdline: "/usr/bin/node /usr/bin/portless proxy start --foreground --port 1355 --https"
}), { kind: "portless", label: "Portless proxy", category: "system" })

check("cloudflared is system", e({ port: 33333, comm: "cloudflared" }), { kind: "cloudflared", category: "system" })

// --- Command-line evidence matches whole words: a path is not a stack.
check("a project at ~/trails is not Rails", e({
  port: 8000, comm: "python3", cmdline: "/home/x/trails/.venv/bin/python3 manage.py runserver", markers: ["manage.py"]
}), { kind: "django" })
check("a project at ~/invite is not Vite", e({
  port: 8000, comm: "python3", cmdline: "/home/x/invite/manage.py runserver", markers: ["manage.py"]
}), { kind: "django" })
check("a Next app under ~/portless-demo is not the proxy", e({
  port: 3000, comm: "node", cmdline: "node /home/x/portless-demo/node_modules/.bin/next dev", deps: ["next"]
}), { kind: "next", category: "dev" })
check("a puma tag mentioning nuxt stays Puma", e({
  port: 3000, comm: "ruby", cmdline: "puma 6.4.2 (tcp://0.0.0.0:3000) [nuxt-migration]"
}), { kind: "puma" })
check("python3.12 is Python", e({ port: 5000, comm: "python3.12" }), { kind: "python" })
check("a LAN-only bind gets its own address in the URL", e({
  port: 8080, comm: "node", deps: ["vite"], addresses: ["192.168.1.5"], scope: "lan"
}), { url: "http://192.168.1.5:8080" })
check("an IPv6-only bind is bracketed", e({
  port: 8080, comm: "node", deps: ["vite"], addresses: ["fd00::5"], scope: "lan"
}), { url: "http://[fd00::5]:8080" })
check("a wildcard bind still opens localhost", e({
  port: 8080, comm: "node", deps: ["vite"], addresses: ["*"], scope: "all"
}), { url: "http://localhost:8080" })

// --- Evidence contract: every marker / dependency a rule tests must be
// collected by scan-ports.sh, or the rule silently never fires in production
// while passing these hand-fed fixtures forever.
{
  const detectSrc = readFileSync(join(here, "..", "lib", "Detect.js"), "utf8")
  const scanSrc = readFileSync(join(here, "..", "scripts", "scan-ports.sh"), "utf8")
  const arr = (name) => {
    const m = scanSrc.match(new RegExp(name + "=\\(([^)]*)\\)"))
    return m ? m[1].split(/\s+/).filter(Boolean) : []
  }
  const scanMarkers = new Set(arr("MARKERS"))
  const scanDeps = new Set(arr("FRAMEWORK_DEPS"))

  const wanted = { markers: new Set(), deps: new Set() }
  for (const m of detectSrc.matchAll(/has\(e\.(deps|markers),\s*"([^"]+)"\)/g))
    wanted[m[1]].add(m[2])
  for (const m of detectSrc.matchAll(/anyOf\(e\.(deps|markers),\s*\[([^\]]+)\]/g))
    for (const lit of m[2].matchAll(/"([^"]+)"/g)) wanted[m[1]].add(lit[1])

  let bad = []
  for (const d of wanted.deps) if (!scanDeps.has(d)) bad.push(`dep '${d}' not in FRAMEWORK_DEPS`)
  for (const mk of wanted.markers) if (!scanMarkers.has(mk)) bad.push(`marker '${mk}' not in MARKERS`)
  if (bad.length === 0) { pass++; console.log("  ok   every rule's evidence is collected by scan-ports.sh") }
  else { fail++; console.log("  FAIL evidence contract"); for (const b of bad) console.log("         " + b) }
}

// ---- formatting and colors ------------------------------------------------
{
  const F = loadQmlJs(formatPath)
  const C = loadQmlJs(colorsPath)
  let bad = []
  const eq = (name, got, want) => { if (got !== want) bad.push(`${name}: expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`) }
  eq("bytesKb rounds up into the next unit", F.bytesKb(1023.6), "1M")
  eq("bytesKb never prints 1024M", F.bytesKb(1048575), "1.0G")
  eq("bytesKb keeps K below the boundary", F.bytesKb(1023.4), "1023K")
  eq("bytesKb G keeps one decimal", F.bytesKb(1572864), "1.5G")
  eq("bytesKb of null is empty", F.bytesKb(null), "")
  eq("uptime days", F.uptime(90000), "1d")
  eq("uptimeLine before a day", F.uptimeLine(86399), "up 23h")
  eq("uptimeLine after a day", F.uptimeLine(86400), "still alive · 1d")
  eq("span seconds", F.span(42), "42s")
  eq("span minutes", F.span(1500), "25m")
  eq("span hours keeps one decimal", F.span(13800), "3.8h")
  const dark = { r: 0.02, g: 0.09, b: 0.18 }, light = { r: 0.98, g: 0.98, b: 0.98 }
  eq("contrast of white on dark is high", C.contrast("#ffffff", dark) > 10, true)
  eq("contrast of a bad hex is zero", C.contrast("#zz", dark), 0)
  eq("iconColor uses the brand when it reads", C.iconColor({ color: "#ffffff" }, true, dark, "fb"), "#ffffff")
  eq("iconColor falls back when brand colors are off", C.iconColor({ color: "#ffffff" }, false, dark, "fb"), "fb")
  eq("iconColor falls back when the brand does not read", C.iconColor({ color: "#ffffff" }, true, light, "fb"), "fb")
  eq("iconColor falls back with no entry", C.iconColor(null, true, dark, "fb"), "fb")
  if (bad.length === 0) { pass++; console.log("  ok   Format.js and Colors.js") }
  else { fail++; console.log("  FAIL Format.js / Colors.js"); for (const b of bad) console.log("         " + b) }
}

// ---- panel and service rules ----------------------------------------------
// Lifted out of the QML the same way the chart rules are, so mode precedence,
// verb availability, and the probe order cannot drift from what runs.
{
  const panelSrc = readFileSync(join(here, "..", "PortalPanel.qml"), "utf8")
  const serviceSrc = readFileSync(join(here, "..", "Service.qml"), "utf8")
  const rowSrc = readFileSync(join(here, "..", "PortRow.qml"), "utf8")
  const scanSrc = readFileSync(join(here, "..", "scripts", "scan-ports.sh"), "utf8")
  const fn = (src, name, params) => {
    const m = src.match(new RegExp("\\n  function " + name + "\\([^)]*\\) \\{\\n([\\s\\S]*?)\\n  \\}\\n"))
    if (!m) throw new Error(`no function ${name}`)
    return new Function(...params, m[1])
  }
  const modeExpr = panelSrc.match(/readonly property string mode: ([\s\S]*?: "list")\n/)
  if (!modeExpr) throw new Error("PortalPanel.qml no longer declares mode")
  const mode = new Function("helpOpen", "pendingAction", "settingsOpen", "detailEntry", "expandedKind", "return " + modeExpr[1])
  let bad = []
  const eq = (name, got, want) => { const g = JSON.stringify(got), w = JSON.stringify(want); if (g !== w) bad.push(`${name}: expected ${w}, got ${g}`) }

  eq("help outranks everything", mode(true, {}, true, {}, "naming"), "help")
  eq("a pending confirmation outranks settings", mode(false, {}, true, {}, "naming"), "confirm")
  eq("settings outrank the charts", mode(false, null, true, {}, "sharing"), "settings")
  eq("the charts outrank an expansion", mode(false, null, false, {}, "sharing"), "detail")
  eq("an expansion names its kind", mode(false, null, false, null, "actions"), "actions")
  eq("nothing open is the list", mode(false, null, false, null, ""), "list")

  const verbsFor = fn(panelSrc, "verbsFor", ["service", "portlessReady", "selectedPort", "expandedKind", "entry"])
  const svc = (o) => ({
    routeFor: () => o.route || null, publicTunnelFor: () => o.tunnel || null,
    actionProviderFor: () => ({ available: true }), publicProviders: [{ id: "cloudflared", available: true }],
    stats: o.stats || {}, urlFor: () => o.url === undefined ? "http://localhost:1" : o.url,
    validProcessIdentity: (p) => !!(p && p.pid > 1 && Number(p.start) > 0),
    canRestart: (e) => !!(e.process && e.argv.length && !e.argvTruncated)
  })
  const ids = (vs) => vs.map((v) => v.id)
  const dev = { port: 3000, pid: 10, start: 20, process: { pid: 10, start: "20" }, category: "dev", url: "http://localhost:3000", argv: ["node"], argvTruncated: false }
  eq("a dev server offers every verb", ids(verbsFor(svc({}), true, -1, "", dev)), ["name", "share", "pause", "restart", "stop"])
  eq("a service is not restartable", ids(verbsFor(svc({}), true, -1, "", { ...dev, category: "service" })), ["name", "share", "pause", "stop"])
  eq("a system port gets no verbs", ids(verbsFor(svc({}), true, -1, "", { ...dev, category: "system" })), [])
  eq("no pid means no process verbs", ids(verbsFor(svc({}), true, -1, "", { ...dev, pid: null, process: null })), ["name"])
  eq("no start means no process verbs", ids(verbsFor(svc({}), true, -1, "", { ...dev, start: null, process: null })), ["name"])
  eq("name remains discoverable before setup", ids(verbsFor(svc({}), false, -1, "", dev)), ["name", "share", "pause", "restart", "stop"])
  eq("an existing name offers setup without the proxy", verbsFor(svc({ route: { reach: "local", managed: false, aliasName: "app" } }), false, -1, "", dev)[0].label, "name setup")
  eq("a truncated command line cannot be restarted", ids(verbsFor(svc({}), true, -1, "", { ...dev, argvTruncated: true })), ["name", "share", "pause", "stop"])
  eq("a paused process offers resume, urgently", verbsFor(svc({ stats: { 3000: { paused: true } } }), true, -1, "", dev)[2], { id: "pause", label: "resume", on: false, urgent: true })
  eq("a shared port omits the duplicate sharing verb", verbsFor(svc({ tunnel: { url: "x" } }), true, -1, "", dev).some(v => v.id === "share"), false)
  eq("the open section's verb is marked on", verbsFor(svc({}), true, 3000, "naming", dev)[0].on, true)
  eq("no URL means no share verb", ids(verbsFor(svc({ url: "" }), true, -1, "", dev)), ["name", "pause", "restart", "stop"])

  const stillListed = fn(panelSrc, "stillListed", ["service", "entryForPort", "entry"])
  const current = { ...dev, name: "app", cwd: "/tmp/app" }
  const processService = { sameProcess: (a, b) => !!(a && b && a.pid === b.pid && a.start === b.start) }
  eq("an exact process keeps its confirmation", stillListed(processService, () => current, current), true)
  eq("a replacement process cancels its confirmation", stillListed(processService, () => ({ ...current, pid: 11, start: 21, process: { pid: 11, start: "21" } }), current), false)
  eq("two unattributed rows do not retain public consent", stillListed(processService, () => ({ ...current, pid: null, start: null, process: null }), { ...current, pid: null, start: null, process: null }), false)

  const validProcessIdentity = fn(serviceSrc, "validProcessIdentity", ["process"])
  eq("pid and start make a process identity", validProcessIdentity({ pid: 2, start: "1" }), true)
  eq("pid 1 is not a process identity", validProcessIdentity({ pid: 1, start: "1" }), false)
  eq("start zero is not a process identity", validProcessIdentity({ pid: 2, start: "0" }), false)
  if (!serviceSrc.includes('property string scanError: ""') || !serviceSrc.includes('property string tunnelError: ""'))
    bad.push("scan and tunnel errors do not have independent state")
  const lifecycleBody = serviceSrc.match(/function _runLifecycle\([^)]*\) \{([\s\S]*?)\n  \}/)?.[1] ?? ""
  if (!lifecycleBody.includes("_queueAction") || lifecycleBody.includes("_expectGone"))
    bad.push("lifecycle disappearance is not delegated to the queued launch")
  const launchCheck = serviceSrc.indexOf("if (!started)")
  const expectGone = serviceSrc.indexOf("_expectGone(root.activeAction.target)")
  if (launchCheck === -1 || expectGone < launchCheck)
    bad.push("lifecycle disappearance is marked before the helper launches")
  if (!serviceSrc.includes("_forgetGone(action.target)"))
    bad.push("failed lifecycle actions do not clear disappearance state")

  const scanKeyFields = serviceSrc.match(/identity\.push\(\[([\s\S]*?)\]\)/)?.[1] ?? ""
  for (const field of ["e.start", "e.argv", "e.argvTruncated", "e.exclusiveOwner"])
    if (!scanKeyFields.includes(field)) bad.push(`scan identity omits ${field}`)

  const notifyVanishedDev = fn(serviceSrc, "_notifyVanishedDev",
    ["devPorts", "_prevDevPorts", "processKey", "_expectedGoneAt", "expectedGoneMs", "publicTunnelFor", "notify"])
  const runVanished = (markers, now, devPorts = [], previous = [
    { port: 3000, process: { pid: 10, start: "20" }, label: "Node" }
  ]) => {
    const notices = [], state = { ...markers }, realNow = Date.now
    Date.now = () => now
    try {
      notifyVanishedDev(devPorts, previous, (p) => p ? `${p.pid}:${p.start}` : "", state, 600000, () => null,
        (...a) => notices.push(a))
    } finally { Date.now = realNow }
    return { notices, markers: state }
  }
  eq("a fresh expected-stop marker suppresses the crash notice",
    runVanished({ "10:20": 700000 - 60000 }, 700000),
    { notices: [], markers: {} })
  eq("an expired expected-stop marker does not suppress a crash",
    runVanished({ "10:20": 700000 - 600001 }, 700000),
    { notices: [["Port 3000 went quiet", "Node is no longer listening"]], markers: {} })
  eq("losing one of a process's ports still reports that port",
    runVanished({}, 700000,
      [{ port: 3001, process: { pid: 10, start: "20" }, label: "Node" }],
      [
        { port: 3000, process: { pid: 10, start: "20" }, label: "Node" },
        { port: 3001, process: { pid: 10, start: "20" }, label: "Node" }
      ]),
    { notices: [["Port 3000 went quiet", "Node is no longer listening"]], markers: {} })
  if (!serviceSrc.includes("targetHealthy: t.targetHealthy === true ? true"))
    bad.push("tunnel status drops target health before the UI")
  const targetOfflineExpr = rowSrc.match(/readonly property bool targetOffline: ([^\n]+)/)?.[1]
  const publicTunnelTextExpr = rowSrc.match(/readonly property string publicTunnelText: ([^\n]+)/)?.[1]
  if (!targetOfflineExpr || !publicTunnelTextExpr) {
    bad.push("the public tunnel row does not model an offline target")
  } else {
    const targetOffline = new Function("publicTunnel", "return " + targetOfflineExpr)
    const publicTunnelText = new Function("publicTunnel", "targetOffline", "return " + publicTunnelTextExpr)
    const staleTunnel = { url: "https://stale.trycloudflare.com", targetHealthy: false }
    eq("an unhealthy tracked tunnel is marked offline", targetOffline(staleTunnel), true)
    eq("an adopted tunnel is not marked offline", targetOffline({ url: "https://adopted.example", targetHealthy: null }), false)
    eq("the public line names an offline target",
      publicTunnelText(staleTunnel, true), "https://stale.trycloudflare.com · target offline")
  }
  const maxPorts = Number(scanSrc.match(/^MAX_PORTS=([0-9]+)/m)?.[1] ?? 0)
  const argvLogicalCap = Number(scanSrc.match(/^ARGV_LOGICAL_CAP=([0-9]+)$/m)?.[1] ?? 0)
  if (argvLogicalCap !== 8192) bad.push(`scanner argv logical cap is ${argvLogicalCap}`)
  const scanCap = Number(serviceSrc.match(/outputCaps:[^\n]*scan:\s*([0-9]+)/)?.[1] ?? 0)
  const maxArgvValue = "\u0001".repeat(argvLogicalCap + 1)
  const maximalArgvDocument = { version: 1, ports: Array.from({ length: maxPorts }, () => ({ argv: [maxArgvValue] })) }
  eq(`scan cap holds ${maxPorts} maximally JSON-escaped sampled argv values`, Buffer.byteLength(JSON.stringify(maximalArgvDocument)) <= scanCap, true)
  const tunnelCap = Number(serviceSrc.match(/outputCaps:[^\n]*poll:\s*([0-9]+)/)?.[1] ?? 0)
  if (tunnelCap < 8 * 1024 * 1024) bad.push(`tunnel poll cap is only ${tunnelCap} bytes`)
  const lifecycleDeadline = Number(serviceSrc.match(/deadlines:[^\n]*lifecycle:\s*([0-9]+)/)?.[1] ?? 0)
  if (lifecycleDeadline !== 20) bad.push(`lifecycle deadline is ${lifecycleDeadline} seconds`)
  if (!/queued\.script === "lifecycle\.sh"\s*\? "lifecycle"\s*:\s*"quick"/.test(serviceSrc))
    bad.push("lifecycle actions still use the quick helper deadline")

  const state = { feedback: null }, timer = { restarted: 0, stopped: 0,
    restart() { this.restarted++ }, stop() { this.stopped++ } }
  const feedbackFn = (name, params) => {
    const body = panelSrc.match(new RegExp("\\n  function " + name + "\\([^)]*\\) \\{\\n([\\s\\S]*?)\\n  \\}\\n"))?.[1]
    if (!body) throw new Error(`no function ${name}`)
    return new Function("state", "feedbackTimer", ...params, body.replace(/\bfeedback\s*=/g, "state.feedback ="))
  }
  const showMoment = feedbackFn("showMoment", ["message", "error"])
  const showGuidance = feedbackFn("showGuidance", ["message", "command"])
  showGuidance(state, timer, "run this", "sudo true")
  eq("copy guidance carries one command", state.feedback, { kind: "copy", text: "run this", error: false, command: "sudo true" })
  eq("copy guidance remains until replacement or dismissal", timer.stopped, 1)
  showMoment(state, timer, "copied", false)
  eq("a moment replaces copy guidance", state.feedback, { kind: "moment", text: "copied", error: false })
  showMoment(state, timer, "failed", true)
  eq("an action failure stays urgent", state.feedback, { kind: "moment", text: "failed", error: true })

  const extract = (src, re) => src.match(re)?.[0] ?? ""
  if (panelSrc.includes("Text.RichText")) bad.push("PortalPanel.qml still renders rich text")
  if (/\bfunction\s+richStep\s*\(/.test(panelSrc)) bad.push("PortalPanel.qml still declares richStep")
  const stepBlockSrc = extract(panelSrc,
    /^        Column \{\n          id: stepBlock\n[\s\S]*?^        \}$/m)
  if (!stepBlockSrc) {
    bad.push("copy guidance is not a Column named stepBlock")
  } else {
    const guidanceTextSrc = extract(stepBlockSrc,
      /^          Text \{\n[\s\S]*?^          \}$/m)
    if (!/^[ \t]*textFormat:[ \t]*Text\.PlainText[ \t]*$/m.test(guidanceTextSrc)
        || !/^[ \t]*text:[ \t]*root\.feedback[ \t]*\?[ \t]*root\.feedback\.text[ \t]*:[ \t]*""[ \t]*$/m.test(guidanceTextSrc)
        || !/^[ \t]*wrapMode:[ \t]*Text\.WrapAtWordBoundaryOrAnywhere[ \t]*$/m.test(guidanceTextSrc)
        || /^[ \t]*elide[ \t]*:/m.test(guidanceTextSrc))
      bad.push("copy guidance does not render feedback text literally with fallback wrapping")
    if (!/^[ \t]*clip:[ \t]*true[ \t]*$/m.test(stepBlockSrc))
      bad.push("copy guidance no longer clips to its block")
    const actionRowSrc = extract(stepBlockSrc,
      /^          Item \{\n[\s\S]*?^          \}$/m)
    if (actionRowSrc.includes("Portless documentation") || /onLinkActivated/.test(actionRowSrc))
      bad.push("generic setup guidance still assumes a Portless destination")
    const copyHitSrc = extract(actionRowSrc,
      /^            MouseArea \{\n              id: copyHit\n[\s\S]*?^            \}$/m)
    if (!/^[ \t]*width:[ \t]*parent\.width[ \t]*$/m.test(actionRowSrc)
        || !/^[ \t]*implicitHeight:[ \t]*Math\.max\(docsLink\.implicitHeight, copyHit\.height\)[ \t]*$/m.test(actionRowSrc)
        || !/^[ \t]*anchors\.right:[ \t]*parent\.right[ \t]*$/m.test(copyHitSrc))
      bad.push("copy guidance actions do not span the row with copy anchored right")
    const copyClickSrc = extract(copyHitSrc,
      /^              onClicked: \{\n[\s\S]*?^              \}$/m)
    if (!/^[ \t]*if \(root\.service && root\.feedback\) root\.service\.copyText\(root\.feedback\.command, true\)[ \t]*$/m.test(copyClickSrc))
      bad.push("copy guidance changed the quiet command copy")
    if (!/^[ \t]*stepBlock\.copied[ \t]*=[ \t]*true[ \t]*$/m.test(copyClickSrc)
        || !/^[ \t]*copiedTimer\.restart\(\)[ \t]*$/m.test(copyClickSrc))
      bad.push("copy guidance click no longer starts copied state and its timer")
    const copiedTimerSrc = extract(copyHitSrc,
      /^              Timer \{\n                id: copiedTimer\n[\s\S]*?^              \}$/m)
    if (!/^[ \t]*interval:[ \t]*1200[ \t]*$/m.test(copiedTimerSrc)
        || !/^[ \t]*onTriggered:[ \t]*stepBlock\.copied[ \t]*=[ \t]*false[ \t]*$/m.test(copiedTimerSrc)
        || !/^[ \t]*onVisibleChanged:[ \t]*if \(!visible\) copied[ \t]*=[ \t]*false[ \t]*$/m.test(stepBlockSrc))
      bad.push("copy guidance changed its reset or copied animation lifetime")
    if (/^[ \t]*linkColor[ \t]*:/m.test(stepBlockSrc)
        || /^[ \t]*onLinkActivated[ \t]*:/m.test(stepBlockSrc))
      bad.push("copy guidance still contains rich-text link handling")
  }
  const closeHandlerSrc = extract(panelSrc,
    /^      onCloseRequested: \{\n[\s\S]*?^      \}$/m)
  if (!/^        if \(root\.feedback !== null && root\.feedback\.kind !== "moment"\) \{\n          root\.feedback = null\n          return\n        \}$/m.test(closeHandlerSrc))
    bad.push("Escape no longer clears persistent guidance first")
  const openedHandlerSrc = extract(panelSrc,
    /^  onOpenedChanged: \{\n[\s\S]*?^  \}$/m)
  if (!/^    if \(!opened\) return\n[\s\S]*?^    feedback = null$/m.test(openedHandlerSrc))
    bad.push("panel reopen no longer clears feedback")

  const probeList = fn(serviceSrc, "probeList", ["ports", "watchedPorts", "focusPort"])
  const p = (n, cat, httpProbe) => ({ port: n, category: cat, web: httpProbe, httpProbe: httpProbe })
  const many = [p(3000, "dev", true), p(3001, "dev", true), p(3002, "dev", true), p(3003, "dev", true), p(3004, "dev", true),
                p(3005, "dev", true), p(3006, "dev", true), p(3007, "dev", true), p(5432, "service", false), p(9000, "dev", true)]
  eq("the charts' port is probed first", probeList(many, [3007], 3005), [3005, 3007, 3000, 3001, 3002, 3003, 3004, 3006])
  eq("the cap is eight", probeList(many, [], 0).length, 8)
  eq("a watched port that is not listening does not spend the cap", probeList(many, [7777, 3006], 0)[0], 3006)
  eq("watching does not authorize HTTP to a non-HTTP service", probeList(many, [5432], 0).includes(5432), false)
  eq("nothing listening, nothing probed", probeList([], [3000], 3000), [])

  if (bad.length === 0) { pass++; console.log("  ok   panel mode, verb and probe rules") }
  else { fail++; console.log("  FAIL panel rules"); for (const b of bad) console.log("         " + b) }
}

// ---- contrast guard ------------------------------------------------------
// Every brand hex a rule can pick must be judged against both theme
// extremes, and the fallback must actually trigger where it has to.
{
  const { readable } = loadQmlJs(colorsPath)
  const black = { r: 0.07, g: 0.07, b: 0.09 }   // typical dark popup surface
  const white = { r: 0.98, g: 0.98, b: 0.98 }   // typical light popup surface
  const src = readFileSync(detectPath, "utf8")
  const table = src.match(/var BRAND = \{([\s\S]*?)\n\}/)
  const brands = [...(table?.[1] ?? "").matchAll(/"(#[0-9a-fA-F]{6})"/g)].map((m) => m[1])
  let bad = []
  if (brands.length === 0) bad.push("no brand colors found in Detect.js")
  for (const hex of brands) {
    if (!readable(hex, black) && !readable(hex, white))
      bad.push(`${hex} is unreadable on both a dark and a light surface`)
  }
  // The guard has to say no somewhere, or it is not a guard.
  if (readable("#0b0b0e", black)) bad.push("near-black passed against a dark surface")
  if (readable("#fdfdfd", white)) bad.push("near-white passed against a light surface")
  if (readable("nonsense", black)) bad.push("a malformed hex was accepted")
  if (bad.length === 0) { pass++; console.log(`  ok   ${brands.length} brand colors pass the contrast guard`) }
  else { fail++; console.log("  FAIL contrast guard"); for (const b of bad) console.log("         " + b) }
}

// ---- settings schema contract --------------------------------------------
// The panel's settings page reads manifest.json's schema at runtime; these
// assert the manifest itself stays coherent, since nothing else would notice.
{
  const manifest = JSON.parse(readFileSync(join(here, "..", "manifest.json"), "utf8"))
  const schema = manifest.barWidget?.schema ?? []
  const defaults = manifest.barWidget?.defaults ?? {}
  const panelSrc = readFileSync(join(here, "..", "PortalPanel.qml"), "utf8")
  const uiBlock = panelSrc.match(/readonly property var settingUi: \(\{([\s\S]*?)\}\)/)
  const uiKeys = new Set([...(uiBlock?.[1] ?? "").matchAll(/"([A-Za-z]+)":\s*\{/g)].map((m) => m[1]))
  let bad = []
  if (schema.length === 0) bad.push("manifest declares no settings schema")
  for (const row of schema) {
    if (!uiKeys.has(row.key)) bad.push(`schema key '${row.key}' has no settingUi entry — it would not render`)
    if (!(row.key in defaults)) bad.push(`schema key '${row.key}' missing from barWidget.defaults`)
    else if (String(defaults[row.key]) !== String(row.defaultValue))
      bad.push(`'${row.key}': defaults=${JSON.stringify(defaults[row.key])} vs schema defaultValue=${JSON.stringify(row.defaultValue)}`)
    if (row.type === "enum" && !row.options?.includes(String(row.defaultValue)))
      bad.push(`'${row.key}': default ${JSON.stringify(row.defaultValue)} is not one of its options`)
  }
  for (const k of uiKeys) if (!schema.some((r) => r.key === k))
    bad.push(`settingUi has '${k}' but the schema does not declare it`)
  if (bad.length === 0) { pass++; console.log(`  ok   ${schema.length} settings agree across manifest and panel`) }
  else { fail++; console.log("  FAIL settings schema contract"); for (const b of bad) console.log("         " + b) }
}

// ---- chart rules ---------------------------------------------------------
// The phase and axis bindings are lifted out of SparkCard.qml itself, so this
// cannot drift from what the component actually paints. The invariant under
// test: an area fill claims magnitude from a true baseline, so the fill is
// drawn if and only if the axis includes zero — and a series with no visible
// shape gets no shape drawn.
{
  const cardSrc = readFileSync(join(here, "..", "SparkCard.qml"), "utf8")
  const binding = (name, args) => {
    const m = cardSrc.match(new RegExp(`readonly property (?:string|real) ${name}: \\{([\\s\\S]*?)\\n  \\}`))
    if (!m) throw new Error(`SparkCard.qml no longer declares ${name}`)
    return new Function(...args, m[1])
  }
  const phaseOf = binding("phase", ["lo", "hi", "format"])
  const floorOf = binding("plotFloor", ["phase", "lo", "hi", "zeroAnchored"])
  const spanOf = binding("plotSpan", ["phase", "lo", "hi", "zeroAnchored"])

  const ms = (v) => Math.round(v) + "ms"
  const num = (v) => String(Math.round(v))
  const mb = (v) => (v / 1024).toFixed(0) + "M"
  // Where a value lands in the plot: 0 = baseline, 1 = top.
  const at = (phase, v, lo, hi, zeroAnchored) =>
    (v - floorOf(phase, lo, hi, zeroAnchored)) / spanOf(phase, lo, hi, zeroAnchored)

  const bad = []
  const ck = (name, got, want) => {
    if (String(got) !== String(want)) bad.push(`${name}: got ${got}, want ${want}`)
  }

  ck("no data is 'collecting'", phaseOf(null, null, num), "collecting")
  ck("all-zero is 'zero'", phaseOf(0, 0, num), "zero")
  ck("constant non-zero is 'steady'", phaseOf(4, 4, num), "steady")
  // 21100K and 21400K both print "21M": a truncated axis would magnify that
  // into a cliff the numbers cannot explain.
  ck("sub-precision drift is 'steady'", phaseOf(21100, 21400, mb), "steady")
  ck("visible variation is 'active'", phaseOf(0, 42, ms), "active")
  ck("0->1ms is 'active'", phaseOf(0, 1, ms), "active")

  ck("a zero series sits ON the baseline", at("zero", 0, 0, 0, true), 0)
  ck("a zero-anchored axis floors at 0", floorOf("active", 5, 42, true), 0)
  ck("a truncated axis floors below its min", floorOf("active", 20000, 21000, false) < 20000, true)
  ck("the peak keeps headroom", at("active", 42, 0, 42, true) < 1, true)
  ck("the peak still reads as the peak", at("active", 42, 0, 42, true) > 0.9, true)
  ck("a truncated band's min stays in frame", at("active", 20000, 20000, 21000, false) > 0.05, true)
  ck("a truncated band's max stays in frame", at("active", 21000, 20000, 21000, false) < 0.95, true)
  // plotY divides by the span in every phase.
  for (const ph of ["collecting", "zero", "steady", "active"])
    ck(`${ph} span is non-zero`, spanOf(ph, 4, 4, true) > 0, true)

  if (bad.length === 0) { pass++; console.log("  ok   chart phases and axis rules") }
  else { fail++; console.log("  FAIL chart rules"); for (const b of bad) console.log("         " + b) }
}

check("the kernel start time passes through with the pid", { port: 3000, pid: 10, start: 15273183, comm: "node", cmdline: "node srv.js", cwd: "/tmp/x", addresses: ["127.0.0.1"] }, { pid: 10, start: 15273183 })
check("a scan without a start time yields null, never undefined", { port: 3001, pid: 11, comm: "node", cmdline: "node", cwd: "/tmp/x", addresses: ["127.0.0.1"] }, { start: null })

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
