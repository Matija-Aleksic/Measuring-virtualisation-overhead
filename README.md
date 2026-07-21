# Measuring Virtualisation Overhead

Data, benchmark scripts, and collected results for the undergraduate thesis
**"Performance Abstraction Tax: A Controlled Analysis of Virtualization and
Container-Based Isolation Across Linux and Windows Systems."**

## Contents

- `benchmark.sh` — main benchmark harness (latest version)
- `benchmark_v5.1.sh`, `benchmark4.sh`, `benchmark4Docker.sh`, `benchmark8c.sh` — earlier iterations of the harness
- `bench.conf.example` — configuration template for `benchmark.sh`
- `Zavrsni.odt` — the thesis document
- `NewTests/`, `OldTests/` — collected benchmark run data across platforms (bare metal, Docker, LXC, QEMU/KVM, VirtualBox, VMware, WSL2) on Linux and Windows hosts

## Running a benchmark

Copy `bench.conf.example` to `bench.conf`, adjust it for the target platform, then run:

```
./benchmark.sh
```
