import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const fixture = mkdtempSync(join(tmpdir(), 'portal-decorate-'))
const scanner = join(fixture, 'scan')
const cli = fileURLToPath(new URL('../scripts/lib/qmljs.mjs', import.meta.url))
writeFileSync(scanner, '#!/bin/sh\nexec /usr/bin/cat "$0.json"\n', { mode: 0o700 })
function run(payload) {
  writeFileSync(scanner + '.json', JSON.stringify(payload))
  return spawnSync(process.execPath, [cli, 'decorate', scanner], {
    encoding: 'utf8', maxBuffer: 128 * 1024 * 1024, timeout: 30000
  })
}
try {
  for (const argument of ['x'.repeat(8180), '\u0001'.repeat(8180)]) {
    const ports = Array.from({ length: 512 }, (_, index) => ({
      port: 40000 + index, comm: 'node', argv: ['node', argument],
      cmdline: 'node ' + argument, addresses: ['127.0.0.1'], scope: 'local',
      markers: [], deps: [], cwd: '', projectRoot: '', projectName: '', exclusiveOwner: true
    }))
    const payload = { version: 1, ports }
    assert(Buffer.byteLength(JSON.stringify(payload)) > 1024 * 1024)
    const result = run(payload)
    assert.equal(result.status, 0, result.stderr.slice(0, 1000))
    const decorated = JSON.parse(result.stdout)
    assert.equal(decorated.length, 512)
    assert.equal(decorated[511].port, 40511)
    assert.equal(decorated[511].argv[1], argument)
  }
  const error = run({ error: 'could not inspect listening sockets' })
  assert.equal(error.status, 1)
  assert.equal(error.stdout, '')
  assert.equal(error.stderr, 'portal: could not inspect listening sockets\n')
  console.log('PASS offline decoration accepts 512 near-cap argv rows, escaped bytes, and scanner errors')
} finally {
  rmSync(fixture, { recursive: true, force: true })
}
