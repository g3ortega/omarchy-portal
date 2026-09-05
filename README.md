# Portal

[![CI](https://github.com/g3ortega/omarchy-portal/actions/workflows/ci.yml/badge.svg)](https://github.com/g3ortega/omarchy-portal/actions/workflows/ci.yml)

Every listening port on your machine, what's running on it, and one key to
open, name, share, pause, restart or stop it. An [Omarchy](https://omarchy.org)
bar plugin.

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
  stack behind it (over 80: Next, Vite, Rails, Django, Phoenix, Go,
  Postgres, Redis, ...).
- Gives a port a local name like `https://acme-web.localhost:1355` through
  [Portless](https://github.com/vercel-labs/portless). New proxies serve this machine
  only. Existing LAN routes are labeled "LAN name".
- Shares a port publicly through Cloudflare or ngrok, and paints anything
  public in your theme's urgent color so you can't forget it's open.
- Charts HTTP latency or TCP RTT, connections, CPU and memory per port. Open the last
  hour, switch to 30 minutes, or inspect up to 48 hours of watched history.
- Pauses, resumes, restarts and stops a dev server. The loud ones ask first.
- Works entirely from the keyboard. Press `?` in the panel.

The bar counts public shares when any are open, otherwise named routes, otherwise
dev servers. A zero count hides the number. The Portal icon stays the same; its color
indicates exposure. The tooltip lists all active categories.

Provider setup, browser trust, and preferences live in Settings (`,`).
Local names use an unprivileged proxy on port 1355 by default. Existing proxies
on port 443 keep their URLs without a port number. Cloudflare sharing does not
flush system DNS caches or request administrator authentication.

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
