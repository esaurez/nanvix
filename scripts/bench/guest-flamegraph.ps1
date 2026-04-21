<#
.SYNOPSIS
    Nanvix guest flamegraph profiler.

.DESCRIPTION
    Runs nanvixd with guest stack profiling enabled and generates a
    flamegraph SVG. When run as Administrator, nanvixd also starts an
    ETW/WPR session for host stacks (nanvixd VMM + OS kernel).

    Without admin, only guest stacks are captured.

.PARAMETER NanvixDir
    Path to the nanvix repository (default: D:\src\nanvix)

.PARAMETER GuestElf
    Path to the guest ELF binary to profile (default: D:\src\cpython\python.elf)

.PARAMETER KernelSymbols
    Path to unstripped kernel.elf.sym

.PARAMETER UserSymbols
    Path to unstripped guest-app.elf.sym

.PARAMETER Script
    Python script content to run (default: factorial computation)

.PARAMETER OutputDir
    Directory for output files (default: D:\src\profiling-output)

.EXAMPLE
    # Run as Administrator for full E2E including Hyper-V kernel stacks:
    Start-Process powershell -Verb RunAs -ArgumentList "-File $PSCommandPath"
#>
param(
    [string]$NanvixDir = "D:\src\nanvix",
    [string]$GuestElf = "D:\src\cpython\python.elf",
    [string]$KernelSymbols = "D:\src\nanvix\bin\kernel.elf.sym",
    [string]$UserSymbols = "D:\src\cpython\python.elf.sym",
    [string]$Script = "",
    [string]$OutputDir = "D:\src\profiling-output"
)

$ErrorActionPreference = "Stop"

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host "=== Nanvix E2E Profiler ===" -ForegroundColor Cyan
Write-Host "Admin: $isAdmin"
Write-Host ""

# Setup output directory
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$etlPath = Join-Path $OutputDir "trace.etl"
$foldedPath = Join-Path $OutputDir "profile.folded"
$svgPath = Join-Path $OutputDir "flamegraph.svg"
$tsLogPath = "$foldedPath.timestamps.log"

# Set symbol and profiler env vars
$env:NANVIX_KERNEL_SYMBOLS = $KernelSymbols
$env:NANVIX_USER_SYMBOLS = $UserSymbols
$env:NANVIX_GUEST_PROFILE = $foldedPath

# Create test ramfs
$ramfsDir = Join-Path $OutputDir "ramfs-content"
New-Item -ItemType Directory -Path $ramfsDir -Force | Out-Null
Copy-Item $GuestElf (Join-Path $ramfsDir (Split-Path $GuestElf -Leaf)) -Force

if ($Script -eq "") {
    $Script = @"
import math
# Mix computation + I/O for profiling all layers
for i in range(50):
    result = sum(math.factorial(j) for j in range(200))
    print(f'iter {i}: {len(str(result))} digits')
print('Done')
"@
}
$Script | Set-Content (Join-Path $ramfsDir "script.py") -Encoding UTF8

$mkramfs = Join-Path $NanvixDir "bin\mkramfs.exe"
$ramfsImg = Join-Path $OutputDir "test.img"
& $mkramfs -o $ramfsImg $ramfsDir 2>&1 | Out-Null

# ---- Layer 3: Start ETW (admin only) ----
$wprStarted = $false
if ($isAdmin) {
    Write-Host "[Layer 3] Starting WPR CPU profiling..." -ForegroundColor Yellow
    wpr -cancel 2>&1 | Out-Null
    $wprResult = wpr -start CPU -filemode 2>&1
    if ($LASTEXITCODE -eq 0) {
        $wprStarted = $true
        Write-Host "[Layer 3] WPR started (ETW kernel stacks active)" -ForegroundColor Green
    } else {
        Write-Host "[Layer 3] WPR failed: $wprResult" -ForegroundColor Red
    }
} else {
    Write-Host "[Layer 3] Skipped — run as admin for Hyper-V kernel stacks" -ForegroundColor DarkYellow
}

# ---- Run nanvixd with layers 1+2 ----
Write-Host ""
Write-Host "[Layer 1+2] Running nanvixd with guest + host profiling..." -ForegroundColor Yellow

# Temporarily enable profiler in standalone.rs would be needed here.
# For now, assume the binary was built with guest_profile_path set.
$nanvixd = Join-Path $NanvixDir "bin\nanvixd.exe"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $nanvixd
$psi.Arguments = "-bin-dir `"$(Join-Path $NanvixDir 'bin')`" -ramfs `"$ramfsImg`" -- `"$GuestElf`" `"-B /script.py`""
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false

$proc = [System.Diagnostics.Process]::Start($psi)
$proc.StandardInput.Close()

$stdout = $proc.StandardOutput.ReadToEndAsync()
$stderr = $proc.StandardError.ReadToEndAsync()
$proc.WaitForExit(300000) | Out-Null

[System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr))

Write-Host $stdout.Result

# Parse stderr for profiler output
$stderrLines = $stderr.Result -split "`n"
$stderrLines | Where-Object { $_ -match "GUEST_PROFILE|PROFILER|ETW" } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

# ---- Layer 3: Stop ETW ----
if ($wprStarted) {
    Write-Host ""
    Write-Host "[Layer 3] Stopping WPR..." -ForegroundColor Yellow
    wpr -stop $etlPath 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[Layer 3] ETL saved: $etlPath ($((Get-Item $etlPath).Length / 1MB) MB)" -ForegroundColor Green
    } else {
        Write-Host "[Layer 3] WPR stop failed" -ForegroundColor Red
    }
}

# ---- Generate unified flamegraph ----
Write-Host ""
Write-Host "Generating unified flamegraph..." -ForegroundColor Yellow

$mergedFolded = Join-Path $OutputDir "merged.folded"
$analyzeScript = Join-Path $NanvixDir "scripts\bench\analyze-etl.py"

if (Test-Path $foldedPath) {
    # Start with guest + host VMM stacks (demangle + sanitize)
    Get-Content $foldedPath |
        rustfilt |
        ForEach-Object { $_ -replace '<','&lt;' -replace '>','&gt;' -replace '\+0x[0-9a-fA-F]+','' } |
        Set-Content $mergedFolded -Encoding UTF8

    $guestHostCount = (Get-Content $mergedFolded | Measure-Object).Count
    Write-Host "  Guest + Host VMM: $guestHostCount stack entries" -ForegroundColor DarkGray

    # Merge kernel stacks from ETL if available
    if ($wprStarted -and (Test-Path $etlPath) -and (Test-Path $analyzeScript)) {
        Write-Host "  Extracting kernel stacks from ETL..." -ForegroundColor Yellow
        $kernelFolded = Join-Path $OutputDir "kernel.folded"
        python $analyzeScript $etlPath --folded $kernelFolded --process nanvixd.exe --symbols 2>$null

        if (Test-Path $kernelFolded) {
            $kernelCount = (Get-Content $kernelFolded | Measure-Object).Count
            Write-Host "  Kernel: $kernelCount stack entries" -ForegroundColor DarkGray

            # Prefix kernel stacks with [KERNEL] and append
            Get-Content $kernelFolded | ForEach-Object {
                $parts = $_ -split " "
                $count = $parts[-1]
                $stack = ($parts[0..($parts.Count-2)] -join " ")
                "[KERNEL];$stack $count"
            } | Add-Content $mergedFolded -Encoding UTF8
        }
    }

    # Generate the unified SVG
    Get-Content $mergedFolded |
        inferno-flamegraph --title "Nanvix E2E Flamegraph (Guest + Host VMM + Kernel)" > $svgPath 2>$null

    Write-Host "Flamegraph: $svgPath ($([math]::Round((Get-Item $svgPath).Length / 1KB, 1)) KB)" -ForegroundColor Green
}

# ---- Summary ----
Write-Host ""
Write-Host "=== Output Files ===" -ForegroundColor Cyan
Get-ChildItem $OutputDir -File | ForEach-Object {
    Write-Host "  $($_.Name): $([math]::Round($_.Length / 1KB, 1)) KB"
}

if ($wprStarted -and (Test-Path $etlPath)) {
    Write-Host ""
    Write-Host "For additional WPA analysis:" -ForegroundColor DarkGray
    Write-Host "  wpa.exe `"$etlPath`""
}

# Cleanup temp
Remove-Item $ramfsDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $ramfsImg -ErrorAction SilentlyContinue
