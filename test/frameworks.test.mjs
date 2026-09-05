import assert from "node:assert/strict"
import { loadQmlJs, detectPath } from "../scripts/lib/qmljs.mjs"
const { decorate } = loadQmlJs(detectPath)
const packages = [
  ["@sveltejs/kit", "sveltekit", true], ["svelte", "svelte", false],
  ["@solidjs/start", "solidstart", true], ["solid-js", "solid", false],
  ["vitepress", "vitepress", true], ["@docusaurus/core", "docusaurus", true],
  ["gatsby", "gatsby", true], ["@adonisjs/core", "adonis", true],
  ["@strapi/strapi", "strapi", true], ["elysia", "elysia", true],
  ["fastify", "fastify", true], ["koa", "koa", true], ["@hapi/hapi", "hapi", true],
  ["hapi", "hapi", true], ["webpack-dev-server", "webpack", true],
  ["parcel", "parcel", false], ["preact", "preact", false],
  ["socket.io", "socketio", false], ["ws", "ws", false],
  ["@nestjs/core", "nest", false], ["@nestjs/platform-express", "nest", true],
  ["@nestjs/platform-fastify", "nest", true], ["@react-router/dev", "remix", true],
  ["@react-router/serve", "remix", true], ["@remix-run/serve", "remix", true], ["react", "react", false], ["vue", "vue", false],
  ["react-router", "remix", false]
]
for (const [dep, kind, httpProbe] of packages) {
  const result = decorate({ port: 41000, comm: "node", deps: [dep] })
  assert.equal(result.kind, kind, dep)
  assert.equal(result.httpProbe, httpProbe, dep)
}
for (const [cmdline, kind] of [
  ["fastapi dev app.py", "fastapi"], ["uvicorn app:app", "uvicorn"],
  ["gunicorn app:wsgi", "gunicorn"], ["flask run", "flask"],
  ["hypercorn app:app", "hypercorn"], ["waitress-serve app:wsgi", "waitress"],
  ["sanic app:app", "sanic"], ["litestar run", "litestar"], ["mkdocs serve", "mkdocs"],
  ["hanami server", "hanami"], ["puma app.ru", "puma"],
  ["symfony server:start", "symfony"], ["mix phx.server", "phoenix"]
]) {
  const result = decorate({ port: 41001, cmdline })
  assert.equal(result.kind, kind, cmdline)
  assert.equal(result.httpProbe, true, cmdline)
}
for (const deps of [["vitepress", "vue", "vite"], ["@docusaurus/core", "react", "webpack-dev-server"], ["@sveltejs/kit", "svelte", "vite"]])
  assert.equal(decorate({ deps }).kind, packages.find(([dep]) => dep === deps[0])[1])
assert.equal(decorate({ deps: ["express", "ws"] }).kind, "express")
assert.equal(decorate({ deps: ["vite", "svelte"] }).kind, "vite")
assert.equal(decorate({ deps: ["express", "solid-js"] }).kind, "express")
assert.equal(decorate({ deps: ["hono", "react"] }).kind, "hono")
assert.equal(decorate({ comm: "ruby", markers: ["Gemfile", "config.ru"] }).kind, "rack")
assert.equal(decorate({ comm: "ruby", markers: ["Gemfile", "bin/rails"] }).kind, "rails")
assert.equal(decorate({ markers: ["mix.exs"] }).kind, "elixir")
assert.equal(decorate({ comm: "java", markers: ["build.gradle.kts"] }).kind, "javadev")
for (const comm of ["node", "bun", "deno", "python3", "ruby", "java", "dotnet", "php", "mysqld", "mariadbd", "postgres", "redis-server", "valkey-server", "mongod", "php-fpm", "anycable-go"])
  assert.equal(decorate({ port: 8080, comm }).httpProbe, false, comm)
for (const markers of [["go.mod"], ["Cargo.toml"], ["mix.exs"], ["Gemfile", "config.ru"]])
  assert.equal(decorate({ port: 8080, markers }).httpProbe, false)
console.log("ok framework/package signals, precise server labels, precedence and conservative HTTP metadata")
