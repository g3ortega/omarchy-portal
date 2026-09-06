#!/bin/bash
set -euo pipefail
python3 "$(dirname -- "${BASH_SOURCE[0]}")/docker-scan.test.py"
