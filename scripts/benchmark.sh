#!/bin/bash

# this script is a single file benchmarking tool for each node in the cluster
#
# command versions that can be run
#	bench.sh					full run (lasts hours)
#	bench.sh --quick				a smoke test to be run first on each node to establish a breadth test
#	bench.sh hpl thermal				runs the inventory, idle, cpu, disk, hpl, and thermal tests
#	bench.sh summary				gives a summary of the measured median/min/max on a node
#	bench.sh merge					combines the data from all nodes in a single file at /data/results/combined.csv
#	bench.sh add A5 passmark_cpu_multi 1234 score	run passmark (value has to be recorded by hand)
#
# run commands as clusteruser on each node
# results go to /data/results/node*_results.csv
# raw output at /data/bench_logs/node*/
#
set -uo pipefail

# -------- global information ----------
DATA="${DATA_DIR:-/data}"
HOST="$(hostname -s)"
CSV="$DATA/results/${HOST}_results.csv"
LOGS="$DATA/bench_logs/$HOST"
STATE="$LOGS/state.env"                 # idle baseline temperature and best HPL settings
RUNID="$(date +%Y%m%d_%H%M)"
HPL="${HPL_BIN:-$HOME/hpl-run/xhpl}"

# -------- quick command ---------
# this command changes all the settings to about 1/10 of the full run to do a quick breadth test to ensure everything
# works on each machine
QUICK=0; [ "${1:-}" = --quick ] && { QUICK=1; shift; }
if [ "$QUICK" = 1 ]; then
    : "${IDLE:=60}" "${SB_TIME:=5}" "${RUNS:=2}" "${REST:=2}" "${MEM_TOTAL:=2G}" "${DISK_SIZE:=256M}" \
      "${DISK_TIME:=10}" "${DISK_RUNS:=1}" "${NBS:=128 192}" "${SWEEP_REPS:=1}" "${HPL_REPS:=1}" \
      "${HEAT:=120}" "${MIN_SOLVES:=2}" "${NCAP:=6000}" "${COOL_MAX:=30}"
else
    : "${IDLE:=600}" "${SB_TIME:=30}" "${RUNS:=5}" "${REST:=20}" "${MEM_TOTAL:=20G}" "${DISK_SIZE:=2G}" \
      "${DISK_TIME:=60}" "${DISK_RUNS:=3}" "${NBS:=128 192 256 384}" "${SWEEP_REPS:=2}" "${HPL_REPS:=3}" \
      "${HEAT:=1200}" "${MIN_SOLVES:=3}" "${NCAP:=0}" "${COOL_MAX:=600}"
fi
: "${MAX_TEMP:=95}" "${MEM_FRAC:=0.8}"

export PATH="/apps/openmpi/bin:$PATH"
export LD_LIBRARY_PATH="/apps/openmpi/lib:/apps/openblas/lib:${LD_LIBRARY_PATH:-}"

# ------ helper functions ------
say() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" > /dev/null 2>&1; }

rec() {  # helper function for recording results
    [ -s "$CSV" ] || echo "date_time,host,test,config,metric,value,unit,notes" > "$CSV"
    printf '%s,%s,%s,%s,%s,%s,%s,"%s"\n' "$(date -Iseconds)" "$HOST" "$1" "$2" "$3" "$4" "$5" "${6:-}" >> "$CSV"
}
setstate() { sed -i "/^$1=/d" "$STATE" 2> /dev/null; echo "$1=$2" >> "$STATE"; }
# helper functions to get the nodes physical hardware information
cores()    { lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l; }
threads()  { getconf _NPROCESSORS_ONLN; }
mem_kb()   { awk '/^MemTotal:/{print $2}' /proc/meminfo; }
avail_kb() { awk '/^MemAvailable:/{print $2}' /proc/meminfo; }
mhz()      { awk '/^cpu MHz/{s+=$4; n++} END{if(n) printf "%.0f", s/n}' /proc/cpuinfo; }
# temperature helper functions to ensure each test runs when a machine is near idle temp and so they dont overheat
TEMPF="${BENCH_TEMP_FILE:-}"
if [ -z "$TEMPF" ]; then
    for z in /sys/class/thermal/thermal_zone*; do
        [ "$(cat "$z/type" 2> /dev/null)" = x86_pkg_temp ] && { TEMPF="$z/temp"; break; }
    done
fi
[ -z "$TEMPF" ] && TEMPF="$(grep -lE 'coretemp|k10temp' /sys/class/hwmon/hwmon*/name 2> /dev/null | head -n 1 | sed 's/name$/temp1_input/')"
temp() { [ -r "${TEMPF:-}" ] && echo $(( $(cat "$TEMPF") / 1000 )); }   # empty if there is no sensor

cool() {  # wait until the CPU is within 5 C of its idle baseline (cool start), up to COOL_MAX seconds
    [ "${NOCOOL:-0}" = 1 ] && return 0
    local base w=0
    base="$(grep -s '^IDLE_TEMP=' "$STATE" | cut -d= -f2)"
    { [ -n "$base" ] && [ -n "$(temp)" ]; } || return 0
    while [ "$(temp)" -gt $(( base + 5 )) ] && [ "$w" -lt "$COOL_MAX" ]; do sleep 10; w=$(( w + 10 )); done
}

fits() { awk -v n="$1" -v a="$(avail_kb)" 'BEGIN{exit !(8*n*n*1.1 <= a*1024)}'; }   # check that the hpl matrix will fit in the ram size of the node

# ------------ HPL run test -------------------
hpl_dat() {  # hpl_dat N NB P Q
    cat <<EOF
HPLinpack benchmark input file
Innovative Computing Laboratory, University of Tennessee
HPL.out      output file name (if any)
6            device out (6=stdout,7=stderr,file)
1            # of problems sizes (N)
$1            Ns
1            # of NBs
$2            NBs
0            PMAP process mapping (0=Row-,1=Column-major)
1            # of process grids (P x Q)
$3            Ps
$4            Qs
16.0         threshold
1            # of panel fact
2            PFACTs (0=left, 1=Crout, 2=Right)
1            # of recursive stopping criterium
4            NBMINs (>= 1)
1            # of panels in recursion
2            NDIVs
1            # of recursive panel fact.
2            RFACTs (0=left, 1=Crout, 2=Right)
1            # of broadcast
1            BCASTs (0=1rg,1=1rM,2=2rg,3=2rM,4=Lng,5=LnM)
1            # of lookahead depth
1            DEPTHs (>=0)
2            SWAP (0=bin-exch,1=long,2=mix)
64           swapping threshold
0            L1 in (0=transposed,1=no-transposed) form
0            U  in (0=transposed,1=no-transposed) form
1            Equilibration (0=no,1=yes)
8            memory alignment in double (> 0)
EOF
}
grid() { awk -v r="$1" 'BEGIN{p=int(sqrt(r)); while (r%p) p--; print p, r/p}'; } # makes the grid near square with P <= Q

GF=""
run_hpl() { 	# runs hpl with configuration TEST CONFIG RANKS N NB [mpirun flags] if the run fails GF stays empty
    local test=$1 cfg=$2 r=$3 n=$4 nb=$5 flags="${6:---bind-to core}" p q w log st ts
    read -r p q <<< "$(grid "$r")"
    w="$(mktemp -d)"; hpl_dat "$n" "$nb" "$p" "$q" > "$w/HPL.dat"
    log="$LOGS/${RUNID}_${test}_${cfg}.txt"
    cool; st="$(temp)"
    say "HPL $test/$cfg: ranks=$r N=$n NB=$nb grid=${p}x${q} start_temp=${st:-n/a}C"
    echo "# mpirun $flags -np $r -x OPENBLAS_NUM_THREADS=${THREADS:-1} $HPL" > "$log"
    ( cd "$w" && mpirun $flags -np "$r" -x OPENBLAS_NUM_THREADS="${THREADS:-1}" "$HPL" >> "$log" 2>&1 )
    read -r GF ts <<< "$(awk '/^W[RC][0-9A-Z]+ /{t=$6; g=$7} /\|\|Ax-b\|\|_oo\/\(eps/{if ($NF=="PASSED") printf "%.3f %s", g, t}' "$log")"
    if [ -n "$GF" ]; then
        rec "$test" "$cfg" gflops "$GF" GFLOPS "N=$n NB=$nb ranks=$r grid=${p}x$q start_temp=${st:-n/a}C"
        rec "$test" "$cfg" time_s "$ts" s "N=$n NB=$nb ranks=$r"
        say "  -> $GF GFLOPS in ${ts}s"
    else
        rec "$test" "$cfg" invalid_run 1 flag "no PASSED result, see $log"
        say "  -> no valid result, see $log"
    fi
    rm -rf "$w"
}

# -------------- other tests -----------------
# also runs an inventory of the node, waits for it to get to idle between steps
step_inventory() { # takes an inventory of all the nodes physical hardware and current software information
    local nic spd
    { lscpu; echo; free -h; echo; lsblk -d -o NAME,ROTA,SIZE,MODEL,TRAN; echo; ip -br a 2> /dev/null; echo
      uname -r; grep PRETTY_NAME /etc/os-release; have sysbench && sysbench --version; } > "$LOGS/inventory.txt" 2>&1
    nic="$(ip -o -4 addr 2> /dev/null | awk '/192\.168\.10\./{print $2; exit}')"
    spd="$(cat "/sys/class/net/$nic/speed" 2> /dev/null)"
    rec A1 inventory physical_cores "$(cores)" cores
    rec A1 inventory hw_threads "$(threads)" threads
    rec A1 inventory ram "$(awk -v k="$(mem_kb)" 'BEGIN{printf "%.1f", k/1048576}')" GB
    [ -n "$spd" ] && rec A1 inventory nic_speed "$spd" Mb/s "iface=$nic"
    say "cores=$(cores) threads=$(threads) ram=$(( $(mem_kb) / 1024 ))MB nic=${nic:-?} ${spd:-?}Mb/s   (full report: $LOGS/inventory.txt)"
}

step_idle() {        # logs the idle temperature and power draw of the machine
    local csv="$LOGS/${RUNID}_idle.csv" s i tmed mmean load
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        [ "$(awk '{print ($1 > 0.3)}' /proc/loadavg)" = 1 ] || break
        say "waiting for the node to go idle (load $(cut -d' ' -f1 /proc/loadavg))"; sleep 10
    done
    say "idle baseline for ${IDLE}s, leave the node alone"
    echo "epoch,temp_c,mhz" > "$csv"
    for (( s = 0; s < IDLE; s += 5 )); do echo "$(date +%s),$(temp),$(mhz)" >> "$csv"; sleep 5; done
    load="$(cut -d' ' -f1 /proc/loadavg)"
    tmed="$(tail -n +2 "$csv" | cut -d, -f2 | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{if (NR) print a[int((NR+1)/2)]}')"
    mmean="$(tail -n +2 "$csv" | cut -d, -f3 | grep -E '^[0-9]+$' | awk '{s+=$1; n++} END{if (n) printf "%.0f", s/n}')"
    if [ -n "$tmed" ]; then rec A2 idle idle_temp "$tmed" C; setstate IDLE_TEMP "$tmed"
    else say "no temperature sensor found: cool starts are skipped (set BENCH_TEMP_FILE=<sysfs file> to fix)"; fi
    [ -n "$mmean" ] && rec A2 idle idle_mhz "$mmean" MHz
    rec A2 idle load1 "$load" load
    [ -n "${IDLE_WATTS:-}" ] && rec A2 idle idle_power "$IDLE_WATTS" W "manual meter reading"
    say "idle: ${tmed:-n/a}C  ${mmean:-n/a}MHz  load $load"
}

step_cpu() {         # runs sysbench on the cpu and memory
    have sysbench || { say "sysbench is not installed: skipping CPU and memory tests"; return 0; }
    local c t th r l v oper ts
    c="$(cores)"; t="$(threads)"; ts="$(printf '%s\n' 1 "$c" "$t" | sort -nu | tr '\n' ' ')"
    for r in $(seq "$RUNS"); do
        for th in $ts; do
            l="$LOGS/${RUNID}_A3_t${th}_run$r.txt"
            sysbench cpu --cpu-max-prime=20000 --threads="$th" --time="$SB_TIME" run > "$l" 2>&1
            v="$(awk '/events per second/{print $NF}' "$l")"
            [ -n "$v" ] && { rec A3 "threads=$th" events_per_sec "$v" ev/s "run $r"; say "A3 threads=$th run $r: $v events/s"; }
            sleep "$REST"
        done
        for th in 1 "$t"; do
            for oper in read write; do
                l="$LOGS/${RUNID}_A4_${oper}_t${th}_run$r.txt"
                sysbench memory --memory-block-size=1M --memory-total-size="$MEM_TOTAL" --threads="$th" --memory-oper="$oper" run > "$l" 2>&1
                v="$(awk -F'[()]' '/MiB transferred/{split($2, a, " "); print a[1]}' "$l")"
                [ -n "$v" ] && { rec A4 "$oper threads=$th" bandwidth "$v" MiB/s "run $r"; say "A4 $oper threads=$th run $r: $v MiB/s"; }
            done
        done
    done
}

step_disk() {        # local disk test (direct I/O, so the page cache cannot hide the disk)
    have sysbench || { say "sysbench is not installed: skipping the disk test"; return 0; }
    local d="/var/tmp/bench_$HOST" r m bs l v u need=3000000
    [ "$QUICK" = 1 ] && need=600000
    mkdir -p "$d" && cd "$d" || die "cannot use $d"
    [ "$(df -Pk "$d" | awk 'NR==2{print $4}')" -ge "$need" ] || die "not enough free space in $d"
    sysbench fileio --file-total-size="$DISK_SIZE" prepare > /dev/null 2>&1 || die "sysbench fileio prepare failed"
    for r in $(seq "$DISK_RUNS"); do
        for m in seqrd seqwr rndrd rndwr; do
            bs=16K; [[ $m == seq* ]] && bs=1M
            l="$LOGS/${RUNID}_A6_${m}_run$r.txt"
            sysbench fileio --file-total-size="$DISK_SIZE" --file-test-mode="$m" --file-block-size="$bs" \
                --file-extra-flags=direct --time="$DISK_TIME" --max-requests=0 run > "$l" 2>&1
            case $m in
                seqrd) v="$(awk '/read, MiB\/s/{print $3}' "$l")";    u=MiB/s ;;
                seqwr) v="$(awk '/written, MiB\/s/{print $3}' "$l")"; u=MiB/s ;;
                rndrd) v="$(awk '/reads\/s/{print $2}' "$l")";        u=IOPS ;;
                rndwr) v="$(awk '/writes\/s/{print $2}' "$l")";       u=IOPS ;;
            esac
            [ -n "$v" ] && { rec A6 "$m" throughput "$v" "$u" "run $r block=$bs"; say "A6 $m run $r: $v $u"; }
        done
    done
    sysbench fileio --file-total-size="$DISK_SIZE" cleanup > /dev/null 2>&1; cd / && rm -rf "$d"
}

step_hpl() {         # run hpl test with NB sweep, then the largest N that fits in RAM
    local c t nmid nmax n nb m rep best=0 best_nb=""
    declare -A SUM CNT
    c="$(cores)"; t="$(threads)"
    nmid=16000; [ "$(mem_kb)" -ge 6000000 ] && nmid=20000
    [ "$NCAP" -gt 0 ] && [ "$nmid" -gt $(( NCAP * 2 / 3 )) ] && nmid=$(( NCAP * 2 / 3 ))
    nmid=$(( nmid / 768 * 768 ))                      # 768 is divisible by every NB in the sweep
    while ! fits "$nmid" && [ "$nmid" -gt 768 ]; do nmid=$(( nmid - 768 )); done

    for rep in $(seq "$SWEEP_REPS"); do
        for nb in $NBS; do
            run_hpl A7 "nb$nb" "$c" "$nmid" "$nb"
            [ -n "$GF" ] && { SUM[$nb]="$(awk -v a="${SUM[$nb]:-0}" -v b="$GF" 'BEGIN{print a+b}')"; CNT[$nb]=$(( ${CNT[$nb]:-0} + 1 )); }
        done
    done
    for nb in $NBS; do
        [ "${CNT[$nb]:-0}" -gt 0 ] || continue
        m="$(awk -v s="${SUM[$nb]}" -v k="${CNT[$nb]}" 'BEGIN{printf "%.3f", s/k}')"
        say "NB=$nb mean: $m GFLOPS"
        awk -v a="$m" -v b="$best" 'BEGIN{exit !(a > b)}' && { best="$m"; best_nb="$nb"; }
    done
    [ -n "$best_nb" ] || die "no valid HPL result in the NB sweep, check $LOGS"
    say "best NB: $best_nb"

    nmax="$(awk -v kb="$(mem_kb)" -v f="$MEM_FRAC" 'BEGIN{printf "%d", sqrt(f*kb*1024/8)}')"
    [ "$NCAP" -gt 0 ] && [ "$nmax" -gt "$NCAP" ] && nmax="$NCAP"
    n=$(( nmax / best_nb * best_nb ))
    while ! fits "$n" && [ "$n" -gt $(( best_nb * 2 )) ]; do n=$(( n * 95 / 100 / best_nb * best_nb )); done
    say "largest N that fits in free RAM: $n"
    for rep in $(seq "$HPL_REPS"); do run_hpl A7 "maxN" "$c" "$n" "$best_nb"; done
    setstate BEST_N "$n"; setstate BEST_NB "$best_nb"

    if [ "${EXTRAS:-0}" = 1 ]; then   # rank-count variants at the mid-size N, compare with the nb$best_nb rows
        [ "$t" -gt "$c" ] && run_hpl A7 hwthreads "$t" "$nmid" "$best_nb" "--use-hwthread-cpus --bind-to hwthread"
        [ "$c" -ge 8 ]    && run_hpl A7 leave1core "$(( c - 1 ))" "$nmid" "$best_nb"
        [ "$c" -gt 1 ]    && THREADS="$c" run_hpl A7 1rank_x_threads 1 "$nmid" "$best_nb" "--bind-to none"
    fi
}

step_thermal() {     # sustained HPL with temperature and frequency logging, plus a thermal watchdog
    local c csv lp t0 i=0 gf1="" gfn="" vals maxt minf f1 fn fmean gd fd thr=NO
    . "$STATE" 2> /dev/null; [ -n "${BEST_N:-}" ] || die "run the hpl step first (no BEST_N in $STATE)"
    c="$(cores)"; csv="$LOGS/${RUNID}_sustained.csv"
    say "sustained HPL for ${HEAT}s at N=$BEST_N NB=$BEST_NB (watchdog stops it at ${MAX_TEMP}C)"
    cool
    echo "epoch,temp_c,mhz" > "$csv"; rm -f "$LOGS/ABORT"
    (
        while true; do
            tt="$(temp)"; echo "$(date +%s),$tt,$(mhz)" >> "$csv"
            if [ -n "$tt" ] && [ "$tt" -ge "$MAX_TEMP" ]; then echo "$tt" > "$LOGS/ABORT"; pkill -TERM -x xhpl; fi
            sleep 5
        done
    ) &
    lp=$!
    t0="$(date +%s)"
    while { [ $(( $(date +%s) - t0 )) -lt "$HEAT" ] || [ "$i" -lt "$MIN_SOLVES" ]; } && [ ! -e "$LOGS/ABORT" ]; do
        i=$(( i + 1 ))
        NOCOOL=1 run_hpl A8 "solve$i" "$c" "$BEST_N" "$BEST_NB"
        [ -n "$GF" ] && { [ -z "$gf1" ] && gf1="$GF"; gfn="$GF"; }
    done
    kill "$lp" 2> /dev/null; wait "$lp" 2> /dev/null
    [ -e "$LOGS/ABORT" ] && say "WATCHDOG: the CPU reached $(cat "$LOGS/ABORT")C, run stopped"

    read -r maxt minf f1 fn fmean <<< "$(awk -F, 'NR>1{n++; e[n]=$1; t[n]=$2; f[n]=$3}
        END{for (i=1; i<=n; i++) {
                if (t[i]+0 > mt) mt = t[i]+0
                if (f[i] != "") { v = f[i]+0; if (!mf || v < mf) mf = v; s += v; k++
                    if (e[i]-e[1] < 60) { a += v; x++ }
                    if (e[n]-e[i] < 60) { b += v; y++ } } }
            printf "%d %d %d %d %d", mt, mf, (x ? a/x : 0), (y ? b/y : 0), (k ? s/k : 0)}' "$csv")"
    gd="$(awk -v a="${gf1:-0}" -v b="${gfn:-0}" 'BEGIN{if (a > 0) printf "%.1f", 100*(a-b)/a}')"
    fd="$(awk -v a="$f1" -v b="$fn" 'BEGIN{if (a > 0) printf "%.1f", 100*(a-b)/a}')"
    awk -v g="${gd:-0}" -v f="${fd:-0}" 'BEGIN{exit !(g > 10 || f > 10)}' && thr=YES
    [ -e "$LOGS/ABORT" ] && thr="YES(watchdog)"
    rec A8 sustained solves "$i" count "duration $(( $(date +%s) - t0 ))s"
    [ "$maxt" -gt 0 ] && rec A8 sustained peak_temp "$maxt" C
    rec A8 sustained mean_mhz "$fmean" MHz "cores=$c (Rpeak = cores x mean_mhz/1000 x FLOPs per cycle)"
    rec A8 sustained first_minute_mhz "$f1" MHz
    rec A8 sustained last_minute_mhz "$fn" MHz
    rec A8 sustained freq_drop_pct "${fd:-}" %
    rec A8 sustained gflops_drop_pct "${gd:-}" % "first=$gf1 last=$gfn"
    rec A8 sustained throttled "$thr" flag "threshold 10 percent"
    [ -n "${WATTS:-}" ] && rec A8 sustained avg_power "$WATTS" W "manual meter reading"
    say "peak ${maxt}C | freq $f1 -> $fn MHz (drop ${fd:-n/a}%) | GFLOPS $gf1 -> $gfn (drop ${gd:-n/a}%) | throttled: $thr"
}

# ------------ reports -----------------
summary() {  # median, min and max for every measurement on this node
    [ -s "$CSV" ] || die "no results yet: $CSV"
    tail -n +2 "$CSV" | awk -F, '$6 != "" && $5 != "invalid_run" {print $3 "|" $4 "|" $5 "|" $7 "," $6}' \
        | sort -t, -k1,1 -k2,2n \
        | awk -F, 'function out() { if (n) { m = (n%2) ? a[(n+1)/2] : (a[n/2] + a[n/2+1])/2
                        printf "%-52s n=%-3d median=%-10s min=%-10s max=%s\n", k, n, m, a[1], a[n] } }
                   $1 != k { out(); k = $1; n = 0 }  { a[++n] = $2 }  END { out() }'
}
merge() {
    local out="$DATA/results/combined.csv" f first=1
    for f in "$DATA"/results/*_results.csv; do
        [ -f "$f" ] || continue
        if [ "$first" = 1 ]; then cat "$f" > "$out.tmp"; first=0; else tail -n +2 "$f" >> "$out.tmp"; fi
    done
    [ -f "$out.tmp" ] || die "no *_results.csv files in $DATA/results"
    mv "$out.tmp" "$out"; say "wrote $out ($(( $(wc -l < "$out") - 1 )) rows)"
}

# ------------- main -----------------
[ "$EUID" -ne 0 ] || die "run this as clusteruser, not root"
mkdir -p "$LOGS" "$DATA/results" 2> /dev/null && touch "$LOGS/.w" 2> /dev/null \
    || die "cannot write to $DATA (check if you are logged in as clusteruser)"

case "${1:-}" in
    summary) summary; exit 0 ;;
    merge)   merge; exit 0 ;;
    add)     shift; [ $# -ge 3 ] || die "usage: $0 add TEST METRIC VALUE [UNIT]"; rec "$1" manual "$2" "$3" "${4:-}" "entered by hand"; exit 0 ;;
esac

STEPS="${*:-inventory idle cpu disk hpl thermal}"
for s in $STEPS; do
    case $s in inventory|idle|cpu|disk|hpl|thermal) ;; *) die "unknown step '$s' (steps: inventory idle cpu disk hpl thermal)" ;; esac
done
case " $STEPS " in *" hpl "*|*" thermal "*)
    have mpirun || die "mpirun not found (is /apps mounted?)"
    [ -x "$HPL" ] || die "xhpl not found at $HPL (set HPL_BIN=/path/to/xhpl)" ;;
esac

exec > >(tee -a "$LOGS/session_$RUNID.log") 2>&1
say "Initial benchmarks on $HOST (quick=$QUICK) steps: $STEPS"
gov="$(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2> /dev/null | tr '\n' ' ')"
[ -n "$gov" ] && [ "$gov" != "performance " ] && say "WARNING: CPU governor is '$gov'. Set it first (needs sudo): echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
[ "$(awk '{print ($1 > 0.5)}' /proc/loadavg)" = 1 ] && say "WARNING: load average is $(cut -d' ' -f1 /proc/loadavg), stop other services first"

for s in $STEPS; do echo; say "===== $s ====="; "step_$s"; done
echo; say "Done. Results: $CSV   Raw output: $LOGS   Medians: ./bench.sh summary"
