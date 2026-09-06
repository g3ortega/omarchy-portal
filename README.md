# Portal

[![CI](https://github.com/g3ortega/omarchy-portal/actions/workflows/ci.yml/badge.svg)](https://github.com/g3ortega/omarchy-portal/actions/workflows/ci.yml)

An [Omarchy](https://omarchy.org) bar plugin for listening TCP ports.
See what runs on each port, then open, name, share, or manage its process.
Setup and preferences live in Settings so the homepage stays focused on your services.

<p align="center">
  <img src="preview.png" width="800" alt="Portal's port list and charts page">
</p>

```sh
omarchy plugin add https://github.com/g3ortega/omarchy-portal.git --enable
omarchy bar move g3ortega.portal --section right
```

Bind it to a key (pick one that's free in `omarchy menu keybindings --print`):

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + ALT + P", "Portal", "omarchy-shell g3ortega.portal toggle")
```

Remove with `scripts/portal uninstall` first (it disables the plugin, stops
every share and name Portal created, drops the Portless CA from the browser
stores Portal added it to, deletes cloudflared if it is still Portal's copy,
and removes Portal's state), then `omarchy plugin remove g3ortega.portal`.

Portal probes inferred HTTP services on `localhost` and calls the local Portless proxy
and ngrok agent. It checks new tunnel hostnames through `1.1.1.1` or
`dns.google` over HTTPS. A confirmed Cloudflared install downloads the pinned
release from GitHub. Cloudflared and ngrok connect to their own services.

## What it does

- Finds every listening TCP port with a couple of `ss` calls and names the
  stack behind it, with over 80 detection rules for frameworks, runtimes,
  and services such as Next.js, Vite, Rails, Django, Phoenix, Go, Postgres, and Redis.
- Identifies published Docker services through local Docker sockets, including
  LiteLLM. Container-only ports stay out of the host list.
- Gives a port a local name like `https://acme-web.localhost:1355` through
  [Portless](https://github.com/vercel-labs/portless). New proxies serve this machine
  only. Existing LAN routes are labeled "LAN name".
- Shares a port publicly through Cloudflare or ngrok, and paints anything
  public in your theme's urgent color so you can't forget it's open.
- Charts HTTP latency or TCP RTT, connections, CPU and memory per port. Open the last
  hour or select 30m, 1h, 3h, 6h, 1d, or 2d.
- Pauses, resumes, restarts, and stops a process you own. Pause, restart, and
  stop ask for confirmation. Stop allows a short grace period for shutdown.
- Keeps confirmations over the current page and errors below the header.
- Works entirely from the keyboard. Press `?` in the panel.

The bar counts public shares when any are open, otherwise named routes, otherwise
dev servers. A zero count hides the number. The Portal icon stays the same; its color
indicates exposure. The tooltip lists all active categories.

Portless, Cloudflared, and ngrok are optional. Listing, process actions, and
charts work without them. Naming and sharing actions appear when their tools
are available. Install and configure providers in Settings (`,`), alongside
browser trust and preferences. Owned names remain removable when Portless is
installed but needs setup. Active public shares remain stoppable if their
provider binary disappears.

Local names use an unprivileged proxy on port 1355 by default. Existing proxies
on port 443 keep their URLs without a port number. Cloudflare sharing does not
flush system DNS caches or request administrator authentication.

Enable **Watch** to save samples in local SQLite history with a 48-hour recording
window. Stopping Watch pauses recording and preserves saved history. Changing
the chart range never deletes samples. Plots retain minimum and maximum values
to keep short CPU spikes visible. The footer reports available coverage and storage errors.
See [chart behavior and controls](docs/guide.md#charts).

Charts default to HTTP latency for recognized web services and TCP RTT for other
listeners. On HTTP services, select **TCP** or press `t` to inspect transport
timing. TCP RTT uses the kernel's estimate from existing connections and sends
no probe traffic. The value is the mean across sockets with an estimate and can
stay unchanged while idle. A listener without connections has no TCP RTT.
This includes the TCP transport beneath WebSockets, but does not measure
WebSocket message handling or database query time. HTTP eligibility is inferred
from framework evidence and known service ports. A runtime name or common web
port alone does not enable HTTP requests.

Listing and sharing are also a CLI (`scripts/portal`) and an IPC target
(`omarchy-shell g3ortega.portal`).

Details, screenshots, settings, CLI, security notes and how to hack on it:
[docs/guide.md](docs/guide.md).

MIT. See [LICENSE](LICENSE).
