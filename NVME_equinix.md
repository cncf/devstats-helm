# Formatting and mounting NVMe

- `apt update && apt upgrade`.
- `apt-get install lvm2`.
- `lvmdiskscan`.
- Carefully, do not use disk that is already mounted as `/`: `pvcreate /dev/nvme0n1 /dev/nvme1n1`.
- `pvs`.
- `vgcreate LVMVolGroup /dev/nvme0n1 /dev/nvme1n1`.
- `vgs`.
- `lvcreate -l 100%FREE -n data LVMVolGroup`.
- `mkfs.ext4 /dev/LVMVolGroup/data`.
- `mount /dev/LVMVolGroup/data /var/openebs -t ext4`.
- `vim /etc/fstab` add `/dev/mapper/LVMVolGroup-data /var/openebs ext4 rw 0 0`.


# Additional disks

- `apt install -y parted`.
- `lsblk; df -h`, chgoose non-mounted disk: `parted -a optimal /dev/sdb mklabel gpt`.
- `parted -a optimal /dev/sdb mkpart primary ext4 0% 100%`
- `mkfs.ext4 /dev/sdb1`.
- `mkdir /data`.
- `mount /dev/sdb1 /var/openebs -t ext4`.
- `vim /etc/fstab` add `/dev/sdb1 /data ext4 rw 0 0`.
