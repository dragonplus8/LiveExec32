@import Darwin;
@import CoreVideo;
#include "bridge.h"
#include "../../GuestFrameworks/CoreVideo/LC32CoreVideoBridge.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>

namespace {

constexpr size_t kMaximumPixelBufferTransfer = 256u * 1024u * 1024u;

bool ReadCoreVideoCall(u32 guestAddress, LC32CoreVideoCall &call) {
    struct {
        uint32_t version;
        uint32_t slotCount;
    } header = {};
    if(!guestAddress ||
       Dynarmic_mem_1read(guestAddress, sizeof(header),
           reinterpret_cast<char *>(&header)) != 0 ||
       header.version != LC32CoreVideoABIVersion ||
       header.slotCount > LC32CoreVideoMaxSlots) {
        return false;
    }

    call = {};
    call.version = header.version;
    call.slotCount = header.slotCount;
    const size_t byteCount = header.slotCount * sizeof(call.slots[0]);
    const uint64_t slotsAddress = static_cast<uint64_t>(guestAddress) +
        offsetof(LC32CoreVideoCall, slots);
    if(slotsAddress > UINT32_MAX ||
       slotsAddress + byteCount > static_cast<uint64_t>(UINT32_MAX) + 1) {
        return false;
    }
    if(byteCount && Dynarmic_mem_1read(static_cast<u32>(slotsAddress),
            byteCount, reinterpret_cast<char *>(call.slots)) != 0) {
        return false;
    }
    return true;
}

bool RequireCoreVideoSlots(const LC32CoreVideoCall &call, uint32_t count) {
    return call.slotCount == count;
}

u32 SlotU32(const LC32CoreVideoCall &call, size_t index) {
    return static_cast<u32>(call.slots[index]);
}

template<typename T>
T SlotHostObject(const LC32CoreVideoCall &call, size_t index) {
    return reinterpret_cast<T>(static_cast<uintptr_t>(call.slots[index]));
}

bool GuestRangeValid(uint32_t guestAddress, size_t byteCount) {
    return static_cast<uint64_t>(byteCount) <=
        (UINT64_C(1) << 32) - static_cast<uint64_t>(guestAddress);
}

bool WriteGuestBytes(uint32_t guestAddress, const void *bytes,
                     size_t byteCount) {
    if(!byteCount) return true;
    if(byteCount > kMaximumPixelBufferTransfer || !guestAddress ||
       !GuestRangeValid(guestAddress, byteCount)) {
        return false;
    }
    return Dynarmic_mem_1write(guestAddress, byteCount,
        reinterpret_cast<char *>(const_cast<void *>(bytes))) == 0;
}

bool ReadGuestBytes(uint32_t guestAddress, void *bytes, size_t byteCount) {
    if(!byteCount) return true;
    if(byteCount > kMaximumPixelBufferTransfer || !guestAddress ||
       !GuestRangeValid(guestAddress, byteCount)) {
        return false;
    }
    return Dynarmic_mem_1read(guestAddress, byteCount,
        reinterpret_cast<char *>(bytes)) == 0;
}

/*
 * Tracks, per locked pixel buffer, whether the outstanding lock was
 * read-only -- Unlock needs this to know whether a copy-back is required.
 * Mirrors the BitmapBacking table CoreGraphics.mm keeps for the same
 * "extra host-side bookkeeping the C API doesn't carry for us" reason.
 */
std::mutex lockStateMutex;
std::unordered_map<CVPixelBufferRef, bool> lockStateReadOnly;

} // namespace

extern "C" uint32_t LC32_CoreVideo_Dispatch(uint32_t opcode,
                                             uint32_t guestCall,
                                             uint32_t) {
    LC32CoreVideoCall call;
    if(!ReadCoreVideoCall(guestCall, call)) return 0;

    switch(static_cast<LC32CoreVideoOpcode>(opcode)) {
        case LC32CoreVideoOpPixelBufferGetTypeID: {
            if(!RequireCoreVideoSlots(call, 0)) return 0;
            return static_cast<u32>(CVPixelBufferGetTypeID());
        }

        case LC32CoreVideoOpPixelBufferCreate: {
            if(!RequireCoreVideoSlots(call, 5)) return kCVReturnInvalidArgument;
            const size_t width = SlotU32(call, 0);
            const size_t height = SlotU32(call, 1);
            const OSType format = static_cast<OSType>(SlotU32(call, 2));
            CFDictionaryRef attributes =
                SlotHostObject<CFDictionaryRef>(call, 3);
            const u32 outHandleAddress = SlotU32(call, 4);
            if(!width || !height) return kCVReturnInvalidArgument;

            CVPixelBufferRef pixelBuffer = nullptr;
            CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                width, height, format, attributes, &pixelBuffer);
            if(status != kCVReturnSuccess) return status;
            if(!pixelBuffer) return kCVReturnAllocationFailed;

            /* Transfers the real +1 CVPixelBufferCreate just handed us into
             * the guest's ownership -- this is the same owned-result path
             * CGColorCreate uses, not the borrowed guest_self accessor
             * path, because the caller now owns this reference. */
            const u32 guestHandle = LC32GuestObjectForOwnedHostObject(
                pixelBuffer);
            if(!guestHandle) {
                CFRelease(pixelBuffer);
                return kCVReturnAllocationFailed;
            }
            if(outHandleAddress &&
               !WriteGuestBytes(outHandleAddress, &guestHandle,
                   sizeof(guestHandle))) {
                return kCVReturnInvalidArgument;
            }
            return kCVReturnSuccess;
        }

        case LC32CoreVideoOpPixelBufferGetWidth: {
            if(!RequireCoreVideoSlots(call, 1)) return 0;
            CVPixelBufferRef pb = SlotHostObject<CVPixelBufferRef>(call, 0);
            return pb ? static_cast<u32>(CVPixelBufferGetWidth(pb)) : 0;
        }
        case LC32CoreVideoOpPixelBufferGetHeight: {
            if(!RequireCoreVideoSlots(call, 1)) return 0;
            CVPixelBufferRef pb = SlotHostObject<CVPixelBufferRef>(call, 0);
            return pb ? static_cast<u32>(CVPixelBufferGetHeight(pb)) : 0;
        }
        case LC32CoreVideoOpPixelBufferGetBytesPerRow: {
            if(!RequireCoreVideoSlots(call, 1)) return 0;
            CVPixelBufferRef pb = SlotHostObject<CVPixelBufferRef>(call, 0);
            return pb ? static_cast<u32>(CVPixelBufferGetBytesPerRow(pb)) : 0;
        }
        case LC32CoreVideoOpPixelBufferGetPixelFormatType: {
            if(!RequireCoreVideoSlots(call, 1)) return 0;
            CVPixelBufferRef pb = SlotHostObject<CVPixelBufferRef>(call, 0);
            return pb
                ? static_cast<u32>(CVPixelBufferGetPixelFormatType(pb)) : 0;
        }
        case LC32CoreVideoOpPixelBufferIsPlanar: {
            if(!RequireCoreVideoSlots(call, 1)) return 0;
            CVPixelBufferRef pb = SlotHostObject<CVPixelBufferRef>(call, 0);
            return pb ? static_cast<u32>(CVPixelBufferIsPlanar(pb)) : 0;
        }
        case LC32CoreVideoOpPixelBufferGetPlaneCount: {
            if(!RequireCoreVideoSlots(call, 1)) return 0;
            CVPixelBufferRef pb = SlotHostObject<CVPixelBufferRef>(call, 0);
            return pb
                ? static_cast<u32>(CVPixelBufferGetPlaneCount(pb)) : 0;
        }

        case LC32CoreVideoOpPixelBufferLockBaseAddress: {
            if(!RequireCoreVideoSlots(call, 4)) return kCVReturnInvalidArgument;
            CVPixelBufferRef pb = SlotHostObject<CVPixelBufferRef>(call, 0);
            const u32 bridgeFlags = SlotU32(call, 1);
            const u32 guestBuffer = SlotU32(call, 2);
            const u32 guestByteCount = SlotU32(call, 3);
            if(!pb) return kCVReturnInvalidArgument;

            const bool readOnly =
                (bridgeFlags & LC32CoreVideoLockFlagReadOnly) != 0;
            const CVPixelBufferLockFlags flags =
                readOnly ? kCVPixelBufferLock_ReadOnly : 0;
            CVReturn status = CVPixelBufferLockBaseAddress(pb, flags);
            if(status != kCVReturnSuccess) return status;

            {
                std::lock_guard<std::mutex> guard(lockStateMutex);
                lockStateReadOnly[pb] = readOnly;
            }

            const void *hostBase = CVPixelBufferGetBaseAddress(pb);
            const size_t hostBytes =
                CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb);
            const size_t copyBytes =
                std::min<size_t>(hostBytes, guestByteCount);
            if(hostBase && guestBuffer && copyBytes &&
               !WriteGuestBytes(guestBuffer, hostBase, copyBytes)) {
                CVPixelBufferUnlockBaseAddress(pb, flags);
                std::lock_guard<std::mutex> guard(lockStateMutex);
                lockStateReadOnly.erase(pb);
                return kCVReturnInvalidArgument;
            }
            return kCVReturnSuccess;
        }

        case LC32CoreVideoOpPixelBufferUnlockBaseAddress: {
            if(!RequireCoreVideoSlots(call, 4)) return kCVReturnInvalidArgument;
            CVPixelBufferRef pb = SlotHostObject<CVPixelBufferRef>(call, 0);
            const u32 bridgeFlags = SlotU32(call, 1);
            const u32 guestBuffer = SlotU32(call, 2);
            const u32 guestByteCount = SlotU32(call, 3);
            if(!pb) return kCVReturnInvalidArgument;

            bool readOnly = (bridgeFlags & LC32CoreVideoLockFlagReadOnly) != 0;
            {
                std::lock_guard<std::mutex> guard(lockStateMutex);
                auto entry = lockStateReadOnly.find(pb);
                if(entry != lockStateReadOnly.end()) {
                    readOnly = entry->second;
                    lockStateReadOnly.erase(entry);
                }
            }

            if(!readOnly && guestBuffer && guestByteCount) {
                void *hostBase = CVPixelBufferGetBaseAddress(pb);
                const size_t hostBytes = CVPixelBufferGetBytesPerRow(pb) *
                    CVPixelBufferGetHeight(pb);
                const size_t copyBytes =
                    std::min<size_t>(hostBytes, guestByteCount);
                if(hostBase && copyBytes &&
                   !ReadGuestBytes(guestBuffer, hostBase, copyBytes)) {
                    return kCVReturnInvalidArgument;
                }
            }

            const CVPixelBufferLockFlags flags =
                readOnly ? kCVPixelBufferLock_ReadOnly : 0;
            return CVPixelBufferUnlockBaseAddress(pb, flags);
        }

        default:
            return 0;
    }
}
