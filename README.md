# devstats-helm
DevStats deployment on bare metal Kubernetes using Helm

# Installing Kubernetes on bare metal

- Setup 4 packet.net servers, give them hostnames: master, node-0, node-1, node-2.
- Install Ubuntu 18.04 LTS on all of them, then update apt `apt update`.
- Turn swap off on all of them `swapoff -a`.
- Reference: [installing kubeadm](https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/).
- `sudo apt install docker.io`, then `kubeadm config images pull` on all nodes.
- `kubeadm init --pod-network-cidr=10.244.0.0/16` on master.
- `kubeadm join ...` as returde by `kubeadm init` on all nodes (excluding master).
- `sysctl net.bridge.bridge-nf-call-iptables=1`.
- `kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/62e44c867a2846fefb68bd5f178daf4da3095ccb/Documentation/kube-flannel.yml`.
- `kubectl get pods --all-namespaces`.
- `kubectl taint nodes --all node-role.kubernetes.io/master-`.
