$subscription = az account show --query id -o tsv
$location = "eastus2"
$group = "rg-aks-appnet"
$appnet = "appnet"
$appsCluster = "appscluster"
$servicesCluster = "servicescluster"
$appsMember = "appsmember"
$servicesMember = "servicesmember"
$appsVnet = "appsVnet"
$servicesVnet = "servicesVnet"
$appsSubnet = "aks"
$servicesSubnet = "aks"

# fetch user id for role assignment
$userId = az ad signed-in-user show -o tsv --query id

# register preview bits
az feature register `
    --namespace Microsoft.AppLink `
    --name PublicPreview `
    --subscription $subscription

az provider register `
    --namespace Microsoft.AppLink `
    --subscription $subscription

az extension add --name appnet-preview --upgrade

# create the shared resource group that holds both clusters, both VNets, and AppNet
az group create -n $group -l $location

# create separate VNets and AKS subnets so each cluster lives on its own network
az network vnet create `
    -g $group `
    -n $appsVnet `
    -l $location `
    --address-prefixes 10.10.0.0/16 `
    --subnet-name $appsSubnet `
    --subnet-prefixes 10.10.0.0/24

az network vnet create `
    -g $group `
    -n $servicesVnet `
    -l $location `
    --address-prefixes 10.20.0.0/16 `
    --subnet-name $servicesSubnet `
    --subnet-prefixes 10.20.0.0/24

$appsVnetId = az network vnet show -g $group -n $appsVnet --query id -o tsv
$servicesVnetId = az network vnet show -g $group -n $servicesVnet --query id -o tsv

# peer the two VNets so AppNet east-west traffic can flow between clusters
az network vnet peering create `
    -g $group `
    -n appsToServices `
    --vnet-name $appsVnet `
    --remote-vnet $servicesVnetId `
    --allow-vnet-access true `
    --allow-forwarded-traffic true

az network vnet peering create `
    -g $group `
    -n servicesToApps `
    --vnet-name $servicesVnet `
    --remote-vnet $appsVnetId `
    --allow-vnet-access true `
    --allow-forwarded-traffic true

$appsSubnetId = az network vnet subnet show -g $group --vnet-name $appsVnet -n $appsSubnet --query id -o tsv
$servicesSubnetId = az network vnet subnet show -g $group --vnet-name $servicesVnet -n $servicesSubnet --query id -o tsv

# create one AKS cluster per VNet with Azure RBAC and OIDC enabled for AppNet/Istio
$appsClusterId = az aks create `
    -g $group `
    -n $appsCluster `
    -l $location `
    --enable-aad `
    --enable-azure-rbac `
    --enable-oidc-issuer `
    --enable-managed-identity `
    --generate-ssh-keys `
    --network-plugin azure `
    --vnet-subnet-id $appsSubnetId `
    --node-count 1 `
    --tier free `
    --query id `
    -o tsv

$servicesClusterId = az aks create `
    -g $group `
    -n $servicesCluster `
    -l $location `
    --enable-aad `
    --enable-azure-rbac `
    --enable-oidc-issuer `
    --enable-managed-identity `
    --generate-ssh-keys `
    --network-plugin azure `
    --vnet-subnet-id $servicesSubnetId `
    --node-count 1 `
    --tier free `
    --query id `
    -o tsv

# assign current user admin RBAC access to cluster apps cluster
az role assignment create `
    --assignee $userId `
    --role "Azure Kubernetes Service RBAC Cluster Admin" `
    --scope $appsClusterId

# assign current user admin RBAC access to cluster services cluster
az role assignment create `
    --assignee $userId `
    --role "Azure Kubernetes Service RBAC Cluster Admin" `
    --scope $servicesClusterId

# create AppNet and wait for it to exist
az appnet create `
    -g $group `
    -n $appnet `
    -l $location `
    --identity-type SystemAssigned

az appnet wait -g $group -n $appnet --created

$appsClusterId = az aks show -g $group -n $appsCluster --query id -o tsv
$servicesClusterId = az aks show -g $group -n $servicesCluster --query id -o tsv

# join the member clusters
az appnet member join `
    -g $group `
    --appnet-name $appnet `
    --member-name $appsMember `
    --member-resource-id $appsClusterId `
    --upgrade-mode SelfManaged `
    --version 1.4

az appnet member join `
    -g $group `
    --appnet-name $appnet `
    --member-name $servicesMember `
    --member-resource-id $servicesClusterId `
    --upgrade-mode SelfManaged `
    --version 1.4

# fetch kube contexts for both clusters so kubectl and istioctl can address them by name
az aks get-credentials -g $group -n $appsCluster --overwrite-existing --context $appsCluster
az aks get-credentials -g $group -n $servicesCluster --overwrite-existing --context $servicesCluster

# convert kubeconfigs to Azure CLI auth so cluster access stays tied to the signed-in user
kubelogin convert-kubeconfig -l azurecli

# enable ambient mode on the default namespace in each cluster
kubectl --context $appsCluster label namespace default istio.io/dataplane-mode=ambient --overwrite
kubectl --context $servicesCluster label namespace default istio.io/dataplane-mode=ambient --overwrite

# create or refresh the default waypoint in each cluster and enroll the namespace to use it
istioctl --context $appsCluster waypoint apply --enroll-namespace --wait --overwrite
istioctl --context $servicesCluster waypoint apply --enroll-namespace --wait --overwrite