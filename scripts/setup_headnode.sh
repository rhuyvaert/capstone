#!/bin/bash
# Head Node Auto-Provisioning Script for Beowulf Cluster (Updated Subnet: 192.168.10.0/24)
set -e

# Configuration Variables
CLUSTER_USER="clusteruser"
CLUSTER_UID=1001
CLUSTER_GID=1001
EXPORT_DIR="/export"
SUBNET="192.168.10.0/24"

echo "[1/5] Creating NFS Directory Layout..."
mkdir -p ${EXPORT_DIR}/home
mkdir -p ${EXPORT_DIR}/apps/{openmpi,openblas,hpl,slurm}
mkdir -p ${EXPORT_DIR}/data/{hpl_logs,sysbench_logs}

echo "[2/5] Creating Cluster User & Group (UID/GID ${CLUSTER_UID})..."
if ! getent group ${CLUSTER_USER} > /dev/null 2>&1; then
    groupadd -g ${CLUSTER_GID} ${CLUSTER_USER}
fi

if ! id -u ${CLUSTER_USER} > /dev/null 2>&1; then
    useradd -u ${CLUSTER_UID} -g ${CLUSTER_GID} \
            -d ${EXPORT_DIR}/home/${CLUSTER_USER} \
            -m -s /bin/bash ${CLUSTER_USER}
fi

echo "[3/5] Setting Directory Permissions..."
chown -R ${CLUSTER_USER}:${CLUSTER_USER} ${EXPORT_DIR}/home/${CLUSTER_USER}
chown -R ${CLUSTER_USER}:${CLUSTER_USER} ${EXPORT_DIR}/apps
chown -R ${CLUSTER_USER}:${CLUSTER_USER} ${EXPORT_DIR}/data
chmod -R 775 ${EXPORT_DIR}/apps ${EXPORT_DIR}/data

echo "[4/5] Generating SSH Keys for Cluster User..."
sudo -u ${CLUSTER_USER} bash -c "
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ''
        cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
    fi
"

echo "[5/5] Installing & Exporting NFS Server..."
apt-get update -y && apt-get install -y nfs-kernel-server

EXPORTS_CONF="/etc/exports"
if ! grep -q "${EXPORT_DIR}/home" "$EXPORTS_CONF"; then
    cat <<EOF >> "$EXPORTS_CONF"

# Beowulf Cluster NFS Exports (Subnet: 192.168.10.0/24)
${EXPORT_DIR}/home    ${SUBNET}(rw,sync,no_root_squash,no_subtree_check)
${EXPORT_DIR}/apps    ${SUBNET}(ro,sync,no_root_squash,no_subtree_check)
${EXPORT_DIR}/data    ${SUBNET}(rw,sync,no_root_squash,no_subtree_check)
EOF
fi

exportfs -ar
systemctl restart nfs-kernel-server

echo "=== Head Node Setup Complete ==="
