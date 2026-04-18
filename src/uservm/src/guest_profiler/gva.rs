// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//! Guest virtual address translation via manual page-table walk.
//!
//! Nanvix is a 32-bit x86 OS using two-level paging (PD + PT).
//! The host can read guest physical memory directly through the
//! mapped vmem buffer, so no WHP API call is needed.

/// Number of entries per page table / page directory.
#[allow(dead_code)]
const ENTRIES_PER_TABLE: usize = 1024;
/// Mask for the page offset within a 4 KiB page.
const PAGE_OFFSET_MASK: u32 = 0xFFF;
/// Mask for extracting the physical frame address from a PDE/PTE.
const FRAME_MASK: u32 = 0xFFFF_F000;
/// Present bit in PDE/PTE.
const PRESENT_BIT: u32 = 1;

/// Translates a guest virtual address to a guest physical address
/// by walking the guest's two-level page tables.
///
/// # Parameters
///
/// - `vmem_ptr`: Host pointer to the start of guest physical memory.
/// - `vmem_size`: Total size of guest physical memory in bytes.
/// - `cr3`: Guest CR3 register value (physical address of the page directory).
/// - `gva`: Guest virtual address to translate.
///
/// # Returns
///
/// `Some(gpa)` if the translation succeeds, `None` if any entry is not present
/// or the address is out of bounds.
pub fn translate_gva(vmem_ptr: *const u8, vmem_size: usize, cr3: u32, gva: u32) -> Option<u32> {
    let pd_base = (cr3 & FRAME_MASK) as usize;
    let pd_index = ((gva >> 22) & 0x3FF) as usize;
    let pt_index = ((gva >> 12) & 0x3FF) as usize;
    let offset = gva & PAGE_OFFSET_MASK;

    // Read PDE.
    let pde_addr = pd_base + pd_index * 4;
    if pde_addr + 4 > vmem_size {
        return None;
    }
    let pde = unsafe { (vmem_ptr.add(pde_addr) as *const u32).read_unaligned() };
    if pde & PRESENT_BIT == 0 {
        return None;
    }

    // Check for 4 MiB large page (PS bit = bit 7).
    if pde & (1 << 7) != 0 {
        let frame = (pde & 0xFFC0_0000) as u32;
        let large_offset = gva & 0x003F_FFFF;
        return Some(frame | large_offset);
    }

    // Read PTE from the page table.
    let pt_base = (pde & FRAME_MASK) as usize;
    let pte_addr = pt_base + pt_index * 4;
    if pte_addr + 4 > vmem_size {
        return None;
    }
    let pte = unsafe { (vmem_ptr.add(pte_addr) as *const u32).read_unaligned() };
    if pte & PRESENT_BIT == 0 {
        return None;
    }

    let frame = pte & FRAME_MASK;
    Some(frame | offset)
}

/// Reads a u32 from guest physical memory.
///
/// Returns `None` if the address is out of bounds.
#[inline]
pub fn read_gpa_u32(vmem_ptr: *const u8, vmem_size: usize, gpa: u32) -> Option<u32> {
    let addr = gpa as usize;
    if addr + 4 > vmem_size {
        return None;
    }
    Some(unsafe { (vmem_ptr.add(addr) as *const u32).read_unaligned() })
}
