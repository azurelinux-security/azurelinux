#!/bin/bash

cd kata-containers/src/tarfs
KERNEL_VERSION=$(rpm -q --queryformat '%{VERSION}' kernel-mshv-devel)
KERNEL_RELEASE=$(rpm -q --queryformat '%{RELEASE}' kernel-mshv-devel)
KERNEL_HEADER_DIR="/usr/src/linux-headers-${KERNEL_VERSION}-${KERNEL_RELEASE}"
make KDIR=${KERNEL_HEADER_DIR}

sudo insmod tarfs.ko
cat /proc/filesystems