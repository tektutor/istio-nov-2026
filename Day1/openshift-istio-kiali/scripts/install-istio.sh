#!/bin/bash
# Part 1: Service Mesh 3 operator, Istio control plane, Istio CNI.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Target cluster: $(oc whoami --show-server) as $(oc whoami)"
read -r -p "Continue? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1

echo "== Step 1: Service Mesh 3 operator =="
oc apply -f manifests/01-servicemesh-operator-subscription.yaml
echo "Waiting for the Istio CRD..."
until oc get crd istios.sailoperator.io >/dev/null 2>&1; do sleep 5; done
oc wait --for=condition=Established crd/istios.sailoperator.io --timeout=5m
oc wait --for=condition=Established crd/istiocnis.sailoperator.io --timeout=5m

echo "== Step 2: Istio control plane =="
oc get project istio-system >/dev/null 2>&1 || oc new-project istio-system >/dev/null
oc apply -f manifests/02-istio.yaml
oc wait --for=condition=Ready istio/default --timeout=5m

echo "Checking the sidecar injector webhook..."
until oc get mutatingwebhookconfiguration 2>/dev/null | grep -q istio-sidecar-injector; do sleep 5; done
echo "Webhook found."

echo "== Step 3: Istio CNI =="
oc get project istio-cni >/dev/null 2>&1 || oc new-project istio-cni >/dev/null
oc apply -f manifests/03-istiocni.yaml
oc wait --for=condition=Ready istiocni/default --timeout=5m

echo
oc get istio,istiorevision,istiocni
oc get pods -n istio-system
echo "Istio is installed."
