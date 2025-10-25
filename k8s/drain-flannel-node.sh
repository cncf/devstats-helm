#!/bin/bash
NODE="$(hostname)"
echo "node: $NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force
systemctl stop kubelet
systemctl stop containerd
ip link del cni0    2>/dev/null || true
ip link del flannel.1 2>/dev/null || true
rm -rf /var/lib/cni/networks/cni0
rm -rf /var/lib/cni/flannel            2>/dev/null || true
rm -f  /run/flannel/subnet.env         2>/dev/null || true
systemctl start containerd
systemctl start kubelet
kubectl -n kube-flannel delete pod -l app=flannel --field-selector spec.nodeName="$NODE"
kubectl uncordon "$NODE"
