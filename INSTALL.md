# Installation from scratch

Status at 2024-10-10:

- Download the newest Debian - [Debian 12.7.0](https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.7.0-amd64-netinst.iso).
- Install it on a PC or VM or wherever you want to run Kubernetes.
- Enable root login `vim /etc/ssh/sshd_config` add line `PermitRootLogin yes`, change `PasswordAuthentication no` to `PasswordAuthentication yes` then `sudo service sshd restart`.
