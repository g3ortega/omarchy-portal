import assert from "node:assert/strict"
import { chmodSync, copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spawnSync } from "node:child_process"

const dir = mkdtempSync(join(tmpdir(), "portal-cli-"))
try {
  const cli = join(dir, "portal")
  copyFileSync(new URL("../scripts/portal", import.meta.url), cli)
  const helper = join(dir, "portless-setup.sh")
  const calls = join(dir, "calls")
  writeFileSync(helper, '#!/bin/bash\nprintf "%s\\n" "$*" >> "$PORTAL_CLI_TEST_CALLS"\nprintf \'{"ok":true,"remaining":[]}\\n\'\n')
  chmodSync(helper, 0o700)
  const run = (...args) => spawnSync("bash", [cli, "setup", ...args], {
    encoding: "utf8", env: { ...process.env, PORTAL_CLI_TEST_CALLS: calls }
  })
  const status = run("--status")
  assert.equal(status.status, 0, status.stderr)
  assert.equal(JSON.parse(status.stdout).ok, true)
  assert.equal(readFileSync(calls, "utf8"), "status\n")
  const setup = run()
  assert.equal(setup.status, 0, setup.stderr)
  assert.equal(readFileSync(calls, "utf8"), "status\nrun\n")
  const invalid = run("--unknown")
  assert.equal(invalid.status, 2)
  assert.match(invalid.stderr, /usage/)
  assert.equal(readFileSync(calls, "utf8"), "status\nrun\n")
  console.log("CLI setup status is read-only; setup and invalid arguments dispatch correctly")
} finally {
  rmSync(dir, { recursive: true, force: true })
}
