#!/bin/bash

set -euxo pipefail

function sshCommand() {
    local COMMAND="$1"

    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR aksnode $COMMAND
}

function uploadFile() {
    local FILE="$1"

    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $FILE aksnode:
}

# Since we are using kata image to bootstrap, add runc runtime class to allow
# running runc containers
kubectl apply -f k8s/runtimeclass-runc.yaml

# Tell containerd to use the tardev snapshotter for the runc runtimeclass
# Add snapshotter = "tardev" after
# [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc] in
# /etc/containerd/config.toml
sshCommand "sudo sed -i 's/\[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runc\]/\[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runc\]\n      snapshotter = \"tardev\"/' /etc/containerd/config.toml"
sshCommand "sudo echo '[proxy_plugins]\n  [proxy_plugins.tardev]\n    type = \"snapshot\"\n    address = \"/run/containerd/tardev-snapshotter.sock\"'" >> /etc/containerd/config.toml
sshCommand "sudo systemctl restart containerd"

echo "# To test the snapshotter, run from the devbox:"
echo kubectl apply -f k8s/busybox.yaml

echo "# To regenerate the approved-container-images file, run from the node:"
echo kubectl get pods -A -o yaml | grep image: | grep -v message: | cut -d':' -f 2,3 | sort | uniq | tr -d " "
echo "# and add pause"