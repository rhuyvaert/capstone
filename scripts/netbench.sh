#!/bin/bash
#
# Series B Testing: Networking, MPI and NFS benchmarks
# Usage:
#		./netbench.sh   b*		run only one test b1-b7
#				all		run all 7 tests
#				-- quick	quick smoke/breadth test

set -uo pipefail

# ------- Global Variables ----------------
DATA="${DATA_DIR:-/data}"
HOST="$(hostname -s)"
SELF="$(readlink -f "$0")"
CSV="$DATA/results/cluster_results.csv"
LOGS="$DATA/cluster_logs"
RUNS_DIR="$DATA/cluster_runs"
HEAD_IP="${HEAD_IP:-192.168.10.1}"
LABEL="${LABEL:-}"
MPI_BASE="--prefix /apps/openmpi --mca btl_tcp_if_include 192.168.10.0/24 --mca oob_tcp_if_include 192.168.10.0/24"
OSU="${OSU_DIR:-/apps/osu/libexec/osu-micro-benchmarks/mpi}"
WORKERS="${WORKERS:-$(awk '!/^[[:space:]]*#/ && NF {print $1}' "$HOME/hostfile" 2> /dev/null | grep -vx "$HOST" | tr '\n' ' ')}"
# change between quick and full test
QUICK=0; [ "${1:-}" = --quick ] && { QUICK=1; shift; }
if [ "$QUICK" = 1 ]; then
    : "${NET_TIME:=5}" "${NET_REPS:=1}" "${PING_N:=20}" "${NFS_MB:=64}" "${SMALL_FILES:=100}"
else
    : "${NET_TIME:=60}" "${NET_REPS:=3}" "${PING_N:=500}" "${NFS_MB:=1024}" "${SMALL_FILES:=1000}"
fi
# mpi and library paths
export PATH="/apps/openmpi/bin:$PATH"
export LD_LIBRARY_PATH="/apps/openmpi/lib:/apps/openblas/lib:${LD_LIBRARY_PATH:-}"

# ---------- Helper Functions -----------------
say() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" > /dev/null 2>&1; }
rec() {
    [ -s "$CSV" ] || echo "date_time,host,test,config,metric,value,unit,notes" > "$CSV"
    printf '%s,%s,%s,%s,%s,%s,%s,"%s"\n' "$(date -Iseconds)" "$HOST" "$1" "$2" "$3" "$4" "$5" "${6:-}" >> "$CSV"
}
rsh() { local n=$1; shift; if [ "$n" = "$HOST" ]; then sh -c "$*"; else ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$n" "$@"; fi; }
# check networking info of the node
netinfo() {
    local i s d u="-" p drv
    i="$(ip -o -4 addr 2> /dev/null | awk '/192\.168\.10\./{print $2; exit}')"
    [ -n "$i" ] || { echo "- - - - -"; return; }
    s="$(cat "/sys/class/net/$i/speed" 2> /dev/null || echo -)"
    d="$(cat "/sys/class/net/$i/duplex" 2> /dev/null || echo -)"
    p="$(readlink -f "/sys/class/net/$i/device" 2> /dev/null)"
    while [ -n "$p" ] && [ "$p" != / ]; do
        if [ -r "$p/idVendor" ] && [ -r "$p/speed" ]; then u="$(cat "$p/speed")"; break; fi
        p="$(dirname "$p")"
    done
    drv="$(basename "$(readlink -f "/sys/class/net/$i/device/driver" 2> /dev/null)")"
    echo "$i $s $d $u ${drv:--}"
}
# check response time between node and head
pingstat() {
    ping -c "$2" -i 0.2 "$1" 2>&1 | awk -F'time=' '/time=/{split($2, a, " "); print a[1]}' | sort -n \
        | awk -v sent="$2" '{v[NR]=$1} END{
            if (!NR) { print "- - - - 100"; exit }
            m = (NR%2) ? v[(NR+1)/2] : (v[NR/2] + v[NR/2+1])/2; i = int(NR*0.99 + 0.9999); if (i < 1) i = 1
            printf "%s %s %s %s %.1f\n", m, v[i], v[1], v[NR], 100*(sent-NR)/sent }'
}

dd_rate() { awk '/copied/{for (i=1; i<=NF; i++) if ($i == "s,") t=$(i-1); b=$1} END{if (t > 0) printf "%.1f", b/t/1048576}'; }
# test network file share rate
nfsbench() {
    local f="$DATA/nfs_test_$(hostname -s)" i t0 t1
    case "$1" in
        write) dd if=/dev/zero of="$f" bs=1M count="$2" conv=fsync 2>&1 | dd_rate ;;
        read)  dd if="$f" of=/dev/null bs=1M iflag=direct 2>&1 | dd_rate ;;
        small) mkdir -p "$f.d"; t0="$(date +%s.%N)"
               for i in $(seq "$3"); do : > "$f.d/f$i"; done
               t1="$(date +%s.%N)"; awk -v n="$3" -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", n/(b-a)}'; rm -rf "$f.d" ;;
        clean) rm -rf "$f" "$f.d" ;;
    esac
}

lab() { echo "${LABEL:+label=$LABEL}"; }
iperf_parse() { awk '/receiver/{for (i=1; i<=NF; i++) if ($i == "Mbits/sec") v=$(i-1); if ($1 == "[SUM]") s=v; else l=v} END{print (s != "" ? s : l)}'; }
iperf_start() {
    local i=0 n
    for n in $WORKERS; do i=$(( i + 1 )); iperf3 -s -D -p $(( 5200 + i )) --pidfile "$RUNS_DIR/iperf_$(( 5200 + i )).pid" > /dev/null 2>&1; done
    sleep 1
}
iperf_stop() { local f; for f in "$RUNS_DIR"/iperf_*.pid; do [ -f "$f" ] || continue; kill "$(cat "$f")" 2> /dev/null; rm -f "$f"; done; return 0; }
pairs_list() {
    local a b
    for a in $WORKERS; do echo "$HOST $a"; done
    for a in $WORKERS; do for b in $WORKERS; do [[ "$a" < "$b" ]] && echo "$a $b"; done; done
}
hosts_arg() { local n out=""; for n in "$@"; do out="${out:+$out,}$n:1"; done; echo "$out"; }
osu_val() { mpirun $MPI_BASE --bind-to core --map-by node --host "$2" -np "$3" "$OSU/$1" -m "$4" 2> /dev/null | awk -v s="$4" '$1 == s {print $2}'; }
need_osu() { [ -x "$OSU/pt2pt/osu_latency" ] || die "OSU micro-benchmarks are not built"; }

# Testing Time
# ---------------- Main -----------------
step_b1() {
    local n i spd dup usb drv
    for n in $HOST $WORKERS; do
        read -r i spd dup usb drv <<< "$(rsh "$n" "$SELF netinfo" 2> /dev/null)"
        [ -n "${i:-}" ] || continue
        [ "$spd" != - ] && rec B1 "$n" link_speed "$spd" Mb/s "iface=$i duplex=$dup driver=$drv $(lab)"
        [ "$usb" != - ] && rec B1 "$n" usb_bus_speed "$usb" Mb/s "480=USB2.0 5000=USB3.0 $(lab)"
        say "$n: $i link ${spd} Mb/s $dup usb_bus=$usb driver=$drv"
    done
}

step_b2() {
    local rep n P rev dir v
    iperf_start
    for rep in $(seq "$NET_REPS"); do
        for n in $WORKERS; do for P in 1 4; do for rev in 0 1; do
            dir=up; [ "$rev" = 1 ] && dir=down
            v="$(rsh "$n" "iperf3 -c $HEAD_IP -p 5201 -t $NET_TIME -P $P $([ "$rev" = 1 ] && echo -R) -f m" 2> /dev/null | iperf_parse)"
            [ -n "$v" ] && { rec B2 "$n $dir P=$P" tcp_throughput "$v" Mbit/s "run $rep $(lab)"; say "B2 $n $dir P=$P run $rep: $v Mbit/s"; }
        done; done; done
    done
    iperf_stop
}

ping_row() {
    local med p99 mn mx loss
    read -r med p99 mn mx loss <<< "$(rsh "$1" "$SELF pingstat $3 $PING_N" 2> /dev/null)"
    [ "${med:--}" = - ] && { say "B3 $1 -> $2: no replies"; return; }
    rec B3 "$1 -> $2" rtt_median "$med" ms "n=$PING_N $(lab)"
    rec B3 "$1 -> $2" rtt_p99 "$p99" ms "n=$PING_N"
    rec B3 "$1 -> $2" rtt_max "$mx" ms "n=$PING_N"
    rec B3 "$1 -> $2" packet_loss "$loss" % "n=$PING_N"
    say "B3 $1 -> $2: median ${med} ms, p99 ${p99} ms, loss ${loss}%"
}
step_b3() {
    local n a b
    for n in $WORKERS; do ping_row "$n" "$HOST" "$HEAD_IP"; done
    while read -r a b; do [ "$a" = "$HOST" ] || ping_row "$a" "$b" "$b"; done <<< "$(pairs_list)"
}

step_b4() {
    need_osu
    local rep a b v
    for rep in $(seq "$NET_REPS"); do
        while read -r a b; do
            v="$(osu_val pt2pt/osu_latency "$(hosts_arg "$a" "$b")" 2 8)";       [ -n "$v" ] && rec B4 "$a <-> $b" latency_8B "$v" us "run $rep"
            v="$(osu_val pt2pt/osu_bw "$(hosts_arg "$a" "$b")" 2 1048576)";      [ -n "$v" ] && rec B4 "$a <-> $b" bandwidth_1MB "$v" MB/s "run $rep"
            v="$(osu_val pt2pt/osu_bibw "$(hosts_arg "$a" "$b")" 2 1048576)";    [ -n "$v" ] && rec B4 "$a <-> $b" bibandwidth_1MB "$v" MB/s "run $rep"
            say "B4 $a <-> $b run $rep done"
        done <<< "$(pairs_list)"
    done
}

step_b5() {
    need_osu
    local rep k n nodes prog size v nw=0
    for n in $WORKERS; do nw=$(( nw + 1 )); done
    for rep in $(seq "$NET_REPS"); do
        for (( k = 1; k <= nw; k++ )); do
            nodes="$(config_nodes "h$k")"
            for prog in osu_bcast osu_allreduce; do for size in 8 1048576; do
                v="$(osu_val "collective/$prog" "$(hosts_arg $nodes)" "$(( k + 1 ))" "$size")"
                [ -n "$v" ] && rec B5 "h$k" "${prog}_${size}B" "$v" us "nodes=$(echo $nodes | tr ' ' '+') run $rep"
            done; done
            say "B5 h$k ($(( k + 1 )) nodes) run $rep done"
        done
    done
}

step_b6() {
    local rep n i v sum j a b arr pids
    iperf_start
    for rep in $(seq "$NET_REPS"); do
        i=0; sum=0; pids=()
        for n in $WORKERS; do
            i=$(( i + 1 ))
            rsh "$n" "iperf3 -c $HEAD_IP -p $(( 5200 + i )) -t $NET_TIME -f m" > "$RUNS_DIR/b6_$n.txt" 2> /dev/null &
            pids+=($!)
        done
        wait "${pids[@]}"
        for n in $WORKERS; do
            v="$(iperf_parse < "$RUNS_DIR/b6_$n.txt")"
            [ -n "$v" ] && { rec B6 "all->head $n" tcp_throughput "$v" Mbit/s "run $rep $(lab)"; sum="$(awk -v a="$sum" -v b="$v" 'BEGIN{print a+b}')"; }
        done
        rec B6 "all->head" aggregate "$sum" Mbit/s "run $rep $(lab)"
        say "B6 all workers -> head, run $rep: $sum Mbit/s aggregate"
    done
    iperf_stop
}

step_b7() {
    local rep n mode v unit sum pids
    for rep in $(seq "$NET_REPS"); do
        for n in $HOST $WORKERS; do
            for mode in write read small; do
                v="$(rsh "$n" "$SELF nfsbench $mode $NFS_MB $SMALL_FILES" 2> /dev/null)"
                unit=MiB/s; [ "$mode" = small ] && unit=files/s
                [ -n "$v" ] && { rec B7 "$n $mode" throughput "$v" "$unit" "run $rep $(lab)"; say "B7 $n $mode run $rep: $v $unit"; }
            done
        done
    done
    for n in $HOST $WORKERS; do rsh "$n" "$SELF nfsbench clean 0 0" > /dev/null 2>&1; done
}

cmd="${1:-}"; shift || true
case "$cmd" in
    netinfo|pingstat|nfsbench) "$cmd" "$@"; exit $? ;;
    b1|b2|b3|b4|b5|b6|b7) "step_$$cmd"; exit 0 ;;
    *) die "unknown command for series_b.sh: $cmd" ;;
esac
