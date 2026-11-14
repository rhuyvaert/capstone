#!/bin/bash
# "sshd" starts an unprivileged sshd on $SSH_PORT (default 2222) as the container user (clusteruser, UID 2001),
# so mpirun inside the head container can start orted in the other nodes' containers. Anything else just runs.
set -e
if [ "${1:-}" = sshd ]; then
    K="$HOME/.sshd"; mkdir -p "$K"; chmod 700 "$K"
    [ -f "$K/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$K/host_ed25519"
    cat > "$K/sshd_config" <<CFG
Port ${SSH_PORT:-2222}
HostKey $K/host_ed25519
PidFile $K/sshd.pid
AuthorizedKeysFile ${KEYDIR:-/data/docker/ssh}/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PrintMotd no
CFG
    exec /usr/sbin/sshd -D -e -f "$K/sshd_config"
fi
exec "$@"
