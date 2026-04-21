// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//! `perf`-based host kernel stack correlation for guest flamegraphs (Linux).
//!
//! This is the Linux equivalent of the Windows ETW module (`etw.rs`).
//! It uses `perf record` to capture CPU sampling with kernel stacks,
//! then correlates with our profiler samples using monotonic timestamps.
//!
//! # How it works
//!
//! 1. **Before VM run**: Start `perf record` with CPU sampling and
//!    kernel+user stacks on the vCPU thread.
//! 2. **During VM run**: Our profiler records `CLOCK_MONOTONIC_RAW`
//!    timestamps (same clock `perf` uses). `perf record` runs concurrently.
//! 3. **After VM exit**: Stop `perf record`, convert to folded stacks
//!    with `perf script | stackcollapse-perf.pl`, filter by vCPU TID.
//!
//! # Sampling rate alignment
//!
//! Both our profiler and `perf record` sample at ~1kHz. Since they use
//! the same monotonic clock, timestamps can be matched directly.

use std::process::{
    Child,
    Command,
    Stdio,
};

/// Manages a `perf record` session for kernel stack sampling.
pub struct PerfSession {
    /// Path to the output perf.data file.
    output_path: String,
    /// Running `perf record` child process.
    child: Option<Child>,
    /// Thread ID of the vCPU thread.
    vcpu_thread_id: Option<u64>,
    /// PID of the nanvixd process (for filtering).
    pid: u32,
}

impl PerfSession {
    /// Creates a new perf session that will write to the given path.
    pub fn new(output_path: &str) -> Self {
        Self {
            output_path: output_path.to_string(),
            child: None,
            vcpu_thread_id: None,
            pid: std::process::id(),
        }
    }

    /// Records the vCPU thread ID for post-processing correlation.
    pub fn set_vcpu_thread_id(&mut self, tid: u64) {
        self.vcpu_thread_id = Some(tid);
    }

    /// Starts `perf record` with CPU sampling and kernel stacks.
    ///
    /// Records at 999Hz (just under 1kHz to avoid aliasing with our
    /// 1kHz timer) with call-graph capture via frame pointers.
    pub fn start(&mut self) -> Result<(), String> {
        if self.child.is_some() {
            return Err("perf session already active".to_string());
        }

        let child = Command::new("perf")
            .args([
                "record",
                "-F",
                "999", // ~1kHz sampling
                "-g",  // capture call graphs
                "--call-graph",
                "fp", // use frame pointers (matches our profiler)
                "-p",
                &self.pid.to_string(),
                "-o",
                &self.output_path,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to start perf record: {e}"))?;

        self.child = Some(child);
        eprintln!(
            "PERF_SESSION: started perf record -F 999 -g -p {} -o {}",
            self.pid, self.output_path
        );
        Ok(())
    }

    /// Stops the `perf record` session by sending SIGINT.
    pub fn stop(&mut self) -> Result<String, String> {
        let child = self
            .child
            .take()
            .ok_or_else(|| "No active perf session".to_string())?;

        // Send SIGINT to perf to gracefully stop recording.
        let pid = child.id();
        let kill_ret = unsafe { libc::kill(pid as i32, libc::SIGINT) };
        if kill_ret != 0 {
            return Err(format!(
                "Failed to send SIGINT to perf (pid {}, errno {})",
                pid,
                std::io::Error::last_os_error()
            ));
        }

        // Wait for perf to finish writing.
        let output = child
            .wait_with_output()
            .map_err(|e| format!("Failed to wait for perf: {e}"))?;

        if !output.status.success() && output.status.code() != Some(0) {
            // perf returns non-zero on SIGINT but that's expected
            let code = output.status.code().unwrap_or(-1);
            if code != 2 && code != -1 {
                // code 2 = interrupted, -1 = signal
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(format!("perf record failed (code {code}): {stderr}"));
            }
        }

        eprintln!(
            "PERF_SESSION: saved perf data to {} (vcpu_tid={:?})",
            self.output_path, self.vcpu_thread_id
        );
        Ok(self.output_path.clone())
    }

    /// Returns the vCPU thread ID for post-processing.
    pub fn vcpu_thread_id(&self) -> Option<u64> {
        self.vcpu_thread_id
    }

    /// Returns the timestamp frequency (nanoseconds for CLOCK_MONOTONIC_RAW).
    pub fn timestamp_frequency(&self) -> u64 {
        1_000_000_000
    }
}

impl Drop for PerfSession {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            eprintln!("PERF_SESSION: killing active session on drop");
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Writes a timestamp log for guest profiler samples.
pub fn write_timestamp_log(
    path: &str,
    guest_samples: &[super::StackSample],
    ts_frequency: u64,
) -> std::io::Result<()> {
    use std::io::Write;

    let mut file = std::fs::File::create(path)?;
    writeln!(file, "# type index timestamp frequency")?;
    writeln!(file, "# Timestamp source: CLOCK_MONOTONIC_RAW ({} ticks/sec)", ts_frequency)?;

    for (i, s) in guest_samples.iter().enumerate() {
        writeln!(file, "guest {} {} {}", i, s.qpc_timestamp, ts_frequency)?;
    }

    Ok(())
}

/// Generates a shell script for post-processing the perf data.
pub fn generate_correlation_script(
    perf_data_path: &str,
    folded_path: &str,
    vcpu_tid: u64,
    output_svg: &str,
) -> String {
    format!(
        r#"#!/bin/bash
# Perf Correlation Script - merge host kernel stacks with guest flamegraph
# Generated by nanvix guest profiler

PERF_DATA="{perf_data_path}"
FOLDED_PATH="{folded_path}"
VCPU_TID={vcpu_tid}
OUTPUT_SVG="{output_svg}"

echo "=== Perf Correlation ==="
echo "perf.data:  $PERF_DATA"
echo "Folded:     $FOLDED_PATH"
echo "vCPU TID:   $VCPU_TID"
echo ""

# Step 1: Convert perf data to folded stacks, filtered by vCPU TID
echo "Step 1: Extracting kernel stacks for TID $VCPU_TID..."
KERNEL_FOLDED="${{PERF_DATA}}.kernel.folded"
if command -v perf &>/dev/null; then
    perf script -i "$PERF_DATA" --tid "$VCPU_TID" 2>/dev/null | \
        stackcollapse-perf.pl 2>/dev/null > "$KERNEL_FOLDED"
    KERNEL_COUNT=$(wc -l < "$KERNEL_FOLDED")
    echo "  Extracted $KERNEL_COUNT kernel stack entries"
else
    echo "  Warning: perf not found"
    KERNEL_COUNT=0
fi

# Step 2: Merge guest + host VMM + kernel stacks
echo "Step 2: Merging stacks..."
MERGED="${{FOLDED_PATH}}.merged.folded"
cat "$FOLDED_PATH" > "$MERGED"
if [ "$KERNEL_COUNT" -gt 0 ]; then
    # Prefix kernel stacks with [KERNEL] marker
    sed 's/^/[KERNEL];/' "$KERNEL_FOLDED" >> "$MERGED"
fi

# Step 3: Generate flamegraph
echo "Step 3: Generating flamegraph..."
if command -v inferno-flamegraph &>/dev/null; then
    cat "$MERGED" | inferno-flamegraph --title "Nanvix E2E Flamegraph" > "$OUTPUT_SVG"
    echo "Flamegraph: $OUTPUT_SVG"
elif command -v flamegraph.pl &>/dev/null; then
    cat "$MERGED" | flamegraph.pl > "$OUTPUT_SVG"
    echo "Flamegraph: $OUTPUT_SVG"
else
    echo "Warning: neither inferno-flamegraph nor flamegraph.pl found"
    echo "Install with: cargo install inferno"
fi

echo ""
echo "Timestamps for correlation: ${{FOLDED_PATH}}.timestamps.log"
"#
    )
}
