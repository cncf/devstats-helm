# devstats-helm

DevStats deployment on Oracle Cloud Ubuntu 24.04 LTS bare metal Kubernetes using Helm.

This is deployed:
- [CNCF prod](https://devstats.cncf.io).

# Shared steps for all nodes (master and workers)

- As root: `sudo bash`:

```
passwd
passwd ubuntu
apt update -y && apt upgrade -y
apt install mdadm mc -y
mdadm --create /dev/md0 --level=10 --raid-devices=8 /dev/nvme[0-7]n1
mkfs.ext4 -L data /dev/md0
mkdir /data                         
mount /dev/md0 /data
bash -c 'mdadm --detail --scan >> /etc/mdadm/mdadm.conf'                                                           
update-initramfs -u
UUID=$(blkid -s UUID -o value /dev/md0)
echo "UUID=$UUID /data ext4 defaults,noatime,x-systemd.before=local-fs.target,x-systemd.requires=local-fs-pre.target 0 2" | tee -a /etc/fstab
umount /data
mount -a
systemctl daemon-reload
mkdir -p /data/{containerd,kubelet,etcd,logs/{containers,pods}}
chown -R root:root /data
chmod 755 /data
ln -s /data/containerd /var/lib/containerd
ln -s /data/kubelet /var/lib/kubelet
ln -s /data/logs/pods /var/log/pods
ln -s /data/logs/containers /var/log/containers
ln -s /data/etcd /var/lib/etcd
```

# Steps for Kubernetes master node

```
```

# Steps for Kubernetes worker nodes

```
```
