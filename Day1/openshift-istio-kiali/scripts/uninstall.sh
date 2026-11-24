#!/bin/bash
# Removes Bookinfo, Kiali and Istio in an order that avoids stuck finalizers:
# custom resources first, operators after, projects last.
set -uo pipefail

echo "Target cluster: $(oc whoami --show-server) as $(oc whoami)"
read -r -p "This removes Bookinfo, Kiali and Istio. Continue? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1

echo "== Bookinfo =="
oc delete project bookinfo --ignore-not-found --wait=true

echo "== Kiali =="
oc delete ossmconsole --all -n openshift-operators --ignore-not-found
oc delete kiali --all -n istio-system --ignore-not-found --wait=true
oc delete clusterrolebinding kiali-monitoring-rbac --ignore-not-found
oc delete subscription kiali-ossm -n openshift-operators --ignore-not-found
for csv in $(oc get csv -n openshift-operators -o name | grep -i kiali); do
  oc delete "$csv" -n openshift-operators
done

echo "== Istio =="
oc delete istio default --ignore-not-found --wait=true
oc delete istiocni default --ignore-not-found --wait=true
oc delete subscription servicemeshoperator3 -n openshift-operators --ignore-not-found
for csv in $(oc get csv -n openshift-operators -o name | grep -i servicemesh); do
  oc delete "$csv" -n openshift-operators
done

echo "== Projects =="
oc delete project istio-system istio-cni --ignore-not-found

echo
echo "Done. User workload monitoring is left enabled."
echo "To also remove the CRDs:"
echo "  oc get crd -o name | grep -E 'sailoperator.io|istio.io|kiali.io' | xargs oc delete"
