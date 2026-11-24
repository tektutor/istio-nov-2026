# Day 1

# Istio Service Mesh and Kiali on OpenShift

This guide installs Red Hat OpenShift Service Mesh 3 (upstream Istio) and Kiali on an OpenShift 4 cluster. It also deploys the Bookinfo sample application to test the mesh.

It is the procedure used on the TekTutor training clusters (for example `ocp4.palmeto.org`).

## Tested versions

| Component | Version |
|---|---|
| OpenShift Service Mesh 3 Operator | 3.5.0 |
| Istio control plane and Istio CNI | v1.31.1 |
| Kiali Operator | `kiali-ossm`, `stable` channel |

If your operator offers a different Istio version, run `oc explain istio.spec.version` and use a supported value in both `manifests/02-istio.yaml` and `manifests/03-istiocni.yaml`. Keep both resources on the same version.

## Repository layout

```
.
├── README.md
├── manifests/
│   ├── 01-servicemesh-operator-subscription.yaml
│   ├── 02-istio.yaml
│   ├── 03-istiocni.yaml
│   ├── 04-ingress-gateway.yaml
│   ├── 05-cluster-monitoring-config.yaml
│   ├── 06-istiod-servicemonitor.yaml
│   ├── 07-istio-proxies-podmonitor.yaml
│   ├── 08-kiali-operator-subscription.yaml
│   ├── 09-kiali-monitoring-rbac.yaml
│   ├── 10-kiali.yaml
│   └── 11-ossmconsole.yaml          (optional)
└── scripts/
    ├── install-istio.sh
    ├── deploy-bookinfo.sh
    ├── setup-kiali.sh
    ├── verify.sh
    └── uninstall.sh
```

## Prerequisites

- An OpenShift 4 cluster.
- The `oc` client, logged in as a user with the `cluster-admin` role.
- No OpenShift Service Mesh 2 installed. OSSM 2 and OSSM 3 conflict unless you configure them for coexistence.

Check before you start:

```bash
oc whoami                         # confirm the user
oc whoami --show-server           # confirm the cluster
oc get clusterversion
oc get csv -A | grep -i servicemesh
```

Always run `oc whoami --show-server` first. If you have more than one cluster, it is easy to apply changes to the wrong one.

---

## Part 1: Install Istio

### Step 1. Install the Service Mesh 3 operator

```bash
oc apply -f manifests/01-servicemesh-operator-subscription.yaml
```

Wait until the operator shows `Succeeded`:

```bash
oc get csv -n openshift-operators -w | grep servicemesh
```

### Step 2. Create the Istio control plane

```bash
oc new-project istio-system
oc apply -f manifests/02-istio.yaml
oc wait --for=condition=Ready istio/default --timeout=5m
```

Check it:

```bash
oc get istio,istiorevision
oc get pods -n istio-system                        # istiod-... 1/1 Running
oc get mutatingwebhookconfiguration | grep istio   # istio-sidecar-injector
```

**Do not skip this check.** If the `istio-sidecar-injector` webhook is missing, no pod gets a sidecar. See [Troubleshooting](#troubleshooting).

### Step 3. Create Istio CNI

```bash
oc new-project istio-cni
oc apply -f manifests/03-istiocni.yaml
oc wait --for=condition=Ready istiocni/default --timeout=5m
oc get pods -n istio-cni -o wide                   # one pod per node
```

The operator log shows PodSecurity warnings for the `install-cni` container. These are expected. The CNI DaemonSet runs privileged on purpose.

Or run Part 1 in one go:

```bash
./scripts/install-istio.sh
```

---

## Part 2: Deploy Bookinfo and the ingress gateway

### Step 4. Deploy Bookinfo with sidecar injection

```bash
oc new-project bookinfo
oc label namespace bookinfo istio-injection=enabled

oc apply -n bookinfo -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml
oc get pods -n bookinfo
```

Every application pod must show `2/2` (the app container plus the `istio-proxy` sidecar). If you see `1/1`, injection did not happen.

The `istio-injection=enabled` label works because the `Istio` resource is named `default` and uses the `InPlace` update strategy. With the `RevisionBased` strategy, use `istio.io/rev=<revision-name>` instead (`oc get istiorevision` shows the name).

### Step 5. Create the ingress gateway

OpenShift Service Mesh 3 does not create an ingress gateway for you. This repo uses gateway injection: a Deployment with `image: auto` that the injector turns into an Envoy gateway.

```bash
oc apply -n bookinfo -f manifests/04-ingress-gateway.yaml
oc apply -n bookinfo -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/bookinfo/networking/bookinfo-gateway.yaml
oc expose service istio-ingressgateway -n bookinfo
oc get route istio-ingressgateway -n bookinfo
```

### Step 6. Test Bookinfo

```bash
GW=$(oc get route istio-ingressgateway -n bookinfo -o jsonpath='{.spec.host}')
curl -s -o /dev/null -w "%{http_code}\n" http://$GW/productpage     # expect 200
```

Open `http://<route-host>/productpage` in a browser. Refresh a few times. The reviews section rotates between no stars, black stars and red stars (reviews v1, v2 and v3).

Or run Part 2 in one go:

```bash
./scripts/deploy-bookinfo.sh
```

---

## Part 3: Install Kiali

Kiali reads metrics from the OpenShift monitoring stack through Thanos Querier. So you first turn on user workload monitoring and tell Prometheus to scrape the mesh.

### Step 7. Enable user workload monitoring

Check whether the ConfigMap exists first. `oc apply` replaces its whole content.

```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml
```

- If it does not exist:
  ```bash
  oc apply -f manifests/05-cluster-monitoring-config.yaml
  ```
- If it exists, add `enableUserWorkload: true` under `config.yaml` with `oc edit` and keep the other settings.

Wait for the pods:

```bash
oc get pods -n openshift-user-workload-monitoring
```

### Step 8. Scrape istiod and the sidecars

```bash
oc apply -f manifests/06-istiod-servicemonitor.yaml
oc apply -n istio-system -f manifests/07-istio-proxies-podmonitor.yaml
oc apply -n bookinfo     -f manifests/07-istio-proxies-podmonitor.yaml
```

OpenShift monitoring ignores `namespaceSelector` in PodMonitor objects. **Apply the PodMonitor in every mesh namespace.** A namespace without it stays empty in the Kiali graph.

### Step 9. Install the Kiali operator

```bash
oc apply -f manifests/08-kiali-operator-subscription.yaml
oc get csv -n openshift-operators -w | grep kiali     # wait for Succeeded
oc get crd kialis.kiali.io                            # must exist before Step 11
```

### Step 10. Let Kiali read cluster metrics

```bash
oc apply -f manifests/09-kiali-monitoring-rbac.yaml
```

### Step 11. Create the Kiali instance

```bash
oc apply -f manifests/10-kiali.yaml
oc get pods -n istio-system -l app=kiali -w          # wait for 1/1 Running
oc get route kiali -n istio-system -o jsonpath='https://{.spec.host}{"\n"}'
```

Or run Part 3 in one go:

```bash
./scripts/setup-kiali.sh
```

### Step 12. Open Kiali

1. Open the Kiali URL, for example `https://kiali-istio-system.apps.ocp4.palmeto.org`.
2. Click **Log In With OpenShift** and choose your identity provider.
3. Log in with your cluster user and allow the requested permissions.

### Step 13. Generate traffic and view the graph

```bash
GW=$(oc get route istio-ingressgateway -n bookinfo -o jsonpath='{.spec.host}')
while true; do curl -s -o /dev/null http://$GW/productpage; sleep 1; done
```

In Kiali, open **Traffic Graph**, select the `bookinfo` namespace and set the time range to **Last 5m**. The graph fills in after 1 to 2 minutes.

### Step 14 (optional). Kiali inside the OpenShift console

```bash
oc apply -f manifests/11-ossmconsole.yaml
```

Refresh the OpenShift web console. A **Service Mesh** menu appears on the left.

---

## Verify everything

```bash
./scripts/verify.sh
```

It checks the operators, the control plane, the webhook, the CNI pods, the Bookinfo sidecars, the gateway response and Kiali.

---

## Traffic routing demo

```bash
BASE=https://raw.githubusercontent.com/istio/istio/release-1.26/samples/bookinfo/networking

oc apply -n bookinfo -f $BASE/destination-rule-all.yaml
oc apply -n bookinfo -f $BASE/virtual-service-all-v1.yaml
# Refresh the page: no stars every time

oc apply -n bookinfo -f $BASE/virtual-service-reviews-50-v3.yaml
# Refresh the page: about half no stars, half red stars
```

In Kiali, turn on **Display > Traffic Distribution** to see the 50/50 split.

---

## Adding a new mesh project

Every new project that should join the mesh needs two things:

```bash
oc label namespace <project> istio-injection=enabled
oc apply -n <project> -f manifests/07-istio-proxies-podmonitor.yaml
```

If the project already has running pods, restart them so they get sidecars:

```bash
oc rollout restart deployment -n <project>
```

---

## Troubleshooting

### Gateway pod in `ImagePullBackOff` pulling image `auto`

**Symptom:**

```
Failed to pull image "auto": ... docker.io/library/auto: requested access to the resource is denied
```

Application pods also show `1/1` instead of `2/2`.

**Cause:** The sidecar injector did not process the pod. The usual reason is that the `Istio` control plane resource does not exist, so there is no istiod and no webhook.

**Check:**

```bash
oc get mutatingwebhookconfiguration | grep istio   # empty means no injector
oc get istio                                       # "not found" means Step 2 was skipped
oc get pods -n istio-system                        # no istiod pod
```

**Fix:** Complete Step 2, confirm the webhook exists, then restart the workloads:

```bash
oc apply -f manifests/02-istio.yaml
oc wait --for=condition=Ready istio/default --timeout=5m
oc rollout restart deployment -n bookinfo
```

### Route returns 503

| Source | Check |
|---|---|
| OpenShift router page ("Application is not available") | `oc get endpoints istio-ingressgateway -n bookinfo` must list a pod IP on port 8080 |
| Envoy `no healthy upstream` | Bookinfo pods must be `2/2 Running` |

### Route returns 404 from Envoy

The Gateway or VirtualService does not match. Check:

```bash
oc get gateway,virtualservice -n bookinfo
oc logs -n bookinfo deploy/istio-ingressgateway
```

### `error: the server doesn't have a resource type "kiali"`

The Kiali operator is not installed. Run Step 9 and wait for the `kialis.kiali.io` CRD.

### Kiali graph is empty

| Check | How |
|---|---|
| Traffic is flowing | Run the curl loop from Step 13 |
| Prometheus scrapes the sidecars | OpenShift console > **Observe > Targets**, filter `istio-proxies-monitor`, status `Up` |
| Metrics exist | **Observe > Metrics**, query `istio_requests_total{namespace="bookinfo"}` |
| PodMonitor exists in the namespace | `oc get podmonitor -n bookinfo` |
| Kiali reaches Thanos | `oc logs -n istio-system deploy/kiali \| grep -i -E "prometheus\|error"` |

### Project stuck in `Terminating`

Find the blocker:

```bash
oc get namespace <project> -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}'
```

If the message names custom resources with finalizers whose operator no longer runs, remove the finalizers:

```bash
for r in $(oc get <resource-type> -n <project> -o name); do
  oc patch "$r" -n <project> --type=merge -p '{"metadata":{"finalizers":null}}'
done
```

To avoid this, delete custom resources before you delete their project or uninstall their operator. The uninstall script below follows that order.

---

## Uninstall

```bash
./scripts/uninstall.sh
```

The script removes things in this order: Bookinfo, Kiali instance, Kiali operator, `Istio`, `IstioCNI`, Service Mesh operator, then the projects. Deleting the custom resources **before** the operators prevents projects from getting stuck in `Terminating`.

---

## References

- [Installing OpenShift Service Mesh 3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html-single/installing/index)
- [OpenShift Service Mesh 3 observability](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html-single/observability/)
- [Kiali Operator provided by Red Hat](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/observability/kiali-operator-provided-by-red-hat)
- [Migrating from Service Mesh 2 to Service Mesh 3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html-single/migrating_from_service_mesh_2_to_service_mesh_3/index)
