# Measuring Virtualisation Overhead

Benchmark harness and collected results for the undergraduate thesis
**"Performance Abstraction Tax: A Controlled Analysis of Virtualization and
Container-Based Isolation Across Linux and Windows Systems."**

## Contents

- `benchmark.sh` — benchmark harness; runs identically on every platform
- `bench.conf.example` — configuration template
- `NewTests/`, `OldTests/` — raw run data, one directory per platform
- `Aleksic.docx`, `Zavrsni.odt` — the thesis document

## Platforms measured

Linux host: bare metal, Docker, LXC, QEMU/KVM, VirtualBox, VMware
Windows host: WSL2, Docker-on-WSL2, Hyper-V, VirtualBox, VMware

`-U24` directories are the Ubuntu-24.04-guest re-run round; `-v7` directories are
the Windows re-run with SMT disabled, which removes a vCPU-topology confound
present in the earlier Windows data.

## Running a benchmark

```
cp bench.conf.example bench.conf   # adjust for the target platform
./benchmark.sh
```

The Python analysis pipeline is not published in this repository.
