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
    [string]$NanvixDir = "D:\src\nanvix",
    [string]$GuestElf = "D:\src\cpython\python.elf",
    [string]$KernelSymbols = "D:\src\nanvix\bin\kernel.elf.sym",
    [string]$UserSymbols = "D:\src\cpython\python.elf.sym",
    [string]$Script = "",
    [string]$OutputDir = "D:\src\profiling-output",
    [string]$RamfsImg = ""
)

$ErrorActionPreference = "Stop"

# ── Check admin ──────────────────────────────────────────────────────────────
# WPR (started by nanvixd) requires admin for kernel stacks.
# Without admin, guest + host VMM profiling still works.

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "WARNING: Not running as admin. ETW kernel stacks will be unavailable." -ForegroundColor DarkYellow
    Write-Host "  Run as admin for full E2E including vid.sys/ntoskrnl stacks." -ForegroundColor DarkYellow
    Write-Host ""
}

# ── Paths ────────────────────────────────────────────────────────────────────

$nanvixd    = Join-Path $NanvixDir "bin\nanvixd.exe"
$mkramfs    = Join-Path $NanvixDir "bin\mkramfs.exe"
$analyzeEtl = Join-Path $NanvixDir "scripts\bench\analyze-etl.py"

if ($WprProfile -eq "") {
    $WprProfile = Join-Path $NanvixDir "scripts\bench\wpr-profile.wprp"
}

foreach ($tool in @($nanvixd, $mkramfs)) {
    if (-not (Test-Path $tool)) {
        Write-Host "ERROR: $tool not found. Run 'z build --profile --release' first." -ForegroundColor Red
        exit 1
    }
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$etlPath        = Join-Path $OutputDir "trace.etl"
$kernelFolded   = Join-Path $OutputDir "kernel.folded"
$mergedFolded   = Join-Path $OutputDir "merged.folded"
$svgPath        = Join-Path $OutputDir "flamegraph.svg"
$stderrPath     = Join-Path $OutputDir "nanvixd-stderr.txt"
# guest.folded path: detected from nanvixd stderr (compiled into the binary).
$guestFolded    = Join-Path $OutputDir "guest.folded"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Nanvix Full E2E Flamegraph (Guest + VMM + Kernel)      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Build ramfs ──────────────────────────────────────────────────────────────

$cleanupRamfs = $false
if ($RamfsImg -eq "" -or -not (Test-Path $RamfsImg)) {
    Write-Host "[SETUP] Building ramfs..." -ForegroundColor Yellow
    $ramfsDir = Join-Path $OutputDir "ramfs-content"
    New-Item -ItemType Directory -Path $ramfsDir -Force | Out-Null
    Copy-Item $GuestElf (Join-Path $ramfsDir (Split-Path $GuestElf -Leaf)) -Force

    if ($Script -eq "") {
        $Script = @"
import math
for i in range(200):
    result = sum(math.factorial(j) for j in range(200))
    print(f'iter {i}: {len(str(result))} digits')
print('Done')
"@
    }
    $Script | Set-Content (Join-Path $ramfsDir "script.py") -Encoding UTF8

    $RamfsImg = Join-Path $OutputDir "test.img"
    & $mkramfs -o $RamfsImg $ramfsDir 2>&1 | Out-Null
    $cleanupRamfs = $true
    Write-Host "  Ramfs: $RamfsImg" -ForegroundColor DarkGray
}

# ── Run nanvixd (all 3 layers) ───────────────────────────────────────────────
# nanvixd handles everything: guest profiling (Layer 1), host VMM sampling
# (Layer 2), and WPR/ETW start+stop (Layer 3, requires admin).

Write-Host "[RUN] Running nanvixd with profiling..." -ForegroundColor Yellow

$env:NANVIX_KERNEL_SYMBOLS = $KernelSymbols
$env:NANVIX_USER_SYMBOLS = $UserSymbols
$env:NANVIX_GUEST_PROFILE = $guestFolded

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $nanvixd
$psi.Arguments = "-bin-dir `"$(Join-Path $NanvixDir 'bin')`" -ramfs `"$RamfsImg`" -- `"$GuestElf`" `"-B /script.py`""
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false

$proc = [System.Diagnostics.Process]::Start($psi)
$proc.StandardInput.Close()

$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()
$proc.WaitForExit(600000) | Out-Null

[System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))

$stderrText = $stderrTask.Result
$stderrText | Set-Content $stderrPath -Encoding UTF8

# Show guest output (last few lines)
$stdoutLines = ($stdoutTask.Result -split "`n" | Where-Object { $_.Trim() -ne "" })
if ($stdoutLines.Count -gt 5) {
    Write-Host "  ... ($($stdoutLines.Count) lines of output)" -ForegroundColor DarkGray
    $stdoutLines | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
} else {
    $stdoutLines | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

# Extract profiler stats from stderr
$stderrLines = $stderrText -split "`n"
$stderrLines | Where-Object { $_ -match "GUEST_PROFILE|PROFILER|ETW_SESSION" } | ForEach-Object {
    Write-Host "  $($_.Trim())" -ForegroundColor DarkGray
}

if (-not (Test-Path $guestFolded)) {
    Write-Host "  WARNING: no guest folded stacks at $guestFolded" -ForegroundColor Red
    Write-Host "  Ensure nanvixd was built with: z build --profile --release" -ForegroundColor Red
}

# Find the ETL that nanvixd produced (at <folded_path>.etl)
$etlPath = "$guestFolded.etl"
if (Test-Path $etlPath) {
    $etlSize = [math]::Round((Get-Item $etlPath).Length / 1MB, 1)
    Write-Host "  ETL: $etlPath ($etlSize MB)" -ForegroundColor Green
} else {
    Write-Host "  No ETL (run as admin for kernel stacks)" -ForegroundColor DarkYellow
}

# ── Merge: Extract kernel stacks and build unified flamegraph ─────────────────

Write-Host "[MERGE] Building unified flamegraph..." -ForegroundColor Yellow

# Set up symbol resolution for xperf.
# Include the nanvixd bin directory so xperf can find nanvixd.pdb.
$binDir = Join-Path $NanvixDir "bin"
if ($env:_NT_SYMBOL_PATH) {
    # Prepend bin dir if not already included
    if ($env:_NT_SYMBOL_PATH -notmatch [regex]::Escape($binDir)) {
        $env:_NT_SYMBOL_PATH = "$binDir;$($env:_NT_SYMBOL_PATH)"
    }
} else {
    $env:_NT_SYMBOL_PATH = "$binDir;srv*C:\Symbols*https://msdl.microsoft.com/download/symbols"
}
if (-not $env:_NT_SYMCACHE_PATH) {
    $env:_NT_SYMCACHE_PATH = "C:\SymCache"
}

# Step 1: Guest stacks — prefix with [GUEST] root.
# Exclude [HOST:*] cooperative stacks (unresolved addresses; ETW covers this).
if (Test-Path $guestFolded) {
    Get-Content $guestFolded |
        Where-Object { $_ -notmatch '^\[HOST' -and $_.Trim() -ne '' } |
        rustfilt |
        ForEach-Object { $_ -replace '<','&lt;' -replace '>','&gt;' -replace '\+0x[0-9a-fA-F]+','' } |
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
    Write-Host "  WARNING: No guest folded stacks found" -ForegroundColor Red
    "" | Set-Content $mergedFolded -Encoding UTF8
}

# Step 2: Host stacks from ETL — prefix with [HOST] root.
# Includes nanvixd VMM code + OS kernel (vid.sys, ntoskrnl).
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
} elseif (Test-Path $etlPath) {
    Write-Host "  analyze-etl.py not found at $analyzeEtl" -ForegroundColor DarkYellow
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

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                        Results                             ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Get-ChildItem $OutputDir -File | Sort-Object Name | ForEach-Object {
    $size = if ($_.Length -gt 1MB) { "$([math]::Round($_.Length / 1MB, 1)) MB" }
            else { "$([math]::Round($_.Length / 1KB, 1)) KB" }
    Write-Host "  $($_.Name): $size"
}

Write-Host ""
if (Test-Path $svgPath) {
    $svgSize = [math]::Round((Get-Item $svgPath).Length / 1KB, 1)
    Write-Host "  Flamegraph: $svgPath ($svgSize KB)" -ForegroundColor Green
    Write-Host "  Total merged stacks: $totalCount" -ForegroundColor Green
}
if (Test-Path $etlPath) {
    Write-Host ""
    Write-Host "  For detailed WPA analysis:" -ForegroundColor DarkGray
    Write-Host "    wpa.exe `"$etlPath`"" -ForegroundColor DarkGray
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

if ($cleanupRamfs) {
    Remove-Item (Join-Path $OutputDir "ramfs-content") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $OutputDir "test.img") -ErrorAction SilentlyContinue
}
