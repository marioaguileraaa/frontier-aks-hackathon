# Challenge 01 — Containers & Azure Container Registry

[< Previous Challenge](./Challenge-00.md) — **[Home](../README.md)** — [Next Challenge >](./Challenge-02.md)

## Introduction

Every cloud-native journey starts with a container. In this challenge you will package the
**FabTechOps** application into Docker container images, store them in a private registry,
and verify they are ready for deployment to Kubernetes.

## Description

The application source code is available in [`Student/Resources/src/`](https://github.com/microsoft/frontier-aks-hackathon/tree/main/Student/Resources/src).

- Create a new **Azure Resource Group** for all resources used in this hackathon.
- Deploy an **Azure Container Registry (ACR)** with **Premium SKU** — required for private
  endpoints (Challenge 11) and geo-replication. Standard SKU will block you later.
- Build container images for the **API** and **Web** components of FabTechOps and publish
  them to your ACR. You can build locally with Docker or use **ACR Tasks** to build in the cloud.
  - **Hint:** ACR Tasks let you build images directly from source without a local Docker daemon.
- Verify that both images are stored in the registry and can be listed.

> **Note:** If you don't have Docker Desktop installed locally, ACR Tasks are the way to go.
> You will need to understand how to authenticate to ACR without storing a password.

## Success Criteria

1. An Azure Container Registry exists in your resource group.
2. Both `fabtech-api:v1` and `fabtech-web:v1` images are in the registry.
3. Demonstrate that you can list the repositories in your ACR.
4. Explain to your coach the difference between building images locally vs. using ACR Tasks, and when you would choose each approach.

## Learning Resources

- [Azure Container Registry overview](https://learn.microsoft.com/azure/container-registry/container-registry-intro)
- [ACR service tiers](https://learn.microsoft.com/azure/container-registry/container-registry-skus)
- [Build images with ACR Tasks](https://learn.microsoft.com/azure/container-registry/container-registry-tutorial-quick-task)
- [ACR authentication](https://learn.microsoft.com/azure/container-registry/container-registry-authentication)
