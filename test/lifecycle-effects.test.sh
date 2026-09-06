#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/test/lifecycle-owner.test.sh" >/dev/null
/usr/bin/python3 -I -S "$ROOT/test/lifecycle-effects.test.py"
