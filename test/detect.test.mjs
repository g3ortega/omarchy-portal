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
check("Rails via puma", e({
  port: 3000, comm: "ruby", cmdline: "puma 6.4.2 (tcp://0.0.0.0:3000) [acme]",
  markers: ["Gemfile", "config.ru"], projectName: "acme"
}), { kind: "rails", label: "Rails", category: "dev", name: "acme" })

check("Rails via Gemfile + config.ru", e({
  port: 3000, comm: "ruby", markers: ["Gemfile", "config.ru"]
}), { kind: "rails" })

check("Rails with a package.json is still Rails", e({
  port: 3000, comm: "ruby", markers: ["Gemfile", "config.ru", "package.json"]
}), { kind: "rails" })
check("Laravel with a package.json is still Laravel", e({
  port: 8000, comm: "php", markers: ["artisan", "package.json"]
}), { kind: "laravel" })

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

check("FastAPI via uvicorn", e({
  port: 8000, comm: "python3", cmdline: "uvicorn app.main:app --reload"
}), { kind: "uvicorn", label: "FastAPI" })

// --- Other stacks
check("Phoenix via mix.exs", e({ port: 4000, comm: "beam.smp", markers: ["mix.exs"] }), { kind: "phoenix" })
check("RabbitMQ is not Phoenix", e({ port: 5672, comm: "beam.smp", cmdline: "beam.smp -s rabbit boot" }), { kind: "rabbit" })
check("Storybook beats vite in the same project", e({ port: 6006, comm: "node", deps: ["storybook", "vite"] }), { kind: "storybook" })
check("Phoenix gets the elixir brand color", e({ port: 4000, comm: "beam.smp", markers: ["mix.exs"] }), { color: "#4b275f" })
check("Laravel via artisan", e({ port: 8000, comm: "php", markers: ["artisan", "composer.json"] }), { kind: "laravel" })
check("Go via go.mod", e({ port: 8080, comm: "main", markers: ["go.mod"] }), { kind: "go", label: "Go" })
check("Rust via Cargo.toml", e({ port: 8080, comm: "server", markers: ["Cargo.toml"] }), { kind: "rust" })

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
check("SolidStart via dependency", e({ port: 3000, comm: "node", deps: ["@solidjs/start"] }), { kind: "solid" })
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
check("a puma tag mentioning nuxt is still Rails", e({
  port: 3000, comm: "ruby", cmdline: "puma 6.4.2 (tcp://0.0.0.0:3000) [nuxt-migration]"
}), { kind: "rails" })
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
  eq("no proxy and no name means no name verb", ids(verbsFor(svc({}), false, -1, "", dev)), ["share", "pause", "restart", "stop"])
  eq("an existing name can be renamed without the proxy", verbsFor(svc({ route: {} }), false, -1, "", dev)[0].label, "rename")
  eq("a truncated command line cannot be restarted", ids(verbsFor(svc({}), true, -1, "", { ...dev, argvTruncated: true })), ["name", "share", "pause", "stop"])
  eq("a paused process offers resume, urgently", verbsFor(svc({ stats: { 3000: { paused: true } } }), true, -1, "", dev)[2], { id: "pause", label: "resume", on: false, urgent: true })
  eq("a shared port offers to stop sharing, urgently", verbsFor(svc({ tunnel: { url: "x" } }), true, -1, "", dev)[1], { id: "share", label: "stop sharing", on: false, urgent: true })
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
  const maxPorts = Number(scanSrc.match(/^MAX_PORTS=([0-9]+)/m)?.[1] ?? 0)
  const argvB64Cutoff = Number(scanSrc.match(/\$\{#argv_b64\} -gt ([0-9]+)/)?.[1] ?? 0)
  const scanCap = Number(serviceSrc.match(/outputCaps:[^\n]*scan:\s*([0-9]+)/)?.[1] ?? 0)
  const maxArgvValue = "\u0001".repeat(Math.floor(argvB64Cutoff * 3 / 4) - 1)
  const maximalArgvDocument = { version: 1, ports: Array.from({ length: maxPorts }, () => ({ argv: [maxArgvValue] })) }
  eq(`scan cap holds ${maxPorts} maximally JSON-escaped argv values`, Buffer.byteLength(JSON.stringify(maximalArgvDocument)) <= scanCap, true)
  const tunnelCap = Number(serviceSrc.match(/outputCaps:[^\n]*poll:\s*([0-9]+)/)?.[1] ?? 0)
  if (tunnelCap < 8 * 1024 * 1024) bad.push(`tunnel poll cap is only ${tunnelCap} bytes`)

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
  showMoment(state, timer, "copied", false)
  eq("a moment replaces copy guidance", state.feedback, { kind: "moment", text: "copied", error: false })
  showMoment(state, timer, "failed", true)
  eq("an action failure stays urgent", state.feedback, { kind: "moment", text: "failed", error: true })

  const probeList = fn(serviceSrc, "probeList", ["ports", "watchedPorts", "focusPort"])
  const p = (n, cat, web) => ({ port: n, category: cat, web: web })
  const many = [p(3000, "dev", true), p(3001, "dev", true), p(3002, "dev", true), p(3003, "dev", true), p(3004, "dev", true),
                p(3005, "dev", true), p(3006, "dev", true), p(3007, "dev", true), p(5432, "service", false), p(9000, "dev", true)]
  eq("the charts' port is probed first", probeList(many, [3007], 3005), [3005, 3007, 3000, 3001, 3002, 3003, 3004, 3006])
  eq("the cap is eight", probeList(many, [], 0).length, 8)
  eq("a watched port that is not listening does not spend the cap", probeList(many, [7777, 3006], 0)[0], 3006)
  eq("services are not probed unless watched", probeList(many, [5432], 0)[0], 5432)
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
