#!/bin/bash

set -euo pipefail

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

mkdir -p ${BUILD_DIR}

pushd ${BUILD_DIR}

AZL_CORE_VERSION=$(get_azl_core_version $BUILD_TARGET)
AZL_CORE_IMAGE_FEED=$(get_azl_core_image_feed $BUILD_TARGET)
AZL_CORE_IMAGE_PATH=$(get_azl_core_image_path $BUILD_TARGET)

log "copy base VHD"
az artifacts universal download \
    --organization "https://dev.azure.com/mariner-org/" \
    --project "mariner" \
    --scope project \
    --feed "AzureLinuxArtifacts" \
    --name "$AZL_CORE_IMAGE_FEED" \
    --version "$AZL_CORE_VERSION" \
    --path .
if [ ! -f "$AZL_CORE_IMAGE_PATH" ]; then
    log "Error: Failed to download base VHD"
    exit 1
fi

pushd $SOURCE_FOLDER/src/secure-base

log "Download Trident RPMs"
az artifacts universal download \
    --organization "https://dev.azure.com/mariner-org/" \
    --project "2311650c-e79e-4301-b4d2-96543fdd84ff" \
    --scope project \
    --feed "Trident" \
    --name $AZL_TRIDENT_ARTIFACT_NAME \
    --version $AZL_TRIDENT_VERSION \
    --path "$RPMS_DIR"

log "Download OCI signature verification RPM"
az artifacts universal download \
    --organization "https://dev.azure.com/mariner-org/" \
    --project "35b0a256-0737-4c9a-ba3e-24b6fbd43188" \
    --scope project \
    --feed "oci-container-artifacts" \
    --name "oci-signature-verification" \
    --version "1.0.0" \
    --path "$RPMS_DIR"

log "Download notation cli binaries"
az artifacts universal download \
    --organization "https://dev.azure.com/mariner-org/" \
    --project "35b0a256-0737-4c9a-ba3e-24b6fbd43188" \
    --scope project \
    --feed "oci-container-artifacts" \
    --name "notation-cli" \
    --version "0.0.1" \
    --path "$SOURCE_FOLDER/src/secure-base/files/oci"

log "Download kernel-ipe"
IPE_KERNEL_BUILD_PIPELINE=4001
CACHE_PATH=/tmp/kernel-ipe
# PIPELINE_LAST_RUN=`az pipelines runs list \
#     --org 'https://dev.azure.com/mariner-org' \
#     --project "mariner" \
#     --pipeline-ids $IPE_KERNEL_BUILD_PIPELINE \
#     --branch main \
#     --query-order QueueTimeDesc \
#     --result succeeded \
#     --reason triggered \
#     --top 1 \
#     --query '[0].id'`
PIPELINE_LAST_RUN=767965
echo PIPELINE RUN ID: $PIPELINE_LAST_RUN
rm -rf $CACHE_PATH
mkdir -p $CACHE_PATH
az pipelines runs artifact download \
    --org 'https://dev.azure.com/mariner-org' \
    --project "mariner" \
    --run-id $PIPELINE_LAST_RUN \
    --path $CACHE_PATH \
    --artifact-name 'drop_publish_kernel_rpm_publish_kernel'
tar -xf $CACHE_PATH/packages/rpms.tar.gz -C $CACHE_PATH
find $CACHE_PATH -type f -name "*.rpm" -exec mv {} $RPMS_DIR \;
