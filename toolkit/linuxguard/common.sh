#!/bin/bash

set -euox pipefail
shopt -s extglob  # required by rm !

# Find location of this script
SOURCE_FOLDER="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
BUILD_OUT_BASE_DIR="${BUILD_OUT_BASE_DIR:-/tmp/mariner}"
ARTIFACT_PUBLISH_DIR="${ARTIFACT_PUBLISH_DIR:-/tmp/artifacts}"
IMAGE_OUTPUT_FORMAT="${IMAGE_OUTPUT_FORMAT:-vhd-fixed}"
IPE_SIGNING_KEY="${IPE_SIGNING_KEY:-$SOURCE_FOLDER/key.pem}"

ALIAS=${ALIAS:-$(whoami)}
BUILD_TARGET="${BUILD_TARGET:=azl3}"

STEAMBOAT_SUBSCRIPTION=${STEAMBOAT_SUBSCRIPTION:-b8f169b2-5b23-444a-ae4b-19a31b5e3652} # EdgeOS_Mariner_Platform_dev
STEAMBOAT_RESOURCE_GROUP=${STEAMBOAT_RESOURCE_GROUP:-${ALIAS}-steamboat-test}
STEAMBOAT_STORAGE_ACCOUNT=${STEAMBOAT_STORAGE_ACCOUNT:-${ALIAS}steamboattest}
STEAMBOAT_GALLERY_RESOURCE_GROUP=${STEAMBOAT_GALLERY_RESOURCE_GROUP:-${ALIAS}-steamboat-gallery-test}
STEAMBOAT_GALLERY_NAME=${STEAMBOAT_GALLERY_NAME:-${ALIAS}linuxguardgallery}
STEAMBOAT_TCB_PUBLISH_LOCATION=${STEAMBOAT_TCB_PUBLISH_LOCATION:-centralus}
PUBLISHER=${PUBLISHER:-$ALIAS}
OFFER=${OFFER:-secure-test-$BUILD_TARGET}
SKU=${SKU:-3.0}
STEAMBOAT_TEST_RESOURCE_GROUP=${STEAMBOAT_TEST_RESOURCE_GROUP:-${ALIAS}-steamboat-vm-test}
export AZCOPY_AUTO_LOGIN_TYPE=${AZCOPY_AUTO_LOGIN_TYPE:-AZCLI}
VM_NAME=secure-test
TEST_VM_SIZE=${TEST_VM_SIZE:-Standard_DS1_v2}
export IMAGE_DEFINITION=${IMAGE_DEFINITION:-secure-test-$BUILD_TARGET}

declare -A _AZL_3_VARS=(
    [core_version]="3.0.20241005"
    [feed]="core_selinux_vhdx-3.0-stable"
    [prism_version]="0.13.0-dev.761130"
    [trident_artifact_name]="rpms-ci"
    [trident_version]="0.3.2025031901-vd360b64"
    [local_update_server_port]="8082"
)
declare -A _UKI_VARS=(
    [core_version]="3.0.20241005"
    [feed]="core_selinux_vhdx-3.0-stable"
    [prism_version]="0.13.0-dev.761130"
    [trident_artifact_name]="rpms-ci"
    [trident_version]="0.3.2025031901-vd360b64"
    [local_update_server_port]="8083"
)

ARTIFACT_PUBLISH_DIR="${ARTIFACT_PUBLISH_DIR}/${BUILD_TARGET}"

if [ -t 1 ]; then
    CYAN="\e[36m"
    RESET="\e[0m"
else
    CYAN=""
    RESET=""
fi

function log() {
    timestamp="$(date "+%F %R:%S")"
    echo -e "${CYAN}+++ $timestamp $1${RESET}"
}

function get_azl_core_version {
    case "$1" in
        "azl3")
            echo "${_AZL_3_VARS[core_version]}"
            ;;
        "uki")
            echo "${_UKI_VARS[core_version]}"
            ;;
        *)
            echo "Error: Unexpected build target - $1"
            exit 1
            ;;
    esac
}

function get_core_majmin_version {
    mapfile -td . majminpatch < <(get_azl_core_version $1) # Parses version string into an array named 'majminpatch'
    if [[ "${#majminpatch[@]}" -gt "2" ]]; then
        echo "${majminpatch[0]}.${majminpatch[1]}" # Returns only the first two parts of a version string
    else
        local IFS="." && echo "${majminpatch[*]}" # Not a big fan of this... I don't want to error out if Core version is an integer, or already a majmin value (e.g., 3.0) so that it supports dev work. But also, this means the function can potentially return an unexpected value (i.e., something that's not majmin)
    fi
}

function get_azl_core_image_path {
    local azl_core_image_version=$(get_azl_core_version $1)
    echo "${BUILD_DIR}/core-${azl_core_image_version}.vhdx"
}

function get_azl_core_image_feed {
    case "$1" in
        "azl3")
            echo "${_AZL_3_VARS[feed]}"
            ;;
        "uki")
            echo "${_UKI_VARS[feed]}"
            ;;
        *)
            echo "Error: Unexpected build target - $1"
            exit 1
            ;;
    esac
}

function get_prism_container_url {
    case "$1" in
        "azl3")
            echo "acrafoimages.azurecr.io/imagecustomizer:${_AZL_3_VARS[prism_version]}"
            ;;
        "uki")
            echo "acrafoimages.azurecr.io/imagecustomizer:${_UKI_VARS[prism_version]}"
            ;;
        *)
            echo "Error: Unexpected build target - $1"
            exit 1
            ;;
    esac
}

function get_azl_trident_artifact_name {
    case "$1" in
        "azl3")
            echo "${_AZL_3_VARS[trident_artifact_name]}"
            ;;
        "uki")
            echo "${_UKI_VARS[trident_artifact_name]}"
            ;;
        *)
            echo "Error: Unexpected build target - $1"
            exit 1
            ;;
    esac
}

function get_azl_trident_version {
    case "$1" in
        "azl3")
            echo "${_AZL_3_VARS[trident_version]}"
            ;;
        "uki")
            echo "${_UKI_VARS[trident_version]}"
            ;;
        *)
            echo "Error: Unexpected build target - $1"
            exit 1
            ;;
    esac
}

function get_local_update_server_port {
    case "$1" in
        "azl3")
            echo "${_AZL_3_VARS[local_update_server_port]}"
            ;;
        "uki")
            echo "${_UKI_VARS[local_update_server_port]}"
            ;;
        *)
            echo "Error: Unexpected build target - $1"
            exit 1
            ;;
    esac
}

function inject_additional_file() {
    local CONFIG=$1
    local SOURCE=$2
    local DEST=$3
    local PERMISSIONS=$4

    yq -i ".os.additionalFiles += [{\"source\": \"$SOURCE\", \"destination\": \"$DEST\", \"permissions\": \"$PERMISSIONS\"}]" $CONFIG
}

function inject_test_files() {
    local CONFIG=$1

    inject_additional_file $CONFIG "test_files/10-podnet.conf" "/etc/cni/net.d/10-podnet.conf" "644"
    inject_additional_file $CONFIG "test_files/run-container.sh" "/usr/local/bin/run-container.sh" "755"
    inject_additional_file $CONFIG "test_files/signatures.json" "/var/lib/containerd/io.containerd.snapshotter.v1.tardev/signatures/signatures.json" "644"
    inject_additional_file $CONFIG "test_files/disable-ipe.sh" "/usr/local/bin/disable-ipe.sh" "755"
    inject_additional_file $CONFIG "test_files/approved-container-images" "/home/azuresu/approved-container-images" "644"
}

function inject_kernel_param() {
    local CONFIG=$1
    local PARAM=$2

    yq -i ".os.kernelCommandLine.extraCommandLine += \"$PARAM\"" $CONFIG
}

function inject_test_kernel_params() {
    local CONFIG=$1

    inject_kernel_param $CONFIG "systemd.journald.forward_to_console=1"
    inject_kernel_param $CONFIG "rd.debug"
    inject_kernel_param $CONFIG "loglevel=6"
    inject_kernel_param $CONFIG "log_buf_len=1M"
}

function inject_postcustomization_script() {
    local CONFIG=$1
    local SCRIPT=$2

    yq -i ".scripts.postCustomization += {\"path\": \"$SCRIPT\"}" $CONFIG
}

function inject_test_postcustomization_scripts() {
    local CONFIG=$1

    inject_postcustomization_script $CONFIG "test_files/selinux-testing-rules.sh"
    inject_postcustomization_script $CONFIG "test_files/increase-tardev-snapshotter-verbosity.sh"
}

function resize_image() {
    local IMAGE_PATH=$1
    # VHD images on Azure must have a virtual size aligned to 1MB. https://learn.microsoft.com/en-us/azure/virtual-machines/linux/create-upload-generic#resize-vhds
    raw_file="resize.raw"
    sudo qemu-img convert -f vpc -O raw $IMAGE_PATH $raw_file
    MB=$((1024*1024))
    size=$(qemu-img info -f raw --output json "$raw_file" | \
    gawk 'match($0, /"virtual-size": ([0-9]+),/, val) {print val[1]}')

    rounded_size=$(((($size+$MB-1)/$MB)*$MB))

    echo "Rounded Size = $rounded_size"

    sudo qemu-img resize $raw_file $rounded_size

    sudo qemu-img convert -f raw -o subformat=fixed,force_size -O vpc $raw_file $IMAGE_PATH
}

function get-latest-version() {
  local G_RG_NAME=$1
  local G_NAME=$2
  local I_NAME=$3

  # TODO improve the sorting
  az sig image-version list -g $G_RG_NAME -r $G_NAME -i $I_NAME --query '[].name' -o tsv | sort -t "." -k1,1n -k2,2n -k3,3n | tail -1
}

function get-image-version() {
    local OP=${1:-}
    if [ -z "${BUILD_BUILDNUMBER:-}" ]; then
        image_version=$(get-latest-version $STEAMBOAT_GALLERY_RESOURCE_GROUP $STEAMBOAT_GALLERY_NAME $OFFER)
        if [ -z $image_version ]; then
            image_version=0.0.1
        else
            if [ "$OP" == "increment" ]; then
                # Increment the semver version
                image_version=$(echo $image_version | awk -F. '{print $1"."$2"."$3+1}')
            fi
        fi
    else
        image_version="$BUILD_BUILDNUMBER.$SYSTEM_JOBATTEMPT"
    fi

    echo $image_version
}

function sign-root-hash() {
    local UNSIGNED_ROOT_HASH=$1
    local SIGNED_ROOT_HASH=$2

    mkdir -p `dirname $SIGNED_ROOT_HASH`
    openssl smime -sign -nocerts -noattr -binary \
        -in $UNSIGNED_ROOT_HASH \
        -inkey $IPE_SIGNING_KEY \
        --signer $SOURCE_FOLDER/ipe-kernel/kernel-ipe/ipe_cert.pem \
        -outform der \
        -out $SIGNED_ROOT_HASH \
        -passin pass:$IPE_SIGNING_KEY_PASSWORD
}

function inject-signed-hash-into-update-image() {
    local CONFIG_SOURCE=$1
    local IN=$2
    local OUT=$3
    local INJECT=$4

    # Note that we cannot call --shrink-filesystems at this point because it
    # modifies the block contents of the individual partitions - which will
    # invalidate the rootfs hash calculated in the previous step.
    docker run --rm \
        --privileged \
        -v "$BUILD_OUT_BASE_DIR:$BUILD_OUT_BASE_DIR:z" \
        -v "/dev:/dev" \
        "$PRISM_CONTAINER_URL" \
        imagecustomizer \
            --build-dir "$BUILD_DIR" \
            --config-file "$CONFIG_SOURCE/empty-config.yaml" \
            --image-file "$IN" \
            --output-image-file "$OUT" \
            --input-signed-verity-hashes-files "$INJECT" \
            --output-image-format cosi \
            --log-level "debug"
}

function inject-signed-hash-into-image() {
    local CONFIG_SOURCE=$1
    local IN=$2
    local OUT=$3
    local INJECT=$4
    local OUT_FORMAT=$5

    docker run --rm \
        --privileged \
        -v "$BUILD_OUT_BASE_DIR:$BUILD_OUT_BASE_DIR:z" \
        -v "/dev:/dev" \
        "$PRISM_CONTAINER_URL" \
        imagecustomizer \
            --build-dir "$BUILD_DIR" \
            --config-file "$CONFIG_SOURCE/empty-config.yaml" \
            --image-file "$IN" \
            --output-image-file "$OUT" \
            --input-signed-verity-hashes-files "$INJECT" \
            --output-image-format "$OUT_FORMAT" \
            --log-level "debug"
}

# Inject custom ssh key into the MIC configs
# Generate the ssh key pair
SSH_PRIVATE_KEY_PATH=id_rsa
SSH_PUBLIC_KEY_PATH=$SSH_PRIVATE_KEY_PATH.pub
SSH_USER=azuresu

function sshCommand() {
    local VM_IP=$1
    local COMMAND=$2

    # BatchMode - running from a script, disable any interactive prompts
    # ConnectTimeout - how long to wait for the connection to be established
    # ServerAliveCountMax - how many keepalive packets can be missed before the connection is closed
    # ServerAliveInterval - how often to send keepalive packets
    # StrictHostKeyChecking - disable host key checking; TODO: remove this and
    # use the known_hosts file instead
    # UserKnownHostsFile - disable known hosts file to simplify local runs
    ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o ServerAliveCountMax=3 \
        -o ServerAliveInterval=10 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i $SSH_PRIVATE_KEY_PATH \
        $SSH_USER@$VM_IP \
        "$COMMAND"
}

while getopts "a:o:f:k:" OPTIONS; do
    case "${OPTIONS}" in
        a) export ARTIFACT_PUBLISH_DIR=$OPTARG;;
        o) export BUILD_OUT_BASE_DIR=$OPTARG;;
        f) export IMAGE_OUTPUT_FORMAT=$OPTARG;;
        k) export IPE_SIGNING_KEY=$OPTARG;;
    esac
done

#
# Derive Variables
#
BUILD_DIR="${BUILD_OUT_BASE_DIR}/${BUILD_TARGET}/build"
OUT_DIR="${BUILD_OUT_BASE_DIR}/${BUILD_TARGET}/out"
RPMS_DIR="${OUT_DIR}/RPMS"

AZL_VERSION=$(get_core_majmin_version $BUILD_TARGET)
AZL_CORE_IMAGE_PATH=$(get_azl_core_image_path $BUILD_TARGET)
AZL_TRIDENT_ARTIFACT_NAME=$(get_azl_trident_artifact_name $BUILD_TARGET)
AZL_TRIDENT_VERSION=$(get_azl_trident_version $BUILD_TARGET)
PRISM_CONTAINER_URL=$(get_prism_container_url $BUILD_TARGET)
TRIDENT_UPDATE_SERVER_PORT=$(get_local_update_server_port $BUILD_TARGET)

