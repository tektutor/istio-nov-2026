#!/bin/bash
# Part 3: user workload monitoring, mesh scraping, Kiali.
# Usage: ./scripts/setup-kiali.sh [mesh-namespace ...]
# Default mesh namespaces: istio-system bookinfo
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -gt 0 ]; then
  MESH_NAMESPACES=("$@")
else
  MESH_NAMESPACES=(istio-system bookinfo)
fi

echo "== Step 7: User workload monitoring =="
if oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
  if oc get configmap cluster-monitoring-config -n openshift-monitoring \
       -o jsonpath='{.data.config\.yaml}' | grep -q 'enableUserWorkload: true'; then
    echo "Already enabled."
  else
    echo "cluster-monitoring-config exists without enableUserWorkload."
    echo "Add 'enableUserWorkload: true' with:"
    echo "  oc edit configmap cluster-monitoring-config -n openshift-monitoring"
    echo "Then run this script again."
    exit 1
  fi
else
  oc apply -f manifests/05-cluster-monitoring-config.yaml
fi

echo "== Step 8: ServiceMonitor and PodMonitors =="
oc apply -f manifests/06-istiod-servicemonitor.yaml
for ns in "${MESH_NAMESPACES[@]}"; do
  oc apply -n "$ns" -f manifests/07-istio-proxies-podmonitor.yaml
done

echo "== Step 9: Kiali operator =="
oc apply -f manifests/08-kiali-operator-subscription.yaml
echo "Waiting for the Kiali CRD..."
until oc get crd kialis.kiali.io >/dev/null 2>&1; do sleep 5; done
oc wait --for=condition=Established crd/kialis.kiali.io --timeout=5m

echo "== Step 10: Monitoring access for Kiali =="
oc apply -f manifests/09-kiali-monitoring-rbac.yaml

echo "== Step 11: Kiali instance =="
oc apply -f manifests/10-kiali.yaml
echo "Waiting for the Kiali pod..."
until oc get pods -n istio-system -l app=kiali 2>/dev/null | grep -q Running; do sleep 10; done
oc wait --for=condition=Ready pod -l app=kiali -n istio-system --timeout=5m

echo
echo "Kiali URL: https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
