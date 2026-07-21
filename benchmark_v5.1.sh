#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — Isolation-Overhead Data Collection Suite v5.0
# =============================================================================
# ONE script, parameterized by bench.conf, that runs everywhere (bare metal,
# container, or Linux guest). Replaces the four hand-diverged v4 forks.
#
# Design goals (see TEST_METHODOLOGY.md / plan.txt):
#   * NEVER abort the whole run on one failed test (no `set -e`); each test is
#     wrapped, its status logged to MANIFEST.tsv, and the suite continues.
#   * Self-describing: every run records identity + environment facts in
#     meta.env so the compiler never has to guess from folder names.
#   * Completeness-provable: RUN_COMPLETE sentinel + per-test manifest.
#   * Overhead-localization: CPU% + cgroup-throttle sampled around every test.
#   * No sudo required for the measurements themselves (dd/fio use O_DIRECT).
#
# Usage:
#   ./benchmark.sh [--config bench.conf] [--iterations N] [--quick]
#                  [--no-kernel] [--platform P] [--host-os OS]
#                  [--isolation None|Container|VM] [--remote-ip IP]
#                  [--io-dir DIR] [--out-root DIR]
# =============================================================================
set -uo pipefail   # NOT -e: a failing benchmark must not kill the suite.

# Force C locale so EVERY tool emits dot-decimal numbers (dd/free/etc. otherwise
# print locale-specific commas like "3,9 GB/s" that break downstream parsing).
export LC_ALL=C LANG=C

SUITE_VERSION="5.1"

# ---- Defaults (overridable by bench.conf, env vars, or flags) ---------------
PLATFORM="${PLATFORM:-Unknown}"
HOST_OS="${HOST_OS:-Unknown}"
ISOLATION_TYPE="${ISOLATION_TYPE:-Unknown}"
CPU_CORES="${CPU_CORES:-0-3}"
CPU_THREADS="${CPU_THREADS:-4}"
MEM_LIMIT="${MEM_LIMIT:-16G}"
ITERATIONS="${ITERATIONS:-10}"
REMOTE_IP="${REMOTE_IP:-}"
IPERF_PORT="${IPERF_PORT:-5201}"
IO_DIR="${IO_DIR:-$HOME}"
DISK_TYPE="${DISK_TYPE:-}"
PROVISIONING_TYPE="${PROVISIONING_TYPE:-}"
KERNEL_VERSION="${KERNEL_VERSION:-6.8}"
OUT_ROOT="${OUT_ROOT:-$PWD}"

CONFIG_FILE="bench.conf"
QUICK=false
DO_KERNEL=true

# ---- Arg parsing ------------------------------------------------------------
# Precedence: CLI flags > bench.conf > env/default. We capture flags into CLI_*
# holders now, source the config, then apply the holders so flags always win.
declare -A CLI=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)     CONFIG_FILE="$2"; shift 2 ;;
        --iterations) CLI[ITERATIONS]="$2"; shift 2 ;;
        --quick)      QUICK=true; shift ;;
        --no-kernel)  DO_KERNEL=false; shift ;;
        --platform)   CLI[PLATFORM]="$2"; shift 2 ;;
        --host-os)    CLI[HOST_OS]="$2"; shift 2 ;;
        --isolation)  CLI[ISOLATION_TYPE]="$2"; shift 2 ;;
        --remote-ip)  CLI[REMOTE_IP]="$2"; shift 2 ;;
        --io-dir)     CLI[IO_DIR]="$2"; shift 2 ;;
        --out-root)   CLI[OUT_ROOT]="$2"; shift 2 ;;
        -h|--help)    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Config file provides the per-platform base (overrides env/defaults).
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# CLI flags win over the config file.
for k in "${!CLI[@]}"; do printf -v "$k" '%s' "${CLI[$k]}"; done

# Quick smoke-test profile — shortens EVERY test so a full pass takes ~30s.
if $QUICK; then
    SYSBENCH_TIME=10; FIO_RUNTIME=10; STRESS_TIME=10; MEM_LIMIT="2G"
    OPENSSL_SECONDS=1; FRACTAL_DIM=400; ZIP_ARGS=(b 1)
    [[ "$ITERATIONS" == "10" ]] && ITERATIONS=1
    DO_KERNEL=false
else
    SYSBENCH_TIME=120; FIO_RUNTIME=60; STRESS_TIME=120
    OPENSSL_SECONDS=3; FRACTAL_DIM=2000; ZIP_ARGS=(b)
fi

PIN=(taskset -c "$CPU_CORES")
SESSION_TS="$(date +%Y%m%d_%H%M%S)"
SESSION_DIR="${OUT_ROOT}/session_${SESSION_TS}_${PLATFORM}"
mkdir -p "$SESSION_DIR"

CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()     { echo -e "${CYAN}[$(date +%T)]${RESET} $*"; }
section() { echo -e "\n${BOLD}${CYAN}== $* ==${RESET}"; }
have()    { command -v "$1" >/dev/null 2>&1; }

# ---- Cache-drop capability (detected once, recorded, never relied upon) ------
DROP_CACHES_OK=false
drop_caches() {
    sync
    if [[ $EUID -eq 0 ]]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && DROP_CACHES_OK=true
    elif have sudo && sudo -n true 2>/dev/null; then
        echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1 && DROP_CACHES_OK=true
    fi
}
drop_caches   # sets DROP_CACHES_OK for meta.env

# ---- CPU / cgroup sampling helpers ------------------------------------------
expand_cores() {   # "0-3,6" -> "0 1 2 3 6"
    local spec="$1" part a b i out=()
    IFS=',' read -ra _parts <<< "$spec"
    for part in "${_parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            a="${part%-*}"; b="${part#*-}"
            for ((i=a; i<=b; i++)); do out+=("$i"); done
        else
            out+=("$part")
        fi
    done
    echo "${out[*]}"
}

snapshot_cpu() {   # prints "idle total" (jiffies) summed over the pinned cores
    local cores=" $(expand_cores "$CPU_CORES") " cpu rest n idle=0 total=0
    while read -r cpu rest; do
        case "$cpu" in
            cpu[0-9]*)
                n="${cpu#cpu}"
                if [[ "$cores" == *" $n "* ]]; then
                    local -a v=($rest) t=0 x
                    for x in "${v[@]}"; do t=$((t + x)); done
                    idle=$(( idle + ${v[3]} + ${v[4]} ))   # idle + iowait
                    total=$(( total + t ))
                fi ;;
        esac
    done < /proc/stat
    echo "$idle $total"
}

CGROUP_THROTTLE_FILE=""
if   [[ -r /sys/fs/cgroup/cpu.stat ]];      then CGROUP_THROTTLE_FILE=/sys/fs/cgroup/cpu.stat
elif [[ -r /sys/fs/cgroup/cpu/cpu.stat ]];  then CGROUP_THROTTLE_FILE=/sys/fs/cgroup/cpu/cpu.stat
fi
read_throttle() {   # prints "nr_throttled throttled_usec" (usec; v1 throttled_time is ns->usec)
    [[ -z "$CGROUP_THROTTLE_FILE" ]] && { echo "NA NA"; return; }
    local nt tu tt
    nt=$(awk '/^nr_throttled /{print $2}'  "$CGROUP_THROTTLE_FILE" 2>/dev/null)
    tu=$(awk '/^throttled_usec /{print $2}' "$CGROUP_THROTTLE_FILE" 2>/dev/null)
    if [[ -z "$tu" ]]; then
        tt=$(awk '/^throttled_time /{print $2}' "$CGROUP_THROTTLE_FILE" 2>/dev/null)
        [[ -n "$tt" ]] && tu=$(( tt / 1000 ))   # ns -> usec (cgroup v1)
    fi
    echo "${nt:-NA} ${tu:-NA}"
}

# ---- Per-iteration globals (set by run_iteration) ---------------------------
RUN_DIR=""; RAW_DIR=""; MANIFEST=""

manifest_row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$MANIFEST"; }
skip_test()    { manifest_row "$1" "skip" "0" "-"; log "SKIP  $1 (tool/precondition missing)"; }

# run_test NAME OUTFILE CMD...   — runs CMD, captures output+status+timing+cpu
run_test() {
    local name="$1" outfile="$2"; shift 2
    local out="${RAW_DIR}/${outfile}" rc start end dur status
    log "RUN   $name"
    read -r i0 t0 <<< "$(snapshot_cpu)"
    read -r nt0 tu0 <<< "$(read_throttle)"
    start=$(date +%s.%N)
    "$@" > "$out" 2>&1
    rc=$?
    end=$(date +%s.%N)
    read -r i1 t1 <<< "$(snapshot_cpu)"
    read -r nt1 tu1 <<< "$(read_throttle)"

    dur=$(awk "BEGIN{printf \"%.2f\", $end-$start}")
    # CPU% over pinned cores during the test
    local pct="NA"
    if [[ "$t1" -gt "$t0" ]]; then
        pct=$(awk "BEGIN{dt=$t1-$t0; di=$i1-$i0; printf \"%.2f\", (dt-di)/dt*100}")
    fi
    # cgroup throttle deltas
    local nt_d="NA" tu_d="NA"
    if [[ "$nt0" != "NA" && "$nt1" != "NA" ]]; then nt_d=$(( nt1 - nt0 )); fi
    if [[ "$tu0" != "NA" && "$tu1" != "NA" ]]; then tu_d=$(( tu1 - tu0 )); fi
    {
        echo "test=$name"
        echo "duration_s=$dur"
        echo "cpu_busy_pct=$pct"
        echo "cgroup_nr_throttled_delta=$nt_d"
        echo "cgroup_throttled_usec_delta=$tu_d"
        echo "cgroup_available=$([[ -n "$CGROUP_THROTTLE_FILE" ]] && echo true || echo false)"
    } > "${RAW_DIR}/${name}_cpu.env"

    status=ok; [[ $rc -ne 0 ]] && status=fail
    manifest_row "$name" "$status" "$dur" "$outfile"
    [[ $rc -ne 0 ]] && log "  ^ $name exited $rc (recorded as fail, continuing)"
    return 0
}

# =============================================================================
# ONE FULL ITERATION OF THE SUITE
# =============================================================================
run_iteration() {
    local iter="$1" warmup="$2"
    local ts; ts="$(date +%Y%m%d_%H%M%S)"
    RUN_DIR="${SESSION_DIR}/benchmark_raw_${ts}"
    RAW_DIR="${RUN_DIR}/raw_logs"
    MANIFEST="${RUN_DIR}/MANIFEST.tsv"
    mkdir -p "$RAW_DIR"
    printf 'test\tstatus\tseconds\toutfile\n' > "$MANIFEST"

    local test_file="${IO_DIR}/full_io_workload.bin"
    rm -f "$test_file"

    # ---- meta.env (identity + environment facts) ----------------------------
    local fs_type cpu_model governor kernel
    fs_type=$(stat -f -c %T "$IO_DIR" 2>/dev/null || echo "unknown")
    cpu_model=$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')
    governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    kernel=$(uname -sr 2>/dev/null || echo "unknown")
    {
        echo "SUITE_VERSION=$SUITE_VERSION"
        echo "PLATFORM=$PLATFORM"
        echo "HOST_OS=$HOST_OS"
        echo "ISOLATION_TYPE=$ISOLATION_TYPE"
        echo "ITERATION=$iter"
        echo "WARMUP=$warmup"
        echo "TIMESTAMP=$ts"
        echo "CPU_CORES=$CPU_CORES"
        echo "CPU_THREADS=$CPU_THREADS"
        echo "MEM_LIMIT=$MEM_LIMIT"
        echo "CPU_MODEL=${cpu_model:-unknown}"
        echo "CPU_GOVERNOR=$governor"
        echo "KERNEL=$kernel"
        echo "IO_DIR=$IO_DIR"
        echo "FILESYSTEM=$fs_type"
        echo "DISK_TYPE=$DISK_TYPE"
        echo "PROVISIONING_TYPE=$PROVISIONING_TYPE"
        echo "REMOTE_IP=$REMOTE_IP"
        echo "DROP_CACHES_OK=$DROP_CACHES_OK"
        echo "CGROUP_THROTTLE_AVAILABLE=$([[ -n "$CGROUP_THROTTLE_FILE" ]] && echo true || echo false)"
        echo "QUICK=$QUICK"
    } > "${RUN_DIR}/meta.env"

    { lscpu; echo; free -h; echo; lsblk; echo; uname -a; } \
        > "${RAW_DIR}/system_snapshot.txt" 2>&1

    section "Iteration ${iter}/${ITERATIONS}  (warmup=${warmup})  -> ${RUN_DIR##*/}"

    # ---- 1. NETWORK ---------------------------------------------------------
    section "Network"
    if have iperf3; then
        iperf3 -s -D >/dev/null 2>&1 && sleep 2
        run_test iperf3_localhost iperf3_localhost.json \
            "${PIN[@]}" iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -t 10 --json
        pkill -x iperf3 2>/dev/null || true

        # TCP probe on the iperf3 port itself, NOT ping: containers drop the
        # NET_RAW capability by default, so ICMP ping fails with "operation not
        # permitted" even when the TCP path (all iperf3 actually needs) is fine
        # — that false negative silently skipped remote tests in every container.
        if [[ -n "$REMOTE_IP" ]] && timeout 2 bash -c "cat < /dev/null > /dev/tcp/${REMOTE_IP}/${IPERF_PORT}" 2>/dev/null; then
            run_test iperf3_remote_tcp iperf3_remote.json \
                "${PIN[@]}" iperf3 -c "$REMOTE_IP" -p "$IPERF_PORT" -t 10 --json
            grep -q '"error"' "${RAW_DIR}/iperf3_remote.json" 2>/dev/null && \
                cp "${RAW_DIR}/iperf3_remote.json" "${RAW_DIR}/iperf3_remote.FAILED"
            run_test iperf3_remote_udp iperf3_remote_udp.json \
                "${PIN[@]}" iperf3 -c "$REMOTE_IP" -p "$IPERF_PORT" -u -b 1G -t 10 --json
        else
            skip_test iperf3_remote_tcp
            skip_test iperf3_remote_udp
            echo "REMOTE_IP='${REMOTE_IP}' unreachable or unset" \
                > "${RAW_DIR}/iperf3_remote.FAILED"
            log "  remote peer unreachable — remote network tests recorded as skip+FAILED"
        fi
    else
        skip_test iperf3_localhost; skip_test iperf3_remote_tcp; skip_test iperf3_remote_udp
    fi

    # ---- 2. CPU & APPLICATION ----------------------------------------------
    section "CPU & Application"
    have sysbench && run_test sysbench_cpu_single sysbench_cpu_single.txt \
        "${PIN[@]}" sysbench cpu --threads=1 --time="$SYSBENCH_TIME" run || skip_test sysbench_cpu_single
    have sysbench && run_test sysbench_cpu_multi sysbench_cpu_multi.txt \
        "${PIN[@]}" sysbench cpu --threads="$CPU_THREADS" --time="$SYSBENCH_TIME" run || skip_test sysbench_cpu_multi
    have stress-ng && run_test stress_ng_cpu stress_ng_full.txt \
        "${PIN[@]}" stress-ng --cpu "$CPU_THREADS" --timeout "${STRESS_TIME}s" --metrics-brief || skip_test stress_ng_cpu
    # NEW: context-switch stressor (plan.txt Hypothesis 5)
    have stress-ng && run_test stress_ng_switch stress_ng_switch.txt \
        "${PIN[@]}" stress-ng --switch "$CPU_THREADS" --timeout "${STRESS_TIME}s" --metrics-brief || skip_test stress_ng_switch
    have 7za && run_test 7zip 7zip_benchmark.txt \
        "${PIN[@]}" 7za "${ZIP_ARGS[@]}" -mmt="$CPU_THREADS" || skip_test 7zip
    # NEW: openssl crypto throughput cross-check
    have openssl && run_test openssl_aes openssl_aes.txt \
        "${PIN[@]}" openssl speed -elapsed -seconds "$OPENSSL_SECONDS" -evp aes-256-gcm || skip_test openssl_aes
    have openssl && run_test openssl_rsa openssl_rsa.txt \
        "${PIN[@]}" openssl speed -elapsed -seconds "$OPENSSL_SECONDS" rsa2048 || skip_test openssl_rsa

    # Python Mandelbrot (real interpreted FP workload)
    if have python3; then
        cat > "${RUN_DIR}/fractal_bench.py" <<'PYEOF'
import sys, time
dim = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
w, h, max_iter = dim, dim, 512
start = time.perf_counter()
for y in range(h):
    zy = -1.25 + y * (2.5 / h)
    for x in range(w):
        zx = -2.0 + x * (2.5 / w)
        c, z = complex(zx, zy), 0j
        for i in range(max_iter):
            z = z*z + c
            if abs(z) > 2: break
print(f"Fractal_Time: {time.perf_counter() - start:.4f}s")
PYEOF
        run_test fractal fractal_workload.txt "${PIN[@]}" python3 "${RUN_DIR}/fractal_bench.py" "$FRACTAL_DIM"
        rm -f "${RUN_DIR}/fractal_bench.py"
    else
        skip_test fractal
    fi

    # ---- 3. STORAGE ---------------------------------------------------------
    section "Storage"
    run_fio() {   # run_fio NAME rw bs qd [extra...]
        local name="$1" rw="$2" bs="$3" qd="$4"; shift 4
        have fio || { skip_test "fio_${name}"; return; }
        run_test "fio_${name}" "fio_${name}.json" \
            "${PIN[@]}" fio --name="$name" --filename="$test_file" --size=1G \
            --bs="$bs" --rw="$rw" --direct=1 --iodepth="$qd" \
            --runtime="$FIO_RUNTIME" --time_based --group_reporting \
            "$@" --output-format=json
    }
    run_fio seq_rw       rw     1M 8
    run_fio rand_4k      randrw 4k 32
    run_fio mixed_70_30  randrw 4k 8 --rwmixread=70
    rm -f "$test_file"

    # dd baseline — O_DIRECT so it's a valid cold-path everywhere; falls back to
    # buffered+fdatasync only where O_DIRECT is unsupported (records which).
    dd_bench() {   # dd_bench write|read
        local op="$1"
        local out="${RAW_DIR}/dd_${op}.txt" rc mode="odirect"
        have dd || { skip_test "dd_${op}"; return; }
        [[ "$DROP_CACHES_OK" == true ]] && drop_caches
        read -r i0 t0 <<< "$(snapshot_cpu)"
        local start end dur
        start=$(date +%s.%N)
        if [[ "$op" == write ]]; then
            "${PIN[@]}" dd if=/dev/zero of="$test_file" bs=1M count=1024 oflag=direct > "$out" 2>&1
            rc=$?
            if [[ $rc -ne 0 ]] && grep -qi "invalid argument\|not permitted" "$out"; then
                mode="buffered_fdatasync"
                "${PIN[@]}" dd if=/dev/zero of="$test_file" bs=1M count=1024 conv=fdatasync > "$out" 2>&1; rc=$?
            fi
        else
            "${PIN[@]}" dd if="$test_file" of=/dev/null bs=1M iflag=direct > "$out" 2>&1
            rc=$?
            if [[ $rc -ne 0 ]] && grep -qi "invalid argument\|not permitted" "$out"; then
                mode="buffered"
                "${PIN[@]}" dd if="$test_file" of=/dev/null bs=1M > "$out" 2>&1; rc=$?
            fi
        fi
        end=$(date +%s.%N); dur=$(awk "BEGIN{printf \"%.2f\", $end-$start}")
        echo "dd_mode=$mode" >> "$out"
        manifest_row "dd_${op}" "$([[ $rc -eq 0 ]] && echo ok || echo fail)" "$dur" "dd_${op}.txt"
    }
    dd_bench write
    dd_bench read
    rm -f "$test_file"

    # NEW: ioping — per-request storage latency + seek rate
    have ioping && run_test ioping_latency ioping_latency.txt \
        ioping -c 30 -D "$IO_DIR" || skip_test ioping_latency
    have ioping && run_test ioping_seek ioping_seek.txt \
        ioping -R -D "$IO_DIR" || skip_test ioping_seek

    # ---- 4. MEMORY ----------------------------------------------------------
    section "Memory"
    have sysbench && run_test sysbench_mem_write sysbench_mem_write.txt \
        "${PIN[@]}" sysbench memory --memory-total-size="$MEM_LIMIT" \
        --memory-oper=write --threads="$CPU_THREADS" run || skip_test sysbench_mem_write
    have sysbench && run_test sysbench_mem_read sysbench_mem_read.txt \
        "${PIN[@]}" sysbench memory --memory-total-size="$MEM_LIMIT" \
        --memory-oper=read --threads="$CPU_THREADS" run || skip_test sysbench_mem_read
    have mbw && run_test mbw mbw_results.txt "${PIN[@]}" mbw 256 || skip_test mbw

    # NEW: STREAM-style bandwidth cross-check (compiled on the fly)
    if have gcc; then
        cat > "${RUN_DIR}/stream_bench.c" <<'CEOF'
#include <stdio.h>
#include <sys/time.h>
#define N 20000000
#define NTIMES 10
static double a[N], b[N], c[N];
static double wt(void){ struct timeval t; gettimeofday(&t,0); return t.tv_sec + t.tv_usec*1e-6; }
int main(void){
    for(long i=0;i<N;i++){ a[i]=1.0; b[i]=2.0; c[i]=0.0; }
    double best_copy=1e30,best_scale=1e30,best_add=1e30,best_triad=1e30,t;
    for(int k=0;k<NTIMES;k++){
        t=wt(); for(long i=0;i<N;i++) c[i]=a[i];            t=wt()-t; if(t<best_copy) best_copy=t;
        t=wt(); for(long i=0;i<N;i++) b[i]=3.0*c[i];        t=wt()-t; if(t<best_scale)best_scale=t;
        t=wt(); for(long i=0;i<N;i++) c[i]=a[i]+b[i];       t=wt()-t; if(t<best_add)  best_add=t;
        t=wt(); for(long i=0;i<N;i++) a[i]=b[i]+3.0*c[i];   t=wt()-t; if(t<best_triad)best_triad=t;
    }
    double gb=(double)N*sizeof(double)/1e6;   /* MB moved per array-pass */
    printf("Copy:  %.1f MB/s\n", 2*gb/best_copy);
    printf("Scale: %.1f MB/s\n", 2*gb/best_scale);
    printf("Add:   %.1f MB/s\n", 3*gb/best_add);
    printf("Triad: %.1f MB/s\n", 3*gb/best_triad);
    return 0;
}
CEOF
        if gcc -O2 -o "${RUN_DIR}/stream_bench" "${RUN_DIR}/stream_bench.c" 2>/dev/null; then
            run_test stream stream_results.txt "${PIN[@]}" "${RUN_DIR}/stream_bench"
        else
            skip_test stream
        fi
        rm -f "${RUN_DIR}/stream_bench" "${RUN_DIR}/stream_bench.c"
    else
        skip_test stream
    fi

    # ---- 5. REAL-WORLD: kernel compile -------------------------------------
    section "Real-world: Linux kernel compile"
    if $DO_KERNEL && have make && have gcc && have wget && have tar; then
        local kurl="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
        local ktar="${OUT_ROOT}/linux-${KERNEL_VERSION}.tar.xz"
        [[ -f "$ktar" ]] || wget -q "$kurl" -O "$ktar"
        if [[ -s "$ktar" ]]; then
            local kbuild="${IO_DIR}/kernel_build_${ts}"
            mkdir -p "$kbuild"
            tar -xJf "$ktar" -C "$kbuild" --strip-components=1 2>/dev/null
            ( cd "$kbuild" && make defconfig >/dev/null 2>&1 )
            local kstart kend kdur krc
            read -r i0 t0 <<< "$(snapshot_cpu)"
            kstart=$(date +%s.%N)
            ( cd "$kbuild" && "${PIN[@]}" /usr/bin/time -v make -j"$CPU_THREADS" ) \
                > "${RAW_DIR}/linux_kernel_compile_raw.txt" 2>&1
            krc=$?
            kend=$(date +%s.%N); kdur=$(awk "BEGIN{printf \"%.2f\", $kend-$kstart}")
            manifest_row kernel_compile "$([[ $krc -eq 0 ]] && echo ok || echo fail)" "$kdur" linux_kernel_compile_raw.txt
            rm -rf "$kbuild"
        else
            skip_test kernel_compile
        fi
    else
        skip_test kernel_compile
        $DO_KERNEL || log "  kernel compile disabled (--no-kernel / --quick)"
    fi

    # ---- Done: completeness sentinel ---------------------------------------
    {
        echo "completed_at=$(date +%Y-%m-%dT%H:%M:%S)"
        echo "ok=$(awk -F'\t' 'NR>1 && $2=="ok"{n++}END{print n+0}'   "$MANIFEST")"
        echo "fail=$(awk -F'\t' 'NR>1 && $2=="fail"{n++}END{print n+0}' "$MANIFEST")"
        echo "skip=$(awk -F'\t' 'NR>1 && $2=="skip"{n++}END{print n+0}' "$MANIFEST")"
    } > "${RUN_DIR}/RUN_COMPLETE"
    log "Iteration ${iter} complete: $(tail -n1 "${RUN_DIR}/RUN_COMPLETE" >/dev/null; cat "${RUN_DIR}/RUN_COMPLETE" | tr '\n' ' ')"
}

# =============================================================================
# DEPENDENCIES (best-effort, non-fatal) + SESSION META
# =============================================================================
section "Setup"
if have apt-get; then
    log "Installing dependencies (best-effort, non-fatal)..."
    export DEBIAN_FRONTEND=noninteractive
    SUDO=""; [[ $EUID -ne 0 ]] && have sudo && SUDO="sudo"
    $SUDO apt-get update -qq 2>/dev/null
    $SUDO apt-get install -y -o Dpkg::Options::="--force-confold" \
        sysbench stress-ng build-essential p7zip-full fio ioping mbw numactl bc \
        python3 wget tar time iperf3 openssl \
        libncurses-dev flex bison libelf-dev libssl-dev 2>/dev/null
fi

{
    echo "SUITE_VERSION=$SUITE_VERSION"
    echo "PLATFORM=$PLATFORM"
    echo "HOST_OS=$HOST_OS"
    echo "ISOLATION_TYPE=$ISOLATION_TYPE"
    echo "ITERATIONS=$ITERATIONS"
    echo "CPU_CORES=$CPU_CORES"
    echo "CPU_THREADS=$CPU_THREADS"
    echo "MEM_LIMIT=$MEM_LIMIT"
    echo "REMOTE_IP=$REMOTE_IP"
    echo "IO_DIR=$IO_DIR"
    echo "DROP_CACHES_OK=$DROP_CACHES_OK"
    echo "QUICK=$QUICK"
    echo "SESSION_TS=$SESSION_TS"
} > "${SESSION_DIR}/session_meta.env"

log "Session: $SESSION_DIR"
log "Platform=$PLATFORM  Host_OS=$HOST_OS  Isolation=$ISOLATION_TYPE  Iterations=$ITERATIONS"
[[ "$DROP_CACHES_OK" == true ]] || log "NOTE: cache-drop not available here; dd uses O_DIRECT (still valid)."

# =============================================================================
# RUN N ITERATIONS
# =============================================================================
for ((iter=1; iter<=ITERATIONS; iter++)); do
    warmup=false; [[ $iter -eq 1 ]] && warmup=true
    run_iteration "$iter" "$warmup"
    if [[ $iter -lt $ITERATIONS ]]; then
        sync; sleep 5    # cooldown between iterations
    fi
done

section "All iterations complete"
log "Collected $ITERATIONS iteration(s) under: $SESSION_DIR"
log "Next: run  python3 compile_results.py --project-root <dir containing session_*>"
