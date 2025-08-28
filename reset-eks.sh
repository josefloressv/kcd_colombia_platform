#!/usr/bin/env bash
set -Eeuo pipefail

# ============================
# Reset EKS: ArgoCD + Add-ons
# ============================
# Usage:
#   DRY_RUN=true  ./reset-eks.sh   # (default) only shows actions
#   DRY_RUN=false ./reset-eks.sh   # executes real deletions
#
# Optional variables:
#   GRACEFUL_PRUNE=true|false  # try to let ArgoCD prune resources by deleting Applications (default true)
#   WAIT_SECONDS=60            # wait time between phases (default 60)
#   FORCE_TERMINATE=true|false # force termination of stuck namespaces/pods (default true)
#   FORCE_ORPHAN_CLEANUP=true|false # cleanup orphan pods with missing namespaces (default true)
#   NAMESPACE_TERMINATION_TIMEOUT=180 # max seconds waiting for namespace final termination
#   NAMESPACE_TERMINATION_CHECK_INTERVAL=5 # polling interval seconds
#
# Requirements: kubectl, jq, helm
# ============================

DRY_RUN="${DRY_RUN:-true}"
GRACEFUL_PRUNE="${GRACEFUL_PRUNE:-true}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
FORCE_TERMINATE="${FORCE_TERMINATE:-true}" # fuerza eliminación si queda namespace/pods en Terminating
FORCE_ORPHAN_CLEANUP="${FORCE_ORPHAN_CLEANUP:-true}" # limpia pods huérfanos cuyo namespace ya no existe

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required binary '$1' not found in PATH"; exit 1; }; }
need kubectl
need jq
need helm

say() { echo -e "👉 $*"; }
run() { if [[ "${DRY_RUN}" == "true" ]]; then echo "DRY_RUN: $*"; else eval "$*"; fi; }

# Sanea strings (quita \r, \n y espacios al borde)
trim() { printf "%s" "$1" | tr -d '\r\n' | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'; }

say "Current kubectl context: $(kubectl config current-context)"
say "Cluster info (summary):"; kubectl cluster-info | sed 's/^/   /' || true
[[ "${DRY_RUN}" == "true" ]] && say "DRY_RUN enabled: nothing will actually be deleted."

patch_clear_finalizers() {
  local kind="$1"
  say "Removing finalizers for $kind (if any)..."
  if kubectl get "$kind" -A -o json >/dev/null 2>&1; then
    kubectl get "$kind" -A -o json \
      | jq -r '.items[] | [.metadata.namespace // "default", .metadata.name] | @tsv' \
      | while IFS=$'\t' read -r ns_name res_name; do
          ns_name="$(trim "${ns_name:-}")"; res_name="$(trim "${res_name:-}")"
          [[ -z "${ns_name}" || -z "${res_name}" ]] && continue
          run "kubectl patch $kind -n \"$ns_name\" \"$res_name\" --type=merge -p '{\"metadata\":{\"finalizers\":[]}}' || true"
        done
  fi
}

delete_all_of_kind() {
  local kind="$1"
  # Note: use ASCII '...' instead of Unicode ellipsis to avoid parsing issues
  say "Deleting all resources of kind $kind..."
  run "kubectl get $kind -A -o name 2>/dev/null | xargs -r kubectl delete --wait=false || true"
}

delete_crd_if_exists() {
  local crd="$1"
  if kubectl get crd "$crd" >/dev/null 2>&1; then
  say "Deleting CRD $crd..."
    run "kubectl delete crd $crd --wait=false || true"
  fi
}

detect_argocd_namespaces() {
  # Return unique ArgoCD-related namespaces (one per line)
  {
    kubectl get deploy -A -l app.kubernetes.io/part-of=argocd -o json 2>/dev/null \
      | jq -r '.items[].metadata.namespace' 2>/dev/null || true
    kubectl get statefulset -A -o json 2>/dev/null \
      | jq -r '.items[] | select(.metadata.name|test("^argocd-application-controller$")) | .metadata.namespace' 2>/dev/null || true
    kubectl get svc -A -o json 2>/dev/null \
      | jq -r '.items[] | select(.metadata.name|test("^argocd-(metrics|notifications-controller-metrics|server-metrics)$")) | .metadata.namespace' 2>/dev/null || true
    if kubectl get ns argocd >/dev/null 2>&1; then echo argocd; fi
  } | awk 'NF{print}' | sort -u
}

NAMESPACE_TERMINATION_TIMEOUT="${NAMESPACE_TERMINATION_TIMEOUT:-180}"
NAMESPACE_TERMINATION_CHECK_INTERVAL="${NAMESPACE_TERMINATION_CHECK_INTERVAL:-5}"

wait_for_namespace_termination() {
  local ns="$1"
  [[ -z "$ns" ]] && return 0
  local waited=0
  say "Esperando a que el namespace $ns termine (timeout ${NAMESPACE_TERMINATION_TIMEOUT}s)..."
  while true; do
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      # Puede que siga habiendo pods 'fantasma' accesibles; intentamos borrarlos si listan
      local ghost_pods
      ghost_pods="$(kubectl get pod -n "$ns" -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null || true)"
      if [[ -n "$ghost_pods" ]]; then
        say "Namespace $ns ya no está listado pero quedan pods fantasma: $ghost_pods -> forzando eliminación"
        while IFS= read -r gp; do
          [[ -z "$gp" ]] && continue
          run "kubectl -n $ns patch pod $gp --type=merge -p '{\"metadata\":{\"finalizers\":[]}}' 2>/dev/null || true"
          run "kubectl -n $ns delete pod $gp --grace-period=0 --force --ignore-not-found || true"
        done <<< "$ghost_pods"
      fi
      break
    fi
    # Si sigue existiendo, revisar pods terminating y limpiar finalizers
    local term_pods
    term_pods="$(kubectl get pod -n "$ns" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.deletionTimestamp or (.status.phase=="Terminating")) | .metadata.name' 2>/dev/null || true)"
    if [[ -n "$term_pods" ]]; then
      say "Pods aún en Terminando en $ns: $term_pods (limpiando finalizers)"
      while IFS= read -r tp; do
        [[ -z "$tp" ]] && continue
        run "kubectl -n $ns patch pod $tp --type=merge -p '{\"metadata\":{\"finalizers\":[]}}' 2>/dev/null || true"
        run "kubectl -n $ns delete pod $tp --grace-period=0 --force --ignore-not-found || true"
      done <<< "$term_pods"
    fi
    # Forzar finalización nuevamente por si hay finalizers a nivel de namespace
    if kubectl get ns "$ns" -o json >/dev/null 2>&1; then
      run "kubectl get ns $ns -o json | jq '.spec.finalizers=[]' | kubectl replace --raw /api/v1/namespaces/$ns/finalize -f - 2>/dev/null || true"
    fi
    (( waited += NAMESPACE_TERMINATION_CHECK_INTERVAL ))
    if (( waited >= NAMESPACE_TERMINATION_TIMEOUT )); then
      say "Timeout esperando al namespace $ns. Continuando..."
      break
    fi
    sleep "$NAMESPACE_TERMINATION_CHECK_INTERVAL"
  done
}

# Force delete ArgoCD controllers (deployments/statefulsets) to avoid recreation
force_delete_argocd_controllers() {
  local ns="$1"
  [[ -z "$ns" ]] && return 0
  # Scale to 0 (ignore errors) then delete known controllers
  for ctrl in \
    statefulset/argocd-application-controller \
    deployment/argocd-applicationset-controller \
    deployment/argocd-dex-server \
    deployment/argocd-notifications-controller \
    deployment/argocd-repo-server \
  deployment/argocd-server \
  deployment/argocd-redis \
  statefulset/argocd-redis; do
      run "kubectl -n $ns scale ${ctrl%%/*}/${ctrl#*/} --replicas=0 2>/dev/null || true"
      run "kubectl -n $ns delete $ctrl --ignore-not-found --wait=false || true"
  done
  # Remaining ReplicaSets (by label)
  run "kubectl -n $ns delete rs -l app.kubernetes.io/name=argocd-application-controller --ignore-not-found --wait=false || true"
}

# Remove finalizers and force delete argocd-* pods in a namespace
force_delete_argocd_pods() {
  local ns="$1"
  [[ -z "$ns" ]] && return 0
  local pods
  pods="$(kubectl -n "$ns" get pods -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name|test("^argocd-(application-controller|applicationset-controller|dex-server|notifications-controller|repo-server|server)-")) | .metadata.name' || true)"
  [[ -z "$pods" ]] && return 0
  say "Forcing deletion of residual ArgoCD pods in $ns: $pods"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    run "kubectl -n $ns patch pod $p --type=merge -p '{\"metadata\":{\"finalizers\":null}}' 2>/dev/null || true"
    run "kubectl -n $ns delete pod $p --grace-period=0 --force --ignore-not-found || true"
  done <<< "$pods"
}

# Fallback: force removal of any remaining ArgoCD resources
force_delete_argocd_leftovers() {
  local ns_list=()
  while IFS= read -r _ns; do
    [[ -z "$_ns" ]] && continue
    ns_list+=("$_ns")
  done < <({
      kubectl get pods -A -l app.kubernetes.io/part-of=argocd -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null;
      kubectl get statefulset -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name|test("argocd-application-controller")) | .metadata.namespace';
      kubectl get svc -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name|test("argocd-(metrics|notifications-controller-metrics|server-metrics)")) | .metadata.namespace';
      kubectl get ns argocd -o jsonpath='{.metadata.name}' 2>/dev/null;
    } | tr ' ' '\n' | sort -u | grep -v '^$' || true)
  [[ ${#ns_list[@]} -eq 0 ]] && return 0
  say "Forcing residual ArgoCD cleanup (persistent resources) in namespaces: ${ns_list[*]}"
  for n in "${ns_list[@]}"; do
    for kind in statefulset deployment; do
      for obj in $(kubectl -n "$n" get "$kind" -l app.kubernetes.io/part-of=argocd -o name 2>/dev/null || true); do
        run "kubectl -n $n scale $obj --replicas=0 || true"
      done
    done
    run "kubectl -n $n delete statefulset,deploy,svc,cm,secret,sa,role,rolebinding,pdb,networkpolicy -l app.kubernetes.io/part-of=argocd --ignore-not-found --wait=false || true"
    for obj in statefulset/argocd-application-controller \
               svc/argocd-metrics \
               svc/argocd-notifications-controller-metrics \
               svc/argocd-server-metrics; do
      run "kubectl -n $n delete $obj --ignore-not-found --wait=false || true"
    done
    for pvc in $(kubectl -n "$n" get pvc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n'); do
      run "kubectl -n $n delete pvc $pvc --ignore-not-found --wait=false || true"
    done
  done
}

force_finalize_namespace() {
  local target_ns="$1"
  [[ -z "$target_ns" ]] && return 0
  [[ "${FORCE_TERMINATE}" != "true" ]] && return 0
  kubectl get ns "$target_ns" >/dev/null 2>&1 || return 0
  say "Checking if namespace $target_ns is stuck (pods Terminating)..."
  local terminating_pods
  terminating_pods="$(kubectl get pods -n "$target_ns" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.deletionTimestamp or (.status.phase=="Terminating")) | .metadata.name' || true)"
  if [[ -n "$terminating_pods" ]]; then
  say "Forcing deletion of stuck pods in $target_ns: $terminating_pods"
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      run "kubectl -n $target_ns patch pod $p --type=merge -p '{\"metadata\":{\"finalizers\":null}}' 2>/dev/null || true"
      run "kubectl -n $target_ns delete pod $p --grace-period=0 --force --ignore-not-found || true"
    done <<< "$terminating_pods"
  fi
  for kind in statefulset pod svc cm secret sa role rolebinding pvc; do
    for obj in $(kubectl -n "$target_ns" get "$kind" -o name 2>/dev/null || true); do
      run "kubectl -n $target_ns patch $obj --type=merge -p '{\"metadata\":{\"finalizers\":[]}}' 2>/dev/null || true"
    done
  done
  if kubectl get ns "$target_ns" -o json >/dev/null 2>&1; then
  say "Forcing namespace finalization for $target_ns (if still present)..."
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "DRY_RUN: kubectl get ns $target_ns -o json | jq '.spec.finalizers=[]' | kubectl replace --raw /api/v1/namespaces/$target_ns/finalize -f -"
    else
      kubectl get ns "$target_ns" -o json | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/$target_ns/finalize" -f - 2>/dev/null || true
    fi
  fi
}

# Cleanup orphan pods (namespace no longer exists) matching patterns
cleanup_orphan_argocd_pods() {
  [[ "${FORCE_ORPHAN_CLEANUP}" != "true" ]] && return 0
  # Obtener lista de namespaces actuales una sola vez
  local existing_ns
  existing_ns=" $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) "
  local pods_json
  pods_json="$(kubectl get pods -A -o json 2>/dev/null || echo '{}')"
  # Patrones configurables (se podría ampliar a otros controladores si es útil)
  local patterns="argocd-application-controller argocd-applicationset-controller argocd-dex-server argocd-notifications-controller argocd-repo-server argocd-server"
  # Iterar pods potencialmente problemáticos
  echo "$pods_json" | jq -r '.items[] | [.metadata.namespace,.metadata.name,.metadata.deletionTimestamp // ""] | @tsv' | while IFS=$'\t' read -r pns pname pdel; do
    [[ -z "$pname" || -z "$pns" ]] && continue
  if ! printf '%s\n' $existing_ns | tr ' ' '\n' | grep -qx "$pns"; then
      for pat in $patterns; do
        if [[ "$pname" == "$pat"* ]]; then
          say "Detected orphan pod $pname in non-existent namespace '$pns' (deletionTimestamp='${pdel}') -> forcing deletion"
          run "kubectl -n $pns patch pod $pname --type=merge -p '{\"metadata\":{\"finalizers\":[]}}' 2>/dev/null || true"
          run "kubectl -n $pns delete pod $pname --grace-period=0 --force --ignore-not-found || true"
        fi
      done
    fi
  done
}

# Cleanup specific ArgoCD related ConfigMaps considered orphan patterns
cleanup_orphan_argocd_configmaps() {
  [[ "${FORCE_ORPHAN_CLEANUP}" != "true" ]] && return 0
  local cm_patterns="argocd-redis-health-configmap kube-root-ca.crt"
  for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    for cm_name in $cm_patterns; do
      if kubectl get configmap "$cm_name" -n "$ns" >/dev/null 2>&1; then
        # Limit deletion to argocd related namespaces
        if [[ "$ns" == "argocd" || "$ns" == argocd-* ]]; then
          say "Cleaning ConfigMap $cm_name in namespace $ns (orphan pattern)"
          run "kubectl -n $ns delete configmap $cm_name --ignore-not-found --wait=false || true"
        fi
      fi
    done
  done
}

# Force delete specific ArgoCD ConfigMaps after controllers are taken down to prevent rapid recreation.
# Note: kube-root-ca.crt is auto-managed by Kubernetes and will reappear until the namespace itself is deleted.
delete_argocd_specific_configmaps() {
  local targets="argocd-redis-health-configmap kube-root-ca.crt"
  for ns in $(detect_argocd_namespaces 2>/dev/null); do
    for cm in $targets; do
      if kubectl get configmap "$cm" -n "$ns" >/dev/null 2>&1; then
        say "Deleting ArgoCD related ConfigMap $cm in namespace $ns"
        run "kubectl -n $ns delete configmap $cm --ignore-not-found --wait=false || true"
      fi
    done
  done
}

# Aggressively remove redis (workload) and its health configmap to avoid recreation loops
force_remove_redis_and_health_cm() {
  local ns_list
  ns_list="$(detect_argocd_namespaces 2>/dev/null || true)"
  [[ -z "$ns_list" ]] && return 0
  for ns in $ns_list; do
    # Delete redis workloads (both deployment and statefulset forms)
    run "kubectl -n $ns scale deployment/argocd-redis --replicas=0 2>/dev/null || true"
    run "kubectl -n $ns scale statefulset/argocd-redis --replicas=0 2>/dev/null || true"
    run "kubectl -n $ns delete deployment/argocd-redis statefulset/argocd-redis --ignore-not-found --wait=false || true"
    # Delete redis pods explicitly
    run "kubectl -n $ns delete pod -l app.kubernetes.io/name=argocd-redis --ignore-not-found --wait=false || true"
    # Retry delete health configmap up to 5 times (may be recreated quickly)
    for i in 1 2 3 4 5; do
      if kubectl get configmap argocd-redis-health-configmap -n "$ns" >/dev/null 2>&1; then
        say "Attempt $i: deleting argocd-redis-health-configmap in namespace $ns"
        run "kubectl -n $ns delete configmap argocd-redis-health-configmap --ignore-not-found --wait=false || true"
        sleep 1
      else
        break
      fi
    done
  done
}

# Force delete argocd-* pods that remain Terminating in any existing namespace
force_delete_terminating_argocd_pods() {
  local pods
  pods="$(kubectl get pods -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name|test("^argocd-(application-controller|applicationset-controller|dex-server|notifications-controller|repo-server|server)-")) | select(.metadata.deletionTimestamp) | [.metadata.namespace,.metadata.name] | @tsv' || true)"
  [[ -z "$pods" ]] && return 0
  say "Force deleting (grace-period=0 --force) ArgoCD pods still in Terminating state..."
  while IFS=$'\t' read -r ns p; do
    [[ -z "$ns" || -z "$p" ]] && continue
    run "kubectl -n $ns patch pod $p --type=merge -p '{\"metadata\":{\"finalizers\":[]}}' 2>/dev/null || true"
    run "kubectl -n $ns delete pod $p --grace-period=0 --force --ignore-not-found || true"
  done <<< "$pods"
}

# ==============
# Fase 1: ArgoCD
# ==============
say "Phase 1/4: cleanup ArgoCD Applications, ApplicationSets and AppProjects"

if [[ "${GRACEFUL_PRUNE}" == "true" ]]; then
  say "Attempt GRACEFUL_PRUNE: delete Applications so ArgoCD prunes managed resources..."
  # Construye array saneado
  ARGO_NS=()
  while IFS= read -r line; do
    line="$(trim "${line:-}")"
    [[ -z "$line" ]] && continue
    ARGO_NS+=("$line")
  done < <(detect_argocd_namespaces)

  if [[ ${#ARGO_NS[@]} -eq 0 ]]; then
  say "No ArgoCD namespace detected, skipping GRACEFUL_PRUNE."
  else
    for ns_name in "${ARGO_NS[@]}"; do
      ns_name="$(trim "${ns_name}")"
  say "Detected ArgoCD namespace: ${ns_name}"
      if kubectl get applications.argoproj.io -n "${ns_name}" >/dev/null 2>&1; then
        kubectl get applications.argoproj.io -n "${ns_name}" -o name \
          | while read -r app; do
              app="$(trim "${app:-}")"
              [[ -z "$app" ]] && continue
              say "Marking for prune and deleting $app in ${ns_name}..."
              run "kubectl patch \"$app\" -n \"${ns_name}\" --type=json -p='[{\"op\":\"add\",\"path\":\"/metadata/finalizers\",\"value\":[\"resources-finalizer.argocd.argoproj.io\"]}]' 2>/dev/null || true"
              run "kubectl delete \"$app\" -n \"${ns_name}\" --wait=false || true"
            done
      fi
    done
  say "Waiting ${WAIT_SECONDS}s to allow prune..."
    if [[ "${GRACEFUL_PRUNE}" == "true" && "${DRY_RUN}" != "true" && "${WAIT_SECONDS}" -gt 0 ]]; then
      sleep "${WAIT_SECONDS}"
    fi
  fi
fi

# List of ArgoCD CRDs (removed at the end after pods/ns)
ARGO_KINDS=(
  "applications.argoproj.io"
  "applicationsets.argoproj.io"
  "appprojects.argoproj.io"
)
for kind in "${ARGO_KINDS[@]}"; do
  # Defensa extra: si por alguna razón la variable está vacía, continuar
  [[ -z "${kind:-}" ]] && continue
  patch_clear_finalizers "$kind"
  delete_all_of_kind "$kind"
done

say "Deleting ArgoCD objects by labels (cluster & namespaced scope)..."
# First cluster-scope (clusterroles/bindings) then namespaced
run "kubectl get clusterrole,clusterrolebinding -A -l app.kubernetes.io/part-of=argocd -o name 2>/dev/null | xargs -r kubectl delete --wait=false || true"
run "kubectl get all,cm,secret,sa,role,rolebinding,svc,deploy,sts,ing -A -l app.kubernetes.io/part-of=argocd -o name 2>/dev/null | xargs -r kubectl delete --wait=false || true"
force_delete_terminating_argocd_pods
cleanup_orphan_argocd_configmaps
force_remove_redis_and_health_cm

# Delete ArgoCD namespaces (if they still exist)
ARGO_NS2=()
while IFS= read -r line; do
  line="$(trim "${line:-}")"
  [[ -z "$line" ]] && continue
  ARGO_NS2+=("$line")
done < <(detect_argocd_namespaces || true)

for ns_name in "${ARGO_NS2[@]:-}"; do
  ns_name="$(trim "${ns_name}")"
  [[ -z "${ns_name}" ]] && continue
  # Force delete controllers and pods before deleting the namespace
  force_delete_argocd_controllers "$ns_name"
  force_delete_argocd_pods "$ns_name"
  force_delete_terminating_argocd_pods
  delete_argocd_specific_configmaps
  force_remove_redis_and_health_cm
  say "Deleting namespace ${ns_name}..."
  run "kubectl delete ns \"${ns_name}\" --wait=false || true"
  wait_for_namespace_termination "$ns_name"
done

# Remove finalizers from namespaces stuck terminating
for ns_name in "${ARGO_NS2[@]:-}"; do
  ns_name="$(trim "${ns_name}")"
  [[ -z "${ns_name}" ]] && continue
  if kubectl get ns "${ns_name}" >/dev/null 2>&1; then
  say "Removing finalizers from namespace ${ns_name} (if present)..."
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "DRY_RUN: kubectl get ns ${ns_name} -o json | jq '.spec.finalizers=[]' | kubectl replace --raw \"/api/v1/namespaces/${ns_name}/finalize\" -f -"
    else
      kubectl get ns "${ns_name}" -o json | jq '.spec.finalizers=[]' \
        | kubectl replace --raw "/api/v1/namespaces/${ns_name}/finalize" -f - || true
    fi
  fi
done

say "Phase: force residual cleanup and finalize any remaining ArgoCD namespaces"
force_delete_argocd_leftovers
for ns in $(detect_argocd_namespaces 2>/dev/null); do
  force_delete_argocd_controllers "$ns"
  force_delete_argocd_pods "$ns"
  force_finalize_namespace "$ns"
  force_delete_terminating_argocd_pods
  delete_argocd_specific_configmaps
  force_remove_redis_and_health_cm
  wait_for_namespace_termination "$ns"
done

say "Deleting ArgoCD CRDs (final step)..."
delete_crd_if_exists applications.argoproj.io
delete_crd_if_exists applicationsets.argoproj.io
delete_crd_if_exists appprojects.argoproj.io

# =========================
# Phase 2: Uninstall add-ons
# =========================
say "Phase 2/4: detect and uninstall Helm-installed add-ons"

HELM_JSON="$(helm list -A -o json 2>/dev/null || echo '[]')"
HELM_FILTERED="$(echo "$HELM_JSON" \
  | jq -r '.[] | select(.chart | test("argo|aws-load-balancer-controller|external-dns|cert-manager|metrics-server|ingress-nginx|secrets-store-csi-driver|external-secrets")) | "\(.name)\t\(.namespace)"' || true)"

if [[ -z "$HELM_FILTERED" ]]; then
  say "No common add-on charts detected (Helm empty or none installed)."
else
  while IFS=$'\t' read -r rel ns_name; do
    rel="$(trim "${rel:-}")"; ns_name="$(trim "${ns_name:-}")"
    [[ -z "$rel" || -z "$ns_name" ]] && continue
  say "Uninstalling Helm release '$rel' in namespace '$ns_name'..."
    run "helm uninstall \"$rel\" -n \"$ns_name\" || true"
  done <<< "$HELM_FILTERED"
fi

# =========================
# Phase 3: CRDs and leftover resources
# =========================
say "Phase 3/4: cleanup add-on CRDs / leftovers"

# AWS Load Balancer Controller
delete_all_of_kind "targetgroupbindings.elbv2.k8s.aws"
delete_crd_if_exists "targetgroupbindings.elbv2.k8s.aws"
delete_crd_if_exists "ingressclassparams.elbv2.k8s.aws"
# (Skipping deletion as CRDs: 'argocd-redis-health-configmap' and 'kube-root-ca.crt' are ConfigMaps; handled in orphan configmap cleanup.)

# cert-manager
for crd in \
  certificaterequests.cert-manager.io \
  certificates.cert-manager.io \
  challenges.acme.cert-manager.io \
  clusterissuers.cert-manager.io \
  issuers.cert-manager.io \
  orders.acme.cert-manager.io \
  certificaterequestpolicies.policy.cert-manager.io \
  certificatepolicies.policy.cert-manager.io
do
  delete_crd_if_exists "$crd"
done

# External Secrets
for crd in \
  externalsecrets.external-secrets.io \
  secretstores.external-secrets.io \
  clustersecretstores.external-secrets.io
do
  delete_crd_if_exists "$crd"
done

# Secrets Store CSI Driver
for crd in \
  secretproviderclasses.secrets-store.csi.x-k8s.io \
  secretproviderclasspodstatuses.secrets-store.csi.x-k8s.io
do
  delete_crd_if_exists "$crd"
done

# =========================
# Fase 4: Limpieza final
# =========================
say "Phase 4/4: final cleanup of stray objects by common add-on labels"
for lbl in \
  "app.kubernetes.io/name=external-dns" \
  "app.kubernetes.io/name=aws-load-balancer-controller" \
  "app.kubernetes.io/name=cert-manager" \
  "k8s-app=metrics-server" \
  "app.kubernetes.io/instance=ingress-nginx"
do
  run "kubectl get all -A -l \"$lbl\" -o name 2>/dev/null | xargs -r kubectl delete --wait=false || true"
done

say "Reset completed (mode: DRY_RUN=${DRY_RUN})."
if [[ "${DRY_RUN}" == "true" ]]; then
  say "Re-run with: DRY_RUN=false ./reset-eks.sh to apply changes."
fi