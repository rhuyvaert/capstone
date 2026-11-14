#!/bin/bash
# dockerimg.sh - build ONE image (OpenMPI + OpenBLAS + HPL + OSU + sysbench + iperf3) and put the identical image on every node.
# Keep this folder in /apps/hplbox/ (shared, so every node sees it at the same path). Order of work:
#   1. ./dockerimg.sh keys                 on the head, as clusteruser: ssh keys for the containers (in /data/docker/ssh)
#   2. ./dockerimg.sh stage                collect the source tarballs and show what the bare-metal build used, so they match
#   3. ./dockerimg.sh build                build the image on the head (time and size are recorded for D5)
#   4. ./dockerimg.sh registry             start the local registry on the head (needs the registry:2 image once)
#   5. sudo /apps/hplbox/dockerimg.sh node on EVERY worker: trust the registry, add clusteruser to the docker group
#   6. ./dockerimg.sh push                 head: tag and push (timed)
#      ./dockerimg.sh pull                 every worker: pull (timed per node, recorded for D5). 'load' is the offline fallback
#   7. ./dockerimg.sh up                   start one long-running container per node (sshd on port 2222)
#   8. ./dockerimg.sh status               docker present, image ID IDENTICAL on every node, container up, sshd listening
#   9. ./dockerimg.sh smoke                version check, hostname across all nodes, a tiny HPL that must PASS
#      ./dockerimg.sh down | exec CMD...   stop the containers | run a command in the head container
set -uo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
[ -f "$HERE/seriesd.conf" ] || { echo "ERROR: $HERE/seriesd.conf not found" >&2; exit 1; }
. "$HERE/seriesd.conf"

DATA="${DATA_DIR:-/data}"
HOST="$(hostname -s)"
SELF="$(readlink -f "$0")"
IMAGE="$IMAGE_NAME:$IMAGE_TAG"
CSV="$DATA/results/cluster_results.csv"
LOGS="$DATA/cluster_logs"
WORKERS="${WORKERS:-$(awk '!/^[[:space:]]*#/ && NF {print $1}' "$HOSTFILE" 2> /dev/null | grep -vx "$HOST" | tr '\n' ' ')}"
ALL="$HOST $WORKERS"

say() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" > /dev/null 2>&1; }
ok()   { printf '  ok       %s\n' "$*"; }
bad()  { printf '  PROBLEM  %s\n' "$*"; BAD=$(( BAD + 1 )); }
rec() {   # same CSV as the other series: test config metric value unit notes
    mkdir -p "$DATA/results" 2> /dev/null
    [ -s "$CSV" ] || echo "date_time,host,test,config,metric,value,unit,notes" > "$CSV"
    printf '%s,%s,%s,%s,%s,%s,%s,"%s"\n' "$(date -Iseconds)" "${REC_HOST:-$HOST}" "$1" "$2" "$3" "$4" "$5" "${6:-}" >> "$CSV"
}
rsh() {   # rsh NODE "command string": local shell for this machine, ssh for the others
    local n=$1; shift
    if [ "$n" = "$HOST" ]; then bash -c "$*"; else ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$n" "$@"; fi
}

# ---------------------------------------------------------------- keys
cmd_keys() {
    [ "$(id -u)" = "$CLUSTER_UID" ] || say "WARNING: you are UID $(id -u), not $CLUSTER_UID: the containers run as $CLUSTER_UID and must be able to read these keys. Run as clusteruser."
    mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
    [ -f "$KEYDIR/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C hplbox -f "$KEYDIR/id_ed25519"
    cp "$KEYDIR/id_ed25519.pub" "$KEYDIR/authorized_keys"
    cat > "$KEYDIR/config" <<EOF
Host *
    Port $SSH_PORT
    IdentityFile $KEYDIR/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
    chmod 600 "$KEYDIR/id_ed25519" "$KEYDIR/config" "$KEYDIR/authorized_keys"
    say "keys ready in $KEYDIR"
}

# ---------------------------------------------------------------- stage / build
pick() {   # pick NAME OVERRIDE glob...   -> copies the newest match to the build context as NAME.src
    local name=$1 override=$2 f; shift 2
    if [ -n "$override" ]; then f="$override"; else f="$(ls -t "$@" 2> /dev/null | head -n 1)"; fi
    if [ -n "$f" ] && [ -f "$f" ]; then cp "$f" "$CTX/src/$name.src" && say "  $name: $f"; return 0; fi
    say "  $name: NOT FOUND"; return 1
}
cmd_stage() {
    local miss=0 f
    mkdir -p "$CTX/src" || die "cannot create $CTX"
    rm -f "$CTX"/src/*
    say "collecting the source tarballs from $SRC_DIR (set OMPI_TAR / OPENBLAS_TAR / HPL_TAR / OSU_TAR to point elsewhere)"
    pick openmpi  "${OMPI_TAR:-}"     "$SRC_DIR"/openmpi-*.tar.*                                                 || miss=1
    pick openblas "${OPENBLAS_TAR:-}" "$SRC_DIR"/[Oo]pen[Bb][Ll][Aa][Ss]*.tar.* "$SRC_DIR"/v0.3*.tar.* "$SRC_DIR"/0.3*.tar.* || miss=1
    pick hpl      "${HPL_TAR:-}"      "$SRC_DIR"/hpl-*.tar.*                                                     || miss=1
    pick osu      "${OSU_TAR:-}"      "$SRC_DIR"/osu-micro-benchmarks-*.tar.*                                    || say "  (OSU is optional, but D4 needs it)"
    if [ "$miss" = 1 ]; then
        echo
        echo "Missing source tarballs. Put the SAME ones the bare-metal build used into $SRC_DIR (a tarball, not an extracted folder):"
        echo "  OpenMPI   https://download.open-mpi.org/release/open-mpi/   (the version in: /apps/openmpi/bin/ompi_info --version)"
        echo "  OpenBLAS  https://github.com/OpenMathLib/OpenBLAS/releases   (the version in: grep OPENBLAS_VERSION /apps/openblas/include/openblas_config.h)"
        echo "  HPL       https://netlib.org/benchmark/hpl/hpl-2.3.tar.gz"
        die "stage incomplete"
    fi
    cp "$HERE/Dockerfile" "$HERE/Make.docker" "$HERE/entrypoint.sh" "$CTX/"
    ( cd "$CTX/src" && sha256sum ./*.src > "$CTX/src/SHA256SUMS" )
    echo
    say "what the bare-metal build on this machine uses (the image must match):"
    { /apps/openmpi/bin/ompi_info 2> /dev/null | grep -E 'Open MPI:|Configure command'
      grep -E 'OPENBLAS_VERSION|MAX_CPU_NUMBER' /apps/openblas/include/openblas_config.h 2> /dev/null; } | sed 's/^/    /'
    for f in "$SRC_DIR"/hpl*/Make.*; do
        [ -f "$f" ] && [ "${f##*/}" != Make.docker ] && grep -hE '^(CCFLAGS|LAlib|HPL_OPTS)' "$f" | sed "s|^|    ${f##*/}: |"
    done 2> /dev/null | grep -v 'Make.Linux_PII\|Make.UNKNOWN' | head -n 12
    echo "  compare those with Make.docker (CCFLAGS, LAlib) and edit Make.docker if the bare-metal build differs"
}
cmd_build() {
    local conf t0 t1 rc size log
    [ -f "$CTX/Dockerfile" ] && [ -f "$CTX/src/openmpi.src" ] || die "run '$0 stage' first"
    have docker || die "docker is not installed here"
    conf="$(/apps/openmpi/bin/ompi_info 2> /dev/null | sed -n 's/^ *Configure command line: *//p' | head -n 1 | sed "s/'--prefix=[^']*'//; s/'//g")"
    [ -n "$conf" ] || { conf="--with-pmix --with-libevent"; say "no ompi_info here, using the default configure options: $conf"; }
    say "building $IMAGE (OpenMPI configure options: $conf)"
    mkdir -p "$LOGS"; log="$LOGS/docker_build_$(date +%Y%m%d_%H%M).log"
    t0="$(date +%s)"
    docker build --build-arg BASE="$BASE_IMAGE" --build-arg OMPI_CONFIGURE="$conf" --build-arg OPENBLAS_THREADS="$OPENBLAS_THREADS" \
        -t "$IMAGE" "$CTX" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"; t1="$(date +%s)"
    [ "$rc" -eq 0 ] || die "build failed (log: $log). The step that failed is the last RUN line above."
    size="$(docker image inspect --format '{{.Size}}' "$IMAGE" | awk '{printf "%.0f", $1/1000000}')"
    rec D5 "$IMAGE" build_time_s "$(( t1 - t0 ))" s "image=$IMAGE base=$BASE_IMAGE"
    rec D5 "$IMAGE" image_size_mb "$size" MB "image=$IMAGE"
    say "built $IMAGE: ${size} MB in $(( t1 - t0 )) s. Next: registry, push, then pull on the workers."
    docker run --rm "$IMAGE" cat /apps/hplbox-build.txt | sed 's/^/    /'
}

# ---------------------------------------------------------------- registry / push / pull / node
cmd_registry() {
    have docker || die "docker is not installed here"
    docker ps -a --format '{{.Names}}' | grep -qx hplreg && { say "registry container already exists"; docker start hplreg > /dev/null; return; }
    mkdir -p "$DATA/docker/registry"
    docker run -d --restart unless-stopped --name hplreg -p 5000:5000 -v "$DATA/docker/registry:/var/lib/registry" registry:2 \
        || die "could not start the registry (it needs the registry:2 image: 'docker pull registry:2' once on the head, which has internet)"
    say "registry running on $REGISTRY"
}
cmd_push() {
    local t0 t1
    say "pushing $IMAGE to $REGISTRY"
    docker tag "$IMAGE" "$REGISTRY/$IMAGE" || die "image $IMAGE not found: build first"
    t0="$(date +%s)"; docker push "$REGISTRY/$IMAGE" || die "push failed (is the registry up? $0 registry)"; t1="$(date +%s)"
    rec D5 "$IMAGE" push_time_s "$(( t1 - t0 ))" s "to $REGISTRY"
    say "pushed in $(( t1 - t0 )) s"
}
cmd_pull() {   # pulls on every worker, one after another, so each pull is timed on its own
    local n t0 t1
    for n in $WORKERS; do
        say "$n: docker pull $REGISTRY/$IMAGE"
        t0="$(date +%s)"
        if rsh "$n" "docker pull -q $REGISTRY/$IMAGE > /dev/null && docker tag $REGISTRY/$IMAGE $IMAGE"; then
            t1="$(date +%s)"; REC_HOST="$n" rec D5 "$IMAGE" pull_time_s "$(( t1 - t0 ))" s "from $REGISTRY"
            say "$n: pulled in $(( t1 - t0 )) s"
        else say "$n: PULL FAILED (run 'sudo $SELF node' there, and check docker is installed)"; fi
    done
}
cmd_load() {   # offline fallback: stream the image straight from the head, no registry
    local n
    for n in $WORKERS; do
        say "$n: docker load"
        docker save "$IMAGE" | ssh -o BatchMode=yes "$n" docker load || say "$n: load failed"
    done
}
cmd_node() {   # run with sudo on every worker
    local f=/etc/docker/daemon.json
    [ "$EUID" -eq 0 ] || die "run this with sudo"
    have docker || die "docker is not installed on $HOST: it has to come from the offline repo first (docker.io and what it needs)"
    mkdir -p /etc/docker
    if [ ! -f "$f" ]; then printf '{\n  "insecure-registries": ["%s"]\n}\n' "$REGISTRY" > "$f"; say "wrote $f"
    elif grep -q "$REGISTRY" "$f"; then say "$f already trusts $REGISTRY"
    else say "WARNING: $f exists without $REGISTRY: add  \"insecure-registries\": [\"$REGISTRY\"]  by hand"; fi
    systemctl enable docker > /dev/null 2>&1; systemctl restart docker
    getent group docker > /dev/null && usermod -aG docker clusteruser && say "clusteruser is in the docker group (it takes effect at the next login)"
    docker info > /dev/null 2>&1 && say "docker: ok on $HOST" || say "docker does not answer on $HOST"
}

# ---------------------------------------------------------------- containers
cmd_up() {
    local n
    for n in $ALL; do
        say "$n: starting $CONT"
        rsh "$n" "docker rm -f $CONT > /dev/null 2>&1; docker run -d --name $CONT $RUN_FLAGS -e SSH_PORT=$SSH_PORT -e KEYDIR=$KEYDIR -e OMPI_MCA_plm_rsh_agent='ssh -F $KEYDIR/config' $MOUNTS $IMAGE sshd > /dev/null" \
            && say "$n: up" || say "$n: FAILED to start (is $IMAGE there? is clusteruser in the docker group?)"
    done
}
cmd_down() { local n; for n in $ALL; do rsh "$n" "docker rm -f $CONT > /dev/null 2>&1" && say "$n: down"; done; }
cmd_exec() { docker exec -u "$CLUSTER_UID:$CLUSTER_UID" -e OMPI_MCA_plm_rsh_agent="ssh -F $KEYDIR/config" "$CONT" "$@"; }

cmd_status() {
    local n id first="" same=1 up
    BAD=0
    for n in $ALL; do
        if ! rsh "$n" "docker version > /dev/null 2>&1"; then bad "$n: docker not available to this user"; continue; fi
        id="$(rsh "$n" "docker image inspect --format '{{.Id}}' $IMAGE 2> /dev/null")"
        if [ -z "$id" ]; then bad "$n: image $IMAGE not present"; continue; fi
        [ -z "$first" ] && first="$id"; [ "$id" = "$first" ] || same=0
        up="$(rsh "$n" "docker inspect --format '{{.State.Running}}' $CONT 2> /dev/null")"
        [ "$up" = true ] && ok "$n: image ${id:7:12}, container up" || bad "$n: image ${id:7:12}, but container $CONT is not running"
        rsh "$n" "ss -ltn 2> /dev/null | grep -qE ':$SSH_PORT\b'" && ok "$n: sshd listening on $SSH_PORT" || bad "$n: nothing listening on port $SSH_PORT"
    done
    [ "$same" = 1 ] && [ -n "$first" ] && ok "image ID is identical on every node that has it" || bad "image IDs differ (or are missing): the nodes are not running the same image"
    return "$BAD"
}

cmd_smoke() {
    local n hosts="" cnt=0 out d=$DATA/docker/smoke
    BAD=0
    for n in $ALL; do hosts="${hosts:+$hosts,}$n:1"; cnt=$(( cnt + 1 )); done
    mkdir -p "$d"
    out="$(cmd_exec mpirun --version 2>&1 | head -n 1)"; ok "inside the container: $out"
    out="$(cmd_exec mpirun $MPI_FLAGS -np "$cnt" --host "$hosts" hostname 2>&1)"
    for n in $ALL; do echo "$out" | grep -qx "$n" && ok "$n: a rank ran there" || bad "$n: no rank answered (output: $(echo "$out" | head -n 2 | tr '\n' ' '))"; done
    cat > "$d/HPL.dat" <<EOF
HPLinpack benchmark input file
Innovative Computing Laboratory, University of Tennessee
HPL.out      output file name (if any)
6            device out (6=stdout,7=stderr,file)
1            # problems sizes (N)
2000         Ns
1            # NBs
128          NBs
0            PMAP process mapping
1            # process grids (P x Q)
1            Ps
$cnt            Qs
16.0         threshold
1            panel fact
2            PFACTs
1            recursive stopping
4            NBMINs
1            panels in recursion
2            NDIVs
1            recursive panel fact.
2            RFACTs
1            broadcast
1            BCASTs
1            lookahead depth
1            DEPTHs
2            SWAP
64           swapping threshold
0            L1 form
0            U form
1            Equilibration
8            memory alignment
EOF
    out="$(cmd_exec mpirun $MPI_FLAGS --bind-to core -np "$cnt" --host "$hosts" -x OPENBLAS_NUM_THREADS=1 --wdir "$d" /opt/hpl/xhpl 2>&1)"
    echo "$out" | grep -q 'PASSED' && ok "tiny HPL across $cnt nodes: residual PASSED ($(echo "$out" | awk '/^W[RC][0-9A-Z]+ /{print $7 " GFLOPS"}' | head -n 1))" \
        || { bad "tiny HPL did not pass"; echo "$out" | tail -n 8 | sed 's/^/           /'; }
    [ "$BAD" -eq 0 ] && say "smoke test passed" || say "$BAD problem(s)"
    return "$BAD"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
    keys) cmd_keys ;; stage) cmd_stage ;; build) cmd_build ;; registry) cmd_registry ;; push) cmd_push ;;
    pull) cmd_pull ;; load) cmd_load ;; node) cmd_node ;; up) cmd_up ;; down) cmd_down ;;
    status) cmd_status ;; smoke) cmd_smoke ;; exec) cmd_exec "$@" ;;
    "" | -h | --help) sed -n '2,15p' "$SELF" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command '$cmd' (keys stage build registry push pull load node up down status smoke exec)" ;;
esac
