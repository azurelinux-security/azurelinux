#!/bin/bash

set -euxo pipefail

LOGIN=${LOGIN:-0}

IMAGE_PIPELINE_BRANCH=${PIPELINE_BRANCH:-main}
IMAGE_PIPELINE_ID=${PIPELINE_ID:-3778} # TCB-Daily-Build
IMAGE_PIPELINE_PROJECT=${PIPELINE_PROJECT:-mariner}
IMAGE_PIPELINE_ORG=${PIPELINE_ORG:-https://dev.azure.com/mariner-org}
IMAGE_ARTIFACT_NAME=${IMAGE_ARTIFACT_NAME:-drop_build_azl3_images_amd64}
IMAGE_ARTIFACT_PATH=${IMAGE_ARTIFACT_PATH:-image/secure-prod.vhd}

ARTIFACTS_DIR=./artifacts

ALIAS=${ALIAS:-$(whoami)}

SA_RG_NAME=${SA_RG_NAME:-$ALIAS-tcb-gallery-storage}
SA_NAME=${SA_NAME:-tcbgallery$ALIAS}
SAC_NAME=${SAC_NAME:-${ALIAS}tcbvhd}

G_RG_NAME=${G_RG_NAME:-$ALIAS-tcb-gallery}
G_NAME=${G_NAME:-tcbgallery$ALIAS}
I_NAME=${I_NAME:-tcb}
O_NAME=${O_NAME:-TCB}
R_NAME=${R_NAME:-westus3}
SUB_ID=${SUB_ID:-b8f169b2-5b23-444a-ae4b-19a31b5e3652} # EdgeOS_Mariner_Platform_dev

VM_RG_NAME=${VM_RG_NAME:-$ALIAS-linuxguard}
VM_NAME=${VM_NAME:-azurelinux-tcb}
VM_USER=${VM_USER:-azureuser}

export AZCOPY_AUTO_LOGIN_TYPE=${AZCOPY_AUTO_LOGIN_TYPE:-AZCLI}

function az-login() {
  az login
}

function get-latest-version() {
  local G_RG_NAME=$1
  local G_NAME=$2
  local I_NAME=$3

  # TODO improve the sorting
  az sig image-version list -g $G_RG_NAME -r $G_NAME -i $I_NAME --query '[].name' -o tsv | sort -t "." -k1,1n -k2,2n -k3,3n | tail -1
}
