# Changelog

## 1.0.0 — 2026-09-01

First release.

- Lists every listening TCP port from two `ss` calls per scan, grouped into your apps, services and system ports, and names the stack behind nearly 50 of them from the process, its project markers and an allowlisted read of `package.json`.
- Local names through Portless: one key gives a port `https://name.localhost`; the name becomes the row's title, what opens and what copies. Any TLD; the one-time resolver rule and the 443 proxy start are handed over as commands, never run with sudo. Setup says what it will install and trust before it does.
- Public sharing through Cloudflare quick tunnels or ngrok, painted in the theme's urgent color on the row, in the header and on the bar. Installing cloudflared asks first and names the pinned release. A fresh hostname is held until its DNS record is live, checked through a resolver outside the system's path. Tunnels and names created outside Portal are adopted. A tunnel whose server died keeps a row to stop it from.
- Charts per port: latency, connections, CPU and memory, an hour in memory and a day on disk for watched ports, with a shared crosshair and axes that only draw an area from a true zero.
- Pause, resume, restart and stop a dev server. Restart re-runs the exact argv with the process's own environment and PATH. Stop, pause and restart ask first, inline. Every signal re-checks the pid still owns the port.
- Everything from the keyboard: vim-style cursor, one key per verb, a filter that starts on any letter, inline confirmations, an in-panel cheatsheet, and `omarchy-shell g3ortega.portal toggle` for a Hyprland bind.
- Settings in the panel, driven by the manifest schema and persisted through the shell's own API.
- A CLI (`scripts/portal`) and an IPC surface for listing, sharing and the setup engine.
- Security: every untrusted string rendered as plain text, argv-only subprocesses, validated URLs and TLDs before anything reaches a row or a pasted command, a checksum-pinned and byte-capped cloudflared installer, owner-only state files that are never followed through a link, pidfiles bound to the process start time, a hard deadline on every helper, capped logs and API bodies, a CA import that must verify the live proxy's certificate, and no sudo. CI is pinned to exact commits and a checksummed font asset.
- Tests: 58 node checks including rules extracted from the QML source, 44 shell checks over the libraries and validators, and a live farm of a dozen-plus stacks in CI.
