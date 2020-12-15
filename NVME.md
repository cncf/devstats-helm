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
