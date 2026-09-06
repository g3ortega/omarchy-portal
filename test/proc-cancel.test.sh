#!/usr/bin/env bash
set -euo pipefail
python3 -I -S "$(dirname -- "${BASH_SOURCE[0]}")/proc-cancel.test.py"
