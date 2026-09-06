#!/bin/bash
set -euo pipefail
/usr/bin/python3 -I -S "$(dirname -- "${BASH_SOURCE[0]}")/portless-rollback-signal.test.py"
