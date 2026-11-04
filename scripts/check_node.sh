#!/bin/bash

# a standalone script to check cluster readiness for benchmarking
# run on each node to verify dependencies and health
# added additional functionality for series 2 and 3 testing

set -uo pipefail

# ---------- settings ------------
DATA="${DATA_DIR:-/data}"
HOST="$(hostname -s)"
HPL="${HPL_BIN:-$HOME/hpl-run/xhpl}"
OSU="${OSU_DIR:-/apps/osu/libexec/osu-micro-benchmarks/mpi}"
HOSTFILE="${HOSTFILE:-$HOME/hostfile}"
WORKERS="${WORKERS:-$(awk '!/^[[:space:]]*#/ && NF {print $1}' "$HOSTFILE" 2> /dev/null | grep -vx "$HOST" | tr '\n' ' ')}"
REPO_DIR="${REPO_DIR:-/srv/www/cluster-repo}"
REPO_URL="${REPO_URL:-http://192.168.10.1:8085/cluster-repo}"

export PATH="/apps/openmpi/bin:$PATH"
export LD_LIBRARY_PATH="/apps/openmpi/lib:/apps/openblas/lib:${LD_LIBRARY_PATH:-}"

# ------ helper functions ---------
say() { echo "[$(date +%H:%M:%S)] $*"; }  	# prints date time
die() { echo "ERROR: $*" >&2; exit 1; }		# callout for a failure
have() { command -v "$1" > /dev/null 2>&1; }	# supress errors and redirect them to stdout
rsh() {						# determine if local shell or ssh to connect
    local n=$1; shift
    if [ "$n" = "HOST" ]; then sh -c "$*";
    else ssh -nn -o BatchMode=yes -o ConnectTimeout=5 "$n" "$@";
    fi
}
rnode() {  # parse csv files for each node and get required information to sort nodes by speed
    local f="$DATA/results/${1}_results.csv" ov="RNODE_$1"
    [ -n "${!ov:-}" ] && { echo "${!ov}"; return; }
    [ -s "$f" ] || return 0
    awk -F, 'NR==1{next}
             $3=="A7" && $5=="gflops" && $6!="" {print $6}' "$f" \
        | sort -n | awk '{a[NR]=$1} END{if (NR) print (NR%2) ? a[(NR+1)/2] : (a[NR/2] + a[(NR/2)+1])/2}'
}
cores()    { lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l; }
threads()  { getconf _NPROCESSORS_ONLN; }
mem_kb()   { awk '/^MemTotal:/{print $2}' /proc/meminfo; }
avail_kb() { awk '/^MemAvailable:/{print $2}' /proc/meminfo; }

TEMPF="${BENCH_TEMP_FILE:-}"
if [ -z "$TEMPF" ]; then
    for z in /sys/class/thermal/thermal_zone*; do
        [ "$(cat "$z/type" 2> /dev/null)" = x86_pkg_temp ] && { TEMPF="$z/temp"; break; }
    done
fi
[ -z "$TEMPF" ] && TEMPF="$(grep -lE 'coretemp|k10temp' /sys/class/hwmon/hwmon*/name 2> /dev/null | head -n 1 | sed 's/name$/temp1_input/')"
temp() { [ -r "${TEMPF:-}" ] && echo $(( $(cat "$TEMPF") / 1000 )); }

# ------- readiness check -----------
step_check() {
    local bad=0 n t r
    ok()   { printf '  ok       %s\n' "$*"; }
    miss() { printf '  MISSING  %s\n' "$*"; bad=$(( bad + 1 )); }
    note() { printf '  note     %s\n' "$*"; }

    echo "== head node ($HOST): base programs & environment"
    for t in awk sed grep sort cut tr tee df lscpu lsblk getconf free pkill mktemp timeout; do
        have "$t" && ok "$t" || miss "$t (part of base system)"
    done

    have mpirun && ok "mpirun" || miss "mpirun (is /apps mounted?)"
    [ -x "$HPL" ] && ok "xhpl at $HPL" || miss "xhpl at $HPL (set HPL_BIN)"
    have iperf3 && ok "iperf3 (needed for network benchmarks)" || miss "iperf3 (sudo apt install iperf3)"
    [ -x "$OSU/pt2pt/osu_latency" ] && ok "OSU micro-benchmarks in $OSU" || note "OSU micro-benchmarks not built (needed for Series B4/B5)"
    [ -w "$DATA" ] && ok "$DATA writable" || miss "$DATA not writable"

    echo "== cluster worker nodes: $WORKERS"
    if [ -z "$WORKERS" ]; then
        note "no worker nodes found in $HOSTFILE"
    else
        for n in $WORKERS; do
            if ! rsh "$n" true > /dev/null 2>&1; then
                miss "$n: ssh failed"
                continue
            fi
            ok "$n: ssh connection active"
            for t in iperf3 sysbench ping dd; do
                rsh "$n" "command -v $t > /dev/null" && ok "$n: $t available" || note "$n: $t missing (can be installed via offline repo)"
            done
            r="$(rnode "$n")"
            [ -n "$r" ] && ok "$n: Series A HPL baseline ($r GFLOPS)" || note "$n: no Series A HPL result found (needed for node ordering)"
        done
    fi

    echo
    if [ "$bad" -eq 0 ]; then
        say "All system checks passed successfully. Node is ready."
    else
        say "$bad critical problem(s) detected. Fix the MISSING items above."
    fi
    return "$bad"
}

step_check "$@"
