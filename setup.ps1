$subscription = az account show --query id -o tsv
$location = "eastus2"
$group = "rg-appnetdemo"
$appnet = "appnetdemo"
$appsCluster = "appscluster"
$servicesCluster = "servicescluster"
$appsMember = "appsmember"
$servicesMember = "servicesmember"
$appsVnet = "appsVnet"
$servicesVnet = "servicesVnet"
$appsSubnet = "aks"
$servicesSubnet = "aks"

# register preview bits
az feature register --namespace Microsoft.AppLink --name PublicPreview --subscription $subscription
az provider register --namespace Microsoft.AppLink --subscription $subscription
az extension add --name appnet-preview --upgrade
az account set -s $subscription

# create resource groups
az group create -n $group -l $location

# create vnets and subnets
az network vnet create -g $group -n $appsVnet -l $location --address-prefixes 10.10.0.0/16 --subnet-name $appsSubnet --subnet-prefixes 10.10.0.0/24
az network vnet create -g $group -n $servicesVnet -l $location --address-prefixes 10.20.0.0/16 --subnet-name $servicesSubnet --subnet-prefixes 10.20.0.0/24
$appsVnetId = az network vnet show -g $group -n $appsVnet --query id -o tsv
$servicesVnetId = az network vnet show -g $group -n $servicesVnet --query id -o tsv

# peer the two vnets (required)
az network vnet peering create -g $group -n appsToServices --vnet-name $appsVnet --remote-vnet $servicesVnetId --allow-vnet-access true --allow-forwarded-traffic true
az network vnet peering create -g $group -n servicesToApps --vnet-name $servicesVnet --remote-vnet $appsVnetId --allow-vnet-access true --allow-forwarded-traffic true
$appsSubnetId = az network vnet subnet show -g $group --vnet-name $appsVnet -n $appsSubnet --query id -o tsv
$servicesSubnetId = az network vnet subnet show -g $group --vnet-name $servicesVnet -n $servicesSubnet --query id -o tsv

# create aks clusters in separate vnets
az aks create -g $group -n $appsCluster -l $location --enable-aad --enable-oidc-issuer --enable-managed-identity --generate-ssh-keys --network-plugin azure --vnet-subnet-id $appsSubnetId --node-count 1 --tier free
az aks create -g $group -n $servicesCluster -l $location --enable-aad --enable-oidc-issuer --enable-managed-identity --generate-ssh-keys --network-plugin azure --vnet-subnet-id $servicesSubnetId --node-count 1 --tier free

# create app network and join both clusters
az appnet create -g $group -n $appnet -l $location --identity-type SystemAssigned
$appsClusterId = az aks show -g $group -n $appsCluster --query id -o tsv
$servicesClusterId = az aks show -g $group -n $servicesCluster --query id -o tsv
az appnet member join -g $group --appnet-name $appnet --member-name $appsMember --member-resource-id $appsClusterId --upgrade-mode SelfManaged
az appnet member join -g $group --appnet-name $appnet --member-name $servicesMember --member-resource-id $servicesClusterId --upgrade-mode SelfManaged

# fetch kube contexts
az aks get-credentials -g $group -n $appsCluster --overwrite-existing --context $appsCluster
az aks get-credentials -g $group -n $servicesCluster --overwrite-existing --context $servicesCluster