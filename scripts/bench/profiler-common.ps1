<#
.SYNOPSIS
    Shared helper functions for Nanvix profiling scripts.

.DESCRIPTION
    Provides common utilities used by full-flamegraph.ps1 and
    guest-flamegraph.ps1: admin detection, ramfs building, nanvixd
    execution with profiler env vars, and flamegraph post-processing.

    Dot-source this file from profiling scripts:
        . "$PSScriptRoot\profiler-common.ps1"
#>

# ── Default Python workload ─────────────────────────────────────────────────

function Get-DefaultProfileScript {
    @"
import math
for i in range(200):
    result = sum(math.factorial(j) for j in range(200))
    print(f'iter {i}: {len(str(result))} digits')
print('Done')
"@
}

# ── Admin check ──────────────────────────────────────────────────────────────

function Test-AdminPrivilege {
    ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ── Build ramfs image ────────────────────────────────────────────────────────

function Build-ProfileRamfs {
    <#
    .SYNOPSIS
        Builds a ramfs image containing the guest ELF and a Python script.
    .OUTPUTS
        Hashtable with RamfsImg and CleanupPath (directory to remove later).
    #>
    param(
        [Parameter(Mandatory)][string]$MkramfsExe,
        [Parameter(Mandatory)][string]$GuestElf,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$OutputDir
    )

    $ramfsDir = Join-Path $OutputDir "ramfs-content"
    New-Item -ItemType Directory -Path $ramfsDir -Force | Out-Null
    Copy-Item $GuestElf (Join-Path $ramfsDir (Split-Path $GuestElf -Leaf)) -Force
    $Script | Set-Content (Join-Path $ramfsDir "script.py") -Encoding UTF8

    $ramfsImg = Join-Path $OutputDir "test.img"
    & $MkramfsExe -o $ramfsImg $ramfsDir 2>&1 | Out-Null

    @{
        RamfsImg    = $ramfsImg
        CleanupPath = $ramfsDir
    }
}

# ── Run nanvixd with profiler ────────────────────────────────────────────────

function Invoke-Nanvixd {
    <#
    .SYNOPSIS
        Runs nanvixd with guest profiling enabled and captures output.
    .DESCRIPTION
        Sets NANVIX_KERNEL_SYMBOLS, NANVIX_USER_SYMBOLS, and
        NANVIX_GUEST_PROFILE_PATH env vars, then launches nanvixd as a
        child process with redirected I/O. Returns stdout, stderr, and
        the profiler-relevant stderr lines.
    .OUTPUTS
        Hashtable with Stdout, Stderr, ProfilerLines keys.
    #>
    param(
        [Parameter(Mandatory)][string]$NanvixdExe,
        [Parameter(Mandatory)][string]$BinDir,
        [Parameter(Mandatory)][string]$RamfsImg,
        [Parameter(Mandatory)][string]$GuestElf,
        [Parameter(Mandatory)][string]$GuestFoldedPath,
        [string]$KernelSymbols = "",
        [string]$UserSymbols = "",
        [int]$TimeoutMs = 600000
    )

    # Set profiler env vars.
    $env:NANVIX_GUEST_PROFILE_PATH = $GuestFoldedPath
    if ($KernelSymbols -ne "") { $env:NANVIX_KERNEL_SYMBOLS = $KernelSymbols }
    if ($UserSymbols -ne "")   { $env:NANVIX_USER_SYMBOLS   = $UserSymbols }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $NanvixdExe
    $psi.Arguments = "-bin-dir `"$BinDir`" -ramfs `"$RamfsImg`" -- `"$GuestElf`" `"-B /script.py`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit($TimeoutMs)

    if (-not $exited) {
        Write-Host "WARNING: nanvixd did not exit within timeout, killing..." -ForegroundColor Red
        $proc.Kill()
        $proc.WaitForExit(5000) | Out-Null
    }

    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))

    $stderrText = $stderrTask.Result
    $profilerLines = ($stderrText -split "`n") |
        Where-Object { $_ -match "GUEST_PROFILE|PROFILER|ETW_SESSION|PERF_SESSION" }

    @{
        Stdout        = $stdoutTask.Result
        Stderr        = $stderrText
        ProfilerLines = $profilerLines
    }
}

# ── Demangle and sanitize folded stacks ──────────────────────────────────────

function Format-FoldedStacks {
    <#
    .SYNOPSIS
        Pipes folded stacks through rustfilt (demangle) and sanitizes
        angle brackets / hex offsets for flamegraph compatibility.
    .OUTPUTS
        Array of cleaned folded stack lines.
    #>
    param(
        [Parameter(Mandatory)][string]$FoldedPath
    )

    Get-Content $FoldedPath |
        rustfilt |
        ForEach-Object {
            $_ -replace '<',' ' -replace '>',' ' -replace '\+0x[0-9a-fA-F]+',''
        }
}

# ── Print results summary ────────────────────────────────────────────────────

function Write-ProfileSummary {
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [string]$SvgPath = ""
    )

    Write-Host ""
    Write-Host ([char]0x2554 + ([string][char]0x2550) * 62 + [char]0x2557) -ForegroundColor Cyan
    Write-Host ("$([char]0x2551)                        Results                             $([char]0x2551)") -ForegroundColor Cyan
    Write-Host ([char]0x255A + ([string][char]0x2550) * 62 + [char]0x255D) -ForegroundColor Cyan
    Write-Host ""

    Get-ChildItem $OutputDir -File |
        Where-Object { $_.Extension -in '.svg','.folded','.txt','.etl','.img' } |
        ForEach-Object {
            $size = if ($_.Length -gt 1MB) { "$([math]::Round($_.Length / 1MB, 1)) MB" }
                    else { "$([math]::Round($_.Length / 1KB, 1)) KB" }
            Write-Host "  $($_.Name): $size"
        }

    if ($SvgPath -ne "" -and (Test-Path $SvgPath)) {
        Write-Host ""
        Write-Host "  Flamegraph: $SvgPath" -ForegroundColor Green
    }
}
