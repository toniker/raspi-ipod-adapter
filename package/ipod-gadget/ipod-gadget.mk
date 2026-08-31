################################################################################
#
# ipod-gadget
#
################################################################################

# oandrew/ipod-gadget master as of 2025-08-15. This exact commit is required:
# it carries "Use hid_descriptor.rpt_desc on >= 6.12.34", the API change for
# the HID report-descriptor accessor that our kernel (raspberrypi/linux
# 6.12.41, see configs/ipod_adapter_defconfig) needs. Any older commit fails
# to build against this tree -- see IPOD-ADAPTER.md Phase 2.
IPOD_GADGET_VERSION = ece6b7b0b29dacb7be0cf9f6436fc390892969e8
IPOD_GADGET_SITE = $(call github,oandrew,ipod-gadget,$(IPOD_GADGET_VERSION))
IPOD_GADGET_LICENSE = MIT
IPOD_GADGET_LICENSE_FILES = LICENSE

# The Kbuild files (Makefile with obj-m / ccflags-y) live in gadget/, not at
# the repo root.
IPOD_GADGET_MODULE_SUBDIRS = gadget

# ipod_audio.c builds an ALSA card by hand (snd_card_new / snd_pcm_new), so
# every translation unit here pulls in <sound/core.h> and <sound/pcm.h>. The
# RPi bcm2709 defconfig does ship CONFIG_SND / CONFIG_SND_PCM (as modules,
# selected by the USB-audio and SoC drivers), but that is incidental -- state
# the dependency explicitly so a future defconfig trim cannot silently break
# the module build.
#
# USB gadget / libcomposite / mass_storage are already forced by
# board/ipod-adapter/linux-usb-gadget.fragment; they are repeated here so the
# package carries its own kernel needs. USB_F_MASS_STORAGE has no Kconfig
# prompt and is only reachable via a selecting symbol, so enable the prompted
# USB_CONFIGFS_MASS_STORAGE rather than the leaf -- ipod_gadget.c calls
# usb_get_function_instance("mass_storage") unconditionally (even with
# only_ipod=1 it still acquires, just doesn't expose, that function).
define IPOD_GADGET_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_SOUND)
	$(call KCONFIG_ENABLE_OPT,CONFIG_SND)
	$(call KCONFIG_ENABLE_OPT,CONFIG_SND_PCM)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_GADGET)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_LIBCOMPOSITE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_CONFIGFS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_CONFIGFS_MASS_STORAGE)
endef

$(eval $(kernel-module))
$(eval $(generic-package))
