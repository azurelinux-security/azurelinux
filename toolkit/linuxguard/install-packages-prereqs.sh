#!/bin/bash
set -euxo pipefail

echo "================================================"
echo "=== installing prereqs for building packages ==="
echo "================================================"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Install prerequisites
sudo tdnf -y install \
    acl \
    binutils \
    bison \
    coreutils \
    cdrkit \
    curl \
    dnf \
    dnf-utils \
    dosfstools \
    gawk \
    gcc \
    git \
    glibc-devel \
    golang \
    kernel-headers \
    make \
    p7zip \
    parted \
    pigz \
    python3 \
    python3-rpm \
    qemu-img \
    rpm \
    rpm-build \
    rsync \
    sudo \
    tar \
    veritysetup \
    wget

# List go version
go version
