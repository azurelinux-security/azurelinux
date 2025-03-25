#!/bin/bash

set -euxo pipefail

NAME=barfoo
DEV=root.raw
DEV_HASH=root-hash.raw
ROOT_HASH=fd4c977b3e41f4d7132113410732acd3434b13aab1b2b32cbc0c460b1e3de6fc
SIGNATURE=roothash.txt.signed2

SIGNATURE_NAME=verity:$ROOT_HASH
SALT=6731a28b9c2bb9d49b9ea630b64762e211f31f31d2cf9d06a8036d6888fa1c43

# sudo keyctl padd user $SIGNATURE_NAME @u < $SIGNATURE
sudo keyctl padd user $SIGNATURE_NAME @s < $SIGNATURE

echo Loaded signature
sudo keyctl list @s

function get_loop_dev() {
    local FILE=$1

    set +e
    losetup -a | grep $FILE | cut -d: -f1 | head -1
    set -e
}

function detach_previous() {
    local FILE=$1

    # Detach the previous device if it was attached
    while true; do
        LOOP=`get_loop_dev $FILE`
        if [ -z "$LOOP" ]; then
            break
        fi
        sudo losetup -d $LOOP
    done
}

detach_previous $DEV
detach_previous $DEV_HASH

losetup -fP $DEV
losetup -fP $DEV_HASH

DEV_LOOP=`get_loop_dev $DEV`
DEV_HASH_LOOP=`get_loop_dev $DEV_HASH`

# dmsetup <logical_start_sector> <num_sectors> verity <version> <dev> <hash_dev> <data_block_size> <hash_block_size> <num_data_blocks> <hash_start_block> <algorithm> <digest> <salt> [<#opt_params> <opt_params>]
# sources:
#   dmsetup table format: https://www.man7.org/linux/man-pages/man8/dmsetup.8.html#TABLE_FORMAT
#   verity target format: https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/verity.html#construction-parameters
TABLE="0 2498744 verity 1 $DEV_LOOP $DEV_HASH_LOOP 4096 4096 312343 1 sha256 $ROOT_HASH $SALT 2 root_hash_sig_key_desc $SIGNATURE_NAME"

echo Loading table: $TABLE

sudo dmsetup create -r $NAME --table "$TABLE"

echo Loaded DM table
sudo dmsetup table $NAME

echo Available devices
ls /dev/mapper
