#!/bin/bash

set -euo pipefail

# Find the absolute path of the directory containing this script
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
. $SCRIPTS_DIR/common.sh

if [ ! -z ${BUILD_BUILDID:-} ]; then
    az login --identity
fi
az account set --subscription $STEAMBOAT_SUBSCRIPTION

PERFORM_UPDATE="${PERFORM_UPDATE:=true}"

if [ -z ${TEST_PLATFORM:-} ]; then
    echo "Error: TEST_PLATFORM not set. It is required for image validation. Supported values are: azure, qemu."
    exit 1
fi

CLEANUP=1
$SCRIPTS_DIR/validate-cleanup.sh
if [ $TEST_PLATFORM == "qemu" ]; then
    SERIAL_LOG_FILE_PATH="$BUILD_DIR/$VM_NAME-virsh-serial.log"
    sudo truncate -s 0 $SERIAL_LOG_FILE_PATH
fi

# Remove any existing trident-update-server docker container on the assigned trident update server port
TRIDENT_UPDATE_SERVER_NAME=trident-update-server
docker stop $TRIDENT_UPDATE_SERVER_NAME > /dev/null 2>&1 || true
docker rm $TRIDENT_UPDATE_SERVER_NAME > /dev/null 2>&1 || true

set -x

scpUploadFile() {
    local VM_IP=$1
    local SRC=$2
    local DEST=$3

    scp -i $SSH_PRIVATE_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $SRC $SSH_USER@$VM_IP:$DEST
}

scpDownloadFile() {
    local VM_IP=$1
    local SRC=$2
    local DEST=$3

    scp -i $SSH_PRIVATE_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $SSH_USER@$VM_IP:$SRC $DEST
}

waitForSsh() {
    local VM_IP=$1

    while ! sshCommand $VM_IP "hostname"; do sleep 1; done
}

downloadSELinuxDebug() {
    local VM_IP=$1
    local DEST=$2

    local AUDIT_LOG=/tmp/audit.log
    local PROCESS_LIST=/tmp/ps.txt
    local BLOCK_DEVS=/tmp/block-devs.txt
    #local FILE_LIST=/tmp/ls.txt
    local DEBUG_FILE=/tmp/selinux-debug.tar.gz

    sshCommand $VM_IP "sudo cp /var/log/audit/audit.log $AUDIT_LOG && sudo chmod 644 $AUDIT_LOG"
    sshCommand $VM_IP "sudo ps axZf > $PROCESS_LIST 2>&1 && sudo chmod 644 $PROCESS_LIST"
    #sshCommand $VM_IP "sudo ls -lZR / > $FILE_LIST 2>&1 && sudo chmod 644 $FILE_LIST"
    sshCommand $VM_IP "sudo lsblk > $BLOCK_DEVS 2>&1 && sudo chmod 644 $BLOCK_DEVS"
    sshCommand $VM_IP "tar -C /tmp -zcf $DEBUG_FILE $(basename $AUDIT_LOG) $(basename $PROCESS_LIST) $(basename $BLOCK_DEVS)" # $(basename $FILE_LIST)"
    scpDownloadFile $VM_IP $DEBUG_FILE $DEST
}

downloadJournalLog() {
    local VM_IP=$1
    local DEST=$2

    local JOURNAL_LOG=/tmp/journal.log

    sshCommand $VM_IP "sudo journalctl --no-pager > $JOURNAL_LOG && sudo chmod 644 $JOURNAL_LOG"
    scpDownloadFile $VM_IP $JOURNAL_LOG $DEST
}

publishLog() {
    local LOG_FILE=$1

    if [[ -n $ARTIFACT_PUBLISH_DIR ]]; then
        LOGS_PUBLISH_DIR=$ARTIFACT_PUBLISH_DIR/logs
        mkdir -p $LOGS_PUBLISH_DIR
        cp $LOG_FILE $LOGS_PUBLISH_DIR/
    fi
}

collectVMArtifacts() {
    local RC=$?
    local VM_IP=$1

    echo -e "\n\nCollecting logs from VM $VM_IP"

    downloadJournalLog $VM_IP journal.log
    publishLog journal.log
    downloadSELinuxDebug $VM_IP selinux-debug.tar.gz
    publishLog selinux-debug.tar.gz

    set +x
    echo -e "\n\nTo connect to the VM, run the following command:"
    echo ssh -i $SOURCE_FOLDER/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null azuresu@$VM_IP
    if [ $RC -ne 0 ]; then
        echo "VM validation failed! Look above the 'Collecting logs from VM' line for more details."
        exit 1
    fi
}

tridentGet() {
    local VM_IP=$1

    sshCommand $VM_IP "sudo trident get"
}

waitForTrident() {
    local VM_IP=$1

    sshCommand $VM_IP "sudo systemd-run --property=After=trident.service trident get"
}

tridentActiveVolume() {
    local VM_IP=$1

    echo `tridentGet $VM_IP | grep abActiveVolume | tr -d ' ' | cut -d':' -f2`
}

waitForLogin() {
    local VM_NAME=$1

    until sudo virsh dumpxml $VM_NAME; do sudo virsh list; sleep 0.1; done
    VM_SERIAL_LOG=`sudo virsh dumpxml $VM_NAME | grep -A 1 console | grep source | cut -d"'" -f2`

    until [ -f "$VM_SERIAL_LOG" ]
    do
        sleep 0.1
    done

    echo "Found VM serial log file: $VM_SERIAL_LOG"

    echo "Running python script wait_for_login"
    sudo src/build_scripts/wait_for_login.py \
        -d "$VM_SERIAL_LOG" \
        -o ./serial.log \
        -t 120
}

getVmIp() {
    local VM_NAME=$1
    while [ `sudo virsh domifaddr $VM_NAME | grep -c "ipv4"` -eq 0 ]; do sleep 1; done
    echo `sudo virsh domifaddr $VM_NAME | grep ipv4 | awk '{print $4}' | cut -d'/' -f1`
}

validateContainerRun() {
    sshCommand $VM_IP 'set -eux; for I in $(cat approved-container-images); do sudo run-container.sh $I; done'

    # Non-ukis are not
    # using ipe enforcement on update images, so requiring UKI image
    if [ $BUILD_TARGET == "uki" ]; then
        set +e
        sshCommand $VM_IP "sudo run-container.sh mcr.microsoft.com/azuredefender/stable/old-file-cleaner:1.0.148"
        RESULT=$?
        set -e
        if [ $RESULT -eq 0 ]; then
            echo "Error: Unsigned container image was allowed to run"
            exit 1
        else
            echo Undesired container state was expected, as we tested running an unsigned image.
        fi
    fi

    # We are creating an ACR to store the modified image
    if [ $TEST_PLATFORM == "azure" ]; then
        $SCRIPTS_DIR/validate-oci-manifest-signatures.sh
    fi
}

validateSELinuxEnforcing() {
    if [ "$BUILD_TARGET" == "uki" ]; then
        echo "Verify SELinux is enforcing"
        sshCommand $VM_IP 'getenforce; test "`getenforce`" == "Enforcing"'
    fi
}

if [ $TEST_PLATFORM == "qemu" ]; then
    # Start the VM to validate the images
    USED_IMAGE_PATH=$BUILD_DIR/secure-test.qcow2
    IMAGE_PATH=$OUT_DIR/secure-test/secure-test.qcow2
    cp $IMAGE_PATH $USED_IMAGE_PATH
    sudo virt-install \
        --name $VM_NAME \
        --memory 2048 \
        --vcpus 2 \
        --os-variant generic \
        --import \
        --disk $USED_IMAGE_PATH,bus=sata \
        --network default \
        --boot uefi,loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader_secure=no \
        --noautoconsole \
        --serial "file,path=$SERIAL_LOG_FILE_PATH"

    waitForLogin $VM_NAME
    VM_IP=`getVmIp $VM_NAME`
elif [ $TEST_PLATFORM == "azure" ]; then
    az group create \
        --name $STEAMBOAT_TEST_RESOURCE_GROUP \
        --location $STEAMBOAT_TCB_PUBLISH_LOCATION \
        --tags creationTime=$(date +%s)

    VM_NAME=secure-test
    VERSION=`get-image-version`
    az vm create \
        --resource-group $STEAMBOAT_TEST_RESOURCE_GROUP \
        --name $VM_NAME \
        --size $TEST_VM_SIZE \
        --os-disk-size-gb 60 \
        --admin-username $SSH_USER \
        --ssh-key-values $SSH_PUBLIC_KEY_PATH \
        --security-type TrustedLaunch \
        --enable-secure-boot false \
        --enable-vtpm true \
        --image /subscriptions/$STEAMBOAT_SUBSCRIPTION/resourceGroups/$STEAMBOAT_GALLERY_RESOURCE_GROUP/providers/Microsoft.Compute/galleries/$STEAMBOAT_GALLERY_NAME/images/$IMAGE_DEFINITION/versions/$VERSION -l $STEAMBOAT_TCB_PUBLISH_LOCATION
    az vm boot-diagnostics enable \
        --name $VM_NAME \
        --resource-group $STEAMBOAT_TEST_RESOURCE_GROUP

    export VM_IP=`az vm show -d -g $STEAMBOAT_TEST_RESOURCE_GROUP -n $VM_NAME --query publicIps -o tsv`

    # Use az cli to confirm the VM deployment status is successful
    while [ "`az vm show -d -g $STEAMBOAT_TEST_RESOURCE_GROUP -n $VM_NAME --query provisioningState -o tsv`" != "Succeeded" ]; do sleep 1; done
fi

waitForSsh $VM_IP

# Attempt to collect artifacts from the VM regardless of pass/fail result.
trap "collectVMArtifacts $VM_IP" EXIT

if [ $TEST_PLATFORM == "qemu" ]; then
    FIRST_BOOT_SERIAL_LOG_FILE_PATH="$BUILD_DIR/firstboot-serial.log"
    sudo cp $SERIAL_LOG_FILE_PATH $FIRST_BOOT_SERIAL_LOG_FILE_PATH && sudo chmod 644 $FIRST_BOOT_SERIAL_LOG_FILE_PATH
    publishLog $FIRST_BOOT_SERIAL_LOG_FILE_PATH
fi

validateSELinuxEnforcing $VM_IP

tridentGet $VM_IP
ACTIVE=`tridentActiveVolume $VM_IP`
if [ "$ACTIVE" != "volume-a" ]; then
    echo "Error: Active volume is not A"
    exit 1
fi

validateContainerRun

if [ $PERFORM_UPDATE == "false" ]; then
    echo "Skipping update validation"
    exit 0
fi

# Temporary workaround for
# https://dev.azure.com/mariner-org/ECF/_workitems/edit/10412: Disable IPE
# enforcement to unblock the update
sshCommand $VM_IP "sudo disable-ipe.sh"

if [ $TEST_PLATFORM == "qemu" ]; then
    # Reset virsh-serial.log so wait_for_login.py scans only for "login:" substring from the second boot.
    # Otherwise, the serial logs from both boots are stored in the same file and wait_for_login.py experiences an early exit
    # after calling trident's update.
    sudo truncate -s 0 $SERIAL_LOG_FILE_PATH
fi

# Update the VM with the new image
docker run -d --rm -p $TRIDENT_UPDATE_SERVER_PORT:80 --name $TRIDENT_UPDATE_SERVER_NAME \
    -v $OUT_DIR:/usr/share/nginx/html \
    mcr.microsoft.com/azurelinux/base/nginx:1

ssh -R $TRIDENT_UPDATE_SERVER_PORT:localhost:$TRIDENT_UPDATE_SERVER_PORT -N -i $SSH_PRIVATE_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $SSH_USER@$VM_IP &

UPDATE_CONFIG_PATH="$BUILD_DIR/src/secure-test/test_files/update-config.yaml"
$BUILD_DIR/src/secure-test/test_files/prepare-update-config-verity.sh "$UPDATE_CONFIG_PATH" "http://localhost:${TRIDENT_UPDATE_SERVER_PORT}"
scpUploadFile $VM_IP $UPDATE_CONFIG_PATH /tmp/update-config.yaml

# Stage the update first, so we can catch any failures before rebooting
sshCommand $VM_IP "sudo trident run -v trace -c /tmp/update-config.yaml --allowed-operations stage"

# Mask failures, as the VM will be rebooted; if anything goes wrong, the next
# check will catch it
set +e
sshCommand $VM_IP "sudo trident run -v debug -c /tmp/update-config.yaml --allowed-operations finalize"
set -e

if [ $TEST_PLATFORM == "azure" ]; then
    sleep 5
elif [ $TEST_PLATFORM == "qemu" ]; then
    waitForLogin $VM_NAME
    VM_IP=`getVmIp $VM_NAME`
fi

waitForSsh $VM_IP

if [ $TEST_PLATFORM == "qemu" ]; then
    SECOND_BOOT_SERIAL_LOG_FILE_PATH="$BUILD_DIR/secondboot-serial.log"
    sudo cp $SERIAL_LOG_FILE_PATH $SECOND_BOOT_SERIAL_LOG_FILE_PATH && sudo chmod 644 $SECOND_BOOT_SERIAL_LOG_FILE_PATH
    publishLog $SECOND_BOOT_SERIAL_LOG_FILE_PATH
fi

validateSELinuxEnforcing $VM_IP

waitForTrident $VM_IP
ACTIVE=`tridentActiveVolume $VM_IP`
if [ "$ACTIVE" != "volume-b" ]; then
    echo "Error: Active volume is not B"
    exit 1
fi

validateContainerRun
