#!/bin/bash

set -euxo pipefail

ALIAS=`whoami`
LOCATION=eastus
RG_NAME_A=$ALIAS-aks
RG_NAME_B=$ALIAS-aks-b
CLUSTER_NAME=aksipe

# Check if $RG_NAME_A exists
if [ $(az group exists --name $RG_NAME_A) = true ]; then
	RG_NAME=$RG_NAME_A
	RG_NAME_NEXT=$RG_NAME_B
else
	RG_NAME=$RG_NAME_B
	RG_NAME_NEXT=$RG_NAME_A
fi

# Check that $RG_NAME_NEXT does not exist
if [ $(az group exists --name $RG_NAME_NEXT) = true ]; then
	echo "Resource group $RG_NAME_NEXT already exists. Exiting."
	exit 1
fi

# az feature show --namespace Microsoft.ContainerService --name AKSHTTPCustomFeatures
az account set --subscription b8f169b2-5b23-444a-ae4b-19a31b5e3652

# Delete the RG if it exists
if [ $(az group exists --name $RG_NAME) = true ]; then
	az group delete --name $RG_NAME --yes --no-wait
fi
RG_NAME=$RG_NAME_NEXT

az group create --name $RG_NAME --location $LOCATION
az aks create \
	--resource-group $RG_NAME \
	--name $CLUSTER_NAME \
	--node-count 1 \
	--node-vm-size Standard_D4ads_v5 \
	--ssh-key-value ~/.ssh/id_rsa.pub \
	 --aks-custom-headers AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,OSImageSubscriptionID=b8f169b2-5b23-444a-ae4b-19a31b5e3652,OSImageResourceGroup=hebebermsouthcentralus,OSImageGallery=hebebermsouthcentralus,OSImageName=azlsec,OSImageVersion=0.0.56,OSSKU=AzureLinux

# After about 5 minutes cluster creation should complete, grab the kubernetes credentials.
az aks get-credentials --resource-group $RG_NAME --name $CLUSTER_NAME --overwrite-existing

./connect-aks.sh
