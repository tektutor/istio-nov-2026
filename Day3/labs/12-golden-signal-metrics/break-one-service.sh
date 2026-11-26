#!/usr/bin/env bash
# Day 3, Lab 12: break one pod of one Netbanking service, without saying which.
# Your task is to find it from the metrics alone.
#   ./break-one-service.sh            break a random pod of accounts, transfer or notification
#   ./break-one-service.sh --answer   show which pod it was
#   ./break-one-service.sh --heal     make every pod healthy again
# Needs NS set to your project, and the toolbox pod from Lab 1.
set -euo pipefail
: "${NS:?set NS first, for example: export NS=user07-netbanking}"
STATE="$HOME/.netbanking-mystery"

chaos_pod() {   # chaos_pod <pod-ip> <json>
  oc exec -n "$NS" deploy/toolbox -- \
    curl -s -o /dev/null -X POST "http://$1:8080/admin/chaos" -d "$2"
}

case "${1:-}" in
  --answer)
    cat "$STATE" 2>/dev/null || echo "Nothing is broken."
    ;;
  --heal)
    for svc in accounts transfer notification; do
      for ip in $(oc get pods -n "$NS" -l app=$svc -o jsonpath='{.items[*].status.podIP}'); do
        chaos_pod "$ip" '{"delay_ms": 0, "fail_rate": 0}'
      done
    done
    rm -f "$STATE"
    echo "All pods are healthy again."
    ;;
  *)
    services=(accounts transfer notification)
    svc=${services[$((RANDOM % 3))]}
    pods=($(oc get pods -n "$NS" -l app=$svc -o jsonpath='{.items[*].metadata.name}'))
    pod=${pods[$((RANDOM % ${#pods[@]}))]}
    ip=$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.podIP}')
    chaos_pod "$ip" '{"fail_rate": 0.5}'
    echo "$svc: pod $pod fails half of its requests" > "$STATE"
    echo "One pod of one service now fails half of its requests. Find it."
    ;;
esac
