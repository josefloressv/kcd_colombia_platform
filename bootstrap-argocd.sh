#!/usr/bin/env bash
set -euo pipefail

# Bootstrap Argo CD in a self-managed (GitOps) fashion WITHOUT leaving a Helm release.
# Safe to run multiple times (idempotent):
# 1. Ensures namespace exists
# 2. Installs/updates Argo CD using the upstream install.yaml (one-shot)
# 3. Applies root Application (App of Apps)
#
# Simplificado: se removió el flujo de auto-gestión "argocd-self" para ahorrar tiempo en la demo.
# Argo CD queda instalado vía manifest upstream + root App (que gestiona sólo add-ons, no Argo CD).
# Si deseas gestionar Argo CD vía Git más adelante, reintroduce un Application para el chart argo-cd.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_APP="${ROOT_DIR}/clusters/prod/root-app.yaml"

echo "[1/4] Ensuring namespace argocd exists"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "[2/4] Applying upstream Argo CD install manifest (controller + CRDs)"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.4.0 \
  --set server.service.type=ClusterIP \

echo "[3/4] Waiting for core Argo CD components to become Available"

wait_deploy() {
  local name="$1"; shift
  if kubectl -n argocd get deploy "$name" >/dev/null 2>&1; then
    echo "  - Waiting for Deployment/$name"
    kubectl -n argocd rollout status deploy/"$name" --timeout=180s || return 1
    return 0
  fi
  return 2
}

wait_statefulset() {
  local name="$1"; shift
  if kubectl -n argocd get statefulset "$name" >/dev/null 2>&1; then
    echo "  - Waiting for StatefulSet/$name"
    # Wait until readyReplicas == replicas
    for i in {1..36}; do
      ready=$(kubectl -n argocd get statefulset "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      desired=$(kubectl -n argocd get statefulset "$name" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "1")
      echo "    ready=$ready desired=$desired (attempt $i)"
      [[ "$ready" == "$desired" && -n "$ready" ]] && return 0
      sleep 5
    done
    echo "StatefulSet/$name failed to become ready in time" >&2
    return 1
  fi
  return 2
}

# Components to wait for (some may be Deployment or StatefulSet depending on version)
CORE_COMPONENTS=(argocd-repo-server argocd-application-controller argocd-server)
for comp in "${CORE_COMPONENTS[@]}"; do
  if ! wait_deploy "$comp"; then
    if ! wait_statefulset "$comp"; then
      echo "ERROR: Component $comp not found as Deployment or StatefulSet or failed to become ready" >&2
      exit 1
    fi
  fi
done

echo "[4/4] Applying root App-of-Apps (${CLUSTER_APP})"
kubectl apply -f "${CLUSTER_APP}"

echo "Done. Current Applications:"
kubectl -n argocd get applications.argoproj.io || true

echo "TIP: Retrieve initial admin password (only if not overwritten yet):"
echo "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
