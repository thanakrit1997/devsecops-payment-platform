#!/usr/bin/env bash
# Offline checks: ./scripts/validate.sh [terraform|manifests]   (default: both)
# Fails (instead of silently skipping) when a required tool is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
what="${1:-all}"

if [[ $what == all || $what == terraform ]]; then
  need terraform
  terraform -chdir=terraform fmt -check
  terraform -chdir=terraform init -backend=false -input=false >/dev/null
  terraform -chdir=terraform validate
fi

if [[ $what == all || $what == manifests ]]; then
  need kubectl # provides `kubectl kustomize`
  for env in dev staging production; do
    echo "render $env"
    kubectl kustomize "gitops/overlays/$env" >/dev/null
  done
  kubectl kustomize argocd >/dev/null

  # Production requirements (docs/EXERCISE.md, Module 5).
  prod=$(kubectl kustomize gitops/overlays/production)
  fail() { echo "FAIL production: $1" >&2; exit 1; }
  grep -q  'namespace: payment-production'       <<<"$prod" || fail "namespace must be payment-production"
  grep -q  'minReplicas: 5'                      <<<"$prod" || fail "HPA floor must be 5 replicas"
  grep -q  'cpu: 500m'                           <<<"$prod" || fail "cpu request must be 500m"
  grep -q  'memory: 512Mi'                       <<<"$prod" || fail "memory request must be 512Mi"
  grep -Eq 'image: [^ ]+@sha256:[0-9a-f]{64}$'   <<<"$prod" || fail "image must be pinned by digest"
  grep -Eq 'privileged: true|:latest|replicas: ' <<<"$prod" && fail "privileged container, :latest tag, or Deployment replicas (HPA owns it)"
  grep -Eq 'supersecret|plaintext-secret'        <<<"$prod" && fail "credential literal rendered"
fi
echo "all checks passed"
