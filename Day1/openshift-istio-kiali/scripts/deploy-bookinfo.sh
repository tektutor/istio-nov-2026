#!/bin/bash
# Part 2: Bookinfo sample app with an injected ingress gateway.
set -euo pipefail
cd "$(dirname "$0")/.."

NS=bookinfo
SAMPLES=https://raw.githubusercontent.com/istio/istio/release-1.26/samples/bookinfo

if ! oc get mutatingwebhookconfiguration 2>/dev/null | grep -q istio-sidecar-injector; then
  echo "No istio-sidecar-injector webhook. Run scripts/install-istio.sh first."
  exit 1
fi

oc get project "$NS" >/dev/null 2>&1 || oc new-project "$NS" >/dev/null
oc label namespace "$NS" istio-injection=enabled --overwrite

oc apply -n "$NS" -f "$SAMPLES/platform/kube/bookinfo.yaml"
oc apply -n "$NS" -f manifests/04-ingress-gateway.yaml
oc apply -n "$NS" -f "$SAMPLES/networking/bookinfo-gateway.yaml"
oc get route istio-ingressgateway -n "$NS" >/dev/null 2>&1 || oc expose service istio-ingressgateway -n "$NS"

echo "Waiting for deployments..."
oc wait --for=condition=Available deployment --all -n "$NS" --timeout=5m

GW=$(oc get route istio-ingressgateway -n "$NS" -o jsonpath='{.spec.host}')
echo
oc get pods -n "$NS"
echo
echo "HTTP status: $(curl -s -o /dev/null -w '%{http_code}' "http://$GW/productpage")"
echo "Bookinfo URL: http://$GW/productpage"
