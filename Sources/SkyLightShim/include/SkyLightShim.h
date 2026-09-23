// SkyLightShim — private SkyLight / WindowServer symbols, resolved at runtime.
//
// Nothing here is linked. Every private function is looked up by name once,
// when the process loads (SkyLightShim.c), and called through a pointer. The
// Swift side calls the same names it always has: each one below is a static
// inline wrapper that forwards to the pointer, or returns the declared
// fallback when the symbol was not found.
//
// Why: these used to be strong `extern`s linked with `-framework SkyLight`,
// and dyld refuses to load a binary with a single unresolved strong symbol.
// One function removed in a macOS update — even one only a rarely used
// command calls — stopped weftd from launching at all. Now it costs exactly
// the feature that uses it, which is already written to cope with the call
// failing (REDESIGN.md, phase 1).
//
// Fallbacks are chosen so a missing symbol reads as an ordinary failure:
// `kCGErrorNotImplemented` for status codes, 0 for ids, NULL for objects,
// nothing at all for void. `weft_private_symbol_*` below says which ones
// resolved; `PrivateAPI.swift` turns that into a report and a self-test.
//
// Verified against macOS 26.5.2 and 27.0 / arm64 in spikes/RESULTS.md.

#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>

typedef int32_t SLConnectionID;
typedef uint32_t SLWindowID;
typedef uint64_t SLSpaceID;

/// Declares one private function: a pointer the loader fills, and an inline
/// wrapper with the function's own name that calls it or returns `fallback`.
/// `attrs` carries ownership annotations, which have to sit on the wrapper
/// because that is the declaration Swift imports.
#define WEFT_PRIVATE_FN(attrs, ret, name, fallback, params, args) \
    typedef ret (*weft_##name##_fn) params;                      \
    extern weft_##name##_fn weft_p_##name;                       \
    static inline attrs ret name params {                        \
        weft_##name##_fn f = weft_p_##name;                      \
        return f ? f args : (fallback);                          \
    }

#define WEFT_PRIVATE_VOID(name, params, args) \
    typedef void (*weft_##name##_fn) params;  \
    extern weft_##name##_fn weft_p_##name;    \
    static inline void name params {          \
        weft_##name##_fn f = weft_p_##name;   \
        if (f) f args;                        \
    }

#define WEFT_RETAINED __attribute__((cf_returns_retained))
#define WEFT_MISSING ((int32_t)kCGErrorNotImplemented)

// MARK: - Which symbols resolved

/// How many private symbols weft knows about, and for each one its name and
/// whether this macOS exports it. Indices are stable within one build only.
int weft_private_symbol_count(void);
const char *weft_private_symbol_name(int index);
bool weft_private_symbol_present(int index);
/// Tests only: act as if this macOS did not export `name` (or undo that).
/// False when weft has no symbol by that name.
bool weft_private_symbol_simulate_missing(const char *name, bool missing);

// MARK: - M1: read-only world model

WEFT_PRIVATE_FN(, SLConnectionID, SLSMainConnectionID, 0, (void), ())

/// 0 on success. WindowServer-local, microseconds, no app IPC.
WEFT_PRIVATE_FN(, int32_t, SLSGetWindowBounds, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid, CGRect *rect), (cid, wid, rect))

/// Whole world topology in one call: array of display dicts.
/// Each dict: "Display Identifier" (CFString UUID), "Spaces" (array of space dicts
/// with "id64" NSNumber + "windows" array of window-id NSNumbers).
/// Caller owns the returned CFArray (Create rule).
WEFT_PRIVATE_FN(WEFT_RETAINED, CFArrayRef, SLSCopyManagedDisplaySpaces, NULL,
    (SLConnectionID cid), (cid))

/// Active space id for a display UUID string.
WEFT_PRIVATE_FN(, SLSpaceID, SLSManagedDisplayGetCurrentSpace, 0,
    (SLConnectionID cid, CFStringRef displayUUID), (cid, displayUUID))

/// Spaces containing each window in `windowIDs`. Returns array of NSNumber (uint64).
/// `mask`: 0x7 (all spaces incl. fullscreen), per spikes/spike.swift.
WEFT_PRIVATE_FN(WEFT_RETAINED, CFArrayRef, SLSCopySpacesForWindows, NULL,
    (SLConnectionID cid, int32_t mask, CFArrayRef windowIDs), (cid, mask, windowIDs))

/// Space kind: 4 = native fullscreen (skip entirely). Microseconds.
/// Missing reads as 0, an ordinary desktop.
WEFT_PRIVATE_FN(, int32_t, SLSSpaceGetType, 0,
    (SLConnectionID cid, SLSpaceID sid), (cid, sid))

/// Display UUID string of the display owning the active menu bar — which is
/// the display keyboard focus is on. This is how "the current space" is
/// decided with more than one display attached: SLS order says nothing about
/// where the user is looking. Caller owns the result (Copy rule).
///
/// Known quirk: some releases answer "Main" instead of a real UUID, so
/// callers must fall back to CGMainDisplayID's UUID when the string does not
/// match a known display.
WEFT_PRIVATE_FN(WEFT_RETAINED, CFStringRef, SLSCopyActiveMenuBarDisplayIdentifier, NULL,
    (SLConnectionID cid), (cid))

// MARK: - Multi-display

/// Display UUID owning a space. One round trip; the alternative is parsing
/// the whole SLSCopyManagedDisplaySpaces topology to answer one question.
WEFT_PRIVATE_FN(WEFT_RETAINED, CFStringRef, SLSCopyManagedDisplayForSpace, NULL,
    (SLConnectionID cid, SLSpaceID sid), (cid, sid))

// NOT DECLARED — `SLSSetDisplaySpaceCompatID`.
//
// Moving a whole space to another display (yabai's `space --display`) needs
// the compat-id pair: SLSSpaceSetCompatID tags the space, then
// SLSSetDisplaySpaceCompatID hands that tag to the destination display.
// The first still exports from SkyLight on macOS 26.5.2; **the second does
// not exist at all** (dyld_info -exports, 2026-09-07 — only
// _SLSSpaceGetCompatID and _SLSSpaceSetCompatID remain). When these were
// linked, declaring it failed the link; `move space display` reports the
// absence instead. This is what "broken on macOS 26" in the user's skhdrc
// actually is.

// MARK: - M4/M5

// Park/unpark + scroll fast path. 0.002ms, no AX clamp (see S2/S4).
WEFT_PRIVATE_FN(, int32_t, SLSMoveWindow, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid, const CGPoint *point), (cid, wid, point))

// Move window to space without changing focused space (see S3). Signatures
// from yabai's scripting-addition payload (MIT — see DESIGN §11.11). NOTE:
// SLSMoveWindowsToManagedSpace returns void — success is verified by
// re-reading SLSCopySpacesForWindows, not by return code.
WEFT_PRIVATE_VOID(SLSMoveWindowsToManagedSpace,
    (SLConnectionID cid, CFArrayRef windowIDs, SLSpaceID sid), (cid, windowIDs, sid))

// Sticky bit for scratchpads (see S3): bit (1 << 11), tag_size 64.
// Same source; SLSClearWindowTags removes bits.
WEFT_PRIVATE_FN(, int32_t, SLSSetWindowTags, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid, uint64_t *tags, size_t tagSize), (cid, wid, tags, tagSize))
WEFT_PRIVATE_FN(, int32_t, SLSClearWindowTags, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid, uint64_t *tags, size_t tagSize), (cid, wid, tags, tagSize))

// Stack rendering: raise active child, z-order only, no AX (see DESIGN §4.1).
// Signature from yabai's scripting-addition payload (MIT — see DESIGN §11.11):
// the 4th parameter is a *relative window id*, not a space. order = 1 orders
// `wid` directly above `relativeWid`.
//
// M3 finding (2026-09-04, macOS 26.5.2): from a regular app connection this
// call fails with rc=1000 for other apps' windows — reordering is a
// privileged operation (clickjacking gate), unlike SLSMoveWindow which works
// (see S4). Ordering weft's *own* windows relative to another app's is
// allowed (S6), which is what the border renderer uses it for.
WEFT_PRIVATE_FN(, int32_t, SLSOrderWindow, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid, int32_t order, SLWindowID relativeWid),
    (cid, wid, order, relativeWid))

// MARK: - Atomic multi-window moves

// A tiling change moves several windows at once, and issuing them as
// individual `SLSMoveWindow` calls means the WindowServer composites each one
// on whatever frame it happens to land in: the windows visibly arrive one
// after another, which is the tearing you see as a "jump" when a bsp divider
// is dragged or a space is retiled. A transaction batches the moves and
// commits them together, so they all appear on the same frame.
//
// Signatures from yabai's animation path (MIT — see DESIGN §11.11).
// `SLSTransactionCommit`'s second argument is a synchronous flag; 0 (async)
// is what an interactive drag wants. Its return value is not an error code
// (S6), so a missing symbol's fallback is only ever compared against by
// nobody.
WEFT_PRIVATE_FN(WEFT_RETAINED, CFTypeRef, SLSTransactionCreate, NULL,
    (SLConnectionID cid), (cid))
WEFT_PRIVATE_FN(, int32_t, SLSTransactionCommit, WEFT_MISSING,
    (CFTypeRef transaction, int32_t synchronous), (transaction, synchronous))
WEFT_PRIVATE_FN(, int32_t, SLSTransactionMoveWindowWithGroup, WEFT_MISSING,
    (CFTypeRef transaction, SLWindowID wid, CGPoint point), (transaction, wid, point))
WEFT_PRIVATE_FN(, int32_t, SLSTransactionOrderWindow, WEFT_MISSING,
    (CFTypeRef transaction, SLWindowID wid, int32_t order, SLWindowID relativeWid),
    (transaction, wid, order, relativeWid))

// MARK: - Borders (weft's own windows)
//
// Everything below acts on windows this process creates, so none of it needs
// a scripting addition or any privilege weft does not already have (S5).
// `SLSNewWindow`'s `type` is 2 for a plain buffered window; the region is the
// window's shape in window-local coordinates, and (x, y) places its origin in
// the global, top-left-origin space `SLSGetWindowBounds` reports in.

WEFT_PRIVATE_FN(, int32_t, SLSNewWindow, WEFT_MISSING,
    (SLConnectionID cid, int32_t type, float x, float y, CFTypeRef region, SLWindowID *outWID),
    (cid, type, x, y, region, outWID))
WEFT_PRIVATE_FN(, int32_t, SLSReleaseWindow, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid), (cid, wid))
WEFT_PRIVATE_FN(, int32_t, SLSSetWindowShape, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid, float x, float y, CFTypeRef region),
    (cid, wid, x, y, region))
WEFT_PRIVATE_FN(, int32_t, SLSSetWindowResolution, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid, double resolution), (cid, wid, resolution))
WEFT_PRIVATE_FN(, int32_t, SLSSetWindowOpacity, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid, bool opaque), (cid, wid, opaque))
WEFT_PRIVATE_FN(, int32_t, SLSSetWindowLevel, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid, int32_t level), (cid, wid, level))
WEFT_PRIVATE_FN(, int32_t, SLSGetWindowLevel, WEFT_MISSING,
    (SLConnectionID cid, SLWindowID wid, int32_t *outLevel), (cid, wid, outLevel))
/// Drawing surface for one of our own windows. Returns a retained CGContext.
WEFT_PRIVATE_FN(WEFT_RETAINED, CGContextRef, SLWindowContextCreate, NULL,
    (SLConnectionID cid, SLWindowID wid, CFDictionaryRef options), (cid, wid, options))

// Region helpers live in CoreGraphics, not SkyLight, and are in no public
// header. Only BorderShim.h calls them; see there for why.
WEFT_PRIVATE_FN(, int32_t, CGSNewRegionWithRectList, WEFT_MISSING,
    (const CGRect *rects, int count, CFTypeRef *outRegion), (rects, count, outRegion))
WEFT_PRIVATE_FN(, int32_t, CGSReleaseRegion, WEFT_MISSING,
    (CFTypeRef region), (region))

#include "BorderShim.h"
#include "AXBridge.h"
