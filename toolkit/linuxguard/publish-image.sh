#!/bin/bash

shopt -s extglob
set -euxo pipefail

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

if [ ! -z ${BUILD_BUILDID:-} ]; then
    az login --identity
fi
az account set --subscription $STEAMBOAT_SUBSCRIPTION

IMAGE_BUILD_BRANCH="${IMAGE_BUILD_BRANCH:=unofficial}"
if [[ $IMAGE_BUILD_BRANCH == "refs/heads/main" ]]; then
    image_definition_base="secure-base-$BUILD_TARGET"
    image_definition_base_update="secure-base-update-$BUILD_TARGET"
    image_definition_prod="secure-prod-$BUILD_TARGET"
    image_definition_prod_update="secure-prod-update-$BUILD_TARGET"
    tools="tools"
else
    echo "Unexpected branch for image publishing. Images can only be published from the main branch."
    exit 1
fi
image_version=`get-image-version increment` # If this scheme changes, update the documentation at the head of the pipeline yaml
# Note: secure-base images are in qcow2 format. These will be published to universal artifacts but not to SIG.
#       secure-prod image in the vhd format will be published to the SIG as well as universal artifacts.


export STORAGE_CONTAINER_NAME="$BUILD_TARGET"
export IMAGE_DEFINITION="$image_definition_prod"
export IMAGE_PATH=$ARTIFACT_DOWNLOAD_DIR/image/secure-prod/secure-prod.vhd
$SCRIPTS_DIR/publish-sig-image.sh

### Publish secure-prod image to universal artifacts

feedname=""
if [ $AZL_VERSION == '3.0' ]; then
    feedname="linux_code_integrity-3.0-stable"
else
    echo "Unexpected AZL_VERSION when attempting to set feed name for publishing: '$AZL_VERSION'"
    exit 1
fi

az artifacts universal publish \
  --organization https://dev.azure.com/mariner-org/ \
  --project="mariner" \
  --scope project \
  --feed "$feedname" \
  --name "$image_definition_prod" \
  --version "$image_version" \
  --description "Azure Linux Secure Prod Image [secure-prod] $AZL_VERSION." \
  --path "$IMAGE_PATH"


### Publish secure-prod update image to universal artifacts

# Get the path to the qcow2 prod update image file
SECURE_PROD_UPDATE_PATH="$ARTIFACT_DOWNLOAD_DIR/update/secure-prod"
pushd $ARTIFACT_DOWNLOAD_DIR/update/secure-prod || { echo "Could not find artifact directory:
\"$ARTIFACT_DOWNLOAD_DIR\"/update/secure-prod"; exit 1; }


popd || { echo "Could not exit artifact directory: \"$ARTIFACT_DOWNLOAD_DIR\"/update/secure-prod"; exit 1; }

az artifacts universal publish \
  --organization https://dev.azure.com/mariner-org/ \
  --project="mariner" \
  --scope project \
  --feed "$feedname" \
  --name "$image_definition_prod_update" \
  --version "$image_version" \
  --description "Azure Linux Secure Prod Update Image [secure-prod] $AZL_VERSION." \
  --path "$SECURE_PROD_UPDATE_PATH"

### Publish secure-base main and update images to universal artifacts

# Get the path to the qcow2 base image file
pushd $ARTIFACT_DOWNLOAD_DIR/image/secure-base || { echo "Could not find artifact directory: \"$ARTIFACT_DOWNLOAD_DIR\"/image/secure-base"; exit 1; }
qcow_base_file=$(find . -maxdepth 3 -type f -name "*.qcow2")
file_count=$(echo "$qcow_base_file" | wc -l)

if [ "$file_count" -ne 1 ]; then
    echo "Error: There are $file_count .qcow2 files. There should be exactly one in the artifact directory: \"$ARTIFACT_DOWNLOAD_DIR\"/image/secure-base"
    exit 1
fi
qcow2_base_absolute_path=$(realpath "$qcow_base_file")

popd || { echo "Could not exit artifact directory: \"$ARTIFACT_DOWNLOAD_DIR\"/image/secure-base"; exit 1; }

# Get the path to the qcow2 update image file
pushd $ARTIFACT_DOWNLOAD_DIR/update/secure-base || { echo "Could not find artifact directory: \"$ARTIFACT_DOWNLOAD_DIR\"/update/secure-base"; exit 1; }
qcow_update_file=$(find . -maxdepth 3 -type f -name "*.qcow2")
file_count=$(echo "$qcow_update_file" | wc -l)

if [ "$file_count" -ne 1 ]; then
    echo "Error: There are $file_count .qcow2 files. There should be exactly one in the artifact directory: \"$ARTIFACT_DOWNLOAD_DIR\"/update/secure-base"
    exit 1
fi
qcow2_update_absolute_path=$(realpath "$qcow_update_file")

popd || { echo "Could not exit artifact directory: \"$ARTIFACT_DOWNLOAD_DIR\"/update/secure-base"; exit 1; }

az artifacts universal publish \
  --organization https://dev.azure.com/mariner-org/ \
  --project="mariner" \
  --scope project \
  --feed "$feedname" \
  --name "$image_definition_base" \
  --version "$image_version" \
  --description "Azure Linux Secure Base Image [secure-base] $AZL_VERSION." \
  --path "$qcow2_base_absolute_path"

az artifacts universal publish \
  --organization https://dev.azure.com/mariner-org/ \
  --project="mariner" \
  --scope project \
  --feed "$feedname" \
  --name "$image_definition_base_update" \
  --version "$image_version" \
  --description "Azure Linux Secure Base Update Image [secure-base] $AZL_VERSION." \
  --path "$qcow2_update_absolute_path"

# No need to publish more than once
if [ "$BUILD_TARGET" == "uki" ]; then
    pushd $PACKAGES_ARTIFACT_DOWNLOAD_DIR/tools || { echo "Could not find artifact directory: \"$PACKAGES_ARTIFACT_DOWNLOAD_DIR\"/tools"; exit 1; }
    tool_file=$(find . -maxdepth 3 -type f -name "solar")
    file_count=$(echo "$tool_file" | wc -l)

    if [ "$file_count" -ne 1 ]; then
        echo "Error: There are $file_count files. There should be exactly one in the artifact directory: \"$PACKAGES_ARTIFACT_DOWNLOAD_DIR\"/tools"
        exit 1
    fi
    solar_absolute_path=$(realpath "$tool_file")

    az artifacts universal publish \
      --organization https://dev.azure.com/mariner-org/ \
      --project="mariner" \
      --scope project \
      --feed "$feedname" \
      --name "$tools" \
      --version "$image_version" \
      --description "Azure Linux Helper Tools." \
      --path "$solar_absolute_path"

    popd || { echo "Could not exit artifact directory: \"$PACKAGES_ARTIFACT_DOWNLOAD_DIR\"/tools"; exit 1; }
fi