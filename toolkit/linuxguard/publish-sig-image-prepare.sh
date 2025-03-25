#!/bin/bash

set -euxo pipefail

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

if [ ! -z ${BUILD_BUILDID:-} ]; then
    az login --identity
fi
az account set --subscription $STEAMBOAT_SUBSCRIPTION

if [ -z ${STORAGE_CONTAINER_NAME:-} ]; then
    echo "STORAGE_CONTAINER_NAME is not set. Exiting..."
    exit 1
fi

if [ -z ${IMAGE_DEFINITION:-} ]; then
    echo "IMAGE_DEFINITION is not set. Exiting..."
    exit 1
fi

if [ "`az group exists -n $STEAMBOAT_RESOURCE_GROUP`" == "false" ]; then
    az group create \
        --name $STEAMBOAT_RESOURCE_GROUP \
        --location $STEAMBOAT_TCB_PUBLISH_LOCATION
fi
if [ "`az group exists -n $STEAMBOAT_GALLERY_RESOURCE_GROUP`" == "false" ]; then
    az group create \
        --name $STEAMBOAT_GALLERY_RESOURCE_GROUP \
        --location $STEAMBOAT_TCB_PUBLISH_LOCATION
fi

# Ensure STEAMBOAT_STORAGE_ACCOUNT exists and the managed identity has access
storage_account_resource_id="/subscriptions/$STEAMBOAT_SUBSCRIPTION/resourceGroups/$STEAMBOAT_RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STEAMBOAT_STORAGE_ACCOUNT"
if ! az storage account show --ids $storage_account_resource_id; then
    echo "Could not find storage account \"$STEAMBOAT_STORAGE_ACCOUNT\" in the expected location. Creating the storage account."

    if [ "`az storage account check-name --name $STEAMBOAT_STORAGE_ACCOUNT --query nameAvailable`" == "false" ]; then
        echo "Storage account name $STEAMBOAT_STORAGE_ACCOUNT is not available"
        exit 1
    fi
    az storage account create \
        --resource-group $STEAMBOAT_RESOURCE_GROUP \
        --name $STEAMBOAT_STORAGE_ACCOUNT \
        --location $STEAMBOAT_TCB_PUBLISH_LOCATION \
        --allow-shared-key-access false
fi

# Ensure "build_target" storage container exists
containerExists=$(az storage container exists --account-name $STEAMBOAT_STORAGE_ACCOUNT --name $STORAGE_CONTAINER_NAME --auth-mode login | jq .exists)
if [[ $containerExists != "true" ]]; then
    echo "Could not find container \"$STORAGE_CONTAINER_NAME\". Creating container \"$STORAGE_CONTAINER_NAME\" in storage account \"$STEAMBOAT_STORAGE_ACCOUNT\"..."
    az storage container create \
        --account-name $STEAMBOAT_STORAGE_ACCOUNT \
        --name $STORAGE_CONTAINER_NAME \
        --auth-mode login
fi

# Ensure STEAMBOAT_GALLERY_NAME exists
if ! az sig show -r $STEAMBOAT_GALLERY_NAME -g $STEAMBOAT_GALLERY_RESOURCE_GROUP; then
    echo "Could not find image gallery \"$STEAMBOAT_GALLERY_NAME\" in resource group \"$STEAMBOAT_GALLERY_RESOURCE_GROUP\". Creating the gallery."
    az sig create \
        --resource-group $STEAMBOAT_GALLERY_RESOURCE_GROUP \
        --gallery-name $STEAMBOAT_GALLERY_NAME \
        --location $STEAMBOAT_TCB_PUBLISH_LOCATION
fi

# Ensure the "build_target" image-definition exists
# Note: We publish only the VHD from the secure-prod the SIG
imageDefinitionExists=$(az sig image-definition list -r $STEAMBOAT_GALLERY_NAME -g $STEAMBOAT_GALLERY_RESOURCE_GROUP | grep "name" | grep -c "$IMAGE_DEFINITION" || :;) # the "|| :;" prevents grep from halting the script when it finds no matches and exits with exit code 1
if [[ $imageDefinitionExists -eq 0 ]]; then
    echo "Could not find image-definition \"$IMAGE_DEFINITION\". Creating definition \"$IMAGE_DEFINITION\" in gallery \"$STEAMBOAT_GALLERY_NAME\"..."
    az sig image-definition create \
        --gallery-image-definition $IMAGE_DEFINITION \
        --publisher $PUBLISHER \
        --offer $OFFER \
        --sku $IMAGE_DEFINITION \
        --gallery-name $STEAMBOAT_GALLERY_NAME \
        --resource-group $STEAMBOAT_GALLERY_RESOURCE_GROUP \
        --os-type Linux \
        --features SecurityType=TrustedLaunchSupported
fi

if ! which azcopy; then
    # Install az-copy dependency
    pipeline_agent_os="$(cat "/etc/os-release" | grep "^ID=" | cut -d = -f 2)"
    pipeline_agent_os_version="$(cat "/etc/os-release" | grep "^VERSION_ID=" | cut -d = -f 2 | tr -d '"')"
    azcopy_download_url="https://packages.microsoft.com/config/$pipeline_agent_os/$pipeline_agent_os_version/packages-microsoft-prod.deb"
    curl -sSL -O $azcopy_download_url
    CURL_STATUS=$?
    if [ $CURL_STATUS -ne 0 ]; then
    echo "Failed to download the debian package repo while attempting to install azcopy. The URL \"$azcopy_download_url\" returned the curl exit status: $CURL_STATUS"
    echo "Suggestion: Are you using a new, non-ubuntu, pipeline agent? If yes, add azcopy installation logic for the new build agent."
    exit 1
    fi
    sudo dpkg -i packages-microsoft-prod.deb
    rm packages-microsoft-prod.deb
    sudo apt-get update -y
    sudo apt-get install azcopy -y
    azcopy --version
    AZCOPY_STATUS=$?
    if [ $AZCOPY_STATUS -ne 0 ]; then
        echo "Failed to install azcopy."
        exit 1
    fi
fi
