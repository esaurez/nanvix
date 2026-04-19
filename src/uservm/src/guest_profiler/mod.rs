// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//! Host-side guest profiler for Nanvix.
//!
//! Samples guest EIP/EBP at a configurable frequency by canceling the vCPU,
//! reading guest registers, and walking the frame-pointer chain through host
//! memory. After the VM exits, collected samples are resolved against ELF
//! symbol tables and written as folded stacks for flamegraph generation.

mod gva;
pub mod host;
mod samples;
mod symbols;

pub use samples::{
    GuestProfiler,
    StackSample,
};
pub use symbols::SymbolResolver;
