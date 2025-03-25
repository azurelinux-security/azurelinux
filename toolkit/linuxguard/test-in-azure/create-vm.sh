#!/bin/bash

set -euxo pipefail

# Include the common functions and variables
. $(dirname $0)/common.sh

if [ $LOGIN -eq 1 ]; then
  az-login
fi

# Delete the RG if it exists
if [ "`az group exists -n $VM_RG_NAME`" == "true" ]; then
  az group delete -n $VM_RG_NAME -y
fi

az group create -n $VM_RG_NAME -l $R_NAME

VERSION=$(get-latest-version $G_RG_NAME $G_NAME $I_NAME)
az vm create \
  -g $VM_RG_NAME \
  -n $VM_NAME \
  --os-disk-size-gb 60 \
  --admin-username $VM_USER \
  --ssh-key-values ~/.ssh/id_rsa.pub \
  --image /subscriptions/$SUB_ID/resourceGroups/$G_RG_NAME/providers/Microsoft.Compute/galleries/$G_NAME/images/$I_NAME/versions/$VERSION -l $R_NAME
az vm boot-diagnostics enable --name $VM_NAME -g $VM_RG_NAME

VM_IP=`az vm show -d -g $VM_RG_NAME -n $VM_NAME --query publicIps -o tsv`

# Connect to the system
ssh $VM_USER@$VM_IP