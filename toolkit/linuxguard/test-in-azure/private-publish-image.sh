#!/bin/bash

set -euxo pipefail

# Include the common functions and variables
. $(dirname $0)/common.sh

if [ $LOGIN -eq 1 ]; then
  az-login 1
fi

DOWNLOAD=${DOWNLOAD:-1}

if [ $DOWNLOAD -eq 1 ]; then
  # Download the image from pipeline
  RUN_ID=$(az pipelines runs list \
      --org $IMAGE_PIPELINE_ORG \
      --project "$IMAGE_PIPELINE_PROJECT" \
      --pipeline-ids $IMAGE_PIPELINE_ID \
      --branch $IMAGE_PIPELINE_BRANCH \
      --query-order QueueTimeDesc \
      --result succeeded \
      --reason triggered \
      --top 1 \
      --query '[0].id')
  echo PIPELINE RUN ID: $RUN_ID
  mkdir -p $ARTIFACTS_DIR
  az pipelines runs artifact download \
    --org $IMAGE_PIPELINE_ORG \
    --project "$IMAGE_PIPELINE_PROJECT" \
    --run-id $RUN_ID \
    --path $ARTIFACTS_DIR \
    --artifact-name $IMAGE_ARTIFACT_NAME
fi

IMAGE_PATH=$ARTIFACTS_DIR/$IMAGE_ARTIFACT_PATH
IMAGE_FILENAME=$(basename $IMAGE_PATH)

az account set --subscription $SUB_ID

# The storage account might be already created, so we need to check for its existence
if [ "`az group exists -n $SA_RG_NAME`" == "false" ]; then
  az group create -n $SA_RG_NAME -l $R_NAME
fi
# Also check that the storage account is present in the expected resource group
if [ "`az storage account list -g $SA_RG_NAME --query "[?name=='$SA_NAME']" --output tsv`" == "" ]; then
  if [ "`az storage account check-name --name $SA_NAME --query nameAvailable`" == "false" ]; then
    echo "Storage account name $SA_NAME is not available"
    exit 1
  fi
  az storage account create -g $SA_RG_NAME -n $SA_NAME -l $R_NAME --allow-shared-key-access false
fi
az storage container create -g $SA_RG_NAME --account-name $SA_NAME -n $SAC_NAME --auth-mode login

# Note, you will need a `Storage Blob Data Contributor` role to run this command, and it fails
# with a zero exit code if you don't have the role, so the failure will only be
# detected as part of sig image-version create.
azcopy copy $IMAGE_PATH https://$SA_NAME.blob.core.windows.net/$SAC_NAME

# Prepare the Shared Image Gallery
az group create -n $G_RG_NAME -l $R_NAME
az sig create -g $G_RG_NAME -r $G_NAME -l $R_NAME
az sig image-definition create -g $G_RG_NAME -r $G_NAME -i $I_NAME --os-type Linux --publisher jiria --offer $O_NAME --sku Test
# Find the first available version number
VERSION=$(get-latest-version $G_RG_NAME $G_NAME $I_NAME)
if [ -z $VERSION ]; then
  VERSION=0.0.1
else
  # Increment the semver version
  VERSION=$(echo $VERSION | awk -F. '{print $1"."$2"."$3+1}')
fi
az sig image-version create \
  --resource-group $G_RG_NAME \
  --gallery-name $G_NAME \
  --gallery-image-definition $I_NAME \
  --gallery-image-version $VERSION \
  --target-regions $R_NAME \
  --os-vhd-storage-account /subscriptions/$SUB_ID/resourceGroups/$SA_RG_NAME/providers/Microsoft.Storage/storageAccounts/$SA_NAME \
  --os-vhd-uri https://$SA_NAME.blob.core.windows.net/$SAC_NAME/$IMAGE_FILENAME
