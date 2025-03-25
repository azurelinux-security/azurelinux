#!/bin/bash
set -ex

echo "================================================"
echo "=== installing prereqs for building iamges   ==="
echo "================================================"

# Remove extended file ACL entries from working directory
pwd
setfacl -bn "$(pwd)"

# To avoid git "fatal: unsafe repository" warning
git config --global --add safe.directory "$(pwd)"

# To avoid "Could not canonicalize hostname" error, which cause some package fail to build
sudo bash -c 'echo "127.0.0.1 $(hostname)" >> /etc/hosts'

# Make sure this user is a member of the docker group and that the service is running.
sudo usermod $USER -G docker
sudo systemctl enable docker.service --now

# DM-Verity requirements
sudo modprobe nbd
