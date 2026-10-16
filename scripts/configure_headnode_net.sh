#!/bin/bash
# Head Node Network Setup Script
set -e

# Configuration Variables
WAN_IF="eth0"                 # External interface (enp3s0)
LAN_IF="eth1"                 # Interface connected to cluster switch
HEAD_IP="192.168.10.1/24"
NETPLAN_CONF="/etc/netplan/01-cluster-network.yaml"

echo "[1/3] Generating Netplan Configuration for Head Node..."
cat <<EOF | sudo tee $NETPLAN_CONF > /dev/null
network:
  version: 2
  renderer: networkd
  ethernets:
    $WAN_IF:
      dhcp4: true
    $LAN_IF:
      dhcp4: false
      addresses:
        - $HEAD_IP
EOF

sudo chmod 600 $NETPLAN_CONF
sudo netplan apply

echo "[2/3] Updating /etc/hosts for Node Resolution..."
cat <<EOF | sudo tee -a /etc/hosts > /dev/null

# Beowulf Cluster Nodes (192.168.10.0/24 Subnet)
192.168.10.1   headnode master
192.168.10.11  node01
192.168.10.12  node02
192.168.10.13  node03
192.168.10.14  node04
EOF

echo "[3/3] Enabling IP Forwarding & NAT..."
sudo sysctl -w net.ipv4.ip_forward=1
sudo sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

sudo iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save

echo "=== Head Node Network Configuration Complete ==="
