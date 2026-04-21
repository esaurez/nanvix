// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//! Guest stack sampling and frame-pointer walking.

use super::gva;
use std::sync::{
    Arc,
    Mutex,
};

/// Returns a high-resolution timestamp for sample correlation.
///
/// On Windows: QPC (QueryPerformanceCounter) — same time source as ETW.
/// On Linux: `clock_gettime(CLOCK_MONOTONIC_RAW)` — same time source as `perf`.
#[inline]
pub fn timestamp_now() -> u64 {
    #[cfg(target_os = "windows")]
    {
        unsafe extern "system" {
            fn QueryPerformanceCounter(counter: *mut i64) -> i32;
        }
        let mut counter: i64 = 0;
        unsafe {
            QueryPerformanceCounter(&mut counter);
        }
        counter as u64
    }
    #[cfg(not(target_os = "windows"))]
    {
        let mut ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        unsafe {
            libc::clock_gettime(libc::CLOCK_MONOTONIC_RAW, &mut ts);
        }
        (ts.tv_sec as u64) * 1_000_000_000 + (ts.tv_nsec as u64)
    }
}

/// Returns the timestamp frequency (ticks per second).
///
/// On Windows: QPC frequency. On Linux: 1_000_000_000 (nanoseconds).
pub fn timestamp_frequency() -> u64 {
    #[cfg(target_os = "windows")]
    {
        unsafe extern "system" {
            fn QueryPerformanceFrequency(freq: *mut i64) -> i32;
        }
        let mut freq: i64 = 0;
        unsafe {
            QueryPerformanceFrequency(&mut freq);
        }
        freq as u64
    }
    #[cfg(not(target_os = "windows"))]
    {
        1_000_000_000 // nanoseconds
    }
}

/// Maximum frame-pointer chain depth per sample.
const MAX_STACK_DEPTH: usize = 128;

/// Kernel/user boundary. Addresses below this are kernel (identity-mapped).
const USER_BASE: u32 = 0x4000_0000;

/// Minimum valid kernel code address.
const KERNEL_CODE_MIN: u32 = 0x0010_0000;
/// Maximum valid kernel code address.
const KERNEL_CODE_MAX: u32 = 0x0040_0000;
/// Minimum valid user code address.
const USER_CODE_MIN: u32 = 0x4000_0000;
/// Maximum valid user code address (python.elf .text ends at ~0x40822000).
const USER_CODE_MAX: u32 = 0x4100_0000;
/// Minimum valid stack address (must be above page 0).
const STACK_ADDR_MIN: u32 = 0x0001_0000;

/// Returns true if the address looks like valid kernel or user code.
fn is_valid_code_addr(addr: u32) -> bool {
    (addr >= KERNEL_CODE_MIN && addr < KERNEL_CODE_MAX)
        || (addr >= USER_CODE_MIN && addr < USER_CODE_MAX)
}

/// Returns true if the address looks like a valid stack frame pointer.
fn is_valid_stack_addr(ebp: u32) -> bool {
    ebp >= STACK_ADDR_MIN && ebp != 0xFFFF_FFFF && (ebp & 3) == 0
}

/// A single stack sample captured from the guest.
#[derive(Clone)]
pub struct StackSample {
    /// Return addresses from the frame-pointer chain (deepest first).
    pub addresses: Vec<u32>,
    /// QPC timestamp when the sample was captured (for ETW correlation).
    pub qpc_timestamp: u64,
}

/// Collects guest stack samples from the host side.
///
/// Thread-safe: the sampling thread pushes samples, the main thread
/// reads them after VM exit.
pub struct GuestProfiler {
    samples: Arc<Mutex<Vec<StackSample>>>,
}

impl GuestProfiler {
    /// Creates a new profiler with pre-allocated sample storage.
    pub fn new(expected_samples: usize) -> Self {
        Self {
            samples: Arc::new(Mutex::new(Vec::with_capacity(expected_samples))),
        }
    }

    /// Returns a clone of the inner Arc for use by the sampling thread.
    pub fn handle(&self) -> Arc<Mutex<Vec<StackSample>>> {
        self.samples.clone()
    }

    /// Captures one stack sample from the guest.
    ///
    /// # Safety requirements
    ///
    /// The caller must ensure the guest vCPU is stopped (not executing) when
    /// this function is called, so that guest memory (page tables, stack
    /// frames) is stable and will not be concurrently modified.
    ///
    /// # Parameters
    ///
    /// - `vmem_ptr`: Host pointer to guest physical memory.
    /// - `vmem_size`: Total guest physical memory size.
    /// - `eip`: Guest instruction pointer.
    /// - `ebp`: Guest base pointer (frame pointer).
    /// - `cr3`: Guest CR3 (page directory physical address).
    pub fn capture_sample(
        samples: &Mutex<Vec<StackSample>>,
        vmem_ptr: *const u8,
        vmem_size: usize,
        eip: u32,
        ebp: u32,
        cr3: u32,
    ) {
        let mut addrs = Vec::with_capacity(MAX_STACK_DEPTH);

        // Only record if EIP looks like a valid code address.
        // Kernel code: 0x00100000..0x00400000
        // User code:   0x40000000..0xF0000000
        if !is_valid_code_addr(eip) {
            return;
        }

        addrs.push(eip);

        let mut current_ebp = ebp;
        for _ in 0..MAX_STACK_DEPTH {
            // EBP must be 4-byte aligned and in a valid range.
            if !is_valid_stack_addr(current_ebp) {
                break;
            }

            // Translate EBP to GPA.
            let gpa = if current_ebp < USER_BASE {
                // Kernel: identity-mapped.
                current_ebp
            } else {
                // User space: walk guest page tables.
                match gva::translate_gva(vmem_ptr, vmem_size, cr3, current_ebp) {
                    Some(gpa) => gpa,
                    None => break,
                }
            };

            // Read saved EBP and return address.
            let saved_ebp = match gva::read_gpa_u32(vmem_ptr, vmem_size, gpa) {
                Some(v) => v,
                None => break,
            };
            let return_addr = match gva::read_gpa_u32(vmem_ptr, vmem_size, gpa + 4) {
                Some(v) => v,
                None => break,
            };

            if return_addr == 0 || !is_valid_code_addr(return_addr) {
                break;
            }

            addrs.push(return_addr);

            // EBP should move up the stack (higher addresses) and remain valid.
            if saved_ebp != 0 && (!is_valid_stack_addr(saved_ebp) || saved_ebp <= current_ebp) {
                break;
            }
            current_ebp = saved_ebp;
        }

        if addrs.len() >= 1 {
            if let Ok(mut s) = samples.lock() {
                s.push(StackSample {
                    addresses: addrs,
                    qpc_timestamp: timestamp_now(),
                });
            }
        }
    }

    /// Returns all collected samples and clears the buffer.
    pub fn drain_samples(&self) -> Vec<StackSample> {
        if let Ok(mut s) = self.samples.lock() {
            std::mem::take(&mut *s)
        } else {
            Vec::new()
        }
    }

    /// Writes samples as folded stacks to a file.
    ///
    /// Each line: `func1;func2;func3 count`
    pub fn write_folded<R: Fn(u32) -> String>(
        &self,
        path: &str,
        resolve: R,
    ) -> std::io::Result<()> {
        use std::{
            collections::HashMap,
            io::Write,
        };

        let samples = self.drain_samples();
        let mut folded: HashMap<String, u64> = HashMap::new();

        for sample in &samples {
            // Build the stack string (deepest frame first → reverse for flamegraph).
            let stack: String = sample
                .addresses
                .iter()
                .rev()
                .map(|&addr| resolve(addr))
                .collect::<Vec<_>>()
                .join(";");

            *folded.entry(stack).or_insert(0) += 1;
        }

        let mut file = std::fs::File::create(path)?;
        let mut entries: Vec<_> = folded.into_iter().collect();
        entries.sort_by(|a, b| b.1.cmp(&a.1));
        for (stack, count) in entries {
            writeln!(file, "{} {}", stack, count)?;
        }

        Ok(())
    }
}
