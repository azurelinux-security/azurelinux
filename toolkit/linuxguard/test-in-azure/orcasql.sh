#!/bin/bash

set -euxo pipefail

export IMAGE_PIPELINE_BRANCH=${PIPELINE_BRANCH:-dev/ritikumar/trident-update}
export IMAGE_PIPELINE_ID=${PIPELINE_ID:-38225} # orcasql-breadth-OneBranch-Buddy-OS-Image_LinuxGuard
export IMAGE_PIPELINE_PROJECT=${PIPELINE_PROJECT:-Database Systems}
export IMAGE_PIPELINE_ORG=${PIPELINE_ORG:-https://msdata.visualstudio.com}
export IMAGE_ARTIFACT_NAME=${IMAGE_ARTIFACT_NAME:-drop_BuildOSImage_BuildMeruAzureLinuxCI}
export IMAGE_ARTIFACT_PATH=${IMAGE_ARTIFACT_PATH:-MeruMarinerGen2Artifacts/disk_meruazurelinuxci_999.7.2024120619.vhd}