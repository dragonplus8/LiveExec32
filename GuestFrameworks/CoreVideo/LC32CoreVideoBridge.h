#ifndef LC32_CORE_VIDEO_BRIDGE_H
#define LC32_CORE_VIDEO_BRIDGE_H

#include <stdint.h>

/*
 * Same shape as LC32CoreGraphicsBridge.h / LC32OpenGLESBridge.h: a fixed
 * version tag, a slot count, and up to LC32CoreVideoMaxSlots 8-byte logical
 * arguments. Keep opcode values explicit and append-only -- guest and host
 * are built independently, so reordering silently turns one call into
 * another.
 */

enum {
    LC32CoreVideoABIVersion = 1,
    LC32CoreVideoMaxSlots = 8,

    /* CVPixelBufferLockBaseAddress() flags this bridge understands today. */
    LC32CoreVideoLockFlagReadOnly = 1u << 0,
};

typedef struct {
    uint32_t version;
    uint32_t slotCount;
    uint64_t slots[LC32CoreVideoMaxSlots];
} LC32CoreVideoCall;

typedef enum : uint32_t {
    LC32CoreVideoOpPixelBufferCreate = 1,
    LC32CoreVideoOpPixelBufferGetWidth = 2,
    LC32CoreVideoOpPixelBufferGetHeight = 3,
    LC32CoreVideoOpPixelBufferGetBytesPerRow = 4,
    LC32CoreVideoOpPixelBufferGetPixelFormatType = 5,
    LC32CoreVideoOpPixelBufferIsPlanar = 6,
    LC32CoreVideoOpPixelBufferGetPlaneCount = 7,
    LC32CoreVideoOpPixelBufferLockBaseAddress = 8,
    LC32CoreVideoOpPixelBufferUnlockBaseAddress = 9,
    LC32CoreVideoOpPixelBufferGetTypeID = 10,
} LC32CoreVideoOpcode;

#endif
