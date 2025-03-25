#!/bin/bash

set -euo pipefail

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

set -x

STEAMBOAT_ACR_NAME=${STEAMBOAT_ACR_NAME:-${ALIAS}acr}

if ! az acr show --name $STEAMBOAT_ACR_NAME --resource-group $STEAMBOAT_TEST_RESOURCE_GROUP; then
    echo "Could not find ACR \"$STEAMBOAT_ACR_NAME\" in the expected location. Creating the ACR."
    az acr create \
        --resource-group $STEAMBOAT_TEST_RESOURCE_GROUP \
        --name $STEAMBOAT_ACR_NAME \
        --sku Basic \
        --admin-enabled true
fi

set +x
PASSWORD=`az acr credential show --name $STEAMBOAT_ACR_NAME --resource-group $STEAMBOAT_TEST_RESOURCE_GROUP --query passwords[0].value -o tsv`

UNSIGNED_IMAGE=mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11
docker pull $UNSIGNED_IMAGE
TEST_IMAGE=$STEAMBOAT_ACR_NAME.azurecr.io/$ALIAS-test
docker tag $UNSIGNED_IMAGE $TEST_IMAGE

# az acr login --name $STEAMBOAT_ACR_NAME --resource-group
# $STEAMBOAT_TEST_RESOURCE_GROUP

# This tends to not work right away, so sleeping for a bit
sleep 30
# Not using az acr login, as rust oci registry logic cannot use the resulting token
docker login $STEAMBOAT_ACR_NAME.azurecr.io \
    --username $STEAMBOAT_ACR_NAME \
    --password $PASSWORD
set -x

docker push $TEST_IMAGE

$BUILD_OUT_BASE_DIR/solar \
    --image $TEST_IMAGE \
    --use-cached-files \
    --signer $SOURCE_FOLDER/ipe-kernel/kernel-ipe/ipe_cert.pem \
    --key $IPE_SIGNING_KEY \
    --passphrase pass:$IPE_SIGNING_KEY_PASSWORD \
    inject-signatures-to-image-manifest

set +x
sshCommand $VM_IP "sudo crictl pull --creds $STEAMBOAT_ACR_NAME:$PASSWORD $TEST_IMAGE"
set -x
sshCommand $VM_IP "sudo PULL_IMAGE=false run-container.sh $TEST_IMAGE"