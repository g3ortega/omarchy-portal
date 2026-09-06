#!/bin/bash
set -euo pipefail
/usr/bin/python3 -I -S "$(dirname -- "${BASH_SOURCE[0]}")/shared-metrics.test.py"
