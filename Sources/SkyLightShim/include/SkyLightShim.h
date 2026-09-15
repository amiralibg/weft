// SkyLightShim — extern decls for private SkyLight / WindowServer symbols.
//
// M1 needs: connection id, window bounds, display→space→window topology.
// M4/M5 symbols (move-to-space, sticky, order, park) are declared now so the
// header is stable; they are only *called* in later milestones.
//
// Verified against macOS 26.5.2 / arm64 in spikes/RESULTS.md (S0–S4).
// No definitions here — linked from /System/Library/PrivateFrameworks/SkyLight.framework.

#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef int32_t SLConnectionID;
typedef uint32_t SLWindowID;
typedef uint64_t SLSpaceID;

// MARK: - M1: read-only world model

extern SLConnectionID SLSMainConnectionID(void);

/// 0 on success. WindowServer-local, microseconds, no app IPC.
extern int32_t SLSGetWindowBounds(SLConnectionID cid, SLWindowID wid, CGRect *rect);

/// Whole world topology in one call: array of display dicts.
/// Each dict: "Display Identifier" (CFString UUID), "Spaces" (array of space dicts
/// with "id64" NSNumber + "windows" array of window-id NSNumbers).
/// Caller owns the returned CFArray (Create rule).
extern CFArrayRef SLSCopyManagedDisplaySpaces(SLConnectionID cid) CF_RETURNS_RETAINED;

/// Active space id for a display UUID string.
extern SLSpaceID SLSManagedDisplayGetCurrentSpace(SLConnectionID cid, CFStringRef displayUUID);

/// Spaces containing each window in `windowIDs`. Returns array of NSNumber (uint64).
/// `mask`: 0x7 (all spaces incl. fullscreen), per spikes/spike.swift.
extern CFArrayRef SLSCopySpacesForWindows(SLConnectionID cid, int32_t mask, CFArrayRef windowIDs) CF_RETURNS_RETAINED;

/// Space kind: 4 = native fullscreen (skip entirely). Microseconds.
extern int32_t SLSSpaceGetType(SLConnectionID cid, SLSpaceID sid);

/// Display UUID string of the display owning the active menu bar — which is
/// the display keyboard focus is on. This is how "the current space" is
/// decided with more than one display attached: SLS order says nothing about
/// where the user is looking. Caller owns the result (Copy rule).
///
/// Known quirk: some releases answer "Main" instead of a real UUID, so
/// callers must fall back to CGMainDisplayID's UUID when the string does not
/// match a known display.
extern CFStringRef SLSCopyActiveMenuBarDisplayIdentifier(SLConnectionID cid) CF_RETURNS_RETAINED;

// MARK: - Multi-display

/// Display UUID owning a space. One round trip; the alternative is parsing
/// the whole SLSCopyManagedDisplaySpaces topology to answer one question.
extern CFStringRef SLSCopyManagedDisplayForSpace(SLConnectionID cid, SLSpaceID sid) CF_RETURNS_RETAINED;

// NOT DECLARED — `SLSSetDisplaySpaceCompatID`.
//
// Moving a whole space to another display (yabai's `space --display`) needs
// the compat-id pair: SLSSpaceSetCompatID tags the space, then
// SLSSetDisplaySpaceCompatID hands that tag to the destination display.
// The first still exports from SkyLight on macOS 26.5.2; **the second does
// not exist at all** (dyld_info -exports, 2026-09-07 — only
// _SLSSpaceGetCompatID and _SLSSpaceSetCompatID remain). Declaring it fails
// the link, so `move space display` reports the absence instead. This is
// what "broken on macOS 26" in the user's skhdrc actually is.

// MARK: - M4/M5 (declared now, used later)

// Park/unpark + scroll fast path. 0.002ms, no AX clamp (see S2/S4).
extern int32_t SLSMoveWindow(SLConnectionID cid, SLWindowID wid, const CGPoint *point);

// Move window to space without changing focused space (see S3). Signatures
// from yabai's scripting-addition payload (MIT — see DESIGN §11.11). NOTE:
// SLSMoveWindowsToManagedSpace returns void — success is verified by
// re-reading SLSCopySpacesForWindows, not by return code.
extern void SLSMoveWindowsToManagedSpace(SLConnectionID cid, CFArrayRef windowIDs, SLSpaceID sid);

// Sticky bit for scratchpads (see S3): bit (1 << 11), tag_size 64.
// Same source; SLSClearWindowTags removes bits.
extern int32_t SLSSetWindowTags(SLConnectionID cid, SLWindowID wid, uint64_t *tags, size_t tagSize);
extern int32_t SLSClearWindowTags(SLConnectionID cid, SLWindowID wid, uint64_t *tags, size_t tagSize);

// Stack rendering: raise active child, z-order only, no AX (see DESIGN §4.1).
// Signature from yabai's scripting-addition payload (MIT — see DESIGN §11.11):
// the 4th parameter is a *relative window id*, not a space. order = 1 orders
// `wid` directly above `relativeWid`.
//
// M3 finding (2026-09-04, macOS 26.5.2): from a regular app connection this
// call fails with rc=1000 for other apps' windows — reordering is a
// privileged operation (clickjacking gate), unlike SLSMoveWindow which works
// (see S4). Stack switches therefore raise via AX until weft-sa (M4) provides
// a Dock-injected connection. Decl kept for the M4 SA path.
extern int32_t SLSOrderWindow(SLConnectionID cid, SLWindowID wid, int32_t order, SLWindowID relativeWid);

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
// is what an interactive drag wants.
extern CFTypeRef SLSTransactionCreate(SLConnectionID cid) CF_RETURNS_RETAINED;
extern int32_t SLSTransactionCommit(CFTypeRef transaction, int32_t synchronous);
extern int32_t SLSTransactionMoveWindowWithGroup(CFTypeRef transaction, SLWindowID wid, CGPoint point);
extern int32_t SLSTransactionOrderWindow(CFTypeRef transaction, SLWindowID wid, int32_t order, SLWindowID relativeWid);

// MARK: - Borders (weft's own windows)
//
// Everything below acts on windows this process creates, so none of it needs
// a scripting addition or any privilege weft does not already have (S5).
// `SLSNewWindow`'s `type` is 2 for a plain buffered window; the region is the
// window's shape in window-local coordinates, and (x, y) places its origin in
// the global, top-left-origin space `SLSGetWindowBounds` reports in.

extern int32_t SLSNewWindow(SLConnectionID cid, int32_t type, float x, float y,
                            CFTypeRef region, SLWindowID *outWID);
extern int32_t SLSReleaseWindow(SLConnectionID cid, SLWindowID wid);
extern int32_t SLSSetWindowShape(SLConnectionID cid, SLWindowID wid, float x, float y, CFTypeRef region);
extern int32_t SLSSetWindowResolution(SLConnectionID cid, SLWindowID wid, double resolution);
extern int32_t SLSSetWindowOpacity(SLConnectionID cid, SLWindowID wid, bool opaque);
extern int32_t SLSSetWindowLevel(SLConnectionID cid, SLWindowID wid, int32_t level);
extern int32_t SLSGetWindowLevel(SLConnectionID cid, SLWindowID wid, int32_t *outLevel);
/// Drawing surface for one of our own windows. Returns a retained CGContext.
extern CGContextRef SLWindowContextCreate(SLConnectionID cid, SLWindowID wid, CFDictionaryRef options) CF_RETURNS_RETAINED;

// Region helpers live in CoreGraphics, not SkyLight, and are in no public
// header. Only BorderShim.h calls them; see there for why.
extern int32_t CGSNewRegionWithRectList(const CGRect *rects, int count, CFTypeRef *outRegion);
extern int32_t CGSReleaseRegion(CFTypeRef region);

#include "BorderShim.h"
#include "AXBridge.h"
