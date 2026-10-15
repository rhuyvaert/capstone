#!/bin/bash
set -euo pipefail # reports missing files

REPO_DIR="/local/rhuyvaer/cluster-config-repo"
HOST="$(hostname)"
cd "$REPO_DIR" # change directory to the repo
sudo -v # ask for super user password once up front

# helper function that skips missing files or bad paths
copy() {
    if [ -e "$1" ]; then
        mkdir -p "$(dirname "$2")"
        sudo cp "$1" "$2"
    else
        echo "  skipped (not found): $1"
    fi
}

echo "Syncing configuration files for $HOST..."

# copy PXE config and provisioning files
copy /srv/tftp/pxelinux.cfg/default   pxe/pxelinux-default
copy /etc/dnsmasq.conf                pxe/dnsmasq.conf
copy /srv/www/autoinstall/meta-data   autoinstall/meta-data
copy /srv/www/autoinstall/vendor-data autoinstall/vendor-data
# redact sensitive information from user-data file
if [ -f /srv/www/autoinstall/user-data ]; then
    mkdir -p autoinstall
    sudo sed -E 's/^([[:space:]]*password:).*/\1 "REDACTED"/' \
        /srv/www/autoinstall/user-data > autoinstall/user-data
fi

# copy nginx config
copy /srv/www/default.conf            nginx/default.conf

# Cluster and Network File Share
copy /etc/exports                     "hosts/$HOST/exports"
copy /etc/fstab                       "hosts/$HOST/fstab"
copy /etc/hosts                       "hosts/$HOST/hosts"
copy /etc/nfs.conf                    "hosts/$HOST/nfs.conf"
for f in /etc/netplan/*.yaml; do copy "$f" "hosts/$HOST/netplan/$(basename "$f")"; done

# clusteruser config (no sensitive information)
copy /home/clusteruser/hostfile       cluster/hostfile
copy /home/clusteruser/.bashrc        cluster/clusteruser.bashrc
copy /home/clusteruser/.ssh/config    cluster/ssh_config

# copy setup scripts
copy /scripts/setup_headnode.sh scripts/
copy /scripts/configure_worker_net.sh scripts/
copy /scripts/configure_headnode_net.sh scripts/
copy /scripts/setup_worker_nfs.sh scripts/

# Current state snapshots
mkdir -p "hosts/$HOST"
apt-mark showmanual		>"hosts/$HOST/packages.txt"
sudo ufw status numbered	>"hosts/$HOST/ufw-status.txt" || true
sudo exportfs -v		>"hosts/$HOST/exportfs.txt"   || true
lscpu				>"hosts/$HOST/lscpu.txt"

# fix ownership to prevent commit conflicts
sudo chown -R rhuyvaer:rhuyvaer "$REPO_DIR"

echo "Sync complete! Ready to commit."
git status --short
