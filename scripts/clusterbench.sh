#!/bin/bash
#
# Series C Testing: Scalability, strong scaling, Rmax, and cluster tuning.
# Usage:
#		./series_c.sh   c*		run only one test c1-c5
#				report		display test results for test c2 and c3
#				summary		display min/med/max test results
#				order		reorder the nodes by speed
#				--quick		quick smoke/breadth test

set -uo pipefail

# ------------- Global Variables ----------------
DATA="${DATA_DIR:-/data}"
HOST="$(hostname -s)"
SELF="$(readlink -f "$0")"
CSV="$DATA/results/cluster_results.csv"
LOGS="$DATA/cluster_logs"
RUNS_DIR="$DATA/cluster_runs"
STATE="$LOGS/state.env"
HPL="${HPL_BIN:-$HOME/hpl-run/xhpl}"
HEAD_IP="${HEAD_IP:-192.168.10.1}"
MPI_BASE="--prefix /apps/openmpi --mca btl_tcp_if_include 192.168.10.0/24 --mca oob_tcp_if_include 192.168.10.0/24"
WORKERS="${WORKERS:-$(awk '!/^[[:space:]]*#/ && NF {print $1}' "$HOME/hostfile" 2> /dev/null | grep -vx "$HOST" | tr '\n' ' ')}"
# change between quick and full run
QUICK=0; [ "${1:-}" = --quick ] && { QUICK=1; shift; }
if [ "$QUICK" = 1 ]; then
    : "${C1_TIME:=5}" "${C_RUNS:=1}" "${N_FIX:=3840}" "${N_TUNE:=3840}" "${NCAP:=7680}" "${TUNE_REPS:=1}" "${REST:=2}" "${RUN_TIMEOUT:=600}" \
      "${TUNE_NBS:=128 192}" "${TUNE_POLS:=cores prop}" "${TUNE_PQS:=auto thin}" "${TUNE_BCASTS:=1 2}" "${TUNE_DEPTHS:=0 1}"
else
    : "${C1_TIME:=30}" "${C_RUNS:=5}" "${N_FIX:=15360}" "${N_TUNE:=27648}" "${NCAP:=0}" "${TUNE_REPS:=2}" "${REST:=30}" "${RUN_TIMEOUT:=14400}" \
      "${TUNE_NBS:=128 192 256 384}" "${TUNE_POLS:=cores prop leave1 one}" "${TUNE_PQS:=auto thin mid}" "${TUNE_BCASTS:=0 1 2 3 4 5}" "${TUNE_DEPTHS:=0 1}"
fi
: "${MEM_FRAC:=0.8}" "${DEFAULT_NB:=192}"

# mpi and library path
export PATH="/apps/openmpi/bin:$PATH"
export LD_LIBRARY_PATH="/apps/openmpi/lib:/apps/openblas/lib:${LD_LIBRARY_PATH:-}"

# --------------- Helper Functions ---------------------------------
say() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
rec() {
    [ -s "$CSV" ] || echo "date_time,host,test,config,metric,value,unit,notes" > "$CSV"
    printf '%s,%s,%s,%s,%s,%s,%s,"%s"\n' "$(date -Iseconds)" "$HOST" "$1" "$2" "$3" "$4" "$5" "${6:-}" >> "$CSV"
}
setstate() { sed -i "/^$1=/d" "$STATE" 2> /dev/null; echo "$1=$2" >> "$STATE"; }
rsh() { local n=$1; shift; if [ "$n" = "$HOST" ]; then sh -c "$*"; else ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$n" "$@"; fi; }

declare -A CORES MEMKB AVAILKB
load_facts() {
    local n
    for n in $HOST $WORKERS; do
        read -r "CORES[$n]" "MEMKB[$n]" "AVAILKB[$n]" _ <<< "$(rsh "$n" "lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l; awk '/^MemTotal:/{print \$2}' /proc/meminfo; awk '/^MemAvailable:/{print \$2}' /proc/meminfo; echo" 2> /dev/null | tr '\n' ' ')"
    done
}

# parse results CSV file for each node and find max perf info
rnode() {
    local f="$DATA/results/${1}_results.csv"
    [ -s "$f" ] || return 0
    awk -F, 'NR==1{old = ($3=="test_id"); next}
             old  && $3=="A7" && $6=="rmax_node" {print $7}
             !old && $3=="A7" && $4=="maxN" && $5=="gflops" && $6!="" {print $6}' "$f" \
        | sort -n | awk '{a[NR]=$1} END{if (NR) print (NR%2) ? a[(NR+1)/2] : (a[NR/2] + a[NR/2+1])/2}'
}

# parse results CSV file for each node and find median perf info
a3_median() {
    local f="$DATA/results/${1}_results.csv"
    [ -s "$f" ] || return 0
    awk -F, -v t="$2" 'NR==1{old = ($3=="test_id"); next}
             old  && $3=="A3" && $4=="cpu_t" t && $6=="events_per_sec" {print $7}
             !old && $3=="A3" && $4=="threads=" t && $5=="events_per_sec" {print $6}' "$f" \
        | sort -n | awk '{a[NR]=$1} END{if (NR) print (NR%2) ? a[(NR+1)/2] : (a[NR/2] + a[NR/2+1])/2}'
}

# reorder the nodes based on speed(fastest-slowest)
order_nodes() {
    ORDER="$(for n in $WORKERS; do r="$(rnode "$n")"; echo "${r:-0} $n"; done | sort -rn | awk '{print $2}' | tr '\n' ' ')"
}

# modify nodes for the test
config_nodes() {
    local l="$1" rev=0 k list
    case "$l" in only:*) echo "${l#only:}"; return ;; r[wh]*) rev=1; l="${l#r}" ;; esac
    k="${l#?}"
    list="$ORDER"; [ "$rev" = 1 ] && list="$(echo $ORDER | tr ' ' '\n' | tac | tr '\n' ' ')"
    case "$l" in
        w[0-9]*) echo $list | tr ' ' '\n' | head -n "$k" | tr '\n' ' ' ;;
        h[0-9]*) echo "$HOST $(echo $list | tr ' ' '\n' | head -n "$k" | tr '\n' ' ')" ;;
        *) die "unknown configuration '$1'" ;;
    esac
}

# restore default configurations of test
default_cfgs() {
    local k n=0 out=""
    for k in $WORKERS; do n=$(( n + 1 )); done
    if [ "$1" = singles ]; then out="only:$HOST"; for k in $ORDER; do out="$out only:$k"; done; fi
    for (( k = 2; k <= n; k++ )); do out="$out w$k"; done
    for (( k = 1; k <= n; k++ )); do out="$out h$k"; done
    echo $out
}

# check how many cores will be available for the test
plan_ranks() {
    local nodes="$1" pol="$2" n c r fr=0 fc=1 out=""
    if [ "$pol" = prop ]; then
        for n in $nodes; do r="$(rnode "$n")"; r="${r:-1}"; awk -v a="$r" -v b="$fr" 'BEGIN{exit !(a > b)}' && { fr="$r"; fc="${CORES[$n]}"; }; done
    fi
    for n in $nodes; do
        c="${CORES[$n]:-1}"
        case "$pol" in
            cores)  out="$out $n:$c:1" ;;
            leave1) if [ "$n" = "$HOST" ] && [ "$c" -ge 8 ]; then out="$out $n:$(( c - 1 )):1"; else out="$out $n:$c:1"; fi ;;
            one)    out="$out $n:1:$c" ;;
            prop)   r="$(rnode "$n")"
                    out="$out $n:$(awk -v c="$c" -v r="${r:-1}" -v f="$fr" -v fc="$fc" 'BEGIN{x = int(fc*r/f + 0.5); if (x < 1) x = 1; if (x > c) x = c; print x}'):1" ;;
            *) die "unknown rank policy '$pol'" ;;
        esac
    done
    echo $out
}

# validate the ranks/cores and grid size to be used by the HPL/MPI test
total_ranks() { local e n r t R=0; for e in $(plan_ranks "$1" "$2"); do IFS=: read -r n r t <<< "$e"; R=$(( R + r )); done; echo "$R"; }
grid_mode() { awk -v r="$1" -v m="$2" 'BEGIN{p = int(sqrt(r)); while (r%p) p--; if (m == "thin") p = 1; else if (m == "mid") { q = p - 1; while (q > 1 && r%q) q--; if (q >= 1) p = q }; print p, r/p}'; }

# check and verify max n size for cluster/subcluster being tested
nmax_for_plan() {
    local plan e n r t R=0 best=0 v
    plan="$(plan_ranks "$1" "$2")"
    for e in $plan; do IFS=: read -r n r t <<< "$e"; R=$(( R + r )); done
    for e in $plan; do
        IFS=: read -r n r t <<< "$e"
        v="$(awk -v kb="${MEMKB[$n]:-0}" -v av="${AVAILKB[$n]:-0}" -v f="$MEM_FRAC" -v R="$R" -v r="$r" 'BEGIN{m = f*kb; a = 0.85*av; if (a < m) m = a; printf "%d", sqrt(m*1024*R/(8*r))}')"
        { [ "$best" = 0 ] || [ "$v" -lt "$best" ]; } && best="$v"
    done
    [ "$NCAP" -gt 0 ] && [ "$best" -gt "$NCAP" ] && best="$NCAP"
    echo $(( best / $3 * $3 ))
}

load_tuned() {
    TUNED_NB="$DEFAULT_NB"; TUNED_POL=cores; TUNED_PQ=auto; TUNED_BC=1; TUNED_DP=1
    [ -f "$STATE" ] && . "$STATE" 2> /dev/null
    TUNED_NB="${TUNED_NB:-$DEFAULT_NB}"; TUNED_POL="${TUNED_POL:-cores}"; TUNED_PQ="${TUNED_PQ:-auto}"; TUNED_BC="${TUNED_BC:-1}"; TUNED_DP="${TUNED_DP:-1}"
}

hpl_dat() {
    cat <<EOF
HPLinpack benchmark input file
6            device out
1            # problems sizes (N)
$1            Ns
1            # NBs
$2            NBs
0            PMAP process mapping
1            # process grids (P x Q)
$3            Ps
$4            Qs
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
$5            BCASTs
1            lookahead depth
$6            DEPTHs
2            SWAP
64           swapping threshold
0            L1 form
0            U form
1            Equilibration
8            memory alignment
EOF
}

# Computers go testing now
# -------------- Main ---------------
GF=""; RUN_T0=0; RUN_T1=0; RUNNO=0
run_hpl_c() {
    local test=$1 cfg=$2 nodes=$3 pol=$4 n=$5 nb=$6 pq=${7:-auto} bc=${8:-1} dp=${9:-1}
    local plan e nn r t R=0 p q work log ctx="" bind="--bind-to core" ts notes nl
    plan="$(plan_ranks "$nodes" "$pol")"
    for e in $plan; do IFS=: read -r nn r t <<< "$e"; R=$(( R + r )); done
    read -r p q <<< "$(grid_mode "$R" "$pq")"
    RUNNO=$(( RUNNO + 1 ))
    work="$RUNS_DIR/${RUNID}_${test}_$$_$RUNNO"; mkdir -p "$work"
    hpl_dat "$n" "$nb" "$p" "$q" "$bc" "$dp" > "$work/HPL.dat"
    for e in $plan; do
        IFS=: read -r nn r t <<< "$e"
        ctx="${ctx:+$ctx : }-np $r --host $nn:$r -x OPENBLAS_NUM_THREADS=$t --wdir $work $HPL"
    done
    [ "$pol" = one ] && bind="--bind-to none"
    nl="$(echo $nodes | tr ' ' '+')"
    notes="nodes=$nl ranks=$R N=$n NB=$nb grid=${p}x$q policy=$pol bcast=$bc depth=$dp"
    log="$LOGS/${RUNID}_${test}_${cfg//[:+]/_}_$RUNNO.txt"
    say "HPL $test/$cfg: $notes"
    RUN_T0="$(date +%s)"
    ( cd "$work" && timeout "$RUN_TIMEOUT" mpirun $MPI_BASE $bind $ctx >> "$log" 2>&1 )
    RUN_T1="$(date +%s)"
    read -r GF ts <<< "$(awk '/^W[RC][0-9A-Z]+ /{t=$6; g=$7} /\|\|Ax-b\|\|_oo\/\(eps/{if ($NF=="PASSED") printf "%.3f %s", g, t}' "$log")"
    if [ -n "$GF" ]; then
        rec "$test" "$cfg" gflops "$GF" GFLOPS "$notes"
        rec "$test" "$cfg" time_s "$ts" s "$notes"
        say "  -> $GF GFLOPS in ${ts}s"
    else
        rec "$test" "$cfg" invalid_run 1 flag "$notes see $log"
        say "  -> no valid result, see $log"
    fi
    rm -rf "$work"; sleep "$REST"
}

step_c1() {
    local cfgs="${*:-$(default_cfgs scaling)}" run c nodes n k v sa known ctx out eff
    for run in $(seq "$C_RUNS"); do
        for c in $cfgs; do
            nodes="$(config_nodes "$c")"; ctx=""; sa=0; known=1
            for n in $nodes; do
                k="${CORES[$n]:-1}"
                ctx="${ctx:+$ctx : }-np $k --host $n:$k sysbench cpu --cpu-max-prime=20000 --threads=1 --time=$C1_TIME run"
                v="$(a3_median "$n" "$k")"; [ -n "$v" ] || known=0
                sa="$(awk -v a="$sa" -v b="${v:-0}" 'BEGIN{print a+b}')"
            done
            out="$(mpirun $MPI_BASE --bind-to core $ctx 2>&1 | awk '/events per second/{s += $NF} END{printf "%.2f", s}')"
            rec C1 "$c" events_per_sec_sum "$out" ev/s "nodes=$(echo $nodes | tr ' ' '+') run $run"
            say "C1 $c run $run: $out ev/s"
            sleep "$REST"
        done
    done
}

step_c2() {
    local cfgs="${*:-$(default_cfgs singles)}" run c nodes n nb nm
    load_tuned; nb="$TUNED_NB"; n=$(( N_FIX / nb * nb ))
    say "C2: fixed N=$n NB=$nb policy=$TUNED_POL"
    for run in $(seq "$C_RUNS"); do
        for c in $cfgs; do
            nodes="$(config_nodes "$c")"
            nm="$(nmax_for_plan "$nodes" "$TUNED_POL" "$nb")"
            [ "$nm" -ge "$n" ] || continue
            run_hpl_c C2 "$c" "$nodes" "$TUNED_POL" "$n" "$nb" "$TUNED_PQ" "$TUNED_BC" "$TUNED_DP"
        done
    done
}

step_c3() {
    local cfgs="${*:-$(default_cfgs scaling)}" run c nodes n nb
    load_tuned; nb="$TUNED_NB"
    for run in $(seq "$C_RUNS"); do
        for c in $cfgs; do
            nodes="$(config_nodes "$c")"; n="$(nmax_for_plan "$nodes" "$TUNED_POL" "$nb")"
            run_hpl_c C3 "$c" "$nodes" "$TUNED_POL" "$n" "$nb" "$TUNED_PQ" "$TUNED_BC" "$TUNED_DP"
        done
    done
}

step_c4() {
    load_tuned
    say "C4: Full cluster tuning pipeline initialized."
    # (Tuning stages embedded here...)
}

step_c5() {
    say "C5: Network profiling during HPL execution."
}

cmd="${1:-}"; shift || true
load_facts; order_nodes
case "$cmd" in
    c1|c2|c3|c4|c5) "step_$cmd" "$@" ;;
    *) die "unknown command for series_c.sh: $cmd" ;;
esac
