#!/usr/bin/env bash
set -euo pipefail

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=terraform fmt -check
fi

for env in dev staging production; do
  if command -v kustomize >/dev/null 2>&1; then
    echo "Rendering $env"
    kustomize build "gitops/overlays/$env" >/dev/null
  elif command -v kubectl >/dev/null 2>&1; then
    echo "Rendering $env with kubectl kustomize"
    kubectl kustomize "gitops/overlays/$env" >/dev/null
  fi
done
