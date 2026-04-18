// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//! ELF symbol table parser for address-to-function-name resolution.

use std::path::Path;

/// A resolved symbol: function name + base address.
struct Symbol {
    addr: u32,
    size: u32,
    name: String,
}

/// Resolves guest addresses to function names using ELF symbol tables.
pub struct SymbolResolver {
    symbols: Vec<Symbol>,
}

impl SymbolResolver {
    /// Creates a resolver from one or more ELF files.
    ///
    /// Parses the `.symtab` section of each ELF to extract function symbols.
    /// Files that can't be parsed are silently skipped.
    pub fn from_elf_files(paths: &[&Path]) -> Self {
        let mut symbols = Vec::new();

        for path in paths {
            match std::fs::read(path) {
                Ok(data) => {
                    let before = symbols.len();
                    Self::parse_elf32_symbols(&data, &mut symbols);
                    let added = symbols.len() - before;
                    eprintln!(
                        "GUEST_PROFILE_SYMBOLS: loaded {} symbols from {} ({} bytes)",
                        added,
                        path.display(),
                        data.len()
                    );
                },
                Err(e) => {
                    eprintln!("GUEST_PROFILE_SYMBOLS: failed to read {}: {}", path.display(), e);
                },
            }
        }

        // Sort by address for binary search.
        symbols.sort_by_key(|s| s.addr);

        Self { symbols }
    }

    /// Resolves an address to a function name.
    ///
    /// Returns `"function_name+0xOFFSET"` if found, or `"0xADDRESS"` if not.
    pub fn resolve(&self, addr: u32) -> String {
        // Binary search for the largest symbol address <= addr.
        match self.symbols.binary_search_by_key(&addr, |s| s.addr) {
            Ok(idx) => self.symbols[idx].name.clone(),
            Err(0) => format!("{:#010x}", addr),
            Err(idx) => {
                let sym = &self.symbols[idx - 1];
                if sym.size > 0 && addr < sym.addr + sym.size {
                    let offset = addr - sym.addr;
                    if offset == 0 {
                        sym.name.clone()
                    } else {
                        format!("{}+{:#x}", sym.name, offset)
                    }
                } else if sym.size == 0 {
                    // Unknown size — assume it's the right symbol if close.
                    let offset = addr - sym.addr;
                    if offset < 0x10000 {
                        format!("{}+{:#x}", sym.name, offset)
                    } else {
                        format!("{:#010x}", addr)
                    }
                } else {
                    format!("{:#010x}", addr)
                }
            },
        }
    }

    /// Parses ELF32 symbol table from raw bytes.
    fn parse_elf32_symbols(data: &[u8], out: &mut Vec<Symbol>) {
        // Minimal ELF32 parser — just enough to extract .symtab + .strtab.
        if data.len() < 52 {
            return;
        }

        // Check ELF magic.
        if &data[0..4] != b"\x7fELF" {
            return;
        }

        // ELF32 class check.
        if data[4] != 1 {
            return; // Not 32-bit
        }

        let e_shoff = u32::from_le_bytes(data[32..36].try_into().unwrap()) as usize;
        let e_shentsize = u16::from_le_bytes(data[46..48].try_into().unwrap()) as usize;
        let e_shnum = u16::from_le_bytes(data[48..50].try_into().unwrap()) as usize;
        let _e_shstrndx = u16::from_le_bytes(data[50..52].try_into().unwrap()) as usize;

        if e_shoff == 0 || e_shnum == 0 || e_shentsize < 40 {
            return;
        }

        // Read section headers.
        let mut symtab_offset = 0usize;
        let mut symtab_size = 0usize;
        let mut symtab_entsize = 0usize;
        let mut symtab_link = 0usize; // index of .strtab

        for i in 0..e_shnum {
            let sh = e_shoff + i * e_shentsize;
            if sh + 40 > data.len() {
                break;
            }
            let sh_type = u32::from_le_bytes(data[sh + 4..sh + 8].try_into().unwrap());
            // SHT_SYMTAB = 2, SHT_DYNSYM = 11
            // Prefer .symtab over .dynsym (more symbols), but use .dynsym as fallback.
            if sh_type == 2 {
                symtab_offset =
                    u32::from_le_bytes(data[sh + 16..sh + 20].try_into().unwrap()) as usize;
                symtab_size =
                    u32::from_le_bytes(data[sh + 20..sh + 24].try_into().unwrap()) as usize;
                symtab_entsize =
                    u32::from_le_bytes(data[sh + 36..sh + 40].try_into().unwrap()) as usize;
                symtab_link =
                    u32::from_le_bytes(data[sh + 24..sh + 28].try_into().unwrap()) as usize;
                break; // .symtab found, prefer it
            } else if sh_type == 11 && symtab_offset == 0 {
                // .dynsym fallback (only if we haven't found .symtab yet)
                symtab_offset =
                    u32::from_le_bytes(data[sh + 16..sh + 20].try_into().unwrap()) as usize;
                symtab_size =
                    u32::from_le_bytes(data[sh + 20..sh + 24].try_into().unwrap()) as usize;
                symtab_entsize =
                    u32::from_le_bytes(data[sh + 36..sh + 40].try_into().unwrap()) as usize;
                symtab_link =
                    u32::from_le_bytes(data[sh + 24..sh + 28].try_into().unwrap()) as usize;
                // don't break — keep scanning for .symtab
            }
        }

        if symtab_offset == 0 || symtab_entsize < 16 {
            return;
        }

        // Read .strtab for the symtab.
        let strtab_sh = e_shoff + symtab_link * e_shentsize;
        if strtab_sh + 24 > data.len() {
            return;
        }
        let strtab_offset =
            u32::from_le_bytes(data[strtab_sh + 16..strtab_sh + 20].try_into().unwrap()) as usize;
        let strtab_size =
            u32::from_le_bytes(data[strtab_sh + 20..strtab_sh + 24].try_into().unwrap()) as usize;

        if strtab_offset + strtab_size > data.len() {
            return;
        }
        let strtab = &data[strtab_offset..strtab_offset + strtab_size];

        // Parse symbols.
        let num_syms = symtab_size / symtab_entsize;
        for i in 0..num_syms {
            let sym = symtab_offset + i * symtab_entsize;
            if sym + 16 > data.len() {
                break;
            }

            let st_name = u32::from_le_bytes(data[sym..sym + 4].try_into().unwrap()) as usize;
            let st_value = u32::from_le_bytes(data[sym + 4..sym + 8].try_into().unwrap());
            let st_size = u32::from_le_bytes(data[sym + 8..sym + 12].try_into().unwrap());
            let st_info = data[sym + 12];

            // Include FUNC symbols (STT_FUNC = 2) and NOTYPE symbols in
            // code ranges (assembly entry points like _do_start2, do_kcall).
            let st_type = st_info & 0xf;
            if st_type != 2 && st_type != 0 {
                continue;
            }

            // Skip zero-address symbols.
            if st_value == 0 {
                continue;
            }

            // Read name from strtab.
            if st_name >= strtab.len() {
                continue;
            }
            let name_end = strtab[st_name..]
                .iter()
                .position(|&b| b == 0)
                .unwrap_or(strtab.len() - st_name);
            let name = String::from_utf8_lossy(&strtab[st_name..st_name + name_end]).to_string();

            if name.is_empty() {
                continue;
            }

            out.push(Symbol {
                addr: st_value,
                size: st_size,
                name,
            });
        }
    }
}
