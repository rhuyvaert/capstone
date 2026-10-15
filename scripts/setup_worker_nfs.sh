#!/bin/bash
# worker node network file share and cluster setup script

# this is run after the net setup and is safe to rerun
set -euo pipefail

# initial config
HEAD_IP="192.168.10.1"
SUBNET="192.168.10.0/24"
CLUSTER_USER="clusteruser"
CLUSTER_UID=2001
CLUSTER_GID=2001

safestop() { echo "Error: $*" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then
    safestop "Run as root: sudo bash $0"
fi

# Step 1
echo "[1/7] Initial checks..."
ping -c 2 -W 2 "$HEAD_IP" > /dev/null || safestop "Can't reach headnode at $HEAD_IP (check if configure_worker_net.sh ran correctly)"

# check if intended UID/GUID is already in use
existing_group=$(getent group "$CLUSTER_GID" | cut -d: -f1 || true)
if [ -n "$existing_group" ] && [ "$existing_group" != "$CLUSTER_USER" ]; then
    safestop "GID $CLUSTER_GID is already in use '$existing_group'"
fi
existing_user=$(getent passwd "$CLUSTER_UID" | cut -d: -f1 || true)
if [ -n "$existing_user" ] && [ "$existing_user" != "$CLUSTER_USER" ]; then
    safestop "UID $CLUSTER_USER is already in use '$existing_user'"
fi

# Step 2
echo "[2/7] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nfs-common openssh-server chrony build-essential gfortran libhwloc-dev libevent-dev libpmix-dev
systemctl enable --now ssh

# Step 3
echo "[3/7] Creating the clusteruser (with UID/GID of ${CLUSTER_UID}, no home directory created)..."
getent group "$CLUSTER_USER" > /dev/null || groupadd -g "$CLUSTER_GID" "$CLUSTER_USER"
id -u "$CLUSTER_USER" > /dev/null 2>&1 || useradd -u "$CLUSTER_UID" -g "$CLUSTER_GID" -d "/home/${CLUSTER_USER}" -M -s /bin/bash "$CLUSTER_USER"

if [ "$(id -u "$CLUSTER_USER")" != "$CLUSTER_UID" ] || [ "$(id -g "$CLUSTER_USER")" != "$CLUSTER_GID" ]; then
    safestop "$CLUSTER_USER exists but its UID/GID is not ${CLUSTER_UID}/${CLUSTER_GID}"
fi

# Step 4
echo "[4/7] Configure NFS mounts..."
mkdir -p "/home/${CLUSTER_USER}" /apps /data

# check fstab
[ -n "$(tail -c1 /etc/fstab)" ] && echo >> /etc/fstab
sed -i '/# BEGIN CLUSTER-NFS/,/# END CLUSTER_NFS/d' /etc/fstab
cat >> /etc/fstab <<EOF
# BEGIN CLUSTER-NFS
${HEAD_IP}:/export/home/${CLUSTER_USER} /home/${CLUSTER_USER} nfs4 defaults,_netdev,nofail 0 0
${HEAD_IP}:/export/apps			/apps		      nfs4 ro,_netdev,nofail       0 0
${HEAD_IP}:/export/data			/data		      nfs4 defaults,_netdev,nofail 0 0
# END CLUSTER-NFS
EOF

systemctl daemon-reload
mount -a

# Step 5
echo "[5/7] Configure time sync between chrony and headnode..."
mkdir -p /etc/chrony/conf.d
grep -q '^confdir' /etc/chrony/chrony.conf || echo "confdir /etc/chrony/conf.d" >> /etc/chrony/chrony.conf
echo "server ${HEAD_IP} iburst prefer" > /etc/chrony/conf.d/cluster.conf
systemctl enable chrony
systemctl restart chrony

# Step 6
echo "[6/7] Build firewall..."
if command -v ufw > /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow from "$SUBNET"
    echo "  ufw: allowed $SUBNET"
else
    echo "  ufw not active, nothing done"
fi

# Step 7
echo "[7/7] Verifying everything..."
FAILS=0
check() { 
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then 
        echo "  OK  $desc"; 
    else 
        echo "  FAIL  $desc"; 
        FAILS=$((FAILS+1)); 
    fi
}

check "$CLUSTER_USER has UID?GID ${CLUSTER_UID}/${CLUSTER_GID}" test "$(id -u "$CLUSTER_USER"):$(id -g "$CLUSTER_USER")" = "${CLUSTER_UID}:${CLUSTER_GID}"
check "/home/${CLUSTER_USER} is an NFS mount" findmt -t nfs4 "/home/${CLUSTER_USER}"
check "/apps is an NFS mount"		      findmt -t nfs4 /apps
check "/data is an NFS mount"		      findmt -t nfs4 /data
check "showmount reaches headnode"	      timeout 15 showmount -e "$HEAD_IP"
check "$CLUSTER_USER can write to /data"      bash -c "runuser -u $CLUSTER_USER -- touch /data/.wtest_\$(hostname) && rm -f /data/.wtest_\$(hostname)"
check "/apps is read-only"		      bash -c "! runuser -u $CLUSTER_USER -- touch /apps/.wtest 2>/dev/null"
check "OpenMPI visible in /apps"	      test -x /apps/openmpi/bin/mpirun

echo "Time sync status:"
chronyc sources 2> /dev/null || true

echo
if ["$FAILS" -eq 0 ]; then
    echo "--- Worker $(hostname) NFS/cluster setup complete: all checks passed ---"
else
    echo "--- Setup finished with $FAILS failed checks, review the FAIL lines above ---"
    exit 1
fi

echo "Next step, add '$(hostname) slots=<physical cores>' to ~/hostfile (use lscpu) on the headnode"
