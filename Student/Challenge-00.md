# Challenge 00 — Prerequisites: Ready, Set, GO!

**[Home](../README.md)** — [Next Challenge >](./Challenge-01.md)

## Introduction

Before you can hack, you need the right tools. This challenge ensures your workstation (or
cloud shell) is ready with a modern cloud-native toolset for working with Azure and AKS.

## Description

Set up a working environment with all the tools required for this hackathon:

- **Azure CLI** (version 2.65 or later)
- **kubectl** — the Kubernetes CLI
- **kubelogin** — needed for Entra ID authentication with AKS
- **Helm** (version 3.14 or later) — the Kubernetes package manager
- **Flux CLI v2** — for GitOps challenges
- **Visual Studio Code** (recommended)
- **Docker Desktop** (optional — only needed for local container builds in Challenge 01)

You may complete all challenges using a local workstation (**WSL2** on Windows, macOS, or
Linux), **GitHub Codespaces**, or **Azure Cloud Shell**.

> **Hint:** `kubectl` and `kubelogin` can both be installed with a single Azure CLI command.
> Flux CLI has an official install script at [fluxcd.io/flux/installation](https://fluxcd.io/flux/installation/).

Once tools are installed, log in to your Azure subscription and verify you have the right
access level. You will also need to ensure the required Azure resource providers are registered
in your subscription.

The source code and manifests used in later challenges are available in the
[`Student/Resources/src/`](./Resources/src/) folder of this repository.

## Success Criteria

1. Running `az --version` shows Azure CLI **>= 2.65.0**
2. Running `kubectl version --client` returns a client version
3. Running `helm version` shows Helm **>= 3.14**
4. Running `flux --version` shows Flux **v2.x**
5. `az account show` returns your target subscription
6. All required resource providers are in `Registered` state

## Pre-flight Validation Checklist

1. Use this checklist before starting Challenge 01 to avoid surprises mid-hackathon:

```bash
# 1. Azure CLI version >= 2.65
az --version | head -1

# 2. Logged in and correct subscription
az account show --query "{name:name,id:id,state:state}" -o table

# 3. kubectl client available
kubectl version --client

# 4. Helm >= 3.14
helm version

# 5. Flux v2
flux --version
```

2. Verify the required Azure resource providers (`Microsoft.ContainerService`,
   `Microsoft.Monitor`, `Microsoft.Dashboard`, `Microsoft.KubernetesConfiguration`,
   `Microsoft.ContainerRegistry`, `Microsoft.Network`, `Microsoft.Insights`) are registered in
   your subscription.

```bash
az provider list \
  --query "[?namespace=='Microsoft.ContainerService' || namespace=='Microsoft.Monitor' \
  || namespace=='Microsoft.Dashboard' || namespace=='Microsoft.KubernetesConfiguration' \
  || namespace=='Microsoft.ContainerRegistry' || namespace=='Microsoft.Network' \
  || namespace=='Microsoft.Insights'].{Provider:namespace, State:registrationState}" \
  -o table
```

Look for `Registered`. To register any that show `NotRegistered`:

```bash
az provider register --namespace <NAMESPACE>
```
   
3. Confirm you have at least 16 available Standard D-series vCPU quota in your target Azure
   region.

```bash
az vm list-usage --location <REGION> --query "[?contains(name.localizedValue, 'Standard DSv') || contains(name.localizedValue, 'Standard Dv')].{Name:name.localizedValue, Used:currentValue, Limit:limit}" --output table
```


## Learning Resources

- [Install Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [Install kubectl and kubelogin](https://learn.microsoft.com/azure/aks/learn/quick-kubernetes-deploy-cli)
- [Install Helm](https://helm.sh/docs/intro/install/)
- [Install Flux CLI](https://fluxcd.io/flux/installation/)
- [Azure Cloud Shell overview](https://learn.microsoft.com/azure/cloud-shell/overview)
- [Azure resource providers](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-providers-and-types)
