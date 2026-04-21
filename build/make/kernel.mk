# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

KERNEL_FEATURES := $(MACHINE) $(LOG_LEVEL)
KERNEL_FEATURES += $(if $(filter yes,$(WHP)),whp,)
KERNEL_FEATURES += $(if $(filter yes,$(RELEASE)),nightly-performance-optimizations,)
KERNEL_FEATURES := $(strip $(KERNEL_FEATURES))
KERNEL_CARGO_FEATURES := $(if $(KERNEL_FEATURES),--features "$(KERNEL_FEATURES)")

all-kernel: init
	$(KERNEL_CARGO_BUILD_CMD) $(KERNEL_CARGO_FEATURES) -p kernel
	$(CP_CMD) $(OBJECTS_DIR)/$(TARGET)-kernel/$(BUILD_MODE)/kernel.elf $(BINARIES_DIR)/kernel.elf
ifeq ($(PROFILER),yes)
	# Profiling build: strip .debug_* sections but keep .symtab so the
	# guest profiler can resolve kernel function names. This reduces the
	# binary loaded into guest RAM (~1.4 MB savings) while preserving
	# the ~60 KB symbol table needed for stack-trace resolution.
	# A full-debug copy is kept as kernel.elf.debug for line-level debugging.
	$(CP_CMD) $(BINARIES_DIR)/kernel.elf $(BINARIES_DIR)/kernel.elf.debug
	@if command -v rust-objcopy >/dev/null 2>&1; then \
		rust-objcopy --strip-debug "$(BINARIES_DIR)/kernel.elf"; \
	elif command -v objcopy >/dev/null 2>&1; then \
		objcopy --strip-debug "$(BINARIES_DIR)/kernel.elf"; \
	else \
		echo "WARNING: objcopy not found, kernel.elf retains debug sections (~1.4 MB extra)"; \
	fi
endif

check-kernel:
	$(KERNEL_CARGO_CHECK_CMD) $(KERNEL_CARGO_FEATURES) -p kernel

format-kernel:
	$(KERNEL_CARGO_FMT_CMD) -p kernel

format-check-kernel:
	$(KERNEL_CARGO_FMT_CMD) -p kernel --check

clean-kernel:
	$(KERNEL_CARGO_CLEAN_CMD) -p kernel
	$(RM_CMD) $(BINARIES_DIR)/kernel.elf

rust-lint-kernel:
	$(KERNEL_CARGO_CLIPPY_CMD) $(KERNEL_CARGO_FEATURES) -p kernel --fix --allow-dirty --allow-no-vcs

rust-lint-check-kernel:
	$(KERNEL_CARGO_CLIPPY_CMD) $(KERNEL_CARGO_FEATURES) -p kernel -- -D warnings
