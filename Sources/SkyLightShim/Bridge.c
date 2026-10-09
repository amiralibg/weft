// The bridged operations (BridgeShim.h): build an `SLSBridged…Operation`,
// hand it to SkyLight's asynchronous perform function, release it.
//
// Operations are built through the Objective-C runtime rather than declared,
// so a class a macOS update removes reads as "missing" here instead of
// failing to load the binary.

#include "BridgeShim.h"

#include <objc/message.h>
#include <objc/runtime.h>

extern void *weft_p_bridge_perform_async;
extern void *weft_p_bridge_perform_sync;

typedef void *(*weft_perform_fn)(void *operation);

static const char *const weft_bridge_classes[] = {
    "SLSBridgedMoveWindowsToManagedSpaceOperation",
    "SLSBridgedShowSpacesOperation",
    "SLSBridgedHideSpacesOperation",
    "SLSBridgedManagedDisplaySetCurrentSpaceOperation",
};

const char *weft_bridge_missing(void) {
    // The perform functions first: `WEFT_PUBLIC_ONLY` takes them away, and
    // that is the answer a report should give.
    if (!weft_private_symbol_present_named("SLSPerformAsynchronousBridgedWindowManagementOperation"))
        return "SLSPerformAsynchronousBridgedWindowManagementOperation";
    if (!weft_private_symbol_present_named("_SLSPerformSynchronousBridgedWindowManagementOperation"))
        return "_SLSPerformSynchronousBridgedWindowManagementOperation";
    for (size_t i = 0; i < sizeof(weft_bridge_classes) / sizeof(weft_bridge_classes[0]); i++) {
        if (objc_getClass(weft_bridge_classes[i]) == Nil) return weft_bridge_classes[i];
    }
    return NULL;
}

static id weft_alloc(const char *className) {
    Class cls = objc_getClass(className);
    if (cls == Nil) return nil;
    return ((id (*)(Class, SEL))objc_msgSend)(cls, sel_registerName("alloc"));
}

/// Perform and release. The operation is serialised for the WindowServer
/// before the perform function returns, so nothing holds it afterwards.
static bool weft_perform(id operation) {
    weft_perform_fn perform = (weft_perform_fn)weft_p_bridge_perform_async;
    if (operation == nil) return false;
    if (perform == NULL) {
        ((void (*)(id, SEL))objc_msgSend)(operation, sel_registerName("release"));
        return false;
    }
    (void)perform((void *)operation);
    ((void (*)(id, SEL))objc_msgSend)(operation, sel_registerName("release"));
    return true;
}

static CFArrayRef weft_numbers_u64(const uint64_t *values, int count) {
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (int i = 0; i < count; i++) {
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &values[i]);
        CFArrayAppendValue(array, n);
        CFRelease(n);
    }
    return array;
}

bool weft_bridge_move_windows(const SLWindowID *wids, int count, SLSpaceID sid) {
    if (count <= 0 || weft_bridge_missing() != NULL) return false;
    CFMutableArrayRef windows = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (int i = 0; i < count; i++) {
        int32_t wid = (int32_t)wids[i];
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
        CFArrayAppendValue(windows, n);
        CFRelease(n);
    }
    id op = ((id (*)(id, SEL, CFArrayRef, uint64_t))objc_msgSend)(
        weft_alloc("SLSBridgedMoveWindowsToManagedSpaceOperation"),
        sel_registerName("initWithWindows:spaceID:"), windows, sid
    );
    bool submitted = weft_perform(op);
    CFRelease(windows);
    return submitted;
}

static id weft_spaces_operation(const char *className, SLSpaceID sid) {
    CFArrayRef spaces = weft_numbers_u64(&sid, 1);
    id op = ((id (*)(id, SEL, CFArrayRef))objc_msgSend)(
        weft_alloc(className), sel_registerName("initWithSpaces:"), spaces
    );
    CFRelease(spaces);
    return op;
}

bool weft_bridge_switch(CFStringRef display, SLSpaceID from, SLSpaceID to) {
    if (display == NULL || from == to || weft_bridge_missing() != NULL) return false;
    if (!weft_perform(weft_spaces_operation("SLSBridgedShowSpacesOperation", to))) return false;
    if (!weft_perform(weft_spaces_operation("SLSBridgedHideSpacesOperation", from))) return false;
    id current = ((id (*)(id, SEL, CFStringRef, uint64_t))objc_msgSend)(
        weft_alloc("SLSBridgedManagedDisplaySetCurrentSpaceOperation"),
        sel_registerName("initWithDisplayIdentifier:spaceID:"), display, to
    );
    return weft_perform(current);
}
