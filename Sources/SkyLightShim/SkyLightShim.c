// The loader for SkyLightShim.h: one pointer per private symbol, filled by
// name before main runs.
//
// SkyLight is opened by path and searched first; anything not there (the
// CoreGraphics region helpers, HIServices' `_AXUIElementGetWindow`) comes from
// the images already loaded. SkyLight is itself already loaded by then —
// CoreGraphics and AppKit depend on it — so the dlopen only hands back a
// handle, it does not load anything.
//
// Two entries are not exported at all: the bridged perform functions
// (BridgeShim.h) are C++ statics, and are found by walking SkyLight's symbol
// table in memory instead (`weft_macho_find_symbol`).

#include "SkyLightShim.h"
#include "AXBridge.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
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
    X(SLSSetWindowTags)                          \
    X(SLSOrderWindow)                            \
    X(SLSTransactionCreate)                      \
    X(SLSTransactionCommit)                      \
    X(SLSTransactionMoveWindowWithGroup)         \
    X(SLSTransactionOrderWindow)                 \
    X(SLSNewWindow)                              \
    X(SLSReleaseWindow)                          \
    X(CGSNewRegionWithRectList)                  \
    X(CGSReleaseRegion)                          \
    X(_AXUIElementGetWindow)

#define WEFT_DEFINE_POINTER(name) weft_##name##_fn weft_p_##name = NULL;
WEFT_PRIVATE_SYMBOLS(WEFT_DEFINE_POINTER)

/// The bridged perform functions; Bridge.c calls them.
void *weft_p_bridge_perform_async = NULL;
void *weft_p_bridge_perform_sync = NULL;

typedef struct {
    const char *name;
    void **slot;
    /// The symbol-table name to walk for, when `name` is not exported.
    const char *walk;
} weft_symbol;

#define WEFT_TABLE_ENTRY(name) { #name, (void **)&weft_p_##name, NULL },
static weft_symbol weft_symbols[] = {
    WEFT_PRIVATE_SYMBOLS(WEFT_TABLE_ENTRY)
    { "SLSPerformAsynchronousBridgedWindowManagementOperation", &weft_p_bridge_perform_async,
      "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation" },
    { "_SLSPerformSynchronousBridgedWindowManagementOperation", &weft_p_bridge_perform_sync,
      "__ZL54_SLSPerformSynchronousBridgedWindowManagementOperationP46SLSSynchronousBridgedWindowManagementOperation" },
};
static const int weft_symbol_total = (int)(sizeof(weft_symbols) / sizeof(weft_symbols[0]));

/// What each lookup found, kept apart from the live pointers so a test can
/// take a symbol away and give it back.
static void *weft_resolved_address[sizeof(weft_symbols) / sizeof(weft_symbols[0])];

/// The address of a symbol in SkyLight's own symbol table, exported or not:
/// yabai's `macho_find_symbol`. SkyLight lives in the shared cache, whose
/// __LINKEDIT is mapped, so the table is read in place. Each name passed here
/// is looked up once per process.
static void *weft_macho_find_symbol(const char *symbol) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *image = _dyld_get_image_name(i);
        if (image == NULL || strstr(image, "/SkyLight.framework/") == NULL) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (header == NULL || header->magic != MH_MAGIC_64) return NULL;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *symtab = NULL;
        const uint8_t *cursor = (const uint8_t *)(header + 1);
        for (uint32_t c = 0; c < header->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cursor;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                if (strncmp(seg->segname, SEG_LINKEDIT, sizeof(seg->segname)) == 0) linkedit = seg;
            } else if (lc->cmd == LC_SYMTAB) {
                symtab = (const struct symtab_command *)lc;
            }
            cursor += lc->cmdsize;
        }
        if (linkedit == NULL || symtab == NULL) return NULL;
        uintptr_t base = (uintptr_t)(linkedit->vmaddr - linkedit->fileoff) + (uintptr_t)slide;
        const char *strings = (const char *)(base + symtab->stroff);
        const struct nlist_64 *syms = (const struct nlist_64 *)(base + symtab->symoff);
        for (uint32_t s = 0; s < symtab->nsyms; s++) {
            uint32_t strx = syms[s].n_un.n_strx;
            if (strx == 0 || strx >= symtab->strsize) continue;
            if (strcmp(strings + strx, symbol) == 0 && syms[s].n_value != 0) {
                return (void *)(syms[s].n_value + (uintptr_t)slide);
            }
        }
        return NULL;
    }
    return NULL;
}

static void weft_resolve_once(void) {
    void *skylight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL
    );
    for (int i = 0; i < weft_symbol_total; i++) {
        void *found = NULL;
        if (weft_symbols[i].walk != NULL) {
            found = weft_macho_find_symbol(weft_symbols[i].walk);
        } else {
            found = skylight ? dlsym(skylight, weft_symbols[i].name) : NULL;
            if (found == NULL) found = dlsym(RTLD_DEFAULT, weft_symbols[i].name);
        }
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

bool weft_private_symbol_present_named(const char *name) {
    weft_resolve();
    for (int i = 0; i < weft_symbol_total; i++) {
        if (strcmp(weft_symbols[i].name, name) == 0) return *weft_symbols[i].slot != NULL;
    }
    return false;
}
