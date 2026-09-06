.pragma library

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
var HTTP_ADAPTERS = {
  nest: ["@nestjs/platform-express", "@nestjs/platform-fastify"],
  reactRouter: ["@react-router/dev", "@react-router/serve", "@remix-run/serve"]
}

var RUNTIMES = {
  js: /^(?:node(?:js|-mainthread)?|bun|deno)$|^(?:next-server|nuxt)(?:\s|$)/,
  ruby: /^(?:ruby[0-9.]*|puma|rails|rackup|sidekiq|hanami)(?:\s|$)/,
  python: /^(?:python[0-9.]*|gunicorn|uvicorn|hypercorn|waitress-serve|fastapi|flask|sanic|litestar|mkdocs|jupyter|streamlit)(?:\s|$)/,
  php: /^(?:php(?:[0-9.]*|-fpm[0-9.]*)|symfony)(?:\s|$)/,
  elixir: /^(?:beam\.smp|elixir|mix)(?:\s|$)/
}

function projectBinary(entry, goBuild) {
  var executable = String((entry.argv || [])[0] || "")
  if (!executable) return false
  var root = String(entry.projectRoot || "").replace(/\/+$/, "")
  if (!root || root[0] !== "/") return false
  if (executable[0] !== "/") {
    if (executable.indexOf("/") === -1 || !entry.cwd) return false
    executable = entry.cwd + "/" + executable
  }
  var parts = executable.split("/"), normalized = []
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === "..") normalized.pop()
    else if (parts[i] && parts[i] !== ".") normalized.push(parts[i])
  }
  executable = "/" + normalized.join("/")
  return executable.indexOf(root + "/") === 0
    || (goBuild && /\/go-build[0-9]+\/b[0-9]+\/exe\/[^/]+$/.test(executable))
}

var LITELLM_IMAGES = ["litellm", "litellm-database"]

function containerImage(entry) {
  var image = String(entry.container && entry.container.image || "").split("@")[0]
  return image.slice(image.lastIndexOf("/") + 1).split(":")[0]
}

var RULES = [
  { id: "litellm", http: true, label: "LiteLLM", icon: "docker", cat: "service",
    test: function (e) { return !!e.container && has(LITELLM_IMAGES, containerImage(e)) } },
  { id: "docker", label: "Docker", icon: "docker", cat: "service",
    test: function (e) { return !!e.container } },
  // --- Portal's own exposure tooling. Listed before the language rules so a
  // node-based proxy is not reported as a dev server.
  { id: "portless", label: "Portless proxy", icon: "globe", cat: "system",
    test: function (e) { return cmd(e, "portless") } },
  { id: "cloudflared", label: "Cloudflare tunnel", icon: "globe", cat: "system",
    test: function (e) { return comm(e, "cloudflared") || cmd(e, "cloudflared") } },
  { id: "ngrok", label: "ngrok tunnel", icon: "globe", cat: "system",
    test: function (e) { return comm(e, "ngrok") || cmd(e, "ngrok ") } },

  // Project dependencies describe the listener only when its runtime is JavaScript.
  { id: "next", runtime: "js", http: true,    label: "Next.js",     icon: "next",    cat: "dev",
    test: function (e) { return has(e.deps, "next") || cmd(e, "next-server") || cmd(e, "next dev") } },
  { id: "nuxt", runtime: "js", http: true,    label: "Nuxt",        icon: "nuxt",    cat: "dev",
    test: function (e) { return has(e.deps, "nuxt") || cmd(e, "nuxt") } },
  { id: "astro", runtime: "js", http: true,   label: "Astro",       icon: "astro",   cat: "dev",
    test: function (e) { return has(e.deps, "astro") || cmd(e, "astro dev") } },
  { id: "sveltekit", runtime: "js", http: true, label: "SvelteKit", icon: "svelte", cat: "dev",
    test: function (e) { return has(e.deps, "@sveltejs/kit") } },
  { id: "solidstart", runtime: "js", http: true, label: "SolidStart", icon: "node", cat: "dev",
    test: function (e) { return has(e.deps, "@solidjs/start") } },
  { id: "vitepress", runtime: "js", http: true, label: "VitePress", icon: "vue", cat: "dev",
    test: function (e) { return has(e.deps, "vitepress") } },
  { id: "docusaurus", runtime: "js", http: true, label: "Docusaurus", icon: "react", cat: "dev",
    test: function (e) { return has(e.deps, "@docusaurus/core") } },
  { id: "gatsby", runtime: "js", http: true, label: "Gatsby", icon: "react", cat: "dev",
    test: function (e) { return has(e.deps, "gatsby") } },
  { id: "adonis", runtime: "js", http: true, label: "AdonisJS", icon: "node", cat: "dev",
    test: function (e) { return has(e.deps, "@adonisjs/core") } },
  { id: "strapi", runtime: "js", http: true, label: "Strapi", icon: "node", cat: "dev",
    test: function (e) { return has(e.deps, "@strapi/strapi") } },
  { id: "elysia", runtime: "js", http: true, label: "Elysia", icon: "node", cat: "dev",
    test: function (e) { return has(e.deps, "elysia") } },
  { id: "angular", runtime: "js", http: true, label: "Angular",     icon: "angular", cat: "dev",
    test: function (e) { return has(e.deps, "@angular/core") || has(e.markers, "angular.json") } },
  { id: "remix", runtime: "js", httpDeps: HTTP_ADAPTERS.reactRouter,   label: "React Router", icon: "react",  cat: "dev",
    test: function (e) { return anyOf(e.deps, ["react-router", "@remix-run/react"]) || anyOf(e.deps, HTTP_ADAPTERS.reactRouter) } },
  // Storybook projects carry vite too; the storybook port must win.
  { id: "storybook", runtime: "js", http: true, label: "Storybook", icon: "package", cat: "dev",
    test: function (e) { return anyOf(e.deps, ["storybook", "@storybook/react"]) || cmd(e, "storybook") } },
  { id: "vite", runtime: "js", http: true,    label: "Vite",        icon: "vite",    cat: "dev",
    test: function (e) { return has(e.deps, "vite") || cmd(e, "vite") } },
  { id: "nest", runtime: "js", httpDeps: HTTP_ADAPTERS.nest,    label: "NestJS",      icon: "node",    cat: "dev",
    test: function (e) { return has(e.deps, "@nestjs/core") || anyOf(e.deps, HTTP_ADAPTERS.nest) } },
  { id: "fastify", runtime: "js", http: true, label: "Fastify", icon: "node", cat: "dev",
    test: function (e) { return has(e.deps, "fastify") } },
  { id: "koa", runtime: "js", http: true, label: "Koa", icon: "node", cat: "dev",
    test: function (e) { return has(e.deps, "koa") } },
  { id: "hapi", runtime: "js", http: true, label: "hapi", icon: "node", cat: "dev",
    test: function (e) { return has(e.deps, "@hapi/hapi") || has(e.deps, "hapi") } },
  { id: "webpack", runtime: "js", http: true, label: "webpack dev server", icon: "package", cat: "dev",
    test: function (e) { return has(e.deps, "webpack-dev-server") } },
  { id: "parcel", runtime: "js", label: "Parcel", icon: "package", cat: "dev",
    test: function (e) { return has(e.deps, "parcel") } },
  { id: "hono", runtime: "js", http: true,    label: "Hono",        icon: "node",    cat: "dev",
    test: function (e) { return has(e.deps, "hono") } },
  { id: "express", runtime: "js", http: true, label: "Express",     icon: "node",    cat: "dev",
    test: function (e) { return has(e.deps, "express") } },
  { id: "svelte", runtime: "js",  label: "Svelte",   icon: "svelte",  cat: "dev",
    test: function (e) { return has(e.deps, "svelte") } },
  { id: "solid", runtime: "js",   label: "SolidJS",  icon: "node",    cat: "dev",
    test: function (e) { return has(e.deps, "solid-js") } },
  { id: "preact", runtime: "js", label: "Preact", icon: "react", cat: "dev",
    test: function (e) { return has(e.deps, "preact") } },
  { id: "socketio", runtime: "js", label: "Socket.IO", icon: "node", cat: "dev",
    test: function (e) { return has(e.deps, "socket.io") } },
  { id: "ws", runtime: "js", label: "WebSocket (ws)", icon: "node", cat: "dev",
    test: function (e) { return has(e.deps, "ws") } },
  { id: "react", runtime: "js",   label: "React",       icon: "react",   cat: "dev",
    test: function (e) { return has(e.deps, "react") } },
  { id: "vue", runtime: "js",     label: "Vue",         icon: "vue",     cat: "dev",
    test: function (e) { return has(e.deps, "vue") } },
  { id: "deno", runtime: "js",    label: "Deno",        icon: "node",    cat: "dev",
    test: function (e) { return comm(e, "deno") } },
  { id: "bun", runtime: "js",     label: "Bun",         icon: "node",    cat: "dev",
    test: function (e) { return comm(e, "bun") } },
  { id: "node", runtime: "js",    label: "Node",        icon: "node",    cat: "dev",
    test: function (e) { return comm(e, "node") } },

  // --- Ruby
  { id: "rails", runtime: "ruby", http: true, label: "Rails", icon: "rails", cat: "dev",
    test: function (e) { return cmd(e, "rails") || has(e.markers, "bin/rails") } },
  { id: "hanami", runtime: "ruby", http: true, label: "Hanami", icon: "ruby", cat: "dev",
    test: function (e) { return cmd(e, "hanami server") } },
  { id: "puma", runtime: "ruby", http: true, label: "Puma", icon: "ruby", cat: "dev",
    test: function (e) { return cmd(e, "puma") } },
  { id: "rack", runtime: "ruby", label: "Rack", icon: "ruby", cat: "dev",
    test: function (e) { return has(e.markers, "Gemfile") && has(e.markers, "config.ru") } },
  { id: "sidekiq", runtime: "ruby", label: "Sidekiq",     icon: "ruby",    cat: "service",
    test: function (e) { return cmd(e, "sidekiq") } },
  { id: "anycable", label: "AnyCable",   icon: "ruby",    cat: "service",
    test: function (e) { return comm(e, "anycable-go") || cmd(e, "anycable") } },
  { id: "ruby", runtime: "ruby",    label: "Ruby",        icon: "ruby",    cat: "dev",
    test: function (e) { return comm(e, "ruby") || has(e.markers, "Gemfile") } },

  // --- Python
  { id: "django", runtime: "python", http: true,  label: "Django",      icon: "django",  cat: "dev",
    test: function (e) { return has(e.markers, "manage.py") || cmd(e, "manage.py runserver") } },
  { id: "fastapi", runtime: "python", http: true, label: "FastAPI", icon: "python", cat: "dev",
    test: function (e) { return cmd(e, "fastapi") } },
  { id: "gunicorn", runtime: "python", http: true, label: "Gunicorn", icon: "python", cat: "dev",
    test: function (e) { return cmd(e, "gunicorn") } },
  { id: "hypercorn", runtime: "python", http: true, label: "Hypercorn", icon: "python", cat: "dev",
    test: function (e) { return cmd(e, "hypercorn") } },
  { id: "waitress", runtime: "python", http: true, label: "Waitress", icon: "python", cat: "dev",
    test: function (e) { return cmd(e, "waitress-serve") } },
  { id: "sanic", runtime: "python", http: true, label: "Sanic", icon: "python", cat: "dev",
    test: function (e) { return cmd(e, "sanic") } },
  { id: "litestar", runtime: "python", http: true, label: "Litestar", icon: "python", cat: "dev",
    test: function (e) { return cmd(e, "litestar run") } },
  { id: "mkdocs", runtime: "python", http: true, label: "MkDocs", icon: "python", cat: "dev",
    test: function (e) { return cmd(e, "mkdocs serve") } },
  { id: "uvicorn", runtime: "python", http: true, label: "Uvicorn",     icon: "python",  cat: "dev",
    test: function (e) { return cmd(e, "uvicorn") } },
  { id: "flask", runtime: "python", http: true,   label: "Flask",       icon: "flask",   cat: "dev",
    test: function (e) { return cmd(e, "flask") } },
  { id: "jupyter", runtime: "python", http: true, label: "Jupyter",     icon: "python",  cat: "dev",
    test: function (e) { return cmd(e, "jupyter") } },
  { id: "streamlit", runtime: "python", http: true, label: "Streamlit", icon: "python",  cat: "dev",
    test: function (e) { return cmd(e, "streamlit") } },
  { id: "python", runtime: "python",  label: "Python",      icon: "python",  cat: "dev",
    test: function (e) { return /^python[0-9.]*$/.test(String(e.comm || "").toLowerCase()) } },

  // --- Other languages
  { id: "phoenix", runtime: "elixir", http: true, label: "Phoenix",     icon: "elixir",  cat: "dev",
    test: function (e) { return cmd(e, "phx.server") } },
  { id: "elixir", runtime: "elixir", label: "Elixir", icon: "elixir", cat: "dev",
    test: function (e) { return has(e.markers, "mix.exs") } },
  { id: "symfony", runtime: "php", http: true, label: "Symfony", icon: "php", cat: "dev",
    test: function (e) { return cmd(e, "symfony server:start") || cmd(e, "symfony serve") } },
  { id: "laravel", runtime: "php", http: true, label: "Laravel",     icon: "laravel", cat: "dev",
    test: function (e) { return has(e.markers, "artisan") } },
  { id: "php", runtime: "php",     label: "PHP",         icon: "php",     cat: "dev",
    test: function (e) { return comm(e, "php") || comm(e, "php-fpm") } },
  { id: "go",      label: "Go",          icon: "go",      cat: "dev",
    test: function (e) { return has(e.markers, "go.mod") && projectBinary(e, true) } },
  { id: "rust",    label: "Rust",        icon: "rust",    cat: "dev",
    test: function (e) { return has(e.markers, "Cargo.toml") && projectBinary(e, false) } },
  { id: "dotnet",  label: ".NET",        icon: "dotnet",  cat: "dev",
    test: function (e) { return comm(e, "dotnet") } },
  // A package.json alone says "some JS project" only once every other stack
  // has had its turn: Rails, Laravel and Django apps ship one too.
  { id: "node", runtime: "js", label: "Node", icon: "node", cat: "dev",
    test: function (e) { return has(e.markers, "package.json") } },

  // --- Backing services
  { id: "postgres", label: "PostgreSQL", icon: "postgres", cat: "service",
    test: function (e) { return comm(e, "postgres") || comm(e, "postmaster") || e.port === 5432 } },
  { id: "mysql",   label: "MySQL",       icon: "mysql",   cat: "service",
    test: function (e) { return comm(e, "mysqld") || comm(e, "mariadbd") || e.port === 3306 } },
  { id: "redis",   label: "Redis",       icon: "redis",   cat: "service",
    test: function (e) { return comm(e, "redis-server") || comm(e, "valkey-server") || cmd(e, "valkey") || e.port === 6379 } },
  { id: "elastic", httpPorts: [9200], label: "OpenSearch",  icon: "elastic", cat: "service",
    test: function (e) { return cmd(e, "opensearch") || cmd(e, "elasticsearch")
                                || e.port === 9200 || e.port === 9300 } },
  { id: "mongo",   label: "MongoDB",     icon: "database", cat: "service",
    test: function (e) { return comm(e, "mongod") || e.port === 27017 } },
  { id: "dynamodb", http: true, label: "DynamoDB",   icon: "database", cat: "service",
    test: function (e) { return cmd(e, "dynamodblocal") || cmd(e, "dynamodb") } },
  { id: "rabbit", httpPorts: [15672],  label: "RabbitMQ",    icon: "server",  cat: "service",
    test: function (e) { return cmd(e, "rabbitmq") || e.port === 5672 } },
  { id: "kafka",   label: "Kafka",       icon: "server",  cat: "service",
    test: function (e) { return cmd(e, "kafka") || e.port === 9092 } },
  { id: "mailpit", httpPorts: [8025], label: "Mail catcher", icon: "server", cat: "service",
    test: function (e) { return cmd(e, "mailpit") || cmd(e, "mailhog") || e.port === 1025 || e.port === 8025 } },
  { id: "minio", http: true,   label: "MinIO",       icon: "package", cat: "service",
    test: function (e) { return cmd(e, "minio") } },
  { id: "docker",  label: "Docker",      icon: "docker",  cat: "service",
    test: function (e) { return comm(e, "docker-proxy") || comm(e, "containerd") } },
  // Java last on purpose: the JVM services above must get first pick.
  { id: "javadev", label: "Java",        icon: "java",    cat: "dev",
    test: function (e) { return comm(e, "java") && anyOf(e.markers, ["pom.xml", "build.gradle", "build.gradle.kts"]) } },
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
  var runtime = String(e.comm || "").toLowerCase()
  for (var i = 0; i < RULES.length; i++) {
    var rule = RULES[i]
    if ((rule.runtime && runtime && !RUNTIMES[rule.runtime].test(runtime)) || !rule.test(e)) continue
    return {
      id: rule.id,
      label: rule.label,
      icon: rule.icon,
      color: BRAND[rule.icon] || "",
      category: rule.cat,
      web: rule.cat === "dev" || has(WEB_PORTS, e.port) || (!!e.container && rule.http === true),
      http: rule.http === true || has(rule.httpPorts, e.port) || anyOf(e.deps, rule.httpDeps || [])
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

function displayName(entry, detected) {
  var e = entry || {}
  if (e.container && e.container.name) return e.container.name
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

var NON_HTTP_COMMS = ["mysqld", "mariadbd", "postgres", "postmaster", "redis-server",
                      "valkey-server", "mongod", "php-fpm", "anycable-go"]

function httpProbeFor(entry, detected) {
  if (has(NON_HTTP_COMMS, String(entry.comm || "").toLowerCase())) return false
  return detected.http === true || cmd(entry, "http.server")
    || (comm(entry, "php") && /(?:^|\s)-S(?:\s|$)/.test(String(entry.cmdline || "")))
}

// Enrich one scan entry with everything the UI needs.
function decorate(entry) {
  var d = classify(entry)
  return {
    port: entry.port,
    pid: entry.pid,
    start: entry.start === undefined ? null : entry.start,
    process: processIdentity(entry),
    comm: entry.container ? "Docker" : entry.comm || "",
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
    httpProbe: httpProbeFor(entry, d),
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
