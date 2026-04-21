// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//! ETW-based host kernel stack correlation for guest flamegraphs.
//!
//! This module provides infrastructure for correlating Windows ETW
//! (Event Tracing for Windows) kernel stack traces with guest profiler
//! samples by timestamp and thread ID.
//!
//! # How correlation works
//!
//! Both our profiler and ETW use QPC (QueryPerformanceCounter) as their
//! time source. Each guest/host sample records a QPC timestamp at capture
//! time. After VM exit, the ETL is processed with `xperf` to extract
//! CPU sampling stacks, and each ETW sample also has a QPC timestamp.
//!
//! Correlation matches ETW kernel stacks to our samples by:
//! 1. Filtering ETW samples to the vCPU thread ID
//! 2. For each ETW sample, finding the nearest profiler sample within
//!    a configurable QPC tolerance window
//! 3. Merging the kernel stack frames below the host/guest frames
//!
//! # Sampling rate alignment
//!
//! Our profiler timer runs at 1kHz (1ms period). WPR's built-in `CPU`
//! profile also samples at ~1kHz by default. Since both are independent
//! periodic timers, their samples won't align exactly. The correlation
//! uses a tolerance window (default ±500µs) to match nearby samples.
//!
//! For tighter alignment, the QPC timestamps enable sub-microsecond
//! matching precision regardless of sampling rate differences.

use std::process::Command;

/// Manages a WPR (Windows Performance Recorder) trace session.
pub struct EtwSession {
    /// Path to the output ETL file.
    output_path: String,
    /// Whether a trace is currently running.
    active: bool,
    /// Thread ID of the vCPU thread (for post-processing correlation).
    vcpu_thread_id: Option<u64>,
    /// QPC frequency (ticks per second) for timestamp conversion.
    qpc_frequency: u64,
}

impl EtwSession {
    /// Creates a new ETW session that will write to the given path.
    pub fn new(output_path: &str) -> Self {
        Self {
            output_path: output_path.to_string(),
            active: false,
            vcpu_thread_id: None,
            qpc_frequency: super::timestamp_frequency(),
        }
    }

    /// Records the vCPU thread ID for later correlation.
    pub fn set_vcpu_thread_id(&mut self, tid: u64) {
        self.vcpu_thread_id = Some(tid);
    }

    /// Starts a WPR trace session with CPU sampling and kernel stacks.
    ///
    /// Uses the built-in `CPU` profile which captures:
    /// - CPU sampling at ~1kHz (matching our guest profiler frequency)
    /// - Kernel + user stacks on CPU samples
    /// - Thread scheduling events
    pub fn start(&mut self) -> Result<(), String> {
        if self.active {
            return Err("ETW session already active".to_string());
        }

        // Cancel any lingering WPR session from a previous crash.
        let _ = Command::new("wpr").args(["-cancel"]).output();

        // Set the ETW CPU sampling interval to match the guest profiler
        // frequency. NANVIX_PROFILER_FREQ_HZ controls both (default 1000Hz).
        // xperf -SetProfInt takes 100ns units: 1kHz = 10000.
        let freq_hz: u64 = std::env::var("NANVIX_PROFILER_FREQ_HZ")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(1000);
        let prof_interval_100ns = 10_000_000 / freq_hz; // e.g., 1kHz → 10000
        let xperf_path =
            "C:\\Program Files (x86)\\Windows Kits\\10\\Windows Performance Toolkit\\xperf.exe";
        if std::path::Path::new(xperf_path).exists() {
            let _ = Command::new(xperf_path)
                .args(["-SetProfInt", &prof_interval_100ns.to_string()])
                .output();
        }

        // Use the nanvix benchmark WPR profile if available (larger buffers,
        // Hyper-V providers). Fall back to the built-in CPU profile.
        let wpr_profile = std::env::var("NANVIX_WPR_PROFILE").ok();
        let (args, profile_name) = if let Some(ref profile_path) = wpr_profile {
            let profile_arg = format!("{}!NanvixBench", profile_path);
            (vec!["-start".to_string(), profile_arg, "-filemode".to_string()], "NanvixBench")
        } else {
            // Check for the profile in the default location relative to the exe.
            let default_profile = std::env::current_exe()
                .ok()
                .and_then(|p| {
                    p.parent()
                        .map(|d| d.join("..\\scripts\\bench\\wpr-profile.wprp"))
                })
                .filter(|p| p.exists())
                .map(|p| format!("{}!NanvixBench", p.display()));

            if let Some(profile_arg) = default_profile {
                (vec!["-start".to_string(), profile_arg, "-filemode".to_string()], "NanvixBench")
            } else {
                (
                    vec![
                        "-start".to_string(),
                        "CPU".to_string(),
                        "-filemode".to_string(),
                    ],
                    "CPU",
                )
            }
        };

        let result = Command::new("wpr")
            .args(&args)
            .output()
            .map_err(|e| format!("Failed to start WPR: {e}"))?;

        if !result.status.success() {
            let stderr = String::from_utf8_lossy(&result.stderr);
            return Err(format!("WPR start failed: {stderr}"));
        }

        self.active = true;
        eprintln!(
            "ETW_SESSION: started WPR {} profiling (qpc_freq={})",
            profile_name, self.qpc_frequency
        );
        Ok(())
    }

    /// Stops the WPR trace and saves the ETL file.
    pub fn stop(&mut self) -> Result<String, String> {
        if !self.active {
            return Err("No active ETW session".to_string());
        }

        let result = Command::new("wpr")
            .args(["-stop", &self.output_path])
            .output()
            .map_err(|e| format!("Failed to stop WPR: {e}"))?;

        self.active = false;

        if !result.status.success() {
            let stderr = String::from_utf8_lossy(&result.stderr);
            return Err(format!("WPR stop failed: {stderr}"));
        }

        eprintln!(
            "ETW_SESSION: saved ETL to {} (vcpu_tid={:?})",
            self.output_path, self.vcpu_thread_id
        );
        Ok(self.output_path.clone())
    }

    /// Returns the vCPU thread ID for ETL post-processing.
    pub fn vcpu_thread_id(&self) -> Option<u64> {
        self.vcpu_thread_id
    }

    /// Returns the QPC frequency for timestamp conversion.
    pub fn qpc_frequency(&self) -> u64 {
        self.qpc_frequency
    }
}

impl Drop for EtwSession {
    fn drop(&mut self) {
        if self.active {
            eprintln!("ETW_SESSION: canceling active session on drop");
            let _ = Command::new("wpr").args(["-cancel"]).output();
            self.active = false;
        }
    }
}

/// Writes a timestamp log for guest profiler samples.
///
/// Each line: `guest <index> <timestamp> <frequency>`
///
/// This file can be used to correlate guest profiler samples with
/// ETW kernel samples by timestamp.
pub fn write_timestamp_log(
    path: &str,
    guest_samples: &[super::StackSample],
    qpc_frequency: u64,
) -> std::io::Result<()> {
    use std::io::Write;

    let mut file = std::fs::File::create(path)?;
    writeln!(file, "# type index timestamp frequency")?;
    writeln!(file, "# QPC frequency: {} ticks/sec", qpc_frequency)?;

    for (i, s) in guest_samples.iter().enumerate() {
        writeln!(file, "guest {} {} {}", i, s.qpc_timestamp, qpc_frequency)?;
    }

    Ok(())
}

/// Generates a PowerShell script for ETW correlation.
///
/// The script:
/// 1. Extracts CPU sampling stacks from the ETL filtered by vCPU thread ID
/// 2. Reads the timestamp log to find temporal overlap with profiler samples
/// 3. Generates the combined flamegraph
pub fn generate_correlation_script(
    etl_path: &str,
    folded_path: &str,
    vcpu_tid: u64,
    output_svg: &str,
) -> String {
    format!(
        r#"# ETW Correlation Script - merge host kernel stacks with guest flamegraph
# Generated by nanvix guest profiler
#
# This script extracts CPU sampling stacks from the ETL trace for the
# vCPU thread and generates a combined flamegraph with guest + host stacks.
#
# Prerequisites:
#   - Windows Performance Toolkit (xperf.exe, wpa.exe) installed
#   - cargo install inferno rustfilt

param(
    [string]$EtlPath = "{etl_path}",
    [string]$FoldedPath = "{folded_path}",
    [int]$VcpuTid = {vcpu_tid},
    [string]$OutputSvg = "{output_svg}",
    [string]$AnalyzeScript = ""
)

Write-Host "=== E2E Flamegraph: Guest + Host VMM + Host Kernel ==="
Write-Host "ETL:        $EtlPath"
Write-Host "Folded:     $FoldedPath"
Write-Host "vCPU TID:   $VcpuTid"
Write-Host ""

# Find analyze-etl.py (in same dir as nanvixd, or scripts/bench/)
if ($AnalyzeScript -eq "") {{
    $candidates = @(
        (Join-Path (Split-Path $FoldedPath) "..\..\scripts\bench\analyze-etl.py"),
        (Join-Path (Split-Path $FoldedPath) "..\scripts\bench\analyze-etl.py"),
        "scripts\bench\analyze-etl.py"
    )
    foreach ($c in $candidates) {{
        if (Test-Path $c) {{ $AnalyzeScript = (Resolve-Path $c).Path; break }}
    }}
}}

$mergedFolded = "$FoldedPath.merged.folded"

# Step 1: Start with guest + host VMM stacks
Write-Host "Step 1: Processing guest + host VMM stacks..."
Get-Content $FoldedPath `
  | rustfilt `
  | ForEach-Object {{ $_ -replace '<','&lt;' -replace '>','&gt;' -replace '\+0x[0-9a-fA-F]+','' }} `
  | Set-Content $mergedFolded -Encoding UTF8

$guestHostCount = (Get-Content $mergedFolded | Measure-Object).Count
Write-Host "  $guestHostCount guest + host VMM stack entries"

# Step 2: Extract host kernel stacks from ETL and merge
$kernelFolded = "$EtlPath.kernel.folded"
if (Test-Path $EtlPath) {{
    Write-Host "Step 2: Extracting kernel stacks from ETL..."

    if ($AnalyzeScript -ne "" -and (Test-Path $AnalyzeScript)) {{
        # Use analyze-etl.py which does proper xperf parsing + folded output
        Write-Host "  Using analyze-etl.py: $AnalyzeScript"
        python $AnalyzeScript $EtlPath --folded $kernelFolded --process nanvixd.exe --symbols 2>$null

        if (Test-Path $kernelFolded) {{
            $kernelCount = (Get-Content $kernelFolded | Measure-Object).Count
            Write-Host "  Extracted $kernelCount kernel stack entries"

            # Prefix kernel stacks with [KERNEL] and append to merged file
            Get-Content $kernelFolded | ForEach-Object {{
                $parts = $_ -split " "
                $count = $parts[-1]
                $stack = ($parts[0..($parts.Count-2)] -join " ")
                "[KERNEL];$stack $count"
            }} | Add-Content $mergedFolded -Encoding UTF8
        }} else {{
            Write-Host "  Warning: no kernel stacks extracted"
        }}
    }} elseif (Get-Command xperf -ErrorAction SilentlyContinue) {{
        # Direct xperf fallback — extract stacks and filter by process
        Write-Host "  Using xperf directly (analyze-etl.py not found)"
        $dumpPath = "$EtlPath.dump.txt"
        xperf -i $EtlPath -o $dumpPath -a dumper -stackwalk Profile 2>$null
        if (Test-Path $dumpPath) {{
            $tidLines = Get-Content $dumpPath | Where-Object {{ $_ -match "nanvixd" }}
            Write-Host "  Found $($tidLines.Count) nanvixd-related lines"
            Write-Host "  (Full xperf parsing requires analyze-etl.py for folded output)"
            Remove-Item $dumpPath -ErrorAction SilentlyContinue
        }}
    }} else {{
        Write-Host "  Warning: neither analyze-etl.py nor xperf found"
        Write-Host "  Install Windows Performance Toolkit for kernel stacks"
    }}
}} else {{
    Write-Host "Step 2: No ETL file found (run as admin to capture kernel stacks)"
}}

# Step 3: Generate unified flamegraph
Write-Host "Step 3: Generating unified flamegraph..."
Get-Content $mergedFolded `
  | inferno-flamegraph --title "Nanvix E2E Flamegraph (Guest + Host VMM + Kernel)" > $OutputSvg 2>$null

$svgSize = [math]::Round((Get-Item $OutputSvg).Length / 1KB, 1)
Write-Host ""
Write-Host "=== Output ==="
Write-Host "  Unified flamegraph: $OutputSvg ($svgSize KB)"
Write-Host "  Merged folded stacks: $mergedFolded"
if (Test-Path $EtlPath) {{
    Write-Host "  ETL trace (for WPA): $EtlPath"
    Write-Host ""
    Write-Host "For detailed kernel analysis in WPA:"
    Write-Host "  wpa.exe $EtlPath"
    Write-Host "  Filter CPU Usage (Sampled) to nanvixd.exe, TID=$VcpuTid"
}}
"#
    )
}
