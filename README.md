# devstats-helm

DevStats deployment on Oracle Cloud Ubuntu 24.04 LTS bare metal Kubernetes using Helm.

This is deployed:
- [CNCF prod](https://devstats.cncf.io).

# Shared steps for all nodes (master and workers)

- As root: `sudo bash`:

```
passwd
passwd ubuntu
apt update && apt upgrade
apt install mdadm -y
mdadm --create /dev/md0 --level=10 --raid-devices=8 /dev/nvme[0-7]n1
mkfs.ext4 -L data /dev/md0
mkdir /data                         
mount /dev/md0 /data
bash -c 'mdadm --detail --scan >> /etc/mdadm/mdadm.conf'                                                           
update-initramfs -u
echo "/dev/md0 /data ext4 defaults,noatime 0 0" | tee -a /etc/fstab
```

# Steps for Kubernetes master node

```
```

# Steps for Kubernetes worker nodes

```
```
