# Scripts for testing IPE using AKS

This directory contains scripts for testing IPE using AKS. These scripts take
several assumptions regarding the dev setup, so probably will need to be
adjusted to fit your needs. Nonetheless, they should provide a good starting
point.

## Prerequisites

1) `az login`; ensure your selected subscription supports BYOI (bring your own
   image) AKS feature (contact Henry if it does not). You can check using `az
   feature show --namespace Microsoft.ContainerService --name
   AKSHTTPCustomFeatures`.

2) Consider setting your alias as part of `deploy-aks.sh` script.

3) `aksnode` is part of your `~/.ssh/config` and points to the worker node of
   the AKS cluster. Entry similar to this can be used:

   ```config
   Host aksnode
        HostName 10.224.0.4
        User azureuser
        ProxyCommand ssh -p 2022 -W %h:%p azureuser@127.0.0.1
   ```

## Scripts

- `deploy-aks.sh`: Deploys an AKS cluster. It will call into `connect-aks.sh` on completion.
- `connect-aks.sh`: Connects to the AKS cluster. Port forwards local port 2022
  to the worker node of the AKS cluster.
- `init-node.sh`: Adds `runc` runtime class to the node, adds packages to build
  the `tarfs` module, pulls `kata-containers` and builds the `tarfs` module,
  injects it into the kernel. Stops the built in `tardev-snapshotter` and
  uploads the private snapshotter binary to the node. Uploads `solar` to the
  node and signs the expected root hashes. Finally, it switches containerd to
  use the `tardev-snapshotter` and for the `runc` runtime class. Finally, it
  restarts containerd. This might cause a disconnect, so you will need to
  recreate the port forward.
- `reupload-snapshotter.sh`: Reuploads the private snapshotter binary to the
  node.

## Usage

1) Run `deploy-aks.sh` to deploy the AKS cluster.
2) Run `init-node.sh` to prepare the node. You might need to re-establish the
   port forwarding after this step.
3) Run `reupload-snapshotter.sh` if you need to reupload the snapshotter binary
   any time later.
4) Start your `tardev-snapshotter` on the AKS node:

   ```bash
   sudo RUST_LOG=tardev_snapshotter=trace ./tardev-snapshotter /var/lib/containerd/io.containerd.snapshotter.v1.tardev /run/containerd/tardev-snapshotter.sock
   ```

5) Deploy `busybox` pod and observe the snapshotter logs:

   ```bash
   kubectl apply -f k8s/busybox.yaml
   ```

6) If you need to support more container images, you can regenerate the manifest
   as follows:

   ```bash
   kubectl get pods -A -o yaml | grep image: | grep -v message: | cut -d':' -f 2,3 | sort | uniq | tr -d " "
   ```

   Dont forget to readd the `pause` container image (see
   `files/approved-container-images`). Then move it to the node, rerun `solar`
   and restart the `tardev-snapshotter`.

   To run `solar`:

   ```bash
   sudo ./solar --images approved-container-images --signer cert.pem --key key.pem --output /var/lib/containerd/io.containerd.snapshotter.v1.tardev/signatures/signatures.json --passphrase pass:***
   ```

