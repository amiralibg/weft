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

#include "AXBridge.h"
