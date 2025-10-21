# Formatting and mounting NVMe

```
sudo apt update && sudo apt upgrade
sudo apt install mdadm -y
sudo mdadm --create /dev/md0 --level=10 --raid-devices=8 /dev/nvme[0-7]n1
sudo mkfs.ext4 -L data /dev/md0
sudo mkdir /data
sudo mount /dev/md0 /data
sudo bash -c 'mdadm --detail --scan >> /etc/mdadm/mdadm.conf'
sudo update-initramfs -u
echo "/dev/md0 /data ext4 defaults,noatime 0 0" | sudo tee -a /etc/fstab
```
