#!/bin/bash
set -euo pipefail # reports missing files

# this shell script doesn't push or commit anything to github, review local distro first then manually commit and push
REPO_DIR="${REPO_DIR:-/local/rhuyvaer/cluster-config-repo}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/scripts}"
CLUSTER_HOME="${CLUSTER_HOME:-/home/clusteruser}"
WWW_DIR="${WWW_DIR:-/srv/www}"
HOSTFILE="$CLUSTER_HOME/hostfile"
HOST="$(hostname)"

cd "$REPO_DIR" 							# change directory to the repo
sudo -v 							# ask for super user password once up front
sudo chown -R "$(id -un):$(id -gn)" "$REPO_DIR"			# make sure there are no files with root-owned permissions

# helper functions-------------------------------------------------------------------------------------------
# copy function that skips missing files
copy() {
    local src="$1" dest="$2" mode="${3:-}"
    if ! sudo test -e "$src"; then
        echo "  skipped  $src (not found)"; return 0
    fi
    if [ -e "$dest" ] && [ "$src" -ef "$dest" ]; then
        echo "  same     $src"; return 0
    fi
    mkdir -p "$(dirname "$dest")"
    if [ "$mode" = redact ]; then
        sudo cat "$src" | redact_secrets > "$dest.tmp" \
            || { rm -f "$dest.tmp"; echo "  FAILED   $src"; return 0; }
    else
        sudo cat "$src" > "$dest.tmp" \
            || { rm -f "$dest.tmp"; echo "  FAILED   $src"; return 0; }
    fi
    mv -f "$dest.tmp" "$dest"
    echo "  ok       $src"
}
# advanced copy function that copies top-level regular files from a directory
copy_dir()  {
    local srcdir="$1" destdir="$2" f
    shift 2
    if ! sudo test -d "$srcdir"; then
        echo "  skipped  $srcdir/ (not found)"; return 0
    fi
    while IFS= read -r -d '' f; do
        copy "$f" "$destdir/$(basename "$f")"
    done < <(sudo find "$srcdir" -maxdepth 1 -type f "$@" -print0)
}
# a snapshot function that saves outputs of commonly used commands
snap() {
    local dest="$1"; shift
    mkdir -p "$(dirname "$dest")"
    if "$@" > "$dest.tmp" 2>/dev/null; then
        mv -f "$dest.tmp" "$dest"; echo "  ok	$dest"
    else
        rm -f "$dest.tmp"; echo "  skipped	$dest (command failed: $*)"
    fi
}
# function that checks the remote worker nodes through clusteruser with a key-based ssh
remote() {
    local node="$1"; shift
    sudo -H -u clusteruser ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new "$node" "$@"
}
# function that connects to the remote nodes using the remote function
remote_to() {
    local node="$1" dest="$2" cmd="$3"
    mkdir -p "$(dirname "$dest")"
    if remote "$node" "$cmd" > "$dest.tmp" 2>/dev/null; then
        mv -f "$dest.tmp" "$dest"; echo "  ok	$node: $cmd"
    else
        rm -f "$dest.tmp"; echo "  skipped	$node: $cmd"
    fi
}
# redact function that protects sensitive information
redact_secrets() {
    sed -E \
        -e 's/^([[:space:]]*password:).*/\1 "REDACTED"/' \
        -e 's/(echo "[A-Za-z0-9_.-]+:)[^"]*(" *\| *chpasswd)/\1REDACTED\2/'
}

echo "Syncing configuration files for $HOST into $REPO_DIR..."

# 1. copy PXE config and provisioning files ----------------------------------------------
echo "[1/7] autoinstall, pxe, and web server files"
copy /srv/tftp/pxelinux.cfg/default     pxe/pxelinux-default
copy /srv/tftp/grub/grub.cfg		pxe/grub.cfg
copy /etc/dnsmasq.conf                  pxe/dnsmasq.conf
copy_dir /etc/dnsmasq.d			pxe/dnsmasq.d
copy_dir /etc/nginx/conf.d		nginx/conf.d
copy "$WWW_DIR/default.conf"		nginx/default.conf
copy "$WWW_DIR/autoinstall/meta-data"   autoinstall/meta-data
copy "$WWW_DIR/autoinstall/vendor-data" autoinstall/vendor-data
copy "$WWW_DIR/autoinstall/user-data"	autoinstall/user-data redact
#snapshot of the files staged in local repo
snap pxe/cluster-repo-packages.txt bash -c "ls '$WWW_DIR/cluster-repo' | grep -F .deb"

# 2. Cluster and Network File Share ------------------------------------------------------
echo "[2/7] cluster scripts from $SCRIPTS_DIR"
copy_dir "$SCRIPTS_DIR" scripts -name '* .sh'
chmod +x scripts/*.sh 2>/dev/null || true

# 3. Headnode config files ---------------------------------------------------------------
echo "[3/7] Head node configuration files from ($HOST)"
copy /etc/exports			"hosts/$HOST/exports"
copy /etc/fstab				"hosts/$HOST/fstab"
copy /etc/hosts				"hosts/$HOST/hosts"
copy /etc/nfs.conf			"hosts/$HOST/nfs.conf"
copy /etc/chrony/chrony.conf		"hosts/$HOST/chrony.conf"
copy /etc/chrony/conf.d/cluster.conf	"hosts/$HOST/chrony-cluster.conf"
copy_dir /etc/netplan 			"hosts/$HOST/netplan" -name '*.yaml'

# 4. clusteruser config and files (no sensitive information) ----------------------------
echo "[4/7] Cluster files"
copy "$HOSTFILE"			cluster/hostfile
copy "$CLUSTER_HOME/.bashrc"		cluster/clusteruser.bashrc
copy "$CLUSTER_HOME/.ssh/config"	cluster/ssh_config
copy "$CLUSTER_HOME/hello.c"		cluster/hello.c
copy_dir "$CLUSTER_HOME/hpl-run"	cluster/hpl \( -name '*.dat' -o -name '*.sh' \)

# 5. Build records and benchmark results ------------------------------------------------
echo "[5/7] Build records and results"
while IFS= read -r f; do
    copy "$f" build/Make.openblas
done < <(sudo find /apps/src -maxdepth 2 -name Make.openblas 2>/dev/null | head -n 1)
mkdir -p build
{
    echo "# Build record, generated $(date -u +%Y-%m-%d)"
    echo "## OpenMPI"
    sudo -u clusteruser env LD_LIBRARY_PATH=/apps/openmpi/lib /apps/openmpi/bin/ompi_info 2>/dev/null \
        | grep -iE "^ *Open MPI:|Configure command line" || echo "(not found)"
    echo "## OpenBLAS"
    grep -m1 OPENBLAS_VERSION /apps/openblas/include/openblas_config.h 2>/dev/null || echo "(not found)"
    echo "## HPL"
    ls -d /apps/src/hpl-* 2>/dev/null || echo "(not found)"
} > build/versions.txt
echo " ok	build/versions.txt"
# only include small result files (>1MB)
copy_dir /data/hpl_logs			results/hpl_logs	-size -1M
copy_dir /data/sysbench_logs		results/sysbench_logs	-size -1M

# 6. Current state snapshots ---------------------------------------------------------
echo "[6/7] Snapshots of $HOST"
H="hosts/$HOST"
snap "$H/os-release.txt"		cat /etc/os-release
snap "$H/lscpu.txt"			lscpu
snap "$H/ip-addr.txt"			ip -br a
snap "$H/mounts.txt"			findmnt --real -o TARGET,SOURCE,FSTYPE,OPTIONS
snap "$H/packages.txt"			apt-mark showmanual
snap "$H/ufw-status.txt"		sudo ufw status numbered
snap "$H/exportfs.txt"			sudo exportfs -v
snap "$H/chrony-sources.txt"		chronyc sources

# 7. Worker node information (read over ssh) -----------------------------------------
echo "[7/7] Worker nodes listed in $HOSTFILE"
NODES=""
if sudo test -f "$HOSTFILE"; then
    NODES="$(sudo awk '!/^[[:space:]]*#/ && NF {print $1}' "$HOSTFILE" | grep -vx "$HOST" || true)"
fi
if [ -z "$NODES" ]; then
    echo " no worker nodes found in hostfile"
fi
for node in $NODES; do
    echo "$node"
    if ! err="$(remote "$node" true 2>&1)"; then
        echo " unreachable over SSH, skipping. Reason:"
        echo "$err" | head -n 3 | sed 's/^/	/'
        continue
    fi
    d="hosts/$node"
    remote_to "$node" "$d/fstab"		"cat /etc/fstab"
    remote_to "$node" "$d/hosts"		"cat /etc/hosts"
    remote_to "$node" "$d/chrony-cluster.conf"	"cat /etc/chrony/conf.d/cluster.conf"
    remote_to "$node" "$d/os-release.txt"	"cat /etc/os-release"
    remote_to "$node" "$d/lscpu.txt"		"lscpu"
    remote_to "$node" "$d/mounts.txt"		"findmnt --real -o TARGET,SOURCE,FSTYPE,OPTIONS"
    remote_to "$node" "$d/ip-addr.txt"		"ip -br a"
    remote_to "$node" "$d/packages.txt"		"apt-mark showmanual"
    remote_to "$node" "$d/chrony-sources.txt"	"chronyc sources"
done
# the netplan for worker nodes is made by the configure_worker_net.sh file in scripts
# fix ownership to prevent commit conflicts

# CLEANUP ---------------------------------------------------------------------------
sudo chown -R rhuyvaer:rhuyvaer "$REPO_DIR"
rm "$dest.tmp"
echo "Sync complete! Ready to commit."
git status --short
