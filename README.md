# AKS Application Network Demo

This repo provisions two AKS clusters in `eastus2`, places each cluster in a different VNet, peers the VNets, creates one Azure Kubernetes Application Network resource, installs ambient waypoints in both clusters, and deploys a sample app where `website` calls a distributed `webapi` service running in both clusters.

The deployed architecture is:

- `website` runs in `appscluster` and is exposed through a `LoadBalancer`
- `webapi` runs in both `appscluster` and `servicescluster`
- both `webapi` Services are marked global and use the namespace waypoint
- cross-cluster load balancing is handled by Azure Kubernetes Application Network and Istio ambient mode
- strict mTLS is enabled by default, with narrow `AuthorizationPolicy` rules allowing only the expected callers

## Deploy the environment

```powershell
# create the shared resource group, both VNets, both clusters, VNet peering,
# AppNet membership, ambient namespace labels, and default waypoints
.\setup.ps1
```

`setup.ps1` now performs these common bootstrap steps for both clusters:

- creates the AKS clusters and joins them to AppNet
- fetches kube contexts and converts kubeconfig auth with `kubelogin`
- labels `default` with `istio.io/dataplane-mode=ambient`
- runs `istioctl waypoint apply --enroll-namespace --wait --overwrite`

## Deploy the workloads

```powershell
# deploy the appscluster manifests
kubectl --context appscluster apply -f .\appscluster\.

# deploy the servicescluster manifests
kubectl --context servicescluster apply -f .\servicescluster\.

# verify the shared webapi service exists in both clusters
kubectl --context appscluster get svc webapi
kubectl --context servicescluster get svc webapi
```

## Validate the deployment

```powershell
# confirm webapi pods exist in both clusters
kubectl --context appscluster get pods -l app=webapi -o wide
kubectl --context servicescluster get pods -l app=webapi -o wide

# confirm the global service view contains both cluster VIPs and both backends
istioctl --context appscluster zc service -n applink-system
istioctl --context servicescluster zc service -n applink-system

# wait for the website LoadBalancer IP
kubectl --context appscluster get svc website -w
```

Open the website service's external IP once it is assigned.

`istioctl zc service` should show `webapi` with two VIPs and `ENDPOINTS 2/2`.

## Istioctl commands used here

- `istioctl waypoint apply --enroll-namespace --wait --overwrite` creates or refreshes the namespace waypoint and enrolls the namespace to use it for L7 processing.
- `istioctl --context appscluster zc service -n applink-system` shows the ambient service view from `appscluster`, including VIPs, waypoints, and merged backend counts.

## Rejoin a cluster to AppNet

`setup.ps1` already joins both clusters. If you need to rejoin `servicescluster`, use:

```powershell
$subscription = az account show --query id -o tsv
$group = "rg-appnetdemo"
$appnet = "appnetdemo"
$servicesCluster = "servicescluster"
$servicesMember = "servicesmember"
$servicesClusterId = az aks show -g $group -n $servicesCluster --query id -o tsv

# join servicescluster to the app network
az appnet member join -g $group --appnet-name $appnet --member-name $servicesMember --member-resource-id $servicesClusterId --upgrade-mode SelfManaged
```

## Concepts

### Azure Kubernetes Application Network

Azure Kubernetes Application Network connects the clusters into one multi-cluster service environment. In this repo it provides the cross-cluster service discovery and routing layer that lets `website` call a single `webapi` service name while backends live in more than one cluster.

### VNet peering

The two AKS clusters live in different VNets. VNet peering provides the east-west network reachability required for AppNet and waypoint-to-waypoint traffic between the clusters.

### Istio ambient mode

Ambient mode is the Istio data plane model used by AppNet here. Instead of sidecars in every pod, traffic is handled by shared node proxies (`ztunnel`) and optional L7 waypoint proxies. The namespace label `istio.io/dataplane-mode=ambient` enrolls workloads into this model.

### Waypoints

A waypoint is an Envoy-based proxy managed through the Kubernetes Gateway API. In this repo, each cluster has a `default/waypoint` that handles service-level L7 processing for workloads in the `default` namespace. The namespace label `istio.io/use-waypoint=waypoint` causes service traffic to use that waypoint.

### Global services

The `webapi` Service is marked with `istio.io/global="true"` in both clusters. That tells the mesh to treat both Services as one logical multi-cluster service. When the service view is healthy, `istioctl zc service` shows both cluster VIPs and the combined backend count.

### mTLS

Mutual TLS means both sides of a service-to-service connection authenticate each other. In this repo, `PeerAuthentication` defaults to `STRICT`, which requires meshed traffic to use authenticated mTLS rather than plain HTTP between workloads.

### PeerAuthentication

`PeerAuthentication` controls whether a workload accepts plain text, permissive, or strict mTLS traffic. The `default` policy in each cluster is `STRICT`, which protects the service mesh by default.

### AuthorizationPolicy

`AuthorizationPolicy` controls which authenticated callers are allowed to reach a workload. The `webapi` policies in this repo allow only the expected identities instead of allowing all traffic. Because the destination waypoint participates in the request path, the working `webapi` policy allows both:

- `cluster.local/ns/default/sa/website`
- `cluster.local/ns/default/sa/waypoint`

### Why the waypoint principal is allowed

With ambient waypoints, the request is enforced through the destination-side mesh path rather than looking like a direct pod-to-pod call all the way through. Allowing the waypoint principal keeps the policy narrow while still matching the actual authenticated path that reaches `webapi`.

## Smoke test

```powershell
# get the website LoadBalancer IP from appscluster
$websiteIp = kubectl --context appscluster -n default get svc website -o jsonpath="{.status.loadBalancer.ingress[0].ip}"

# quick smoke test from outside the cluster
curl.exe http://$websiteIp/
```