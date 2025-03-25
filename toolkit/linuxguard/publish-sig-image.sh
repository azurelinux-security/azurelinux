#!/bin/bash

set -euxo pipefail

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

if [ ! -z ${BUILD_BUILDID:-} ]; then
    az login --identity
fi
az account set --subscription $STEAMBOAT_SUBSCRIPTION

current_date="$(date +'%y%m%d')"
current_time="$(date +'%H%M%S')"

storage_account_url="https://$STEAMBOAT_STORAGE_ACCOUNT.blob.core.windows.net"
storage_account_resource_id="/subscriptions/$STEAMBOAT_SUBSCRIPTION/resourceGroups/$STEAMBOAT_RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STEAMBOAT_STORAGE_ACCOUNT"

export STORAGE_CONTAINER_NAME="${STORAGE_CONTAINER_NAME:-$ALIAS-$BUILD_TARGET-test}"
$SCRIPTS_DIR/publish-sig-image-prepare.sh
export IMAGE_PATH=${IMAGE_PATH:-$OUT_DIR/secure-test/secure-test.vhd}

image_version=`get-image-version increment`
storage_blob_name="${current_date##+(0)}.${current_time##+(0)}-$image_version.vhd"
storage_blob_endpoint="$storage_account_url/$STORAGE_CONTAINER_NAME/$storage_blob_name"

# Get the path to the VHD file
resize_image $IMAGE_PATH

# Upload the image artifact to Steamboat Storage Account
azcopy copy "$IMAGE_PATH" "$storage_blob_endpoint"

# Create Image Version from storage account blob
az sig image-version create \
  --resource-group $STEAMBOAT_GALLERY_RESOURCE_GROUP \
  --gallery-name $STEAMBOAT_GALLERY_NAME \
  --gallery-image-definition $IMAGE_DEFINITION \
  --gallery-image-version $image_version \
  --target-regions $STEAMBOAT_TCB_PUBLISH_LOCATION \
  --os-vhd-storage-account $storage_account_resource_id \
  --os-vhd-uri "$storage_blob_endpoint"
