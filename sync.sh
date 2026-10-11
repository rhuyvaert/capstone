#!/bin/bash
echo "Syncing configuration files..."
REPO_DIR="/home/rhuyvaer/cluster-config-repo"

# copy PXE config
sudo cp /srv/tftp/pxelinux.cfg/default ./pxe/pxelinux-default

# copy all yaml files
cp /srv/www/autoinstall/user-data ./autoinstall/
cp /srv/www/autoinstall/meta-data ./autoinstall/
cp /srv/www/autoinstall/vendor-data ./autoinstall/

# copy server configs
cp /srv/www/default.conf ./nginx/default.conf

# fix ownership to prevent commit conflicts
sudo chown -R rhuyvaer:rhuyvaer "$REPO_DIR"

echo "Sync complete! Ready to commit."
