# Framework and library detection

Detection uses evidence the scanner emits. Rules now own HTTP eligibility through http, httpPorts and httpDeps metadata. HTTP_ADAPTERS collects Nest and React Router adapter names, and NON_HTTP_COMMS keeps database/native-protocol exclusions above framework inference. No runtime or conventional port alone enables an active HTTP request.

## Added signals

| IDs | Observable evidence | HTTP policy |
|---|---|---|
| sveltekit / svelte | @sveltejs/kit / svelte dependency | Kit yes; component library no |
| solidstart / solid | @solidjs/start / solid-js dependency | Start yes; component library no |
| vitepress, docusaurus, gatsby | vitepress, @docusaurus/core, gatsby dependencies | Yes |
| adonis, strapi, elysia | @adonisjs/core, @strapi/strapi, elysia dependencies | Yes |
| fastify, koa, hapi | fastify, koa, @hapi/hapi or legacy hapi dependencies | Yes; distinct labels instead of Express |
| webpack, parcel | webpack-dev-server, parcel dependencies | webpack dev server yes; general Parcel dependency no |
| preact, socketio, ws | preact, socket.io, ws dependencies | No generic HTTP probe |
| nest | @nestjs/core or named HTTP adapter | Core alone no; @nestjs/platform-express or @nestjs/platform-fastify yes |
| remix | react-router, @remix-run/react or named server/dev adapter | Libraries alone no; @react-router/dev, @react-router/serve, @remix-run/serve yes |
| fastapi, uvicorn, flask, gunicorn | Respective command token | Yes; each retains its actual server/framework label |
| hypercorn, waitress, sanic, litestar, mkdocs | hypercorn, waitress-serve, sanic, litestar run, mkdocs serve command | Yes |
| rails, puma, rack, hanami | rails command or bin/rails marker; puma command; Gemfile+config.ru; hanami server | Rails/Puma/Hanami yes; generic Rack project no |
| phoenix, elixir | phx.server command; generic mix.exs marker | Phoenix yes; generic Elixir no |
| symfony | symfony server:start or symfony serve command | Yes; php-fpm exclusion still wins |
| javadev | java process plus pom.xml, build.gradle or build.gradle.kts | No inference of HTTP from generic JVM project |
| redis | valkey-server executable alongside existing Redis signals | No |

Specific server frameworks precede their component libraries. Express and Hono precede ws/React dependencies, so a helper library does not obscure the server. Uvicorn no longer claims FastAPI, Gunicorn no longer claims Flask, Puma and a generic Rack project no longer claim Rails, and mix.exs alone no longer claims Phoenix. These are intentional classification corrections.

The current scanner reads package.json once per discovered root, caps it at 256 KiB, and emits only allowlisted names from dependencies/devDependencies/peerDependencies. This expansion adds names to that existing pass. It does not execute project code or inspect secrets. Existing root caching remains intact. Marker additions are bin/rails and build.gradle.kts.

Dependency presence is project-level evidence, not proof of the protocol on each socket. In a project running several servers, conservative runtime/database exclusions and the separated TCP measurements remain necessary. An HTTP framework can also expose a non-HTTP secondary port; precise per-socket protocol discovery would need explicit configuration or passive traffic knowledge beyond this detector.

## Detection limits

Go Gin/Fiber/Echo, Rust Axum/Actix Web/Rocket, Java Spring Boot/Quarkus, .NET ASP.NET Core, PHP Composer frameworks and Ruby Gemfile frameworks have useful package evidence, but the scanner currently emits only those manifests' presence. A go.mod file does not prove Gin; Cargo.toml does not prove Axum; dotnet does not prove HTTP. Reading dependencies for these languages needs a separately bounded parser, rather than new rules that can never fire in production.

Verified candidates for such a parser include github.com/gin-gonic/gin, the axum/actix-web/rocket Rust crates, Spring's web starter artifacts, and Microsoft.NET.Sdk.Web. Parse exact structured package identifiers and retain protocol uncertainty for generic runtime libraries. Never run go list, Cargo, Gradle, Bundler or project scripts merely to decorate the port list.

## Primary sources checked

- [hapi package name](https://hapi.dev/tutorials/en_us/getting-started), [Fastify](https://fastify.dev/docs/v5.7.x/Guides/Getting-Started/), [Koa](https://koajs.com/), [Elysia](https://elysiajs.com/quick-start), [Adonis core](https://docs.adonisjs.com/configuration), [Strapi](https://docs.strapi.io/).
- [VitePress](https://vitepress.dev/guide/getting-started), [Docusaurus package](https://docusaurus.io/docs/installation), [Gatsby CLI](https://www.gatsbyjs.com/docs/reference/gatsby-cli/), [webpack dev server](https://webpack.js.org/configuration/dev-server/), [Parcel](https://parceljs.org/features/development/).
- [React Router framework and adapters](https://reactrouter.com/start/framework/installation), [Nest microservices and TCP support](https://docs.nestjs.com/microservices/basics), [Socket.IO server](https://socket.io/docs/v4/server-installation/), [ws client/server library](https://github.com/websockets/ws).
- [FastAPI CLI](https://fastapi.tiangolo.com/fastapi-cli/), [Uvicorn ASGI separation](https://www.uvicorn.org/concepts/asgi/), [Gunicorn](https://gunicorn.org/), [Hypercorn usage](https://hypercorn.readthedocs.io/en/latest/tutorials/usage.html), [Waitress runner](https://docs.pylonsproject.org/projects/waitress/en/stable/runner.html), [Sanic server](https://sanic.dev/en/guide/running/running.md), [Litestar CLI](https://docs.litestar.dev/main/usage/cli.html), [MkDocs serve](https://www.mkdocs.org/user-guide/cli/).
- [Puma is a Rack HTTP server](https://puma.io/), [Hanami server](https://docs.hanamirb.org/1.3.3/), [Phoenix command](https://phoenix.hexdocs.pm/up_and_running.html), [Symfony server](https://symfony.com/doc/current/setup.html).
- [Gin module](https://github.com/gin-gonic/gin), [Axum crate](https://docs.rs/axum/latest/axum/), [Actix Web](https://actix.rs/docs/getting-started/), [Rocket crate](https://docs.rs/rocket/latest/rocket/), [Spring web starters](https://docs.spring.io/spring-boot/reference/web/index.html), [Quarkus tooling](https://quarkus.io/guides/maven-tooling/), [.NET Web SDK](https://learn.microsoft.com/en-us/dotnet/core/project-sdk/overview).

Focused verification covers new dependency/command mappings, precedence, conservative runtime/library behavior, database exclusions, and the scanner allowlist contract. The existing probe-list fixture now supplies httpProbe explicitly and proves watching a non-HTTP service does not schedule HTTP. No production project dependencies were installed or executed for classification.
