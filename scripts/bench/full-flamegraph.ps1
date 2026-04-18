<#
.SYNOPSIS
    Full end-to-end Nanvix flamegraph: Guest + Host (VMM + OS Kernel).

.DESCRIPTION
    Generates a single unified flamegraph with two root frames:
      [GUEST]: Nanvix kernel + user app via 1kHz WHv sampling + ELF symbols
      [HOST]:  nanvixd VMM + OS kernel (vid.sys, ntoskrnl) via ETW/WPR

    Guest stacks are captured by the built-in profiler timer which
    interrupts the VP and walks the frame-pointer chain through guest
    memory. Host stacks are captured by ETW CPU sampling (started
    automatically by nanvixd when running as admin). Both sample at
    the same configurable frequency (NANVIX_PROFILER_FREQ_HZ, default
    1kHz). Without admin, only guest stacks are captured.

.PARAMETER NanvixDir
    Path to the nanvix repository root.

.PARAMETER GuestElf
    Path to the guest ELF binary to profile (e.g., python.elf, my-app.elf).

.PARAMETER KernelSymbols
    Path to kernel.elf with .symtab for guest kernel symbol resolution.

.PARAMETER UserSymbols
    Path to unstripped guest binary (.sym file) for user-space symbol resolution.

.PARAMETER Script
    Script content to execute inside the VM (passed as "-B /script.py").

.PARAMETER OutputDir
    Directory for all output files.

.PARAMETER RamfsImg
    Pre-built ramfs image. If not provided, one is built from GuestElf + Script.

.EXAMPLE
    # Run as Administrator with defaults (CPython):
    .\full-flamegraph.ps1

    # Custom Python workload:
    .\full-flamegraph.ps1 -Script "for i in range(1000): print(i)"

    # Custom guest application with pre-built ramfs:
    .\full-flamegraph.ps1 -RamfsImg "D:\src\my-app\ramfs.img" `
        -GuestElf "D:\src\my-app\my-app.elf" `
        -UserSymbols "D:\src\my-app\my-app.elf.sym"
#>
[CmdletBinding()]
param(
    [string]$NanvixDir = (Resolve-Path "$PSScriptRoot\..\..").Path,
    [string]$GuestElf = "",
    [string]$KernelSymbols = "",
    [string]$UserSymbols = "",
    [string]$Script = "",
    [string]$OutputDir = "",
    [string]$RamfsImg = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\profiler-common.ps1"

# Resolve defaults relative to NanvixDir.
if ($KernelSymbols -eq "") { $KernelSymbols = Join-Path $NanvixDir "bin\kernel.elf" }
if ($OutputDir -eq "") { $OutputDir = Join-Path (Split-Path $NanvixDir) "profiling-output" }

# ── Paths ────────────────────────────────────────────────────────────────────

$nanvixd    = Join-Path $NanvixDir "bin\nanvixd.exe"
$mkramfs    = Join-Path $NanvixDir "bin\mkramfs.exe"
$analyzeEtl = Join-Path $NanvixDir "scripts\bench\analyze-etl.py"

foreach ($tool in @($nanvixd, $mkramfs)) {
    if (-not (Test-Path $tool)) {
        Write-Host "ERROR: $tool not found. Run 'z build --profile --release' first." -ForegroundColor Red
        exit 1
    }
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$guestFolded    = Join-Path $OutputDir "guest.folded"
$kernelFolded   = Join-Path $OutputDir "kernel.folded"
$mergedFolded   = Join-Path $OutputDir "merged.folded"
$svgPath        = Join-Path $OutputDir "flamegraph.svg"
$stderrPath     = Join-Path $OutputDir "nanvixd-stderr.txt"

# ── Admin check ──────────────────────────────────────────────────────────────

$isAdmin = Test-AdminPrivilege
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Nanvix Full E2E Flamegraph (Guest + VMM + Kernel)      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

if (-not $isAdmin) {
    Write-Host "WARNING: Not running as admin. ETW kernel stacks will be unavailable." -ForegroundColor DarkYellow
    Write-Host "  Run as admin for full E2E including vid.sys/ntoskrnl stacks." -ForegroundColor DarkYellow
    Write-Host ""
}

# ── Build ramfs ──────────────────────────────────────────────────────────────

$cleanupRamfs = $false
if ($RamfsImg -eq "" -or -not (Test-Path $RamfsImg)) {
    Write-Host "[SETUP] Building ramfs..." -ForegroundColor Yellow
    if ($Script -eq "") { $Script = Get-DefaultProfileScript }
    $ramfs = Build-ProfileRamfs -MkramfsExe $mkramfs -GuestElf $GuestElf -Script $Script -OutputDir $OutputDir
    $RamfsImg = $ramfs.RamfsImg
    $cleanupRamfs = $true
    Write-Host "  Ramfs: $RamfsImg" -ForegroundColor DarkGray
}

# ── Run nanvixd ──────────────────────────────────────────────────────────────

Write-Host "[RUN] Running nanvixd with profiling..." -ForegroundColor Yellow

$result = Invoke-Nanvixd `
    -NanvixdExe $nanvixd `
    -BinDir (Join-Path $NanvixDir "bin") `
    -RamfsImg $RamfsImg `
    -GuestElf $GuestElf `
    -GuestFoldedPath $guestFolded `
    -KernelSymbols $KernelSymbols `
    -UserSymbols $UserSymbols

$result.Stderr | Set-Content $stderrPath -Encoding UTF8

# Show guest output (last few lines)
$stdoutLines = ($result.Stdout -split "`n" | Where-Object { $_.Trim() -ne "" })
if ($stdoutLines.Count -gt 5) {
    Write-Host "  ... ($($stdoutLines.Count) lines of output)" -ForegroundColor DarkGray
    $stdoutLines | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
} else {
    $stdoutLines | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

$result.ProfilerLines | ForEach-Object { Write-Host "  $($_.Trim())" -ForegroundColor DarkGray }

if (-not (Test-Path $guestFolded)) {
    Write-Host "  WARNING: no guest folded stacks at $guestFolded" -ForegroundColor Red
    Write-Host "  Ensure nanvixd was built with: z build --profile --release" -ForegroundColor Red
}

# Find the ETL that nanvixd produced
$etlPath = "$guestFolded.etl"

# ── Merge: Build unified flamegraph ──────────────────────────────────────────

Write-Host "[MERGE] Building unified flamegraph..." -ForegroundColor Yellow

# Set up symbol resolution for xperf.
$binDir = Join-Path $NanvixDir "bin"
if ($env:_NT_SYMBOL_PATH) {
    if ($env:_NT_SYMBOL_PATH -notmatch [regex]::Escape($binDir)) {
        $env:_NT_SYMBOL_PATH = "$binDir;$($env:_NT_SYMBOL_PATH)"
    }
} else {
    $env:_NT_SYMBOL_PATH = "$binDir;srv*C:\Symbols*https://msdl.microsoft.com/download/symbols"
}
if (-not $env:_NT_SYMCACHE_PATH) { $env:_NT_SYMCACHE_PATH = "C:\SymCache" }

# Guest stacks → [GUEST] prefix
if (Test-Path $guestFolded) {
    Format-FoldedStacks -FoldedPath $guestFolded |
        Where-Object { $_ -notmatch '^\[HOST' -and $_.Trim() -ne '' } |
        ForEach-Object {
            $parts = $_ -split " "
            $count = $parts[-1]
            $stack = ($parts[0..($parts.Count-2)] -join " ")
            "[GUEST];$stack $count"
        } |
        Set-Content $mergedFolded -Encoding UTF8
    $guestCount = (Get-Content $mergedFolded | Where-Object { $_.Trim() -ne "" } | Measure-Object).Count
    Write-Host "  [GUEST]: $guestCount stack entries" -ForegroundColor DarkGray
} else {
    "" | Set-Content $mergedFolded -Encoding UTF8
}

# Host stacks from ETL → [HOST] prefix
if ((Test-Path $etlPath) -and (Test-Path $analyzeEtl)) {
    Write-Host "  Extracting host stacks from ETL (this may take a few minutes)..." -ForegroundColor DarkGray
    python $analyzeEtl $etlPath --folded $kernelFolded --process nanvixd.exe --symbols 2>&1 |
        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    if (Test-Path $kernelFolded) {
        $kernelCount = (Get-Content $kernelFolded | Measure-Object).Count
        Write-Host "  [HOST]: $kernelCount stack entries" -ForegroundColor DarkGray
        Get-Content $kernelFolded | ForEach-Object {
            $parts = $_ -split " "
            $count = $parts[-1]
            $stack = ($parts[0..($parts.Count-2)] -join " ")
            "[HOST];$stack $count"
        } | Add-Content $mergedFolded -Encoding UTF8
    } else {
        Write-Host "  No host stacks extracted (first run may need symbol download)" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "  No ETL — run as admin for host stacks" -ForegroundColor DarkYellow
}

# ── Generate flamegraph ──────────────────────────────────────────────────────

Write-Host "[SVG] Generating unified flamegraph..." -ForegroundColor Yellow
$totalCount = (Get-Content $mergedFolded | Where-Object { $_.Trim() -ne "" } | Measure-Object).Count
Get-Content $mergedFolded |
    Where-Object { $_.Trim() -ne "" } |
    inferno-flamegraph --title "Nanvix E2E Flamegraph (Guest + Host VMM + Windows Kernel)" > $svgPath 2>$null

# ── Summary ──────────────────────────────────────────────────────────────────

Write-ProfileSummary -OutputDir $OutputDir -SvgPath $svgPath
Write-Host "  Total merged stacks: $totalCount" -ForegroundColor Green
if (Test-Path $etlPath) {
    Write-Host ""
    Write-Host "  For detailed WPA analysis:" -ForegroundColor DarkGray
    Write-Host "    wpa.exe `"$etlPath`"" -ForegroundColor DarkGray
}

# Cleanup
if ($cleanupRamfs) {
    Remove-Item (Join-Path $OutputDir "ramfs-content") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $OutputDir "test.img") -ErrorAction SilentlyContinue
}
