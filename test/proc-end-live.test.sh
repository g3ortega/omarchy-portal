#!/bin/bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Never enter the live test unless the signal-safety mocks pass first.
PORTAL_TEST_ONLY=proc-end bash "$HERE/scripts.test.sh"
exec /usr/bin/python3 -I -S "$HERE/proc-end-live.test.py"
