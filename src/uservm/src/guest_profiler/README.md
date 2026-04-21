# Nanvix Guest Profiler — End-to-End Guide

This document explains how to use the Nanvix guest profiler to generate
flamegraphs that span from guest user-space code through the guest kernel,
the host VMM, and optionally the host OS kernel.

## Architecture

The profiler captures stack traces at two levels, merged into a single
flamegraph with `[GUEST]` and `[HOST]` root frames:

```
┌─────────────────────────────────────────────────────┐
│  [HOST]: Host VMM + OS Kernel                       │
│  nanvixd, vid.sys, ntoskrnl, KVM, scheduler         │
│  Captured by: ETW/WPR (Windows) / perf record (Linux)│
├─────────────────────────────────────────────────────┤
│  [GUEST]: Guest kernel + user application           │
│  Nanvix kernel, CPython, libc, syscalls             │
│  Captured by: 1kHz WHvCancelRunVirtualProcessor     │
│  + frame-pointer walk + ELF symbol resolution       │
└─────────────────────────────────────────────────────┘
│  Captured by: WHv/KVM register read + frame walk    │
└─────────────────────────────────────────────────────┘
```

## How Sampling Works

### Statistical Validity

The profiler uses **periodic sampling** — the standard technique used by
`perf`, VTune, Instruments, and all production profilers.

1. **Periodic time sampling**: A 1 kHz timer fires every ~1 ms from a
   dedicated thread, independent of guest or host execution state. The
   probability of capturing any code path is proportional to the time
   spent in that path.

2. **Overhead**: Each sample requires a `WHvCancelRunVirtualProcessor`
   call, register reads, and a frame-pointer walk. At 1 kHz over a
   3-second run, this adds ~3,000 interrupts. Overhead varies by system
   but is typically small relative to guest execution time.

3. **Guest sampling**: When the timer cancels the VP during guest
   execution, `WHvRunVirtualProcessor` returns with `Interrupted` and
   guest registers (EIP/EBP/CR3) reflect the exact interrupted state.
   This is a true point-in-time sample of guest execution.

4. **Host sampling**: Host-side profiling (nanvixd VMM code + OS kernel)
   is handled entirely by ETW (Windows) or `perf record` (Linux). These
   tools run concurrently at the same configurable frequency as the guest
   profiler (controlled by `NANVIX_PROFILER_FREQ_HZ`) and provide full
   symbol resolution via PDB (Windows) or DWARF (Linux), including
   kernel code (vid.sys, ntoskrnl).

5. **Caveats**:
   - The timer is periodic (not randomized/Poisson), which can alias
     with periodic guest activity. If the guest has a periodic workload
     at the same frequency as our profiler, we would consistently sample
     the same phase of that cycle, biasing the flamegraph. For
     alias-resistant profiling, consider using a prime-number frequency
     like 997 Hz. In practice, WHP emulates the LAPIC timer internally
     (zero VM exits for delivery), so aliasing with guest timers is
     unlikely on WHP.
   - `thread::sleep(1ms)` precision depends on `timeBeginPeriod(1)`
     (Windows) which provides ~1 ms granularity but not sub-ms precision.
   - ETW/perf kernel correlation: our profiler uses QPC (Windows) or
     `CLOCK_MONOTONIC_RAW` (Linux) for timestamps. ETW uses QPC
     natively. For `perf`, the default clock may differ — if precise
     timestamp matching is needed, run `perf record --clockid
     monotonic_raw`.

### Sample Count Guidelines

| Duration | Samples at 1 kHz | Statistical quality |
|----------|-----------------|---------------------|
| 100 ms   | ~100            | Rough profile       |
| 1 s      | ~1,000          | Good for hot paths  |
| 5 s      | ~5,000          | Reliable profiling  |
| 30 s     | ~30,000         | Production quality  |

For meaningful flamegraphs, aim for at least 1,000 samples. Run the
workload long enough to accumulate sufficient data.

### Guest vs Host Sampling

**Guest sampling** is done by the built-in profiler timer:

```
Timer thread                    vCPU thread
─────────────                   ───────────
                                WHvRunVirtualProcessor() ──── guest executing
WHvCancelRunVirtualProcessor() → |
                                ← returns Interrupted
                                → read guest EIP/EBP/CR3
                                → walk frame-pointer chain
                                → store StackSample with QPC timestamp
```

The guest profiler only captures stacks when the VP was executing guest
code (Interrupted exit). When the timer fires during VMM exit handling,
the cancel is a no-op and the next `WHvRunVirtualProcessor` returns
immediately — no sample is taken because host profiling is delegated to
ETW/perf which captures the host stack with full symbol resolution.

**Host sampling** is done by ETW (Windows) or `perf record` (Linux),
which runs concurrently at the same frequency as the guest profiler.
The ETL/perf.data is post-processed by `analyze-etl.py` / `perf script`
to extract folded stacks filtered by the nanvixd process.

## Prerequisites

### Tools

```bash
# Flamegraph generation
cargo install inferno rustfilt

# Windows kernel tracing (optional, requires admin)
# Install Windows Performance Toolkit from Windows SDK

# Linux kernel tracing (optional)
sudo apt install linux-tools-common linux-tools-$(uname -r)
```

### Frame Pointers

All binaries in the profiled stack must preserve frame pointers for
the stack walker to produce deep call chains. Without frame pointers,
stack walks terminate after 1-2 frames.

## Building for Profiling

Use `.\z build --profile --release` to build everything in profiling
mode. This single command produces binaries with symbols and frame
pointers across the entire Nanvix stack.

### What `--profile --release` does

The `--profile` flag activates the `release-profiling` Cargo profile
(instead of the default `release` profile). This profile inherits all
release optimizations (opt-level=3, LTO, panic=abort) but adds:

| Setting | `release` | `release-profiling` | Why |
|---------|-----------|---------------------|-----|
| `strip` | `true` | `false` | Preserves .symtab (ELF) and PDB symbols (Windows) |
| `debug` | `false` | `"line-tables-only"` | Emits function names in PDB; sufficient for xperf/WPA |

The `--profile` flag also enables the `profile-time` Cargo feature,
which activates PERF_TIMINGS output and the guest profiler code paths.

### How symbols are handled per component

```
Component       Built by            Loaded into VM?   Symbol strategy
──────────────  ──────────────────  ────────────────  ──────────────────────────────────
kernel.elf      z build --profile   Yes               .symtab kept, .debug_* stripped
                                                      (objcopy --strip-debug, automated)
                                                      ~60 KB overhead in guest RAM

nanvixd.exe     z build --profile   No (host)         PDB file alongside .exe
                                                      (separate file, no runtime cost)

python.elf      cpython z build     Yes               Stripped (--strip-all).
                                                      .sym file saved on host before
                                                      stripping (automated by docker.py)
                                                      Zero overhead in guest RAM

User app (any)  App's build system  Yes               See "Requirements" below
```

### Building nanvix (kernel + nanvixd)

```powershell
cd D:\src\nanvix
.\z build --profile --release -- LOG_LEVEL=panic
```

This produces:
- `bin/kernel.elf` — `.symtab` preserved, `.debug_*` stripped automatically.
  Only ~60 KB larger than a fully stripped build. Usable directly as
  the symbol file (no separate `.sym` step).
- `bin/kernel.elf.debug` — full debug copy (for line-level debugging with GDB)
- `bin/nanvixd.exe` + `bin/nanvixd.pdb` — PDB contains function symbols
  for xperf/WPA resolution. The PDB is never loaded into the VM.

Set the symbol path — `kernel.elf` is its own symbol file:

```powershell
$env:NANVIX_KERNEL_SYMBOLS = "D:\src\nanvix\bin\kernel.elf"
```

### Building guest user applications (e.g., CPython)

Guest applications compiled with the Nanvix cross-toolchain must:

1. **Preserve frame pointers**: Compile C/C++ code with
   `-fno-omit-frame-pointer`. For Rust guest code, the Cargo profile
   already handles this. For CPython, this is set in `Makefile.nanvix`
   and `.nanvix/config.py`.

2. **Save an unstripped symbol file before stripping**: The stripped
   binary goes into the VM (minimal size). The unstripped `.sym` copy
   stays on the host for offline symbol resolution. For CPython,
   `docker.py` does this automatically.

```powershell
cd D:\src\cpython
.\z setup --with-nanvix D:\src\nanvix
.\z build
# python.elf      → 13.9 MB (stripped, loaded into VM)
# python.elf.sym  → 46 MB (unstripped, host-only, for profiler)

$env:NANVIX_USER_SYMBOLS = "D:\src\cpython\python.elf.sym"
```

If you need a full clean rebuild (e.g., after changing CFLAGS):

```powershell
docker volume rm (docker volume ls --format "{{.Name}}" `
  | Where-Object { $_ -like "cpython-nanvix-build*" })
.\z setup --with-nanvix D:\src\nanvix
.\z build
```

### Requirements for any guest user application

| Requirement | How to achieve | Why |
|------------|----------------|-----|
| Frame pointers | `-fno-omit-frame-pointer` (C/C++) | Stack walker reads EBP chain |
| Symbol file | Keep unstripped binary with `.symtab` | Guest profiler resolves addresses offline |
| Set env var | `NANVIX_USER_SYMBOLS=<path>` | Points profiler to symbol file at runtime |

Without `.symtab`, only `.dynsym` (exported symbols) is available —
static/internal functions won't resolve. With `.symtab`, expect ~97%
resolution; without, ~85%.

### Host-side symbol resolution (nanvixd + OS kernel)

Host stacks are captured by ETW (Windows) or `perf record` (Linux)
and resolved externally — not by the profiler itself:

- **Windows**: `xperf -symbols` resolves nanvixd addresses via the PDB
  file (must be built with `--profile`). OS kernel symbols are resolved
  via `_NT_SYMBOL_PATH` pointing to the Microsoft symbol server.
  The `full-flamegraph.ps1` script adds the nanvixd bin directory to
  `_NT_SYMBOL_PATH` automatically.
- **Linux**: `perf script` resolves via DWARF debug info.

Set the symbol server path for Windows kernel resolution:

```powershell
$env:_NT_SYMBOL_PATH = "srv*C:\Symbols*https://msdl.microsoft.com/download/symbols"
$env:_NT_SYMCACHE_PATH = "C:\SymCache"
```

## Generating a Flamegraph

### Quick Start (all-in-one script)

The simplest path — run as Administrator for full E2E including
Windows kernel stacks:

```powershell
# Build
.\z build --profile --release -- LOG_LEVEL=panic

# Run (as admin for kernel stacks via WPR/ETW)
.\scripts\bench\full-flamegraph.ps1
```

Without admin, guest + host VMM profiling still works — only the
kernel stacks (vid.sys, ntoskrnl) require elevation.

### Manual Steps

#### 1. Enable the Profiler

Set the `NANVIX_GUEST_PROFILE` environment variable to the output path:

```powershell
# Windows
$env:NANVIX_GUEST_PROFILE = "D:\src\profiling-output\guest.folded"
$env:NANVIX_KERNEL_SYMBOLS = "D:\src\nanvix\bin\kernel.elf"
$env:NANVIX_USER_SYMBOLS = "D:\src\cpython\python.elf.sym"
```

```bash
# Linux
export NANVIX_GUEST_PROFILE=/path/to/output.folded
export NANVIX_KERNEL_SYMBOLS=/path/to/kernel.elf
export NANVIX_USER_SYMBOLS=/path/to/python.elf.sym
```

When `NANVIX_GUEST_PROFILE` is not set, the profiler is disabled.

#### 2. Run the Workload

```powershell
.\bin\nanvixd.exe -bin-dir bin -ramfs test.img -- python.elf "-B /script.py"
```

nanvixd automatically:
- Starts the 1kHz guest profiler timer
- Captures guest + host VMM stacks
- Starts a WPR session for kernel stacks (if admin, otherwise skipped)
- Stops WPR and saves the ETL on exit
- Writes folded stacks and timestamp log

Output on stderr:
```
GUEST_PROFILE_SYMBOLS: loaded 381 symbols from kernel.elf
GUEST_PROFILE_SYMBOLS: loaded 35252 symbols from python.elf.sym
GUEST_PROFILE: wrote 105 samples to output.folded
GUEST_PROFILE: wrote 3 host samples to output.folded
ETW_SESSION: started WPR CPU profiling (qpc_freq=10000000)
ETW_SESSION: saved ETL to output.folded.etl
```

#### 3. Generate Flamegraph

For guest-only flamegraph (no kernel stacks):

```powershell
Get-Content output.folded `
  | rustfilt `
  | ForEach-Object {
      $_ -replace '<','&lt;' -replace '>','&gt;' -replace '\+0x[0-9a-fA-F]+',''
    } `
  | inferno-flamegraph --title "Nanvix Guest Flamegraph" > flamegraph.svg
```

For unified flamegraph with kernel stacks (requires `analyze-etl.py`):

```powershell
# Extract kernel stacks from ETL (needs _NT_SYMBOL_PATH for OS symbols)
$env:_NT_SYMBOL_PATH = "srv*C:\Symbols*https://msdl.microsoft.com/download/symbols"
python scripts\bench\analyze-etl.py output.folded.etl --folded kernel.folded --process nanvixd.exe --symbols

# Merge and generate
Get-Content output.folded | Where-Object { $_ -notmatch '^\[HOST' } `
  | rustfilt `
  | ForEach-Object { $_ -replace '<','&lt;' -replace '>','&gt;' -replace '\+0x[0-9a-fA-F]+','' } `
  | Set-Content merged.folded
Get-Content kernel.folded | ForEach-Object {
    $p = $_ -split " "; "[KERNEL];$($p[0..($p.Count-2)] -join ' ') $($p[-1])"
  } | Add-Content merged.folded
Get-Content merged.folded | inferno-flamegraph --title "Nanvix E2E" > flamegraph.svg
```

Or use `full-flamegraph.ps1` which does all of the above automatically.

#### 4. Additional Analysis

**Windows**: Open the ETL in WPA for detailed kernel stack analysis:
```powershell
wpa.exe output.folded.etl
# Filter CPU Usage (Sampled) to nanvixd.exe
```

**Linux**: Run the correlation script:
```bash
bash output.folded.correlation.sh
# Or manually:
perf report -i output.folded.perf.data --tid <vcpu_tid>
```

## Interpreting the Flamegraph

### Reading the SVG

- **X-axis**: Represents the proportion of samples, not time. Wider bars
  = more samples = more time spent.
- **Y-axis**: Call stack depth. Bottom = root (entry point), top = leaf
  (where CPU was actually executing).
- **Colors**: Random; they carry no meaning.

### What to Look For

1. **Wide leaf functions**: These are where the CPU spends the most time.
   Optimization targets.

2. **Tall narrow stacks**: Deep call chains that aren't expensive. Usually
   fine.

3. **`[HOST:exit_handling]` frames**: Time spent in the VMM handling VM
   exits. If this is wide, the guest is causing many exits (PMIO, IKC).

4. **`[KERNEL]` frames** (from ETW/perf correlation): Time spent in the
   host OS kernel. Wide `vid.sys` frames indicate SLAT fault overhead.

### Symbol Resolution

| Symbol format | Meaning |
|--------------|---------|
| `PyDict_SetItem` | Resolved function name |
| `0x40362942` | Unresolved address (missing from symbol files) |
| `kernel::mm::virt::vmem::Vmm::try_find_user_frame` | Demangled Rust symbol |
| `[HOST:exit_handling]` | Host VMM stack (addresses are raw hex until PDB resolution is implemented) |

Expected resolution rates:
- **With `.symtab`** (unstripped binaries): ~97%
- **With `.dynsym` only** (stripped binaries): ~85%
- **Remaining ~3%**: Data pointers on the stack (type objects, mutex
  tables) — not real return addresses

## Symbol File Details

The ELF symbol parser supports two symbol table types:

| Section | Contents | Typical count |
|---------|----------|--------------|
| `.symtab` | All symbols including `static` functions | ~35,000 (CPython) |
| `.dynsym` | Only exported/dynamic symbols | ~12,000 (CPython) |

The parser prefers `.symtab` and falls back to `.dynsym`. Both
`STT_FUNC` (regular functions) and `STT_NOTYPE` (assembly entry points)
are included.

## Platform Differences

| Feature | Windows (WHP) | Linux (KVM) |
|---------|--------------|-------------|
| Guest cancel | `WHvCancelRunVirtualProcessor` | Signal to vCPU thread |
| Guest regs | `WHvGetVirtualProcessorRegisters` | `KVM_GET_REGS` |
| Host profiling | ETW / WPR (auto-managed) | `perf record` |
| Timestamps | QPC | `CLOCK_MONOTONIC_RAW` |
| Host symbols | `.etl` → `analyze-etl.py` / WPA | `perf.data` → `perf report` |

## Troubleshooting

### No samples collected
- Ensure `NANVIX_GUEST_PROFILE` env var is set to an output path
- Ensure the workload runs long enough (>100 ms for meaningful data)

### Shallow stacks (1-2 frames)
- Rebuild with `-fno-omit-frame-pointer` (CPython: `Makefile.nanvix`)
- Ensure `force-frame-pointers = true` in `Cargo.toml` release profile

### Many unresolved addresses
- Use unstripped symbol files (`.symtab`, not just `.dynsym`)
- Set `NANVIX_KERNEL_SYMBOLS` and `NANVIX_USER_SYMBOLS` env vars
- Rebuild symbol files after code changes

### ETW/perf fails to start
- Windows: WPR requires administrator privileges. nanvixd logs
  `"ETW session failed to start"` and continues without kernel stacks.
  Run nanvixd (or the script) as admin for full E2E.
- Linux: `perf record` may need `CAP_SYS_ADMIN` or `kernel.perf_event_paranoid=1`
- Both: profiling continues without kernel stacks; guest stacks are still captured

### No kernel stacks in flamegraph
- Ensure nanvixd ran as admin (check stderr for `ETW_SESSION: started`)
- Run `analyze-etl.py --folded --symbols` on the `.etl` file to extract them
- Set `_NT_SYMBOL_PATH` for Windows kernel symbol resolution
- `full-flamegraph.ps1` handles all of this automatically
