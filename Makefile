# Zurvan — top-level orchestration.
#
# Each target delegates to a script under its own directory so the heavy lifting
# stays readable and editable on its own. This Makefile just wires them together
# and defines the build order.
#
# Build order (bottom-up):  kernel -> userland -> init -> rootfs -> run
#
# Nothing here has been booted yet. Treat targets as the intended entry points,
# not a proven pipeline. Kernel config and PID 1 logic are the parts to reason
# about yourself.

# --- Layout -----------------------------------------------------------------
TOP        := $(CURDIR)
BUILD      := $(TOP)/build
ROOTFS_OUT := $(BUILD)/rootfs
INITRD     := $(BUILD)/rootfs.cpio.gz

KERNEL_IMG := $(TOP)/kernel/build/bzImage

export TOP BUILD ROOTFS_OUT INITRD KERNEL_IMG

# --- Meta -------------------------------------------------------------------
.DEFAULT_GOAL := help
.PHONY: help all kernel userland init rootfs run iso clean distclean

help: ## Show this help
	@echo "Zurvan build targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Typical first run:  make kernel && make userland && make init && make rootfs && make run"

all: kernel userland init rootfs ## Build every layer (does not run)

# --- Layers -----------------------------------------------------------------
kernel: ## Fetch, configure and build the Linux kernel
	@kernel/build.sh

userland: ## Build static busybox, then bash
	@userland/build-busybox.sh
	@userland/build-bash.sh

init: ## Compile the C PID 1
	@$(MAKE) -C init

rootfs: ## Assemble rootfs/ and pack rootfs.cpio.gz
	@scripts/build.sh

# --- Run --------------------------------------------------------------------
run: ## Boot the built image in QEMU (-nographic; Ctrl-A X to exit)
	@scripts/run-qemu.sh

iso: ## (ROADMAP) Build a bootable ISO with GRUB — not part of v1
	@scripts/make-iso.sh

# --- Cleanup ----------------------------------------------------------------
clean: ## Remove the assembled rootfs and initramfs
	@rm -rf "$(BUILD)"
	@$(MAKE) -C init clean

distclean: clean ## Also remove kernel/userland build trees
	@rm -rf kernel/build kernel/src userland/build userland/src
