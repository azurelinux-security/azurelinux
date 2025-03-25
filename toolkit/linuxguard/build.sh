#!/bin/bash

set -euo pipefail

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

SCRIPTS_DIR="${SOURCE_FOLDER}/scripts"
SPECS_DIR="${SOURCE_FOLDER}/SPECS"
REUSE_SOURCES="${REUSE_SOURCES:-false}"

function cleanup() {
    log "Cleaning up..."

    if [[ -n $LOG_PUBLISH_DIR ]]; then
        publish_build_logs
    fi
}

function build_solar() {
    if [[ -d "kata-containers" && $REUSE_SOURCES == "false" ]]; then
        sudo rm -rf kata-containers
    fi
    if [ ! -d "kata-containers" ]; then
        git clone -b jiria/embedsignatures https://github.com/microsoft/kata-containers
    fi
    pushd kata-containers/src/tools/sign-oci-layer-root-hashes
    OPENSSL_STATIC=1 \
		OPENSSL_LIB_DIR=$(dirname `whereis libssl.a | cut -d" " -f2`) \
		OPENSSL_INCLUDE_DIR=/usr/include/openssl \
        BUILD_TYPE=release make build
    SOLAR_PUBLISH_DIR=$ARTIFACT_PUBLISH_DIR/tools
    mkdir -p $SOLAR_PUBLISH_DIR
    cp target/release/solar $SOLAR_PUBLISH_DIR/
    cp target/release/solar $BUILD_OUT_BASE_DIR/
    popd
}

function clone_azl3() {
    if [[ -d "azurelinux" && $REUSE_SOURCES == "false" ]]; then
        sudo rm -rf azurelinux
    fi
    if [ ! -d "azurelinux" ]; then
        git clone -b "3.0-stable" "https://github.com/microsoft/azurelinux.git"
    fi
}

# Build a list of specs in a spec folder with a list of remote repos
# Expects toolchain and worker chroot to be present before being called.
#
# Arguments:
#  $1 Path to specs folder
function build_specs() {
    local SPECS_DIR="$1"

    pushd "${BUILD_DIR}/azurelinux/toolkit"
    sudo make build-packages \
        -j$(nproc) \
        SPEC_LIST="selinux-policy-ci containerd tardev-snapshotter" \
        SPECS_DIR="${SPECS_DIR}" \
        QUICK_REBUILD_PACKAGES=y \
        PRECACHE=n \
        CONFIG_FILE= \
        REBUILD_TOOLS=y \
        GOFLAGS="-buildvcs=false" \
        BUILD_DIR=$BUILD_DIR \
        OUT_DIR=$OUT_DIR \
        LOG_LEVEL=info
    MAKE_STATUS=${PIPESTATUS[0]}

    if [ $MAKE_STATUS -ne 0 ]; then
        log "!!! ERROR: make build-packages failed with status $MAKE_STATUS"
        exit $MAKE_STATUS
    fi

    sudo chown -R $(id -u):$(id -g) ${BUILD_DIR} ${OUT_DIR}

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

build_solar

#
# Build local packages
#
log "Build local packages"

clone_azl3

build_specs $SPECS_DIR

publish_package_build_artifacts
