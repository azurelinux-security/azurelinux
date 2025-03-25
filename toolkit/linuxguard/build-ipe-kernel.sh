#!/bin/bash

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

set -x

az login --identity
if [ $? -ne 0 ]; then
    echo "Azure login failed"
    exit 1
fi
current_date="$(date +'%y%m%d')"

echo "current_date: $current_date"

SPECS_DIR="${SOURCE_FOLDER}/ipe-kernel"

function cleanup() {
    log "Cleaning up..."

    if [[ -n $LOG_PUBLISH_DIR ]]; then
        publish_build_logs
    fi
}

# Build a list of specs in a spec folder with a list of remote repos
# Expects toolchain and worker chroot to be present before being called.
#
# Arguments:
#  $1 Path to specs folder
function build_specs() {
    local SPECS_DIR="$1"
    pushd "${BUILD_DIR}"
    git clone -b "3.0-stable" "https://github.com/microsoft/azurelinux.git"
    popd

    pushd "${BUILD_DIR}/azurelinux/toolkit"
    sudo make build-packages \
        -j$(nproc) \
        SRPM_PACK_LIST="kernel-ipe kernel-headers" \
        SPECS_DIR="${SPECS_DIR}" \
        USE_PREVIEW_REPO=y \
        QUICK_REBUILD_PACKAGES=y \
        PRECACHE=n \
        CONFIG_FILE= \
        REBUILD_TOOLS=y \
        GOFLAGS="-buildvcs=false" \
        BUILD_DIR=$BUILD_DIR \
        OUT_DIR=$OUT_DIR \
        LOG_LEVEL=info \
        USE_CCACHE=y
    MAKE_STATUS=${PIPESTATUS[0]}

    if [ $MAKE_STATUS -ne 0 ]; then
        log "!!! ERROR: make build-packages failed with status $MAKE_STATUS"
        exit $MAKE_STATUS
    fi
    popd
}

# Package build artifacts and place in build artifact publishing directory
# This overwrites packaged artifacts from previous calls to this function
# The SRPMs and RPMs from previous calls are preserved and packaged as long as
#  `make clean` has not been called between builds of separate repos
#
# No arguments
# Global variables expected to be defined: BUILD_DIR, OUT_DIR, $ARTIFACT_PUBLISH_DIR
# Assumes toolkit is at ${BUILD_DIR}/azurelinux/toolkit
publish_package_build_artifacts() {
    log "pack built RPMs and SRPMs"

    pushd "${BUILD_DIR}/azurelinux/toolkit"
    sudo make compress-srpms compress-rpms \
        BUILD_DIR=$BUILD_DIR \
        OUT_DIR=$OUT_DIR
    MAKE_STATUS=${PIPESTATUS[0]}
    if [ $MAKE_STATUS -ne 0 ]; then
        log "!!! ERROR: make compress-srpms compress-rpms failed with status $MAKE_STATUS"
        exit $MAKE_STATUS
    fi

    PACKAGE_PUBLISH_DIR=$ARTIFACT_PUBLISH_DIR/packages
    mkdir -p $PACKAGE_PUBLISH_DIR
    sudo mv $OUT_DIR/srpms.tar.gz $PACKAGE_PUBLISH_DIR
    sudo mv $OUT_DIR/rpms.tar.gz $PACKAGE_PUBLISH_DIR
    popd
}

# Package log artifacts and place in log artifact publishing directory
# This overwrites packaged logs from previous calls to this function
# The logs from previous calls are preserved and packaged as long as
#  `make clean` has not been called between builds of separate repos
#
# No arguments
# Global variables expected to be defined: LOG_PUBLISH_DIR, BUILD_DIR
publish_build_logs() {
    log "-- pack logs"
    mkdir -p "$LOG_PUBLISH_DIR"
    if [[ -d $BUILD_DIR/logs ]]; then
        tar -C "$BUILD_DIR/logs" -czf "$LOG_PUBLISH_DIR/pkggen.logs.tar.gz" .
    else
        log "-- Warning - no 'logs' folder under $BUILD_DIR"
    fi
    log "-- pack package build artifacts"
    if [[ -d $BUILD_DIR/pkg_artifacts ]]; then
        tar -C "$BUILD_DIR/pkg_artifacts" -czf "$LOG_PUBLISH_DIR/pkg_artifacts.tar.gz" .
    else
        log "-- Warning - no 'pkg_artifacts' folder under $BUILD_DIR"
    fi
}

#
# main
#

trap cleanup EXIT

#
# Derive Variables
#
LOG_PUBLISH_DIR="${ARTIFACT_PUBLISH_DIR}/LOGS"

mkdir -p ${BUILD_DIR}
mkdir -p ${OUT_DIR}
mkdir -p ${LOG_PUBLISH_DIR}

pushd ${BUILD_DIR}

#
# Build local packages
#
log "Build local packages"

build_specs $SPECS_DIR

publish_package_build_artifacts
