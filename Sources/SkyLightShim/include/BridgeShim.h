// BridgeShim — SkyLight's bridged window-management operations: moving
// another app's windows between desktops, and switching a display's desktop
// (docs/NATIVE.md, spikes/RESULTS.md S10–S12).
//
// Each operation is an Objective-C object (`SLSBridged…Operation`) handed to a
// perform function that SkyLight does not export. The two perform functions
// are C++ statics found by walking SkyLight's in-memory symbol table, the way
// yabai 7.1.25 does; they sit in the shim's symbol table with every other
// private call, so `weft_private_symbol_present` reports them and
// `WEFT_PUBLIC_ONLY` turns them off.
//
// Nothing here says whether an operation did anything. The perform function's
// return value is a pointer-shaped number that means nothing (S10), so these
// return only whether an operation was submitted, and every caller reads the
// result back from the WindowServer (Bridge.swift).

#pragma once

#include "SkyLightShim.h"

/// NULL when this macOS has everything the bridge uses: both perform
/// functions and every operation class. Otherwise the name of the first piece
/// missing, for a report.
const char *weft_bridge_missing(void);

/// Submit one move of `count` windows to desktop `sid`. True when submitted,
/// never "moved": read each window's desktop back.
bool weft_bridge_move_windows(const SLWindowID *wids, int count, SLSpaceID sid);

/// Submit a switch of `display` from `from` to `to`: show `to`, hide `from`,
/// make `to` the display's current desktop, in that order. Setting the current
/// desktop alone leaves the old one on the glass (S11). True when submitted,
/// never "switched": read the display's current desktop back.
bool weft_bridge_switch(CFStringRef display, SLSpaceID from, SLSpaceID to);
