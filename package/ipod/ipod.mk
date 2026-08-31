################################################################################
#
# ipod
#
################################################################################

# oandrew/ipod master HEAD. The repo has had no commits since Jan 2021 -- it is
# the stable reference client for oandrew/ipod-gadget (see package/ipod-gadget).
# Fork survey and the decision to use upstream rather than a car-specific fork
# are in IPOD-ADAPTER.md Phase 3 / open questions.
IPOD_VERSION = 3762132cc9ad94c5301dddb9365a923350e0020f
IPOD_SITE = $(call github,oandrew,ipod,$(IPOD_VERSION))
IPOD_LICENSE = MIT
IPOD_LICENSE_FILES = LICENSE

# cmd/ipod is the only binary; the infra names it after the build target,
# i.e. "ipod".
IPOD_BUILD_TARGETS = cmd/ipod

$(eval $(golang-package))
