#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <stdint.h>
#include <stdio.h>

extern BOOL _objc_rootIsDeallocating(id object);
extern uint64_t LC32LookupHostMapping(uint32_t guestObject);

@interface NSObject (LC32RootDeallocReentry)
- (uint64_t)host_self;
@end

typedef struct {
    unsigned callbacks;
    BOOL deallocating;
    uint64_t before;
    uint64_t resolved;
    uint64_t after;
} Observation;

static char observationKey;
static unsigned failures;

static void check(const char *name, BOOL passed) {
    printf("%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

@interface LC32RootAssociationProbe : NSObject {
@public
    id owner; // Unretained; it is still allocated while its associations die.
    Observation *observation;
}
@end

@implementation LC32RootAssociationProbe
- (void)dealloc {
    const uint32_t address = (uint32_t)(uintptr_t)owner;
    observation->callbacks++;
    observation->deallocating = _objc_rootIsDeallocating(owner);
    observation->before = LC32LookupHostMapping(address);
    observation->resolved = [owner host_self];
    observation->after = LC32LookupHostMapping(address);
    [super dealloc];
}
@end

static void observeRootCleanup(id owner, Observation *observation) {
    // No native mirror for the observer: its last guest association reference
    // must invoke -dealloc synchronously inside owner's object_dispose.
    LC32RootAssociationProbe *probe = class_createInstance(
        [LC32RootAssociationProbe class], 0);
    probe->owner = owner;
    probe->observation = observation;
    objc_setAssociatedObject(owner, &observationKey, probe,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [probe release];
}

@interface LC32OwnedTeardownProbe : NSObject
@end

@implementation LC32OwnedTeardownProbe
@end

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    Observation detached = {};
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    // The convenience result's native autorelease drains its lifetime pin.
    // Guest root -dealloc has detached that dead peer by the time libobjc
    // releases this object's associated observer.
    NSMutableData *data = [NSMutableData dataWithLength:32];
    observeRootCleanup(data, &detached);
    [pool drain];
    check("root-association-runs-before-free",
        detached.callbacks == 1 && detached.deallocating);
    check("root-association-observes-detached-key", detached.before == 0);
    check("root-association-does-not-recreate-peer",
        detached.resolved == 0 && detached.after == 0);
    if(detached.callbacks != 1 || !detached.deallocating ||
            detached.before || detached.resolved || detached.after) {
        printf("  callbacks=%u deallocating=%d before=0x%llx "
               "resolved=0x%llx after=0x%llx\n", detached.callbacks,
            detached.deallocating, (unsigned long long)detached.before,
            (unsigned long long)detached.resolved,
            (unsigned long long)detached.after);
    }

    Observation owned = {};
    pool = [NSAutoreleasePool new];
    LC32OwnedTeardownProbe *object = [LC32OwnedTeardownProbe new];
    const uint64_t nativePeer = [object host_self];
    observeRootCleanup(object, &owned);
    [object release];
    [pool drain];
    check("root-owned-teardown-keeps-native-peer",
        nativePeer && owned.callbacks == 1 && owned.deallocating &&
        owned.before == nativePeer && owned.resolved == nativePeer &&
        owned.after == nativePeer);
    if(!nativePeer || owned.callbacks != 1 || !owned.deallocating ||
            owned.before != nativePeer || owned.resolved != nativePeer ||
            owned.after != nativePeer) {
        printf("  peer=0x%llx callbacks=%u deallocating=%d before=0x%llx "
               "resolved=0x%llx after=0x%llx\n",
            (unsigned long long)nativePeer, owned.callbacks,
            owned.deallocating, (unsigned long long)owned.before,
            (unsigned long long)owned.resolved,
            (unsigned long long)owned.after);
    }

    // A normal unmapped guest and a class must still be able to acquire peers.
    pool = [NSAutoreleasePool new];
    id unmapped = class_createInstance([LC32OwnedTeardownProbe class], 0);
    const BOOL initiallyUnmapped = LC32LookupHostMapping(
        (uint32_t)(uintptr_t)unmapped) == 0;
    check("live-unmapped-object-can-create-peer", initiallyUnmapped &&
        !_objc_rootIsDeallocating(unmapped) && [unmapped host_self] != 0);
    check("class-can-resolve-peer", [[LC32OwnedTeardownProbe class]
        host_self] != 0);
    [unmapped release];
    [pool drain];
    return failures ? 1 : 0;
}
