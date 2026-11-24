# Netbanking lab kit

Lab kit for **Istio Workbook Module 1: Why Netbanking Needs a Service Mesh**.

Netbanking is a tiny internet bank: 4 Python services (`web`, `transfer`,
`accounts`, `notification`) and Redis. One container image holds all 4
services; the `SERVICE` environment variable picks which one a container runs.

## Layout

```
app/                      source code and Dockerfile
  common.py               logging, health checks, chaos switch, header propagation
  web.py                  the page customers open
  transfer.py             moves money (naive_call and the RESILIENT=true fix)
  accounts.py             owns the balances in Redis
  notification.py         sends the SMS (writes a log line)
  main.py                 picks the service named in SERVICE
deploy/                   applied with: oc apply -n $NS -f deploy/
  10-redis.yaml
  20-accounts.yaml        2 pods
  30-transfer.yaml        RESILIENT=false
  40-notification.yaml
  50-web.yaml             4 threads, plus a Route
  60-toolbox.yaml         a curl pod
  extras/accounts-v2.yaml Problem 6 only
  mesh/podmonitor.yaml    Lab 2 only
```

## Quick start

```bash
export U=user07 NS=user07-netbanking
oc new-project $NS
oc new-build --name=netbanking --binary --strategy=docker -n $NS
oc start-build netbanking --from-dir=app --follow -n $NS
oc set image-lookup netbanking -n $NS
oc apply -n $NS -f deploy/
```

## Chaos switch

Every pod answers `POST /admin/chaos` with a JSON body:

| Body | Effect on that one pod |
|---|---|
| `{"delay_ms": 10000}` | Wait 10 seconds before every answer |
| `{"fail_rate": 0.5}` | Fail half of all requests with HTTP 503 |
| `{"delay_ms": 0, "fail_rate": 0}` | Healthy again |

`/healthz`, `/readyz` and `/admin/*` are never slowed or failed, so Kubernetes
keeps reporting the pod as healthy.

## Settings

| Variable | Services | Default | Effect |
|---|---|---|---|
| `SERVICE` | all | none | `web`, `transfer`, `accounts` or `notification` |
| `VERSION` | all | `v1` | accounts `v2` also returns the IFSC code |
| `THREADS` | all | `8` | gunicorn threads; `web` uses 4 |
| `DELAY_MS`, `FAIL_RATE` | all | `0` | Start-up values for the chaos switch |
| `REDIS_HOST` | accounts | empty | Empty means in-memory balances (laptop tests only) |
| `RESILIENT` | transfer | `false` | `true` adds timeout, retries and a circuit breaker |
| `ACCOUNTS_URL`, `TRANSFER_URL`, `NOTIFICATION_URL` | web, transfer | `http://<name>:8080` | Downstream addresses |

## Reset the bank

```bash
oc exec -n $NS deploy/redis -- redis-cli flushall
oc rollout restart deploy/accounts-v1 -n $NS
```

The total balance must always be 175000.
