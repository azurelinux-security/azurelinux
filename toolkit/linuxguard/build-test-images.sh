#!/bin/bash

set -euo pipefail

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

BUILD_MAIN="${BUILD_MAIN:=true}"
BUILD_UPDATE="${BUILD_UPDATE:=true}"

if [ -z ${IPE_SIGNING_KEY_PASSWORD:-} ]; then
    echo "Error: IPE signing key password not set. It is required for basic IPE validation."
    exit 1
fi

if [ -z ${TEST_PLATFORM:-} ]; then
    echo "Error: TEST_PLATFORM not set. It is required for image validation. Supported values are: azure, qemu."
    exit 1
fi

if [ $TEST_PLATFORM == "azure" ]; then
    IMAGE_OUTPUT_FORMAT=vhd-fixed
    IMAGE_EXTENSION=vhd
elif [ $TEST_PLATFORM == "qemu" ]; then
    IMAGE_OUTPUT_FORMAT=qcow2
    IMAGE_EXTENSION=qcow2
else
    echo "Error: Unsupported TEST_PLATFORM value: $TEST_PLATFORM. Supported values are: azure, qemu."
    exit 1
fi

mkdir -p ${BUILD_DIR}
mkdir -p ${OUT_DIR}/secure-base
mkdir -p ${OUT_DIR}/secure-prod

# Inject custom ssh key into the MIC configs
# Generate the ssh key pair
SSH_PRIVATE_KEY_PATH=$SOURCE_FOLDER/id_rsa
SSH_PUBLIC_KEY_PATH=$SSH_PRIVATE_KEY_PATH.pub

SECURE_BASE_MAIN_IMAGE_PATH=$OUT_DIR/secure-base/secure-base.qcow2
SECURE_BASE_UPDATE_IMAGE_PATH=$OUT_DIR/secure-base/secure-base-update.qcow2
IMAGE_PATH=$OUT_DIR/secure-test/secure-test.$IMAGE_EXTENSION
UNSIGNED_IMAGE_PATH=$OUT_DIR/secure-test/secure-test-unsigned.$IMAGE_EXTENSION
MIC_CONFIG=$BUILD_TARGET-config.yaml

# Use solar tool to sign the approved container images
$BUILD_OUT_BASE_DIR/solar \
    --images $SOURCE_FOLDER/src/test_files/approved-container-images \
    --signer $SOURCE_FOLDER/ipe-kernel/kernel-ipe/ipe_cert.pem \
    --key $IPE_SIGNING_KEY \
    --passphrase pass:$IPE_SIGNING_KEY_PASSWORD \
    --use-cached-files \
    generate-standalone-signatures-manifest \
    --output $SOURCE_FOLDER/src/test_files/signatures.json

# Cleanup. For any local repetitive builds
rm -rf $SOURCE_FOLDER/src/secure-test/*
# Note: We need to build an image very similar to the secure-prod
#       The only difference should be the custom SSH key that we need to
#       insert
mkdir -p $SOURCE_FOLDER/src/secure-test
cp -rf $SOURCE_FOLDER/src/secure-prod/* $SOURCE_FOLDER/src/secure-test/
cp -rf $SOURCE_FOLDER/src/test_files $SOURCE_FOLDER/src/secure-test/
pushd $SOURCE_FOLDER/src/secure-test

if [ ! -f $SSH_PRIVATE_KEY_PATH ]; then
    ssh-keygen -t rsa -b 4096 -f $SSH_PRIVATE_KEY_PATH -N ""
    chmod 600 $SSH_PRIVATE_KEY_PATH
fi

BASE_CONFIG=$BUILD_TARGET-config.yaml
UPDATE_CONFIG=$BUILD_TARGET-update-config.yaml

if [ $TEST_PLATFORM == "qemu" ]; then
    # Patch the config files with the ssh key
    $SOURCE_FOLDER/src/build_scripts/update-ssh-key.py $BUILD_TARGET-config.yaml $SSH_PUBLIC_KEY_PATH $BASE_CONFIG
    $SOURCE_FOLDER/src/build_scripts/update-ssh-key.py $BUILD_TARGET-update-config.yaml $SSH_PUBLIC_KEY_PATH $UPDATE_CONFIG
fi

# Inject test configuration
inject_test_files $BASE_CONFIG
inject_test_kernel_params $BASE_CONFIG
inject_test_postcustomization_scripts $BASE_CONFIG
inject_test_files $UPDATE_CONFIG
inject_test_kernel_params $UPDATE_CONFIG

# Derive Trident host status from the base image MIC config
$SOURCE_FOLDER/src/build_scripts/generate-host-status-template.py $BASE_CONFIG files/trident/host_status.yaml

echo "Contents of host_status.yaml..."
cat files/trident/host_status.yaml

cp -rT "$SOURCE_FOLDER/src" "$BUILD_DIR/src"

mkdir -p $RPMS_DIR
CONFIG_SOURCE=$BUILD_DIR/src/secure-test

if [ $BUILD_MAIN == "true" ]; then
    log "Running Prism to generate the base image"

    echo "Using following Prism config:"
    cat $CONFIG_SOURCE/$BASE_CONFIG

    BASE_HASH_FILE_NAME="root-a.hash"
    BASE_NON_SIGNED_HASH_FILES_PATH="$OUT_DIR/test-edition/base/non-signed-root-hashes"
    BASE_NON_SIGNED_ROOT_HASH_FILE_PATH="$BASE_NON_SIGNED_HASH_FILES_PATH/$BASE_HASH_FILE_NAME"

    mkdir -p $BASE_NON_SIGNED_HASH_FILES_PATH
    mkdir -p $OUT_DIR/secure-test

    docker run --rm \
        --privileged \
        -v "$BUILD_OUT_BASE_DIR:$BUILD_OUT_BASE_DIR:z" \
        -v "/dev:/dev" \
        "$PRISM_CONTAINER_URL" \
        imagecustomizer \
            --build-dir "$BUILD_DIR" \
            --config-file "$CONFIG_SOURCE/$BASE_CONFIG" \
            --image-file "$SECURE_BASE_MAIN_IMAGE_PATH" \
            --log-level "debug" \
            --output-image-format "$IMAGE_OUTPUT_FORMAT" \
            --output-image-file "$UNSIGNED_IMAGE_PATH" \
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

    BASE_SIGNED_ROOT_HASH_FILE_PATH="$OUT_DIR/test-edition/base/signed-root-hashes/$BASE_HASH_FILE_NAME.sig"
    sign-root-hash $BASE_NON_SIGNED_ROOT_HASH_FILE_PATH $BASE_SIGNED_ROOT_HASH_FILE_PATH

    # Inject signed root hash file if it exists
    log "Injecting signed files into base image"
    inject-signed-hash-into-image \
        $CONFIG_SOURCE \
        $UNSIGNED_IMAGE_PATH \
        $IMAGE_PATH \
        $BASE_SIGNED_ROOT_HASH_FILE_PATH \
        $IMAGE_OUTPUT_FORMAT
fi

if [ $BUILD_UPDATE == "true" ]; then
    # Generate the update images
    log "Running MIC to generate the update images"
    echo "Using following MIC config..."
    cat $CONFIG_SOURCE/$UPDATE_CONFIG

    UPDATE_HASH_FILE_NAME="root.hash"
    UPDATE_NON_SIGNED_HASH_FILES_PATH="$OUT_DIR/secure-test/update/non-signed-root-hashes"
    UPDATE_NON_SIGNED_ROOT_HASH_FILE_PATH="$UPDATE_NON_SIGNED_HASH_FILES_PATH/$UPDATE_HASH_FILE_NAME"

    mkdir -p $UPDATE_NON_SIGNED_HASH_FILES_PATH

    UPDATE_TEST_EDITION_IMAGE_PATH="$OUT_DIR/secure-test-update.cosi"
    UPDATE_TEST_EDITION_UNSIGNED_IMAGE_PATH="$OUT_DIR/secure-test/secure-test-update-unsigned.qcow2"

    docker run --rm \
        --privileged \
        -v "$BUILD_OUT_BASE_DIR:$BUILD_OUT_BASE_DIR:z" \
        -v "/dev:/dev" \
        "$PRISM_CONTAINER_URL" \
        imagecustomizer \
            --build-dir "$BUILD_DIR" \
            --config-file "$CONFIG_SOURCE/$UPDATE_CONFIG" \
            --image-file "$SECURE_BASE_UPDATE_IMAGE_PATH" \
            --output-image-format "qcow2" \
            --output-image-file "$UPDATE_TEST_EDITION_UNSIGNED_IMAGE_PATH" \
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

    UPDATE_SIGNED_ROOT_HASH_FILE_PATH="$OUT_DIR/secure-test/update/signed-root-hashes/$UPDATE_HASH_FILE_NAME.sig"
    sign-root-hash $UPDATE_NON_SIGNED_ROOT_HASH_FILE_PATH $UPDATE_SIGNED_ROOT_HASH_FILE_PATH

    inject-signed-hash-into-update-image $CONFIG_SOURCE $UPDATE_TEST_EDITION_UNSIGNED_IMAGE_PATH $UPDATE_TEST_EDITION_IMAGE_PATH $UPDATE_SIGNED_ROOT_HASH_FILE_PATH
fi
