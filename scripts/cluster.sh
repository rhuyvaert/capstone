#!/bin/bash
#
# Command file for Beowulf Cluster Benchmarks
# Usage:
#   ./cluster.sh check                 	delegates to check_node.sh
#   		 b                     	runs series_b.sh
#   		 c                     	runs series_c.sh
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
    kill -TERM -- "-$pid" 2> /dev/null && say "Stop signal sent." || say "Could not signal $pid"
    rm -f "$PIDF"
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

run_modular() {
    echo $$ > "$PIDF"

    local target="$1"; shift
    case "$target" in
        check)  "$DIR/check_node.sh" "$@" ;;
        b)      "$DIR/netbench.sh" "$@" ;;
        c)      "$DIR/clusterbench.sh" "$@" ;;
        *)      die "unknown module target: $target" ;;
    esac
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
    check|b|c)
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
        echo "Usage: $0 {check|b|c|start|status|stop|tail}"
        exit 0
        ;;
    *) die "Unknown command '$cmd'" ;;
esac
