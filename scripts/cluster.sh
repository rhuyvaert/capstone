#!/bin/bash
#
# Command file for Beowulf Cluster Benchmarks
# Usage:
#   ./cluster.sh check                 	delegates to check_node.sh
#   		 b                     	runs series_b.sh
#   		 c                     	runs series_c.sh
#		 cs			runs slurm version of series c tests
#                start [--quick] b    	runs in background
#                status | stop | tail	checks status of background testing
#		 build-osu FILE		run once to build the osu microbenchmark

set -uo pipefail

DATA="${DATA_DIR:-/data}"
LOGS="$DATA/cluster_logs"
STATUS="$LOGS/status"; PIDF="$LOGS/cluster.pid"
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
OSU="${OSU_DIR:-/apps/osu/libexec/osu-micro-benchmarks/mpi}"

export PATH="/apps/openmpi/bin:$PATH"
export LD_LIBRARY_PATH="/apps/openmpi/lib:/apps/openblas/lib:${LD_LIBRARY_PATH:-}"

say() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" > /dev/null 2>&1; }
setstatus() { echo "$1|$(date +%s)|${2:-}" > "$STATUS"; }

bg_start() {
    [ $# -ge 1 ] || die "usage: $0 start [--quick] b or c"
    mkdir -p "$LOGS"
    setsid -f "$SELF" "$@" > "$LOGS/launch.log" 2>&1 < /dev/null
    say "Started background cluster task: $SELF $*"
    say "Monitor via: $0 status   or   $0 tail"
}

status() {
    local st t detail pid state last
    [ -f "$STATUS" ] || { echo "no background run recorded in $LOGS"; return; }
    IFS='|' read -r st t detail < "$STATUS"; state="$st"
    if [ "$st" = running ] && [ -f "$PIDF" ]; then
        kill -0 "$(cat "$PIDF")" 2> /dev/null || state="DEAD (process terminated)"
    fi
    printf 'state: %s\ntask:  %s  (started %s min ago)\n' "$state" "$detail" "$(( ($(date +%s) - t) / 60 ))"
}

stop() {
    local pid; pid="$(cat "$PIDF" 2> /dev/null)"
    [ -n "$pid" ] || { say "no run in progress"; return; }
    kill -TERM -- "-$pid" 2> /dev/null && say "Stop signal sent." || say "Could not signal $pid (was it started with: $0 start ...?)"
}

tail_log() {
    local f; f="$(ls -t "$LOGS"/session_*.log 2> /dev/null | head -n 1)"
    [ -n "$f" ] || die "no session log found"
    tail -n 25 -f "$f"
}

build_osu() {
    local tb="${1:?usage: $0 build-osu /path/to/osu-micro-benchmarks-X.tar.gz}" dir
    [ -f "$tb" ] || die "no such file: $tb"
    have mpicc || die "mpicc not found (is /apps/openmpi mounted? PATH is $PATH)"
    dir="$(tar tf "$tb" | head -n 1 | cut -d/ -f1)"
    mkdir -p /apps/src && cd /apps/src && tar xf "$tb" && cd "$dir" \
        && ./configure CC=mpicc CXX=mpicxx --prefix=/apps/osu > /dev/null \
        && make -j"$(nproc)" > /dev/null && make install > /dev/null \
        && say "OSU installed successfully into: /apps/osu" || die "OSU build failed"
}

QUICK_ARG=""

run_modular() {
    local target="$1" steps s; shift
    mkdir -p "$LOGS" "$DATA/results" "$DATA/cluster_runs"
    if [ "$target" != check ]; then     # long runs: one at a time, with a status file and a session log
        if [ -f "$PIDF" ] && grep -qa cluster.sh "/proc/$(cat "$PIDF")/cmdline" 2> /dev/null; then
            die "a run is already in progress (pid $(cat "$PIDF")). Stop it first: $0 stop"
        fi
        echo $$ > "$PIDF"
        on_term() { setstatus stopped "stopped by signal"; rm -f "$PIDF"; exit 143; }
        trap on_term TERM INT
        trap 'rc=$?; if [ -f "$PIDF" ]; then if [ "$rc" -eq 0 ]; then setstatus finished "done"; else setstatus failed "exit code $rc"; fi; rm -f "$PIDF"; fi' EXIT
        exec > >(tee -a "$LOGS/session_$(date +%Y%m%d_%H%M).log") 2>&1
    fi
    case "$target" in
        check)  "$DIR/check_node.sh" "$@" ;;
        b)  if [ $# -gt 0 ]; then setstatus running "b $*"; "$DIR/netbench.sh" $QUICK_ARG "$@"
            else for s in b1 b2 b3 b4 b5 b6 b7; do setstatus running "$s"; say "===== $s ====="; "$DIR/netbench.sh" $QUICK_ARG "$s" || say "$s failed"; done; fi ;;
        c)  if [ $# -gt 0 ]; then setstatus running "c $*"; "$DIR/clusterbench.sh" $QUICK_ARG "$@"
            else for s in c1 c2 c4 c3 c5; do setstatus running "$s"; say "===== $s ====="; "$DIR/clusterbench.sh" $QUICK_ARG "$s" || say "$s failed"; done; fi ;;
        cs) if [ $# -gt 0 ]; then setstatus running "cs $*"; "$DIR/slurm_clusterbench.sh" $QUICK_ARG "$@"
            else for s in c1 c2 c3; do setstatus running "cs $s"; say "===== slurm $s ====="; "$DIR/slurm_clusterbench.sh" $QUICK_ARG "$s" || say "slurm $s failed"; done; fi ;;
        *)      die "unknown module target: $target" ;;
    esac
}

[ "${1:-}" = --quick ] && { QUICK_ARG="--quick"; shift; }
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
    check|b|c|cs)
        run_modular "$cmd" "$@"
	;;
    build-osu)
	build_osu "$@"
	exit 0
	;;
    start)  bg_start "$@"; exit $? ;;
    status) status; exit 0 ;;
    stop)   stop; exit 0 ;;
    tail)   tail_log; exit 0 ;;
    "" | -h | --help)
        echo "Usage: $0 {check|b|c|cs|start|status|stop|tail}   (cs = Series C through Slurm)"
        exit 0
        ;;
    *) die "Unknown command '$cmd'" ;;
esac
