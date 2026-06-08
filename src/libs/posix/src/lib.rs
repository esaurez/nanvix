// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// Configuration
//==================================================================================================

#![deny(clippy::all)]
#![cfg_attr(not(feature = "std"), no_std)]

//==================================================================================================
// Modules
//==================================================================================================

extern crate nvx;

// Force `sys-ffi`'s `#[no_mangle]` kernel-call wrappers into the
// `libposix.a` staticlib so C consumers (cpython's `_nanvixmodule.c`,
// libposix's own C glue, port-library test ELFs) can resolve the
// unmangled `__kcall_*` / `_do_exit_thread` / `__kcall_snapshot` names
// at link time.  Without this `extern crate`, cargo metadata alone is
// not enough to force a leaf crate with no `pub` re-exports to be
// linked into the final staticlib.
extern crate sys_ffi;

extern crate alloc;

#[cfg(feature = "syscall")]
extern crate syslog;

// Address and routing parameter area.
pub mod arpa;

/// Dynamic linking.
pub mod dlfcn;

/// Dummy implementations.
pub mod dummy;

/// System error numbers.
pub mod errno;

/// Virtual environments.
pub mod venv;

/// Definitions for network database operations.
pub mod netdb;

/// Definitions for the poll() function.
pub mod poll;

/// Posix threads.
pub mod pthread;

/// Password structure.
pub mod pwd;

/// File last access and modification times.
pub mod utime;

/// System-specific headers.
pub mod sys;
