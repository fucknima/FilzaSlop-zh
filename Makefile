# Use the newest SDK bundled with this Theos installation.  ContainerManager
# entry points are resolved at runtime, so private SDK headers are not needed.
TARGET := iphone:clang:17.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FilzaApplySandboxExt

UNRAR_DIR = Vendor/unrar
UNRAR_SOURCES = $(addprefix $(UNRAR_DIR)/, \
    filestr.cpp scantree.cpp dll.cpp qopen.cpp rar.cpp strlist.cpp strfn.cpp \
    pathfn.cpp smallfn.cpp global.cpp file.cpp filefn.cpp filcreat.cpp \
    archive.cpp arcread.cpp unicode.cpp system.cpp crypt.cpp crc.cpp \
    rawread.cpp encname.cpp resource.cpp match.cpp timefn.cpp rdwrfn.cpp \
    consio.cpp options.cpp errhnd.cpp rarvm.cpp secpassword.cpp rijndael.cpp \
    getbits.cpp sha1.cpp sha256.cpp blake2s.cpp hash.cpp extinfo.cpp \
    extract.cpp volume.cpp list.cpp find.cpp unpack.cpp headers.cpp \
    threadpool.cpp rs16.cpp cmddata.cpp ui.cpp largepage.cpp)

FilzaApplySandboxExt_FILES = Tweak.m MCMBridge.m MCMFilzaIntegration.m \
    PosterBoardFeature.m TGFocusedInputResponderTimingFix.m \
    StartupProgressController.m ArchiveUnzipFix.m RootHelperBlocker.m \
    Core/FSCapabilities.m FeaturePruning.m Access/FSAccessManager.m FSLog.m \
    Vendor/minizip/FSMinizipZip.c $(UNRAR_SOURCES)

# --- Flags ---
FilzaApplySandboxExt_CFLAGS = -I$(PWD) \
    -I$(PWD)/Vendor/unrar -I$(PWD)/Vendor/unrar/include -I$(PWD)/Vendor/minizip \
    -fobjc-arc \
    -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable \
    -Wno-incompatible-pointer-types -Wno-incompatible-pointer-types-discards-qualifiers \
    -Wno-deprecated-declarations -Wno-nonportable-include-path -Wno-format
FilzaApplySandboxExt_CFLAGS += -Wno-arc-performSelector-leaks

FilzaApplySandboxExt_CCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
FilzaApplySandboxExt_CCFLAGS += -std=c++11 -DRARDLL -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -Wno-error
FilzaApplySandboxExt_OBJCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
FilzaApplySandboxExt_OBJCCFLAGS = $(FilzaApplySandboxExt_CFLAGS)

FilzaApplySandboxExt_FRAMEWORKS = UIKit Foundation IOKit CoreFoundation Security
FilzaApplySandboxExt_PRIVATE_FRAMEWORKS = IOSurface
FilzaApplySandboxExt_LIBRARIES = z sandbox

FilzaApplySandboxExt_INSTALL_TARGET_PROCESSES = Filza

include $(THEOS_MAKE_PATH)/tweak.mk
