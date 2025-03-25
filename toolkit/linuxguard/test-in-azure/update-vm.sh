#!/bin/bash

set -euxo pipefail

# Include the common functions and variables
. $(dirname $0)/common.sh

UPDATE_IMAGE_PATH=$ARTIFACTS_DIR/update/*.raw.zst

if [ $LOGIN -eq 1 ]; then
  az-login
fi

VM_IP=`az vm show -d -g $VM_RG_NAME -n $VM_NAME --query publicIps -o tsv`
scp $UPDATE_IMAGE_PATH $VM_USER@$VM_IP:/tmp/
ssh $VM_USER@$VM_IP "sudo sed -i 's#http://.*/#file:///tmp/#' /var/lib/trident/update-config.yaml"
ssh $VM_USER@$VM_IP "sudo trident run -c /var/lib/trident/update-config.yaml"

az serial-console connect -g jiria-lg-vm2 -n azurelinux-tcb
# TODO, check that the VM is actually updated
