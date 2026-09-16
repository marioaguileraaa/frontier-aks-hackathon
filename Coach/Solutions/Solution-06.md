# Challenge 06 — Autoscaling — Coach Solution

[< Previous Solution](./Solution-05.md) | [Home](../../README.md) | [Next Solution >](./Solution-07.md)

## Notes & Guidance

- **Scale-to-zero with KEDA** is the most impressive demo — queue empty = 0 pods, enqueue
  messages = pods appear. Time this to show within the challenge window.
- HPA and KEDA can coexist on the same deployment only if the HPA targets a **different**
  metric (e.g., CPU) and KEDA is set as the primary scaler. In practice, for event-driven
  workloads, remove the HPA and let KEDA own all scaling.
- VPA in `Off` mode is safe for demos and shows useful recommendations. `Auto` mode causes
  pod restarts and is risky during a hackathon.
- **Karpenter / NAP** may be preview in some regions. AKS Automatic includes it by default.
  For Standard clusters, the cluster must be created in Challenge 02 with
  `--node-provisioning-mode Auto`, `--network-dataplane cilium`, and
  `--network-plugin-mode overlay`. These prerequisites cannot be added later.

### Common Issues

- **HPA shows `<unknown>` for CPU:** Metrics Server must be running. Check:
  `kubectl get deployment metrics-server -n kube-system`. Also verify that resource
  **requests** (not just limits) are set on the target containers.
- **KEDA scale-to-zero not working:** Ensure `minReplicaCount: 0` is set in the ScaledObject.
  KEDA defaults to 1 if not specified.
- **Service Bus TriggerAuthentication:** Use the `kube-system:keda-operator` ServiceAccount
  for the federated credential. The KEDA operator pod is the actual token requestor, not the
  application pods. Set `provider: azure-workload` in the `TriggerAuthentication`.

## Solution

### Part 1: Horizontal Pod Autoscaler

```bash
# Ensure resource requests are set (HPA requires them)
kubectl set resources deployment/fabtech-api \
  --namespace $NAMESPACE \
  --requests=cpu=250m,memory=256Mi \
  --limits=cpu=500m,memory=512Mi

# Create HPA
kubectl autoscale deployment fabtech-api \
  --namespace $NAMESPACE \
  --cpu=50% \
  --min=2 \
  --max=10

kubectl get hpa -n fabtech -w
```

Generate load in a separate terminal:

```bash
kubectl run -it --rm load-test \
  --image=busybox \
  --restart=Never \
  --namespace=$NAMESPACE \
  -- sh -c 'i=0; while [ "$i" -lt 100 ]; do (while true; do wget -q -O /dev/null http://fabtech-api:3001/sessions; done) & i=$((i+1)); done; wait'
```

### Part 2: KEDA Add-on

Before we start, remove the HPA from the `fabtech-api` deployment — KEDA will own scaling.

```bash
kubectl delete hpa fabtech-api -n $NAMESPACE
```

```bash
RG=rg-frontier-aks
CLUSTER_NAME=aks-frontier

az aks update \
  --resource-group $RG \
  --name $CLUSTER_NAME \
  --enable-keda

kubectl get pods -n kube-system | grep keda
```

### Service Bus Setup

```bash
SB_NS=sb-frontier-$RANDOM

az servicebus namespace create \
  --resource-group $RG \
  --name $SB_NS \
  --sku Standard

az servicebus queue create \
  --resource-group $RG \
  --namespace-name $SB_NS \
  --name fabtech-jobs
```

### KEDA Workload Identity Auth for Service Bus

> **How KEDA WI works:** With `provider: azure-workload` in the `TriggerAuthentication`,
> the KEDA operator pod (`kube-system:keda-operator`) is the actual token requestor — it
> fetches queue metrics on behalf of the scaler. The federated credential must therefore
> target `kube-system:keda-operator`, not an app-namespace SA.

```bash
MI_NAME=mi-keda-servicebus
NAMESPACE=fabtech

az identity create --resource-group $RG --name $MI_NAME
MI_CLIENT_ID=$(az identity show --resource-group $RG --name $MI_NAME --query clientId -o tsv)
MI_OBJECT_ID=$(az identity show --resource-group $RG --name $MI_NAME --query principalId -o tsv)

# Grant Service Bus Data Receiver to the identity
SB_ID=$(az servicebus namespace show --resource-group $RG --name $SB_NS --query id -o tsv)
az role assignment create \
  --role "Azure Service Bus Data Receiver" \
  --assignee-object-id $MI_OBJECT_ID \
  --assignee-principal-type ServicePrincipal \
  --scope $SB_ID

# Get OIDC issuer
OIDC_ISSUER=$(az aks show --resource-group $RG --name $CLUSTER_NAME \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

# Federated credential must target kube-system:keda-operator
# (the AKS managed KEDA operator pod is what actually requests the token)
az identity federated-credential create \
  --name fc-keda-operator \
  --identity-name $MI_NAME \
  --resource-group $RG \
  --issuer $OIDC_ISSUER \
  --subject "system:serviceaccount:kube-system:keda-operator" \
  --audience api://AzureADTokenExchange

# Annotate the keda-operator ServiceAccount with the MI client ID
kubectl annotate serviceaccount keda-operator \
  --namespace kube-system \
  "azure.workload.identity/client-id=$MI_CLIENT_ID" --overwrite

# Restart the operator so the WI webhook injects the projected token
kubectl rollout restart deployment/keda-operator -n kube-system
kubectl rollout status deployment/keda-operator -n kube-system --timeout=60s
```

KEDA `TriggerAuthentication` and `ScaledObject`:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: fabtech-sb-auth
  namespace: $NAMESPACE
spec:
  podIdentity:
    provider: azure-workload   # NOT "azure-workload-identity"
    identityId: "$MI_CLIENT_ID"
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: fabtech-api-scaler
  namespace: $NAMESPACE
spec:
  scaleTargetRef:
    name: fabtech-api
  minReplicaCount: 0
  maxReplicaCount: 20
  pollingInterval: 15
  cooldownPeriod: 60
  triggers:
  - type: azure-servicebus
    metadata:
      queueName: fabtech-jobs
      namespace: $SB_NS
      messageCount: "5"
    authenticationRef:
      name: fabtech-sb-auth
EOF
```

Send test messages to trigger scale-up:

> **Easiest option:** Azure Portal → your Service Bus namespace → `fabtech-jobs` queue →
> **Service Bus Explorer** → Send → send 20 messages.

Alternative (Python stdlib, no pip required):

```bash
SERVICE_BUS_CONNECTION_STRING=$(az servicebus namespace authorization-rule keys list \
  --resource-group $RG \
  --namespace-name $SB_NS \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv)

python3 - << PYEOF
import urllib.request, urllib.parse, hmac, hashlib, base64, time

conn = """$SERVICE_BUS_CONNECTION_STRING"""
parts = dict(p.split("=", 1) for p in conn.split(";") if "=" in p)
sb_host = parts["Endpoint"].replace("sb://", "").rstrip("/")
key_name = parts["SharedAccessKeyName"]
key = parts["SharedAccessKey"]
queue = "fabtech-jobs"

def sas_token(uri, key_name, key, ttl=300):
    expiry = int(time.time()) + ttl
    string_to_sign = urllib.parse.quote_plus(uri) + "\n" + str(expiry)
    sig = base64.b64encode(hmac.new(key.encode(), string_to_sign.encode(), hashlib.sha256).digest()).decode()
    return "SharedAccessSignature sr={}&sig={}&se={}&skn={}".format(
        urllib.parse.quote_plus(uri), urllib.parse.quote_plus(sig), expiry, key_name)

url = "https://{}/{}/messages".format(sb_host, queue)
token = sas_token("https://{}/{}".format(sb_host, queue), key_name, key)
for i in range(20):
    req = urllib.request.Request(url, data="job-{}".format(i).encode(), method="POST")
    req.add_header("Authorization", token)
    req.add_header("Content-Type", "application/json")
    urllib.request.urlopen(req)
print("Sent 20 messages")
PYEOF

kubectl get pods -n $NAMESPACE -w
```

### Part 3: Node Auto Provisioning (Karpenter)

```bash
az aks show \
  --resource-group $RG \
  --name $CLUSTER_NAME \
  --query "{nodeProvisioningProfile:nodeProvisioningProfile, agentPools:agentPoolProfiles[].{name:name,mode:mode}}" \
  -o jsonc
```

If you used **AKS Automatic** in Challenge 02, NAP is already available. For **AKS Standard**,
NAP only works if the cluster was created in Challenge 02 with:

```bash
az aks create \
  ... \
  --network-plugin-mode overlay \
  --network-dataplane cilium \
  --node-provisioning-mode Auto
```

If the cluster was not created with those flags, do not use `az aks update` to try to add
NAP later — recreate the cluster with the correct Challenge 02 configuration instead.

Apply the `NodePool` and `AKSNodeClass` manifests to enable Karpenter:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: general
spec:
  imageFamily: AzureLinux
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: general
      requirements:
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["on-demand", "spot"]
        - key: "karpenter.azure.com/sku-family"
          operator: In
          values: ["D", "E"]
  limits:
    cpu: "100"
    memory: 400Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
    budgets:
    - nodes: "20%"   # At most 20% of nodes disrupted at once
EOF
```

### Verify NAP — Trigger Provisioning and Consolidation

Enforce Karpenter to provision new nodes by deploying `pause`
containers that each request 1 CPU — more than fits on the existing nodes:

```bash
kubectl get nodepool general   # wait for READY=True

# Deploy inflate workload — each replica requests 1 CPU
kubectl create deployment inflate \
  --image=registry.k8s.io/pause:3.9 \
  --replicas=20 \
  --namespace $NAMESPACE
kubectl patch deployment inflate \
  --patch '{"spec":{"template":{"spec":{"containers":[{"name":"pause","resources":{"requests":{"cpu":"1"}}}]}}}}' \
  --namespace $NAMESPACE

# Watch the inflate pods go Pending (no nodes available)
kubectl get pods -n $NAMESPACE -w | grep inflate

# in a different terminal, watch Karpenter provision new nodes (typically within 60 s)
kubectl get nodes -w | grep general

# Confirm Karpenter created NodeClaim(s)
kubectl get nodeclaims | grep general

# Clean up — Karpenter consolidates the now-idle nodes (consolidateAfter: 30s)
kubectl delete deployment inflate -n $NAMESPACE
kubectl get nodes -w | grep general  # in a different terminal, watch the Karpenter nodes drain and disappear 
```

> **Expected timeline:** new node visible in ~60 s after pods go Pending; node removed ~90 s
> after the inflate deployment is deleted (30 s consolidation window + drain time).
