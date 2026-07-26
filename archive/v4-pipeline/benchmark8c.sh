#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — Raw Data Collection Suite v4.1 (CONTROLLED)
# =============================================================================

set -euo pipefail

# ── LIMITS (ADDED) ───────────────────────────────────────────────────────────
CPU_CORES="0-3"
CPU_THREADS=4
MEM_LIMIT="16G"
PIN="taskset -c ${CPU_CORES}"

# -- Colours & Setup ----------------------------------------------------------
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BASE_DIR="benchmark_raw_${TIMESTAMP}"
RAW_DIR="${BASE_DIR}/raw_logs"
mkdir -p "$RAW_DIR"

log() { echo -e "${CYAN}[$(date +%T)]${RESET} $*"; }
section() { echo -e "\n${BOLD}${CYAN}-- $* --${RESET}"; }
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

# =============================================================================
# 1. SETUP & INITIALIZATION
# =============================================================================
section "Setup & Initialization"
log "Installing ALL dependencies (Non-Interactive)..."
set +e
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    sysbench stress-ng build-essential p7zip-full fio ioping mbw numactl bc \
    python3 wget tar libncurses-dev flex bison libelf-dev libssl-dev time iperf3
set -e

log "Capturing baseline system state..."
{ lscpu; free -h; lsblk; uname -a; } > "${RAW_DIR}/system_snapshot.txt"

# =============================================================================
# 2. NETWORK BENCHMARKS (iperf3)
# =============================================================================
section "Network Benchmarks"

log "iperf3: Localhost Loopback..."
iperf3 -s -D > /dev/null 2>&1 && sleep 2
$PIN iperf3 -c 127.0.0.1 -t 10 --json > "${RAW_DIR}/iperf3_localhost.json" 2>&1
pkill iperf3 || true

log "iperf3: Remote Server (192.168.100.36)..."
REMOTE_IP="192.168.100.36"
if ping -c 1 -W 2 192.168.100.1 > /dev/null 2>&1; then
    $PIN iperf3 -c "$REMOTE_IP" -p 5201 -t 10 --json > "${RAW_DIR}/iperf3_remote.json" 2>&1 || echo "Remote failed" > "${RAW_DIR}/remote_err.log"
else
    log "Remote unreachable, skipping."
fi

# =============================================================================
# 3. CPU & APPLICATION BENCHMARKS
# =============================================================================
section "CPU & Application Benchmarks"

log "sysbench: CPU Single-thread (120s)..."
$PIN sysbench cpu --threads=1 --time=120 run > "${RAW_DIR}/sysbench_cpu_single.txt"

log "sysbench: CPU Multi-thread (${CPU_THREADS} threads, 120s)..."
$PIN sysbench cpu --threads=${CPU_THREADS} --time=120 run > "${RAW_DIR}/sysbench_cpu_multi.txt"

log "stress-ng: CPU metrics (120s)..."
$PIN $SUDO stress-ng --cpu ${CPU_THREADS} --timeout 120s --metrics-brief > "${RAW_DIR}/stress_ng_full.txt" 2>&1

log "7-Zip: Internal Benchmark..."
$PIN 7za b -mmt=${CPU_THREADS} > "${RAW_DIR}/7zip_benchmark.txt"

log "Python: Mandelbrot Fractal (2000x2000)..."
cat << 'EOF' > fractal_bench.py
import time
w, h, max_iter = 2000, 2000, 512
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
EOF
$PIN python3 fractal_bench.py > "${RAW_DIR}/fractal_workload.txt"
rm fractal_bench.py

# =============================================================================
# 4. DISK I/O SUITE (UNCHANGED)
# =============================================================================
section "Disk I/O Benchmarks"

TEST_FILE="${HOME}/full_io_workload.bin"
rm -f "$TEST_FILE"

run_fio() {
    local name=$1; local rw=$2; local bs=$3; local qd=$4; local extra=${5:-}
    log "fio: $name..."
    $PIN $SUDO fio --name="$name" --filename="$TEST_FILE" --size=1G --bs="$bs" --rw="$rw" \
        --direct=1 --iodepth="$qd" --runtime=60 --time_based --group_reporting \
        $extra --output-format=json > "${RAW_DIR}/fio_${name}.json" 2>&1
    $PIN $SUDO fio --name="$name" --filename="$TEST_FILE" --size=1G --bs="$bs" --rw="$rw" \
        --direct=1 --iodepth="$qd" --runtime=60 --time_based --group_reporting \
        $extra --output-format=normal > "${RAW_DIR}/fio_${name}_raw.txt" 2>&1
}

run_fio "seq_rw" "rw" "1M" "8"
run_fio "rand_4k" "randrw" "4k" "32"
run_fio "mixed_70_30" "randrw" "4k" "8" "--rwmixread=70"

log "dd: Baseline Write/Read..."
$SUDO sync && echo 3 | $SUDO tee /proc/sys/vm/drop_caches >/dev/null
$PIN dd if=/dev/zero of="$TEST_FILE" bs=1M count=1024 conv=fdatasync > "${RAW_DIR}/dd_write.txt" 2>&1
$PIN dd if="$TEST_FILE" of=/dev/null bs=1M > "${RAW_DIR}/dd_read.txt" 2>&1
rm -f "$TEST_FILE"

# =============================================================================
# 5. MEMORY SUITE
# =============================================================================
section "Memory Benchmarks"

log "sysbench: Memory Write (${MEM_LIMIT})..."
$PIN sysbench memory --memory-total-size=${MEM_LIMIT} --memory-oper=write --threads=${CPU_THREADS} run > "${RAW_DIR}/sysbench_mem_write.txt"

log "sysbench: Memory Read (${MEM_LIMIT})..."
$PIN sysbench memory --memory-total-size=${MEM_LIMIT} --memory-oper=read --threads=${CPU_THREADS} run > "${RAW_DIR}/sysbench_mem_read.txt"

log "mbw: Memory Bandwidth (256MB)..."
$PIN mbw 256 > "${RAW_DIR}/mbw_results.txt" 2>&1

# =============================================================================
# 6. HEAVY WORKLOAD: KERNEL COMPILE
# =============================================================================
section "Heavy Workload: Linux Kernel Build"

KVER="6.8"
KURL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz"

log "Fetching Kernel ${KVER} source..."
[ ! -f "linux-kernel.tar.xz" ] && wget -q "$KURL" -O linux-kernel.tar.xz
mkdir -p kernel_build && tar -xJf linux-kernel.tar.xz -C kernel_build --strip-components=1
cd kernel_build
make defconfig >> /dev/null 2>&1

log "Compiling Kernel (${CPU_THREADS} threads)..."
$PIN { /usr/bin/time -v make -j${CPU_THREADS}; } > "../${RAW_DIR}/linux_kernel_compile_raw.txt" 2>&1

cd .. && rm -rf kernel_build linux-kernel.tar.xz

# =============================================================================
# FINISH
# =============================================================================
section "Benchmark Complete"
log "Total files collected: $(ls -1 "${RAW_DIR}" | wc -l)"