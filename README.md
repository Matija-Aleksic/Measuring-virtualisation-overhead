# Measuring Virtualisation Overhead

Data, benchmark scripts, and collected results for the undergraduate thesis
**"Performance Abstraction Tax: A Controlled Analysis of Virtualization and
Container-Based Isolation Across Linux and Windows Systems."**

## Contents

### Collection
- `benchmark.sh` — main benchmark harness (v5); runs identically on every platform
- `bench.conf.example` — configuration template for `benchmark.sh`
- `bench.py` — reduced suite (v6.0) used for the Ubuntu-24.04-guest re-run round
- `rerun_u24.sh` — provisioning + orchestration for that round

The Mandelbrot CPU workload is **not** a separate file: each harness writes a small
`fractal_bench.py` into the run directory and deletes it afterwards.

### Analysis
- `compile_results.py` — raw logs → `results_long.csv` / `results_stats.csv` / completeness report
- `make_analysis.py` — stats → `NewTests/ANALYSIS.md`
- `make_figures.py` — stats → `NewTests/figs/*.png`
- `make_thesis_tables.py` — stats → `NewTests/thesis_tables/*.csv` **and** the tables in `zavrsni.docx`

### Data & documents
- `NewTests/`, `OldTests/` — collected benchmark run data across platforms (bare metal, Docker, LXC, QEMU/KVM, VirtualBox, VMware, WSL2) on Linux and Windows hosts
- `NewTests/thesis_tables/` — one CSV per thesis table, ready for plotting
- `Zavrsni.odt`, `zavrsni.docx` — the thesis document
- `archive/` — superseded v4-era scripts, kept for provenance only (see `archive/README.md`)

## Running a benchmark

Copy `bench.conf.example` to `bench.conf`, adjust it for the target platform, then run:

```
./benchmark.sh
```

## Regenerating the analysis

```
python3 compile_results.py --project-root . --out-dir NewTests/compiled_all
python3 make_analysis.py     --stats NewTests/compiled_all/results_stats.csv --out NewTests/ANALYSIS.md
python3 make_figures.py      --stats NewTests/compiled_all/results_stats.csv --out NewTests/figs
python3 make_thesis_tables.py --stats NewTests/compiled_all/results_stats.csv   # add --no-docx to skip the document
```
