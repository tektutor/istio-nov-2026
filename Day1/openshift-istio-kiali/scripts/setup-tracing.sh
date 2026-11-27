#!/usr/bin/env bash
# TRAINER ONLY (cluster-admin). Distributed tracing for Day 3, Lab 6.
# The same steps as the workbook Appendix, Part D, with waits in place of watching:
#   D1  Tempo operator
#   D2  Red Hat build of OpenTelemetry operator
#   D3  TempoMonolithic "sample" in tracing-system, with the Jaeger UI Route
#   D4  OpenTelemetry Collector "otel" in istio-system
#   D5  Tracing on in the Istio resource, plus a mesh-wide Telemetry at 100% sampling
#   D6  Traces in Kiali (only if Kiali is installed)
# Usage: ./setup-tracing.sh
# Afterwards, every project restarts its pods and runs reset (Day 3, Lab 6, Step 1).
set -euo pipefail

say() { echo; echo "== $*"; }

wait_for_csv() {   # wait_for_csv <namespace> <name-part>
  local ns=$1 part=$2 i
  for i in $(seq 1 60); do
    if oc get csv -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null \
        | grep "$part" | grep -q Succeeded; then
      oc get csv -n "$ns" | grep "$part"
      return 0
    fi
    sleep 10
  done
  echo "The $part operator did not reach Succeeded in 10 minutes. Check: oc get csv -n $ns"
  exit 1
}

wait_for_crd() {   # wait_for_crd <crd-name>
  local crd=$1 i
  for i in $(seq 1 30); do
    oc get crd "$crd" >/dev/null 2>&1 && break
    sleep 10
  done
  oc wait --for=condition=Established "crd/$crd" --timeout=120s
}

if ! oc auth can-i create subscriptions -n openshift-marketplace >/dev/null 2>&1; then
  echo "Run this as cluster-admin."
  exit 1
fi

say "D1: Tempo operator"
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-tempo-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-tempo-operator
  namespace: openshift-tempo-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: tempo-product
  namespace: openshift-tempo-operator
spec:
  channel: stable
  name: tempo-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

say "D2: Red Hat build of OpenTelemetry operator"
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-opentelemetry-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-opentelemetry-operator
  namespace: openshift-opentelemetry-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opentelemetry-product
  namespace: openshift-opentelemetry-operator
spec:
  channel: stable
  name: opentelemetry-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

say "Waiting for both operators (2 to 5 minutes)"
wait_for_csv openshift-tempo-operator tempo
wait_for_csv openshift-opentelemetry-operator opentelemetry
wait_for_crd tempomonolithics.tempo.grafana.com
wait_for_crd opentelemetrycollectors.opentelemetry.io

say "D3: Tempo instance in tracing-system"
oc get project tracing-system >/dev/null 2>&1 || oc new-project tracing-system >/dev/null
oc apply -n tracing-system -f - <<'EOF'
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoMonolithic
metadata:
  name: sample
spec:
  storage:
    traces:
      backend: memory
      size: 2Gi
  jaegerui:
    enabled: true
    route:
      enabled: true
EOF
for i in $(seq 1 30); do
  [ -n "$(oc get route -n tracing-system -o name 2>/dev/null)" ] && break
  sleep 10
done
oc wait --for=condition=Ready pods --all -n tracing-system --timeout=300s

say "D4: OpenTelemetry Collector in istio-system"
oc apply -n istio-system -f - <<'EOF'
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
spec:
  mode: deployment
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    exporters:
      otlp:
        endpoint: tempo-sample.tracing-system.svc:4317
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [otlp]
EOF
for i in $(seq 1 30); do
  oc get deploy otel-collector -n istio-system >/dev/null 2>&1 && break
  sleep 5
done
oc rollout status deploy/otel-collector -n istio-system --timeout=300s

say "D5: Tracing on in Istio"
oc patch istio default --type=merge -p '
spec:
  values:
    meshConfig:
      enableTracing: true
      extensionProviders:
      - name: otel
        opentelemetry:
          port: 4317
          service: otel-collector.istio-system.svc.cluster.local
'
oc wait --for=condition=Ready istio/default --timeout=5m
oc apply -n istio-system -f - <<'EOF'
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
spec:
  tracing:
  - providers:
    - name: otel
    randomSamplingPercentage: 100
EOF

JAEGER=$(oc get route -n tracing-system -o jsonpath='{.items[0].spec.host}')

say "D6: Traces in Kiali"
if oc get kiali kiali -n istio-system >/dev/null 2>&1; then
  oc patch kiali kiali -n istio-system --type=merge -p "
spec:
  external_services:
    tracing:
      enabled: true
      provider: tempo
      use_grpc: false
      internal_url: http://tempo-sample.tracing-system.svc:3200
      external_url: https://$JAEGER
"
else
  echo "No Kiali resource named kiali in istio-system: skipped."
fi

say "Done"
echo "Jaeger UI: https://$JAEGER"
echo
echo "Each project must restart its pods to send spans, then restore the balances:"
echo "  oc rollout restart deployment -n <project>"
echo "  reset"
