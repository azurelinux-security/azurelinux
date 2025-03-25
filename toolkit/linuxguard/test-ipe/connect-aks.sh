#!/bin/bash
set -euxo pipefail

# At this point your default profile in kubectl will be the cluster you just created

# Observe both nodes running in your cluster. Note the INTERNAL-IP that we'll use to SSH into these VMs from our debug container later.
kubectl get nodes -o wide

# Get first node name
NODE_NAME=$(kubectl get nodes -o wide | awk 'NR==2{print $1}')

# This creates a debug container with the host OS mounted as /host and chroots into it. This isnt fully a Mariner environment, but its enough to poke around for some things.
kubectl debug node/$NODE_NAME --image=mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11 -- sleep infinity

# Get debugger name
NODE_DEBUGGER=$(kubectl get pods -o wide | awk 'NR==2{print $1}')

sleep 5
kubectl port-forward $NODE_DEBUGGER 2022:22



