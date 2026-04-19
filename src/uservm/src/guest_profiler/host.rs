// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//! Host-side (VMM) stack sampling via cooperative self-capture.
//!
//! When the profiler timer fires while the vCPU thread is NOT inside
//! `WHvRunVirtualProcessor` (i.e., handling a VM exit), the vCPU thread
//! cooperatively captures its own stack using `RtlCaptureStackBackTrace`.
//! This avoids the complexity and risk of cross-thread stack unwinding.

use std::sync::{
    Arc,
    Mutex,
    atomic::{
        AtomicBool,
        Ordering,
    },
};

/// A host-side stack sample captured from the VMM thread.
#[derive(Clone)]
pub struct HostStackSample {
    /// Return addresses from the host call stack (caller first).
    pub addresses: Vec<u64>,
    /// What the VMM was doing when sampled (e.g., "exit_handling").
    pub context: &'static str,
}

/// Maximum frames to capture per host stack sample.
const MAX_HOST_FRAMES: usize = 64;

/// Captures the current thread's call stack using `RtlCaptureStackBackTrace`.
///
/// Returns a vector of return addresses (most recent frame first).
pub fn capture_host_stack() -> Vec<u64> {
    // RtlCaptureStackBackTrace from ntdll.dll — always available on Windows.
    unsafe extern "system" {
        fn RtlCaptureStackBackTrace(
            frames_to_skip: u32,
            frames_to_capture: u32,
            back_trace: *mut *mut std::ffi::c_void,
            back_trace_hash: *mut u32,
        ) -> u16;
    }

    let mut frames: Vec<*mut std::ffi::c_void> = vec![std::ptr::null_mut(); MAX_HOST_FRAMES];
    let captured = unsafe {
        RtlCaptureStackBackTrace(
            1, // skip this function
            frames.len() as u32,
            frames.as_mut_ptr(),
            std::ptr::null_mut(),
        )
    };
    frames
        .iter()
        .take(captured as usize)
        .map(|p| *p as u64)
        .collect()
}

/// Collects host stack samples from the VMM thread.
pub struct HostProfiler {
    samples: Arc<Mutex<Vec<HostStackSample>>>,
    /// Set by the timer thread to signal a sample request. Checked and
    /// cleared by the vCPU thread before entering WHvRunVirtualProcessor.
    sample_pending: Arc<AtomicBool>,
}

impl HostProfiler {
    /// Creates a new host profiler.
    pub fn new(expected_samples: usize) -> Self {
        Self {
            samples: Arc::new(Mutex::new(Vec::with_capacity(expected_samples))),
            sample_pending: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Returns an `Arc<AtomicBool>` that the timer thread should set to
    /// `true` each time it fires. The vCPU thread checks and clears it.
    pub fn pending_flag(&self) -> Arc<AtomicBool> {
        self.sample_pending.clone()
    }

    /// Checks and clears the pending sample flag.
    ///
    /// Returns `true` if a sample was pending (timer fired while we were
    /// in exit handling, not inside WHvRunVirtualProcessor).
    #[inline]
    pub fn consume_pending(&self) -> bool {
        self.sample_pending.swap(false, Ordering::Acquire)
    }

    /// Returns a shared handle to the samples buffer for reading after VM exit.
    pub fn samples_handle(&self) -> Arc<Mutex<Vec<HostStackSample>>> {
        self.samples.clone()
    }

    /// Captures a host stack sample at the current point.
    ///
    /// Called by the vCPU run loop when it detects the profiler timer
    /// fired during exit handling (fast-interrupted detection).
    #[inline]
    pub fn capture(&self, context: &'static str) {
        let addresses = capture_host_stack();
        if !addresses.is_empty() {
            if let Ok(mut s) = self.samples.lock() {
                s.push(HostStackSample { addresses, context });
            }
        }
    }
}

/// Writes host samples from a shared samples buffer as folded stacks.
///
/// Appends to the file at `path`. Host addresses are output as hex
/// (host-side PDB symbol resolution is not yet implemented).
pub fn write_host_folded_from_samples(
    samples: &Arc<Mutex<Vec<HostStackSample>>>,
    path: &str,
) -> std::io::Result<()> {
    use std::{
        collections::HashMap,
        io::Write,
    };

    let samples = match samples.lock() {
        Ok(s) => s.clone(),
        Err(_) => return Ok(()),
    };
    if samples.is_empty() {
        return Ok(());
    }

    let mut folded: HashMap<String, u64> = HashMap::new();

    for sample in &samples {
        let mut parts: Vec<String> = vec![format!("[HOST:{}]", sample.context)];
        for &addr in sample.addresses.iter().rev() {
            parts.push(format!("{:#018x}", addr));
        }
        let stack = parts.join(";");
        *folded.entry(stack).or_insert(0) += 1;
    }

    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;

    let mut entries: Vec<_> = folded.into_iter().collect();
    entries.sort_by(|a, b| b.1.cmp(&a.1));
    for (stack, count) in entries {
        writeln!(file, "{} {}", stack, count)?;
    }

    Ok(())
}
