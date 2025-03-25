#!/bin/bash
set -euo pipefail

# Description:
# This script is to be ran once, by an admin, when moving the pipelines to a new subscription.
# Values for the deployed resources should match those found in .pipelines/vars/vars-common.yml
#
# The following resources are erected by this script:
#   - A Resource Group
#   - A 1ES Image
#   - A 1ES AgentPool
#   - A Storage Account
#   - A Shared Image Gallery (i.e., Azure Compute Gallery)
#
# The Admin must have the following roles for the script to succeed:
#


STEAMBOAT_SUBSCRIPTION="035db282-f1c8-4ce7-b78f-2a7265d5398c"
STEAMBOAT_RESOURCE_GROUP="official-tcb-pipelines"
STEAMBOAT_STORAGE_ACCOUNT="tcbimages"
STEAMBOAT_GALLERY_NAME="tcbgallery"
STEAMBOAT_TCB_PUBLISH_LOCATION="westus3"


az group create -n $STEAMBOAT_RESOURCE_GROUP -l $STEAMBOAT_TCB_PUBLISH_LOCATION
 