sudo iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited || true
sudo iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited || true
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
sudo systemctl disable --now netfilter-persistent
sudo apt remove iptables-persistent
# sudo reboot
