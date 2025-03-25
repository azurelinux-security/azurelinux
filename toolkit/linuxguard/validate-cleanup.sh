#!/bin/bash

set -euo pipefail

CLEANUP=${CLEANUP:-1}
if [ $CLEANUP -eq 0 ]; then
    echo "Skipping cleanup"
    exit 0
fi

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

if [ -z ${TEST_PLATFORM:-} ]; then
    echo "Error: TEST_PLATFORM not set. It is required for image validation. Supported values are: azure, qemu."
    exit 1
fi

if [ $TEST_PLATFORM == "azure" ]; then
    # Delete the RG if it exists
    if [ "`az group exists -n $STEAMBOAT_TEST_RESOURCE_GROUP`" == "true" ]; then
        az group delete -n $STEAMBOAT_TEST_RESOURCE_GROUP -y
    fi
    # TODO also delete the storage RG
elif [ $TEST_PLATFORM == "qemu" ]; then
    virsh destroy $VM_NAME || true
    virsh undefine --nvram $VM_NAME || true
else
    echo "Error: Unsupported TEST_PLATFORM value: $TEST_PLATFORM. Supported values are: azure, qemu."
    exit 1
fi