#!/bin/bash
# Checks every layer of the install and prints PASS or FAIL for each.
NS=${1:-bookinfo}
fail=0

check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  $name"
  else
    echo "FAIL  $name"
    fail=1
  fi
}

echo "Cluster: $(oc whoami --show-server) as $(oc whoami)"
echo

check "Service Mesh operator Succeeded" \
  bash -c "oc get csv -n openshift-operators | grep servicemeshoperator3 | grep -q Succeeded"
check "Istio 'default' Ready" \
  oc wait --for=condition=Ready istio/default --timeout=5s
check "istiod pod Running" \
  bash -c "oc get pods -n istio-system -l app=istiod | grep -q Running"
check "Sidecar injector webhook exists" \
  bash -c "oc get mutatingwebhookconfiguration | grep -q istio-sidecar-injector"
check "IstioCNI 'default' Ready" \
  oc wait --for=condition=Ready istiocni/default --timeout=5s
check "Namespace $NS has istio-injection=enabled" \
  bash -c "oc get namespace $NS --show-labels | grep -q istio-injection=enabled"
check "All app pods in $NS have a sidecar (2/2)" \
  bash -c "! oc get pods -n $NS --no-headers -l '!istio' | awk '{print \$2}' | grep -v '^2/2$' | grep -q ."
check "Gateway pod Running" \
  bash -c "oc get pods -n $NS -l istio=ingressgateway | grep -q '1/1.*Running'"

GW=$(oc get route istio-ingressgateway -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)
check "Gateway returns 200 on /productpage" \
  bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://$GW/productpage)\" = 200 ]"

check "User workload monitoring enabled" \
  bash -c "oc get pods -n openshift-user-workload-monitoring | grep -q prometheus-user-workload"
check "PodMonitor exists in $NS" \
  oc get podmonitor istio-proxies-monitor -n "$NS"
check "Kiali CRD exists" \
  oc get crd kialis.kiali.io
check "Kiali pod Running" \
  bash -c "oc get pods -n istio-system -l app=kiali | grep -q Running"

echo
if [ $fail -eq 0 ]; then
  echo "All checks passed."
  echo "Bookinfo: http://$GW/productpage"
  echo "Kiali:    https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
else
  echo "Some checks failed. See the Troubleshooting section in README.md."
  exit 1
fi
