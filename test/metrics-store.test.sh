#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
/usr/bin/python3 -I -S "$ROOT/test/metrics-store.test.py"
