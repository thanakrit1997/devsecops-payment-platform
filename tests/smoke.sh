#!/usr/bin/env bash
# Usage: tests/smoke.sh [base-url]   e.g. after `kubectl port-forward svc/payment-api 8080:80`
set -euo pipefail
BASE_URL="${1:-http://localhost:8080}"
get() { curl --fail --silent --show-error --max-time 5 "$BASE_URL$1"; }
get /health | grep -q '"status":"ok"'    || { echo "health: unexpected body" >&2; exit 1; }
get /ready  | grep -q '"status":"ready"' || { echo "ready: unexpected body" >&2; exit 1; }
echo "smoke test passed"
