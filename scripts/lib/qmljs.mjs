// Load a QML `.pragma library` JS file under plain node.
//
// The single home for the strip-pragma + Function-eval dance: node cannot
// parse the `.pragma library` directive, so it is removed before evaluation
// and the file's node-only `module.exports` shim provides the exports.
// Used by the tests and by scripts/portal (via the CLI modes below).

import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const libDir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "lib")

export function loadQmlJs(path) {
  const source = readFileSync(path, "utf8").replace(/^\s*\.pragma\s+library\s*$/m, "")
  const mod = { exports: {} }
  new Function("module", "exports", source)(mod, mod.exports)
  return mod.exports
}

export const detectPath = join(libDir, "Detect.js")
export const iconsPath = join(libDir, "Icons.js")
export const formatPath = join(libDir, "Format.js")
export const colorsPath = join(libDir, "Colors.js")

// CLI modes for the bash side of scripts/portal:
//   node qmljs.mjs icons                  -> { name: glyph } map as JSON
//   node qmljs.mjs decorate <scan-script> -> run the scan, print decorated ports
const mode = process.argv[2]
if (mode === "icons") {
  const { CP, g } = loadQmlJs(iconsPath)
  const out = {}
  for (const name of Object.keys(CP)) out[name] = g(name)
  console.log(JSON.stringify(out))
} else if (mode === "decorate") {
  const { decorate } = loadQmlJs(detectPath)
  const scan = JSON.parse(execFileSync(process.argv[3]).toString())
  console.log(JSON.stringify(scan.ports.map(decorate)))
}
