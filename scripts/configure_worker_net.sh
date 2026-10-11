#!/bin/bash
# Worker Node Network Setup Script
set -e

if [ "$#" -ne 2 ]; then
    echo "Usage: sudo bash configure_worker_net.sh <NODE_NUMBER> <IF_NAME>"
    echo "Example: sudo bash configure_worker_net.sh 1 enp3s0"
    exit 1
fi

NODE_NUM=$1
IF_NAME=$2

# ensure each node gets a subnet ip that is sequential starting at 192.168.10.11
NODE_IP="192.168.10.$((10 + NODE_NUM))"
HOSTNAME="node$(printf "%02d" $NODE_NUM)"
NETPLAN_CONF="/etc/netplan/01-cluster-network.yaml"

echo "[1/3] Setting Hostname to $HOSTNAME..."
sudo hostnamectl set-hostname $HOSTNAME

echo "[2/3] Writing Netplan Config ($NODE_IP on $IF_NAME)..."
cat <<EOF | sudo tee $NETPLAN_CONF > /dev/null
network:
  version: 2
  renderer: networkd
  ethernets:
    $IF_NAME:
      dhcp4: false
      addresses:
        - $NODE_IP/24
      routes:
        - to: default
          via: 192.168.10.1
      nameservers:
        addresses:
          - 192.168.10.1
          - 1.1.1.1
EOF

sudo chmod 600 $NETPLAN_CONF
sudo netplan apply

echo "[3/3] Syncing Cluster /etc/hosts Matrix..."
cat <<EOF | sudo tee -a /etc/hosts > /dev/null

# Beowulf Cluster Host Mapping
192.168.10.1   headnode master
192.168.10.11  node01
192.168.10.12  node02
192.168.10.13  node03
192.168.10.14  node04
EOF

echo "=== Worker Node $HOSTNAME Configuration Complete ==="
