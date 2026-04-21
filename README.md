# AKS Application Network Demo

This repo provisions two AKS clusters in `eastus2`, places each cluster in a different VNet, peers the VNets, creates one Azure Kubernetes Application Network resource, and deploys a sample app where `website` calls a distributed `webapi` service with strict mTLS.

## Deploy the environment

```powershell
# create the shared resource group, both VNets, both clusters, VNet peering, and AppNet membership
.\setup.ps1
```

## Deploy the workloads

```powershell
$namespace = "demo"

# deploy the appscluster slice
kubectl --context appscluster apply -f .\workload.yaml -l topology=appscluster

# deploy the servicescluster slice
kubectl --context servicescluster apply -f .\workload.yaml -l topology=servicescluster

# verify the shared webapi service exists in both clusters
kubectl --context appscluster -n $namespace get svc webapi
kubectl --context servicescluster -n $namespace get svc webapi
```

## Join servicescluster to the app network

`setup.ps1` already joins both clusters. If you need to join `servicescluster` again, use:

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

## Move webapi fully to servicescluster

Deleting the `webapi` Service object from `appscluster` breaks `WEBAPI_URL=webapi`. Keep the Service name in `appscluster` and remove only the local backend so the request resolves cross-cluster through Application Network.

```powershell
$namespace = "demo"

# remove the local webapi backend from appscluster
kubectl --context appscluster -n $namespace delete deploy webapi-v1

# keep the webapi service name in appscluster but leave it with no local endpoints
@'
apiVersion: v1
kind: Service
metadata:
  name: webapi
  namespace: demo
  labels:
    app: webapi
    istio.io/global: "true"
spec:
  ports:
  - name: http
    port: 80
    targetPort: 80
  selector:
    app: webapi
    version: remote
'@ | kubectl --context appscluster apply -f -

# ensure the servicescluster instance is present
kubectl --context servicescluster apply -f .\workload.yaml -l topology=servicescluster
```

## Validate cross-cluster service discovery

```powershell
$namespace = "demo"

# confirm appscluster no longer has local webapi pods
kubectl --context appscluster -n $namespace get pods -l app=webapi

# confirm servicescluster hosts the remote webapi backend
kubectl --context servicescluster -n $namespace get pods -l app=webapi

# port-forward the website to test the cross-cluster call path
kubectl --context appscluster -n $namespace port-forward svc/website 8080:80
```

Open `http://localhost:8080` after the port-forward starts.