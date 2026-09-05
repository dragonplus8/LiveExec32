#import <CoreVideo/CoreVideo.h>
#import <CoreFoundation/CoreFoundation+LC32.h>
#import <LC32/LC32.h>

#include <pthread.h>
#include <stdint.h>
#include <string.h>

#include "LC32CoreVideoBridge.h"

/*
 * CVPixelBufferRef, like CGColorRef, is a real ISA-swizzled CF object on the
 * host. We do not invent a separate handle table for it: CVPixelBufferCreate
 * asks the host to mint the real object and hand back a guest proxy via
 * -guest_self (see ObjCProxy.md), and CVPixelBufferRetain/Release just reuse
 * ordinary CFRetain/CFRelease, which already understand guest CF proxies.
 */

static pthread_once_t LC32CoreVideoDispatcherOnce = PTHREAD_ONCE_INIT;
static uint64_t LC32CoreVideoDispatcherAddress;

static void LC32CoreVideoResolveDispatcher(void) {
    LC32CoreVideoDispatcherAddress =
        LC32Dlsym("LC32_CoreVideo_Dispatch", YES);
}

static uint32_t LC32CoreVideoDispatch(LC32CoreVideoOpcode opcode,
                                      const uint64_t *slots,
                                      uint32_t slotCount) {
    if(slotCount > LC32CoreVideoMaxSlots) return 0;
    pthread_once(&LC32CoreVideoDispatcherOnce,
        LC32CoreVideoResolveDispatcher);
    if(!LC32CoreVideoDispatcherAddress) return 0;

    LC32CoreVideoCall call = {
        .version = LC32CoreVideoABIVersion,
        .slotCount = slotCount,
    };
    if(slotCount) memcpy(call.slots, slots, slotCount * sizeof(*slots));

    /* Same SVC 1002 "invoke native C function" transport CoreGraphics and
     * OpenGLES use: the dispatcher address, opcode, and a pointer to the
     * packed call go in as the first three post-function-pointer words. */
    return LC32InvokeHostCRet32(LC32CoreVideoDispatcherAddress,
        (uint32_t)opcode, (uint32_t)(uintptr_t)&call);
}

static uint64_t LC32CoreVideoHostObject(const void *object) {
    return object ? [(id)object host_self] : 0;
}

static uint64_t LC32CoreVideoGuestPointer(const void *pointer) {
    return (uint32_t)(uintptr_t)pointer;
}

#define LC32_CV_CALL0(opcode) \
    LC32CoreVideoDispatch((opcode), NULL, 0)
#define LC32_CV_CALL(opcode, ...) \
    LC32CoreVideoDispatch((opcode), (const uint64_t[]){__VA_ARGS__}, \
        (uint32_t)(sizeof((const uint64_t[]){__VA_ARGS__}) / sizeof(uint64_t)))
#define LC32_CV_U32(value) ((uint64_t)(uint32_t)(value))
#define LC32_CV_HOST(value) LC32CoreVideoHostObject((const void *)(value))
#define LC32_CV_PTR(value) LC32CoreVideoGuestPointer((const void *)(value))

#pragma mark - Lifetime

/*
 * CVPixelBufferRef is toll-free bridged to CFTypeRef on the real framework,
 * so ordinary CFRetain/CFRelease -- which already know how to walk the
 * guest<->host CF proxy identity -- are the correct retain/release. There is
 * nothing CoreVideo-specific to bridge here.
 */
CVPixelBufferRef CVPixelBufferRetain(CVPixelBufferRef texture) {
    if(texture) CFRetain(texture);
    return texture;
}

void CVPixelBufferRelease(CVPixelBufferRef texture) {
    if(texture) CFRelease(texture);
}

CFTypeID CVPixelBufferGetTypeID(void) {
    return (CFTypeID)LC32_CV_CALL0(LC32CoreVideoOpPixelBufferGetTypeID);
}

#pragma mark - Creation

CVReturn CVPixelBufferCreate(CFAllocatorRef allocator,
                              size_t width, size_t height,
                              OSType pixelFormatType,
                              CFDictionaryRef pixelBufferAttributes,
                              CVPixelBufferRef *pixelBufferOut) {
    if(!pixelBufferOut) return kCVReturnInvalidArgument;
    *pixelBufferOut = NULL;
    if(width == 0 || height == 0 || width > UINT32_MAX ||
       height > UINT32_MAX) {
        return kCVReturnInvalidArgument;
    }

    /*
     * The allocator argument is a host-side concern (the real buffer lives
     * entirely on the host); only width/height/format/attributes and a
     * guest output slot for the created proxy's handle cross the SVC.
     */
    uint32_t createdHandle = 0;
    CVReturn result = (CVReturn)LC32_CV_CALL(
        LC32CoreVideoOpPixelBufferCreate,
        LC32_CV_U32(width), LC32_CV_U32(height),
        LC32_CV_U32(pixelFormatType), LC32_CV_HOST(pixelBufferAttributes),
        LC32_CV_PTR(&createdHandle));
    if(result != kCVReturnSuccess || !createdHandle) {
        return result != kCVReturnSuccess ? result : kCVReturnError;
    }

    *pixelBufferOut = (CVPixelBufferRef)(uintptr_t)createdHandle;
    return kCVReturnSuccess;
}

#pragma mark - Introspection

size_t CVPixelBufferGetWidth(CVPixelBufferRef pixelBuffer) {
    if(!pixelBuffer) return 0;
    return (size_t)LC32_CV_CALL(LC32CoreVideoOpPixelBufferGetWidth,
        LC32_CV_HOST(pixelBuffer));
}

size_t CVPixelBufferGetHeight(CVPixelBufferRef pixelBuffer) {
    if(!pixelBuffer) return 0;
    return (size_t)LC32_CV_CALL(LC32CoreVideoOpPixelBufferGetHeight,
        LC32_CV_HOST(pixelBuffer));
}

size_t CVPixelBufferGetBytesPerRow(CVPixelBufferRef pixelBuffer) {
    if(!pixelBuffer) return 0;
    return (size_t)LC32_CV_CALL(LC32CoreVideoOpPixelBufferGetBytesPerRow,
        LC32_CV_HOST(pixelBuffer));
}

OSType CVPixelBufferGetPixelFormatType(CVPixelBufferRef pixelBuffer) {
    if(!pixelBuffer) return 0;
    return (OSType)LC32_CV_CALL(
        LC32CoreVideoOpPixelBufferGetPixelFormatType,
        LC32_CV_HOST(pixelBuffer));
}

Boolean CVPixelBufferIsPlanar(CVPixelBufferRef pixelBuffer) {
    if(!pixelBuffer) return false;
    return (Boolean)LC32_CV_CALL(LC32CoreVideoOpPixelBufferIsPlanar,
        LC32_CV_HOST(pixelBuffer));
}

size_t CVPixelBufferGetPlaneCount(CVPixelBufferRef pixelBuffer) {
    if(!pixelBuffer) return 0;
    return (size_t)LC32_CV_CALL(LC32CoreVideoOpPixelBufferGetPlaneCount,
        LC32_CV_HOST(pixelBuffer));
}

#pragma mark - Pixel access (copy-based MVP tier)

/*
 * MVP tier, matching the tradeoff CGColorGetComponents makes: lock does one
 * host->guest copy of the whole plane into a guest buffer whose lifetime is
 * tied to the pixel buffer object; unlock copies back only if the lock
 * wasn't read-only. This is correct but not zero-copy -- a real-time camera
 * pipeline would eventually want the page-mapping tier described in the
 * design notes instead.
 */
CVReturn CVPixelBufferLockBaseAddress(CVPixelBufferRef pixelBuffer,
                                       CVPixelBufferLockFlags lockFlags) {
    if(!pixelBuffer) return kCVReturnInvalidArgument;

    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    if(!height || !bytesPerRow ||
       height > UINT32_MAX / bytesPerRow) {
        return kCVReturnInvalidArgument;
    }
    const uint32_t byteCount = (uint32_t)(height * bytesPerRow);

    void *buffer = LC32GetAssociatedGuestBuffer((id)pixelBuffer, byteCount);
    if(!buffer) return kCVReturnPixelBufferNotOpenGLCompatible;

    const uint32_t bridgeFlags =
        (lockFlags & kCVPixelBufferLock_ReadOnly)
            ? LC32CoreVideoLockFlagReadOnly : 0;
    return (CVReturn)LC32_CV_CALL(
        LC32CoreVideoOpPixelBufferLockBaseAddress,
        LC32_CV_HOST(pixelBuffer), LC32_CV_U32(bridgeFlags),
        LC32_CV_PTR(buffer), LC32_CV_U32(byteCount));
}

CVReturn CVPixelBufferUnlockBaseAddress(CVPixelBufferRef pixelBuffer,
                                         CVPixelBufferLockFlags lockFlags) {
    if(!pixelBuffer) return kCVReturnInvalidArgument;

    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    const uint32_t byteCount =
        (height && bytesPerRow && height <= UINT32_MAX / bytesPerRow)
            ? (uint32_t)(height * bytesPerRow) : 0;

    /* Reuses the same associated buffer Lock populated; does not allocate
     * a new one, since the size is unchanged between lock and unlock. */
    void *buffer = byteCount
        ? LC32GetAssociatedGuestBuffer((id)pixelBuffer, byteCount) : NULL;

    const uint32_t bridgeFlags =
        (lockFlags & kCVPixelBufferLock_ReadOnly)
            ? LC32CoreVideoLockFlagReadOnly : 0;
    return (CVReturn)LC32_CV_CALL(
        LC32CoreVideoOpPixelBufferUnlockBaseAddress,
        LC32_CV_HOST(pixelBuffer), LC32_CV_U32(bridgeFlags),
        LC32_CV_PTR(buffer), LC32_CV_U32(byteCount));
}

void *CVPixelBufferGetBaseAddress(CVPixelBufferRef pixelBuffer) {
    if(!pixelBuffer) return NULL;
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    if(!height || !bytesPerRow || height > UINT32_MAX / bytesPerRow) {
        return NULL;
    }
    /* Returns the same guest buffer Lock filled in; callers must lock
     * before calling this, exactly as the real framework requires. */
    return LC32GetAssociatedGuestBuffer((id)pixelBuffer,
        (uint32_t)(height * bytesPerRow));
}
