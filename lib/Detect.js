.pragma library

// Pure classification of scan-ports.sh evidence. Tested by test/detect.test.mjs.
// The first matching rule wins. Put specific rules before general ones.

// Brand tints. Used only for the icon glyph; all text stays on theme colors so
// the panel still reads correctly in any Omarchy theme.
var BRAND = {
  next: "#ffffff", react: "#61dafb", vue: "#42b883", nuxt: "#00dc82",
  svelte: "#ff3e00", angular: "#dd0031", astro: "#ff5d01", vite: "#a259ff",
  node: "#5fa04e", rails: "#cc0000", ruby: "#cc342d", python: "#3776ab",
  django: "#092e20", go: "#00add8", rust: "#dea584", php: "#777bb4",
  laravel: "#ff2d20", java: "#f89820", elixir: "#4b275f", dotnet: "#512bd4",
  docker: "#2496ed", postgres: "#336791", mysql: "#00758f", redis: "#dc382d",
  elastic: "#fed10a"
}

function has(list, value) {
  if (!list) return false
  for (var i = 0; i < list.length; i++) if (list[i] === value) return true
  return false
}

function anyOf(list, values) {
  for (var i = 0; i < values.length; i++) if (has(list, values[i])) return true
  return false
}

// Match a word or phrase in the command line, case-insensitive, on word
// boundaries: a project at ~/trails is not Rails, ~/invite is not Vite, and
// a Next app in ~/portless-demo is not the Portless proxy.
var BOUNDARY = "(^|[\\s/=:.,;()\\[\\]'\"])"
function cmd(entry, needle) {
  var n = needle.trim().replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  return new RegExp(BOUNDARY + n + "($|[\\s/=:.,;()\\[\\]'\"])", "i").test(String(entry.cmdline || ""))
}

function comm(entry, name) {
  return String(entry.comm || "").toLowerCase() === name
}

// category: "dev" (something you are building), "service" (a backing store or
// broker), "system" (infrastructure you did not start). Drives grouping.
var RULES = [
  // --- Portal's own exposure tooling. Listed before the language rules so a
  // node-based proxy is not reported as a dev server.
  { id: "portless", label: "Portless proxy", icon: "globe", cat: "system",
    test: function (e) { return cmd(e, "portless") } },
  { id: "cloudflared", label: "Cloudflare tunnel", icon: "globe", cat: "system",
    test: function (e) { return comm(e, "cloudflared") || cmd(e, "cloudflared") } },
  { id: "ngrok", label: "ngrok tunnel", icon: "globe", cat: "system",
    test: function (e) { return comm(e, "ngrok") || cmd(e, "ngrok ") } },

  // --- JS/TS dev servers. Check deps first: cmdline is often just "node".
  { id: "next",    label: "Next.js",     icon: "next",    cat: "dev",
    test: function (e) { return has(e.deps, "next") || cmd(e, "next-server") || cmd(e, "next dev") } },
  { id: "nuxt",    label: "Nuxt",        icon: "nuxt",    cat: "dev",
    test: function (e) { return has(e.deps, "nuxt") || cmd(e, "nuxt") } },
  { id: "astro",   label: "Astro",       icon: "astro",   cat: "dev",
    test: function (e) { return has(e.deps, "astro") || cmd(e, "astro dev") } },
  { id: "svelte",  label: "SvelteKit",   icon: "svelte",  cat: "dev",
    test: function (e) { return anyOf(e.deps, ["@sveltejs/kit", "svelte"]) } },
  { id: "angular", label: "Angular",     icon: "angular", cat: "dev",
    test: function (e) { return has(e.deps, "@angular/core") || has(e.markers, "angular.json") } },
  { id: "remix",   label: "React Router", icon: "react",  cat: "dev",
    test: function (e) { return anyOf(e.deps, ["react-router", "@remix-run/react"]) } },
  // Storybook projects carry vite too; the storybook port must win.
  { id: "storybook", label: "Storybook", icon: "package", cat: "dev",
    test: function (e) { return anyOf(e.deps, ["storybook", "@storybook/react"]) || cmd(e, "storybook") } },
  { id: "vite",    label: "Vite",        icon: "vite",    cat: "dev",
    test: function (e) { return has(e.deps, "vite") || cmd(e, "vite") } },
  { id: "nest",    label: "NestJS",      icon: "node",    cat: "dev",
    test: function (e) { return has(e.deps, "@nestjs/core") } },
  { id: "react",   label: "React",       icon: "react",   cat: "dev",
    test: function (e) { return has(e.deps, "react") } },
  { id: "vue",     label: "Vue",         icon: "vue",     cat: "dev",
    test: function (e) { return has(e.deps, "vue") } },
  { id: "hono",    label: "Hono",        icon: "node",    cat: "dev",
    test: function (e) { return has(e.deps, "hono") } },
  { id: "solid",   label: "SolidStart",  icon: "node",    cat: "dev",
    test: function (e) { return anyOf(e.deps, ["@solidjs/start", "solid-js"]) } },
  { id: "express", label: "Express",     icon: "node",    cat: "dev",
    test: function (e) { return anyOf(e.deps, ["express", "fastify", "koa", "hapi"]) } },
  { id: "deno",    label: "Deno",        icon: "node",    cat: "dev",
    test: function (e) { return comm(e, "deno") } },
  { id: "bun",     label: "Bun",         icon: "node",    cat: "dev",
    test: function (e) { return comm(e, "bun") } },
  { id: "node",    label: "Node",        icon: "node",    cat: "dev",
    test: function (e) { return comm(e, "node") } },

  // --- Ruby
  { id: "rails",   label: "Rails",       icon: "rails",   cat: "dev",
    test: function (e) { return cmd(e, "puma") || cmd(e, "rails") || cmd(e, "bin/dev")
                                || (has(e.markers, "Gemfile") && has(e.markers, "config.ru")) } },
  { id: "sidekiq", label: "Sidekiq",     icon: "ruby",    cat: "service",
    test: function (e) { return cmd(e, "sidekiq") } },
  { id: "anycable", label: "AnyCable",   icon: "ruby",    cat: "service",
    test: function (e) { return comm(e, "anycable-go") || cmd(e, "anycable") } },
  { id: "ruby",    label: "Ruby",        icon: "ruby",    cat: "dev",
    test: function (e) { return comm(e, "ruby") || has(e.markers, "Gemfile") } },

  // --- Python
  { id: "django",  label: "Django",      icon: "django",  cat: "dev",
    test: function (e) { return has(e.markers, "manage.py") || cmd(e, "manage.py runserver") } },
  { id: "uvicorn", label: "FastAPI",     icon: "python",  cat: "dev",
    test: function (e) { return cmd(e, "uvicorn") || cmd(e, "fastapi") } },
  { id: "flask",   label: "Flask",       icon: "flask",   cat: "dev",
    test: function (e) { return cmd(e, "flask") || cmd(e, "gunicorn") } },
  { id: "jupyter", label: "Jupyter",     icon: "python",  cat: "dev",
    test: function (e) { return cmd(e, "jupyter") } },
  { id: "streamlit", label: "Streamlit", icon: "python",  cat: "dev",
    test: function (e) { return cmd(e, "streamlit") } },
  { id: "python",  label: "Python",      icon: "python",  cat: "dev",
    test: function (e) { return /^python[0-9.]*$/.test(String(e.comm || "").toLowerCase()) } },

  // --- Other languages
  { id: "phoenix", label: "Phoenix",     icon: "elixir",  cat: "dev",
    test: function (e) { return has(e.markers, "mix.exs") } },
  { id: "laravel", label: "Laravel",     icon: "laravel", cat: "dev",
    test: function (e) { return has(e.markers, "artisan") } },
  { id: "php",     label: "PHP",         icon: "php",     cat: "dev",
    test: function (e) { return comm(e, "php") || comm(e, "php-fpm") } },
  { id: "go",      label: "Go",          icon: "go",      cat: "dev",
    test: function (e) { return has(e.markers, "go.mod") } },
  { id: "rust",    label: "Rust",        icon: "rust",    cat: "dev",
    test: function (e) { return has(e.markers, "Cargo.toml") } },
  { id: "dotnet",  label: ".NET",        icon: "dotnet",  cat: "dev",
    test: function (e) { return comm(e, "dotnet") } },
  // A package.json alone says "some JS project" only once every other stack
  // has had its turn: Rails, Laravel and Django apps ship one too.
  { id: "node",    label: "Node",        icon: "node",    cat: "dev",
    test: function (e) { return has(e.markers, "package.json") } },

  // --- Backing services
  { id: "postgres", label: "PostgreSQL", icon: "postgres", cat: "service",
    test: function (e) { return comm(e, "postgres") || comm(e, "postmaster") || e.port === 5432 } },
  { id: "mysql",   label: "MySQL",       icon: "mysql",   cat: "service",
    test: function (e) { return comm(e, "mysqld") || comm(e, "mariadbd") || e.port === 3306 } },
  { id: "redis",   label: "Redis",       icon: "redis",   cat: "service",
    test: function (e) { return comm(e, "redis-server") || cmd(e, "valkey") || e.port === 6379 } },
  { id: "elastic", label: "OpenSearch",  icon: "elastic", cat: "service",
    test: function (e) { return cmd(e, "opensearch") || cmd(e, "elasticsearch")
                                || e.port === 9200 || e.port === 9300 } },
  { id: "mongo",   label: "MongoDB",     icon: "database", cat: "service",
    test: function (e) { return comm(e, "mongod") || e.port === 27017 } },
  { id: "dynamodb", label: "DynamoDB",   icon: "database", cat: "service",
    test: function (e) { return cmd(e, "dynamodblocal") || cmd(e, "dynamodb") } },
  { id: "rabbit",  label: "RabbitMQ",    icon: "server",  cat: "service",
    test: function (e) { return cmd(e, "rabbitmq") || e.port === 5672 } },
  { id: "kafka",   label: "Kafka",       icon: "server",  cat: "service",
    test: function (e) { return cmd(e, "kafka") || e.port === 9092 } },
  { id: "mailpit", label: "Mail catcher", icon: "server", cat: "service",
    test: function (e) { return cmd(e, "mailpit") || cmd(e, "mailhog") || e.port === 1025 || e.port === 8025 } },
  { id: "minio",   label: "MinIO",       icon: "package", cat: "service",
    test: function (e) { return cmd(e, "minio") } },
  { id: "docker",  label: "Docker",      icon: "docker",  cat: "service",
    test: function (e) { return comm(e, "docker-proxy") || comm(e, "containerd") } },
  // Java last on purpose: the JVM services above must get first pick.
  { id: "javadev", label: "Java",        icon: "java",    cat: "dev",
    test: function (e) { return comm(e, "java") && anyOf(e.markers, ["pom.xml", "build.gradle"]) } },
  { id: "java",    label: "Java",        icon: "java",    cat: "service",
    test: function (e) { return comm(e, "java") } },

  // --- System noise
  { id: "dns",     label: "DNS",         icon: "cog",     cat: "system",
    test: function (e) { return e.port === 53 || comm(e, "systemd-resolve") } },
  { id: "cups",    label: "Printing",    icon: "cog",     cat: "system",
    test: function (e) { return e.port === 631 || comm(e, "cupsd") } },
  { id: "ssh",     label: "SSH",         icon: "lock",    cat: "system",
    test: function (e) { return e.port === 22 || comm(e, "sshd") } }
]

// Ports that are conventionally a web UI even when we cannot name the stack.
var WEB_PORTS = [80, 443, 3000, 3001, 4000, 4200, 4321, 5000, 5173, 5174,
                 8000, 8080, 8081, 8100, 8888, 9000]

function classify(entry) {
  var e = entry || {}
  for (var i = 0; i < RULES.length; i++) {
    var rule = RULES[i]
    if (!rule.test(e)) continue
    return {
      id: rule.id,
      label: rule.label,
      icon: rule.icon,
      color: BRAND[rule.icon] || "",
      category: rule.cat,
      web: rule.cat === "dev" || has(WEB_PORTS, e.port)
    }
  }
  return {
    id: "unknown",
    label: e.comm ? e.comm : "Unknown",
    icon: "server",
    color: "",
    category: e.projectRoot ? "dev" : "system",
    web: has(WEB_PORTS, e.port)
  }
}

// Display name for the row: package name, else the project directory, else
// the detected stack, else the process, else the port. The whole fallback
// chain lives here — the scanner emits raw facts only — so it is unit-testable
// and has one home.
function displayName(entry, detected) {
  var e = entry || {}
  if (e.projectName) return e.projectName
  if (e.projectRoot) {
    var parts = String(e.projectRoot).split("/")
    var base = parts[parts.length - 1]
    if (base) return base
  }
  if (detected && detected.id !== "unknown") return detected.label
  if (e.comm) return e.comm
  return "port " + e.port
}

// localhost, unless the process is bound to one specific non-loopback
// address, in which case that is the only address that answers.
function urlFor(entry, detected) {
  var e = entry || {}
  if (!detected || !detected.web) return ""
  var scheme = (e.port === 443) ? "https" : "http"
  var addrs = e.addresses || []
  var reachableLocally = addrs.length === 0 || addrs.some(function (a) {
    return a === "*" || a === "0.0.0.0" || a === "::" || a === "::1" || a.indexOf("127.") === 0
  })
  var host = reachableLocally ? "localhost" : (addrs[0].indexOf(":") !== -1 ? "[" + addrs[0] + "]" : addrs[0])
  return scheme + "://" + host + ":" + e.port
}

function processIdentity(entry) {
  if (entry.exclusiveOwner !== true) return null
  var pid = String(entry.pid == null ? "" : entry.pid)
  var start = String(entry.start == null ? "" : entry.start)
  if (!/^[1-9][0-9]*$/.test(pid) || parseInt(pid, 10) <= 1
      || !/^[1-9][0-9]*$/.test(start)) return null
  return { pid: parseInt(pid, 10), start: start }
}

// Enrich one scan entry with everything the UI needs.
function decorate(entry) {
  var d = classify(entry)
  return {
    port: entry.port,
    pid: entry.pid,
    start: entry.start === undefined ? null : entry.start,
    process: processIdentity(entry),
    comm: entry.comm || "",
    cmdline: entry.cmdline || "",
    cwd: entry.cwd || "",
    projectRoot: entry.projectRoot || "",
    scope: entry.scope || "local",
    addresses: entry.addresses || [],
    kind: d.id,
    label: d.label,
    icon: d.icon,
    color: d.color,
    category: d.category,
    web: d.web,
    name: displayName(entry, d),
    url: urlFor(entry, d),
    argv: entry.argv || [],
    argvTruncated: entry.argvTruncated === true
  }
}

// Node-only export so the rules can be unit tested. `module` is undefined
// inside QML, so this is inert there.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { decorate: decorate }
}
