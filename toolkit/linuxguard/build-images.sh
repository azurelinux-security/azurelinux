#!/bin/bash

set -euo pipefail

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

mkdir -p ${BUILD_DIR}
mkdir -p ${OUT_DIR}/secure-base
mkdir -p ${OUT_DIR}/secure-prod

ONLY_BASE_IMAGE=${ONLY_BASE_IMAGE:-false}
ONLY_BASE_IMAGES=${ONLY_BASE_IMAGES:-false}

MIC_CONFIG=$BUILD_TARGET-config.yaml

pushd $SOURCE_FOLDER/src/secure-prod

# Derive Trident host status from the base image MIC config
$SOURCE_FOLDER/src/build_scripts/generate-host-status-template.py $BUILD_TARGET-config.yaml files/trident/host_status.yaml

popd

pushd $SOURCE_FOLDER/src/secure-base

# Derive Trident host status from the base image MIC config
$SOURCE_FOLDER/src/build_scripts/generate-host-status-template.py $BUILD_TARGET-config.yaml files/trident/host_status.yaml

popd

log "Using the following MIC Config:"
cat $SOURCE_FOLDER/src/secure-prod/$MIC_CONFIG

ls $RPMS_DIR
CONFIG_SOURCE_BASE=$BUILD_DIR/src/secure-base
CONFIG_SOURCE_PROD=$BUILD_DIR/src/secure-prod

ls $SOURCE_FOLDER/src/secure-base/files/oci

cp -rT "$SOURCE_FOLDER/src" "$BUILD_DIR/src"

# If the key password is not set, fail as we cannot sign the root hash later on
if [[ -z ${IPE_SIGNING_KEY_PASSWORD:-} ]]; then
    log "IPE signing key password not set, aborting."
    exit 1
fi

log "Running MIC to generate the secure-base main image"
SECURE_BASE_MAIN_IMAGE_PATH=$OUT_DIR/secure-base/secure-base.qcow2
SECURE_BASE_MAIN_UNSIGNED_IMAGE_PATH=$OUT_DIR/secure-base/secure-base-unsigned.qcow2
docker run --rm \
    --privileged \
    -v "$BUILD_OUT_BASE_DIR:$BUILD_OUT_BASE_DIR:z" \
    -v "/dev:/dev" \
    "$PRISM_CONTAINER_URL" \
    imagecustomizer \
        --build-dir "$BUILD_DIR" \
        --config-file "$CONFIG_SOURCE_BASE/$MIC_CONFIG" \
        --image-file "$AZL_CORE_IMAGE_PATH" \
        --log-level "debug" \
        --output-image-format "qcow2" \
        --output-image-file "$SECURE_BASE_MAIN_IMAGE_PATH" \
        --rpm-source "$RPMS_DIR"

if [[ $ONLY_BASE_IMAGE == "true" ]]; then
    log "Only main image was requested. Skipping update image generation."
    exit 0
fi

# Publish secure-base main image artifacts
if [[ -n $ARTIFACT_PUBLISH_DIR ]]; then
    log "Publishing secure base build artifacts..."
    VM_IMAGE_PUBLISH_DIR=$ARTIFACT_PUBLISH_DIR/image
    mkdir -p $VM_IMAGE_PUBLISH_DIR/secure-base
    cp $OUT_DIR/secure-base/secure-base.qcow2 $VM_IMAGE_PUBLISH_DIR/secure-base/secure-base.qcow2
    if [[ ! -f $VM_IMAGE_PUBLISH_DIR/secure-base/secure-base.qcow2 ]]; then
        log "[Error] A qcow2 image was expected in the publishing directory but was not found."
        exit 1
    fi
fi

log "Running MIC to generate the secure-base update images"
SECURE_BASE_UPDATE_IMAGE_PATH=$OUT_DIR/secure-base/secure-base-update.qcow2
docker run --rm \
    --privileged \
    -v "$BUILD_OUT_BASE_DIR:$BUILD_OUT_BASE_DIR:z" \
    -v "/dev:/dev" \
    "$PRISM_CONTAINER_URL" \
    imagecustomizer \
        --build-dir "$BUILD_DIR" \
        --config-file "$CONFIG_SOURCE_BASE/$BUILD_TARGET-update-config.yaml" \
        --image-file "$SECURE_BASE_MAIN_IMAGE_PATH" \
        --rpm-source "$RPMS_DIR" \
        --output-image-format "qcow2" \
        --output-image-file "$SECURE_BASE_UPDATE_IMAGE_PATH" \
        --log-level "debug"

if [[ $ONLY_BASE_IMAGES == "true" ]]; then
    log "Only secure-base images were requested. Skipping secure-prod image generation."
    exit 0
fi

# TODO do not inject update-config.yaml into secure-prod image, only
# secure-test image

log "Running MIC to generate the secure-prod main image"

BASE_HASH_FILE_NAME="root-a.hash"
BASE_NON_SIGNED_HASH_FILES_PATH="$OUT_DIR/secure-prod/main/non-signed-root-hashes"
BASE_NON_SIGNED_ROOT_HASH_FILE_PATH="$BASE_NON_SIGNED_HASH_FILES_PATH/$BASE_HASH_FILE_NAME"

mkdir -p $BASE_NON_SIGNED_HASH_FILES_PATH

SECURE_PROD_MAIN_IMAGE_PATH="$OUT_DIR/secure-prod/secure-prod.vhd"
SECURE_PROD_MAIN_UNSIGNED_IMAGE_PATH="$OUT_DIR/secure-prod/secure-prod-unsigned.qcow2"

docker run --rm \
    --privileged \
    -v "$BUILD_OUT_BASE_DIR:$BUILD_OUT_BASE_DIR:z" \
    -v "/dev:/dev" \
    "$PRISM_CONTAINER_URL" \
    imagecustomizer \
        --build-dir "$BUILD_DIR" \
        --config-file "$CONFIG_SOURCE_PROD/$MIC_CONFIG" \
        --image-file "$SECURE_BASE_MAIN_IMAGE_PATH" \
        --log-level "debug" \
        --output-image-format "vhd" \
        --output-image-file "$SECURE_PROD_MAIN_UNSIGNED_IMAGE_PATH" \
        --rpm-source "$RPMS_DIR" \
        --output-verity-hashes \
        --output-verity-hashes-dir "$BASE_NON_SIGNED_HASH_FILES_PATH" \
        --require-signed-rootfs-root-hash

        # Temporary workaround for
        # https://dev.azure.com/mariner-org/ECF/_workitems/edit/10412:
        # As Trident does not inject the signature yet, we cannot
        # require it
        # --require-signed-root-hashes \

# Sign exported root hash files if it exists
log "Signing root hash files"

BASE_SIGNED_ROOT_HASH_FILE_PATH="$OUT_DIR/secure-prod/main/signed-root-hashes/$BASE_HASH_FILE_NAME.sig"

sign-root-hash $BASE_NON_SIGNED_ROOT_HASH_FILE_PATH $BASE_SIGNED_ROOT_HASH_FILE_PATH

# Inject signed root hash file if it exists
log "Injecting signed files into base image"
inject-signed-hash-into-image \
    $CONFIG_SOURCE_PROD \
    $SECURE_PROD_MAIN_UNSIGNED_IMAGE_PATH \
    $SECURE_PROD_MAIN_IMAGE_PATH \
    $BASE_SIGNED_ROOT_HASH_FILE_PATH \
    "vhd-fixed"

# Publish secure-prod main image artifacts
if [[ -n $ARTIFACT_PUBLISH_DIR ]]; then
    log "Publishing secure-prod build artifacts..."
    VM_IMAGE_PUBLISH_DIR=$ARTIFACT_PUBLISH_DIR/image
    mkdir -p $VM_IMAGE_PUBLISH_DIR/secure-prod
    cp $SECURE_PROD_MAIN_IMAGE_PATH $VM_IMAGE_PUBLISH_DIR/secure-prod/secure-prod.vhd
    qemu-img convert -f raw -O qcow2 $SECURE_PROD_MAIN_IMAGE_PATH $VM_IMAGE_PUBLISH_DIR/secure-prod/secure-prod.qcow2

    if [[ ! -f $VM_IMAGE_PUBLISH_DIR/secure-prod/secure-prod.qcow2 ]]; then
        log "[Error] A qcow2 image was expected in the publishing directory but was not found."
        exit 1
    fi
fi

# Generate the secure-prod update images
log "Running MIC to generate the secure-prod update images"

UPDATE_HASH_FILE_NAME="root.hash"
UPDATE_NON_SIGNED_HASH_FILES_PATH="$OUT_DIR/secure-prod/update/non-signed-root-hashes"
UPDATE_NON_SIGNED_ROOT_HASH_FILE_PATH="$UPDATE_NON_SIGNED_HASH_FILES_PATH/$UPDATE_HASH_FILE_NAME"

mkdir -p $UPDATE_NON_SIGNED_HASH_FILES_PATH

UPDATE_PROD_EDITION_IMAGE_PATH="$OUT_DIR/secure-prod/secure-prod-update.cosi"
UPDATE_PROD_EDITION_UNSIGNED_IMAGE_PATH="$OUT_DIR/secure-prod/secure-prod-update-unsigned.qcow2"

docker run --rm \
    --privileged \
    -v "$BUILD_OUT_BASE_DIR:$BUILD_OUT_BASE_DIR:z" \
    -v "/dev:/dev" \
    "$PRISM_CONTAINER_URL" \
    imagecustomizer \
        --build-dir "$BUILD_DIR" \
        --config-file "$CONFIG_SOURCE_PROD/$BUILD_TARGET-update-config.yaml" \
        --image-file "$SECURE_BASE_UPDATE_IMAGE_PATH" \
        --rpm-source "$RPMS_DIR" \
        --output-image-format "qcow2" \
        --output-image-file "$UPDATE_PROD_EDITION_UNSIGNED_IMAGE_PATH" \
        --output-verity-hashes \
        --output-verity-hashes-dir "$UPDATE_NON_SIGNED_HASH_FILES_PATH" \
        --require-signed-rootfs-root-hash \
        --log-level "debug"

        # Temporary workaround for
        # https://dev.azure.com/mariner-org/ECF/_workitems/edit/10412:
        # As Trident does not inject the signature yet, we cannot
        # require it
        # --require-signed-root-hashes \

# Sign exported root hash files if it exists
log "Signing root hash files for the update image"

UPDATE_SIGNED_ROOT_HASH_FILE_PATH="$OUT_DIR/secure-prod/update/signed-root-hashes/$UPDATE_HASH_FILE_NAME.sig"
sign-root-hash $UPDATE_NON_SIGNED_ROOT_HASH_FILE_PATH $UPDATE_SIGNED_ROOT_HASH_FILE_PATH

# Inject signed root hash file if it exists
log "Injecting signed files into update image"

inject-signed-hash-into-update-image \
    $CONFIG_SOURCE_PROD \
    $UPDATE_PROD_EDITION_UNSIGNED_IMAGE_PATH \
    $UPDATE_PROD_EDITION_IMAGE_PATH \
    $UPDATE_SIGNED_ROOT_HASH_FILE_PATH

if [[ -n $ARTIFACT_PUBLISH_DIR ]]; then
    log "Publishing build artifacts..."
    UPDATE_IMAGE_PUBLISH_DIR=$ARTIFACT_PUBLISH_DIR/update
    mkdir -p $UPDATE_IMAGE_PUBLISH_DIR/secure-base
    cp $OUT_DIR/secure-base/*-update.qcow2 $UPDATE_IMAGE_PUBLISH_DIR/secure-base
    mkdir -p $UPDATE_IMAGE_PUBLISH_DIR/secure-prod
    cp $OUT_DIR/secure-prod/*.cosi $UPDATE_IMAGE_PUBLISH_DIR/secure-prod
fi
