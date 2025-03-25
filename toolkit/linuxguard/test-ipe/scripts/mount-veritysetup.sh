#!/bin/bash

set -euxo pipefail

NAME=foobar
DEV=root.raw
DEV_HASH=root-hash.raw
ROOT_HASH=fd4c977b3e41f4d7132113410732acd3434b13aab1b2b32cbc0c460b1e3de6fc
SIGNATURE=roothash.txt.signed2

sudo veritysetup open $DEV $NAME $DEV_HASH $ROOT_HASH --root-hash-signature=$SIGNATURE

echo Loaded signature
sudo keyctl list @u

echo Loaded DM table
sudo dmsetup table $NAME

echo Available devices
ls /dev/mapper

# sudo veritysetup close $NAME