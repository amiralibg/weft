// The loader for SkyLightShim.h: one pointer per private symbol, filled by
// name before main runs.
//
// SkyLight is opened by path and searched first; anything not there (the
// CoreGraphics region helpers, HIServices' `_AXUIElementGetWindow`) comes from
// the images already loaded. SkyLight is itself already loaded by then —
// CoreGraphics and AppKit depend on it — so the dlopen only hands back a
// handle, it does not load anything.

#include "SkyLightShim.h"
#include "AXBridge.h"

#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

#define WEFT_PRIVATE_SYMBOLS(X)                  \
    X(SLSMainConnectionID)                       \
    X(SLSGetWindowBounds)                        \
    X(SLSCopyManagedDisplaySpaces)               \
    X(SLSManagedDisplayGetCurrentSpace)          \
    X(SLSCopySpacesForWindows)                   \
    X(SLSSpaceGetType)                           \
    X(SLSCopyActiveMenuBarDisplayIdentifier)     \
    X(SLSCopyManagedDisplayForSpace)             \
    X(SLSMoveWindow)                             \
    X(SLSMoveWindowsToManagedSpace)              \
    X(SLSSetWindowTags)                          \
    X(SLSClearWindowTags)                        \
    X(SLSOrderWindow)                            \
    X(SLSTransactionCreate)                      \
    X(SLSTransactionCommit)                      \
    X(SLSTransactionMoveWindowWithGroup)         \
    X(SLSTransactionOrderWindow)                 \
    X(SLSNewWindow)                              \
    X(SLSReleaseWindow)                          \
    X(SLSSetWindowShape)                         \
    X(SLSSetWindowResolution)                    \
    X(SLSSetWindowOpacity)                       \
    X(SLSSetWindowLevel)                         \
    X(SLSGetWindowLevel)                         \
    X(SLWindowContextCreate)                     \
    X(CGSNewRegionWithRectList)                  \
    X(CGSReleaseRegion)                          \
    X(_AXUIElementGetWindow)

#define WEFT_DEFINE_POINTER(name) weft_##name##_fn weft_p_##name = NULL;
WEFT_PRIVATE_SYMBOLS(WEFT_DEFINE_POINTER)

typedef struct {
    const char *name;
    void **slot;
} weft_symbol;

#define WEFT_TABLE_ENTRY(name) { #name, (void **)&weft_p_##name },
static weft_symbol weft_symbols[] = { WEFT_PRIVATE_SYMBOLS(WEFT_TABLE_ENTRY) };
static const int weft_symbol_total = (int)(sizeof(weft_symbols) / sizeof(weft_symbols[0]));

/// What each lookup found, kept apart from the live pointers so a test can
/// take a symbol away and give it back.
static void *weft_resolved_address[sizeof(weft_symbols) / sizeof(weft_symbols[0])];

static void weft_resolve_once(void) {
    void *skylight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL
    );
    for (int i = 0; i < weft_symbol_total; i++) {
        void *found = skylight ? dlsym(skylight, weft_symbols[i].name) : NULL;
        if (found == NULL) found = dlsym(RTLD_DEFAULT, weft_symbols[i].name);
        weft_resolved_address[i] = found;
        *weft_symbols[i].slot = found;
    }
}

static pthread_once_t weft_resolved = PTHREAD_ONCE_INIT;

static void weft_resolve(void) { pthread_once(&weft_resolved, weft_resolve_once); }

// Before main, so no call site ever sees an unfilled pointer and none of them
// has to ask. Initialisers run dependencies first, so the frameworks this
// searches are loaded and initialised by now.
__attribute__((constructor)) static void weft_resolve_at_load(void) { weft_resolve(); }

int weft_private_symbol_count(void) { return weft_symbol_total; }

const char *weft_private_symbol_name(int index) {
    if (index < 0 || index >= weft_symbol_total) return NULL;
    return weft_symbols[index].name;
}

bool weft_private_symbol_present(int index) {
    weft_resolve();
    if (index < 0 || index >= weft_symbol_total) return false;
    return *weft_symbols[index].slot != NULL;
}

bool weft_private_symbol_simulate_missing(const char *name, bool missing) {
    weft_resolve();
    for (int i = 0; i < weft_symbol_total; i++) {
        if (strcmp(weft_symbols[i].name, name) != 0) continue;
        *weft_symbols[i].slot = missing ? NULL : weft_resolved_address[i];
        return true;
    }
    return false;
}
