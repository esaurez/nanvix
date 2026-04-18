<#
.SYNOPSIS
    Nanvix guest-only flamegraph profiler.

.DESCRIPTION
    Runs nanvixd with guest stack profiling and generates a flamegraph SVG.
    This captures only guest stacks (Nanvix kernel + user application).
    For a full E2E flamegraph including host VMM and OS kernel stacks,
    use full-flamegraph.ps1 instead.

.PARAMETER NanvixDir
    Path to the nanvix repository (default: D:\src\nanvix)

.PARAMETER GuestElf
    Path to the guest ELF binary to profile (default: D:\src\cpython\python.elf)

.PARAMETER KernelSymbols
    Path to kernel ELF with .symtab for symbol resolution

.PARAMETER UserSymbols
    Path to unstripped guest-app ELF (.sym file)

.PARAMETER Script
    Python script content to run (default: factorial computation)

.PARAMETER OutputDir
    Directory for output files (default: D:\src\profiling-output)

.EXAMPLE
    .\guest-flamegraph.ps1
    .\guest-flamegraph.ps1 -Script "print('hello')"
#>
param(
    [string]$NanvixDir = (Resolve-Path "$PSScriptRoot\..\..").Path,
    [string]$GuestElf = "",
    [string]$KernelSymbols = "",
    [string]$UserSymbols = "",
    [string]$Script = "",
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\profiler-common.ps1"

# Resolve defaults relative to NanvixDir.
if ($KernelSymbols -eq "") { $KernelSymbols = Join-Path $NanvixDir "bin\kernel.elf" }
if ($OutputDir -eq "") { $OutputDir = Join-Path (Split-Path $NanvixDir) "profiling-output" }

# ── Paths ────────────────────────────────────────────────────────────────────

$nanvixd = Join-Path $NanvixDir "bin\nanvixd.exe"
$mkramfs = Join-Path $NanvixDir "bin\mkramfs.exe"

foreach ($tool in @($nanvixd, $mkramfs)) {
    if (-not (Test-Path $tool)) {
        Write-Host "ERROR: $tool not found. Run 'z build --profile --release' first." -ForegroundColor Red
        exit 1
    }
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$foldedPath = Join-Path $OutputDir "guest.folded"
$svgPath    = Join-Path $OutputDir "flamegraph.svg"

Write-Host ""
Write-Host "=== Nanvix Guest Flamegraph ===" -ForegroundColor Cyan
Write-Host ""

# ── Build ramfs ──────────────────────────────────────────────────────────────

Write-Host "[SETUP] Building ramfs..." -ForegroundColor Yellow
if ($Script -eq "") { $Script = Get-DefaultProfileScript }
$ramfs = Build-ProfileRamfs -MkramfsExe $mkramfs -GuestElf $GuestElf -Script $Script -OutputDir $OutputDir
Write-Host "  Ramfs: $($ramfs.RamfsImg)" -ForegroundColor DarkGray

# ── Run nanvixd ──────────────────────────────────────────────────────────────

Write-Host "[RUN] Running nanvixd with guest profiling..." -ForegroundColor Yellow

$result = Invoke-Nanvixd `
    -NanvixdExe $nanvixd `
    -BinDir (Join-Path $NanvixDir "bin") `
    -RamfsImg $ramfs.RamfsImg `
    -GuestElf $GuestElf `
    -GuestFoldedPath $foldedPath `
    -KernelSymbols $KernelSymbols `
    -UserSymbols $UserSymbols

Write-Host $result.Stdout
$result.ProfilerLines | ForEach-Object { Write-Host "  $($_.Trim())" -ForegroundColor DarkGray }

# ── Generate flamegraph ──────────────────────────────────────────────────────

if (Test-Path $foldedPath) {
    Write-Host ""
    Write-Host "[SVG] Generating flamegraph..." -ForegroundColor Yellow
    Format-FoldedStacks -FoldedPath $foldedPath |
        inferno-flamegraph --title "Nanvix Guest Flamegraph" > $svgPath 2>$null

    Write-ProfileSummary -OutputDir $OutputDir -SvgPath $svgPath
} else {
    Write-Host "ERROR: No guest stacks produced. Check that nanvixd was built with profiling." -ForegroundColor Red
}

# Cleanup
Remove-Item $ramfs.CleanupPath -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $ramfs.RamfsImg -ErrorAction SilentlyContinue
