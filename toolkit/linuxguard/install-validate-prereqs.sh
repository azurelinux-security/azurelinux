#!/bin/bash

# MIC
sudo usermod $USER -G docker
sudo systemctl enable docker.service --now

# Booting
sudo apt -y install \
   acl \
   bc \
   bridge-utils \
   clang \
   libcairo2-dev \
   libgirepository1.0-dev \
   libvirt-daemon-system \
   libvirt-dev \
   libvirt-clients \
   ncat \
   openssh-client \
   openssl \
   ovmf \
   protobuf-compiler \
   python3-bcrypt \
   python3-dev \
   python3-docker \
   python3-jinja2 \
   python3-libvirt \
   python3-netifaces \
   python3-venv \
   qemu \
   qemu-efi \
   qemu-kvm \
   qemu-utils \
   swtpm \
   swtpm-tools \
   virt-manager \
   zstd
