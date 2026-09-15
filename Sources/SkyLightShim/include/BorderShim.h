// BorderShim — the SkyLight calls that take a CoreFoundation region.
//
// A region is an unannotated CF type crossing a private API, and Swift cannot
// know who owns one handed back through an out-parameter (releasing it from
// Swift as well is a double free). So a region is created, used and released
// here, in C, and never crosses into Swift.
//
// Shapes are lists of rects in window-local coordinates. A border's window is
// shaped to the ring, not the rectangle it bounds: the compositor only blends
// where a window's shape is, so the app window underneath redraws without our
// window being part of that work.

#pragma once

#include "SkyLightShim.h"

static inline CFTypeRef weft_region_from_rects(const CGRect *rects, int count) {
    CFTypeRef region = NULL;
    if (count <= 0 || CGSNewRegionWithRectList(rects, count, &region) != 0) return NULL;
    return region;
}

/// A window at global `origin`, shaped to `rects`. 0 on success; `outWID` is
/// only meaningful then.
static inline int32_t weft_border_window_create(
    SLConnectionID cid, CGPoint origin, const CGRect *rects, int count, SLWindowID *outWID
) {
    CFTypeRef region = weft_region_from_rects(rects, count);
    if (region == NULL) return -1;
    int32_t err = SLSNewWindow(cid, 2, (float)origin.x, (float)origin.y, region, outWID);
    CGSReleaseRegion(region);
    return err;
}

/// Move and reshape a window in one call.
///
/// `SLSSetWindowShape`'s (x, y) is the window's *global* origin, not an offset
/// within it — passing 0,0 to "just resize" teleports the window to the corner
/// of the main display for a frame before a follow-up move puts it back.
static inline int32_t weft_border_window_set_shape(
    SLConnectionID cid, SLWindowID wid, CGPoint origin, const CGRect *rects, int count
) {
    CFTypeRef region = weft_region_from_rects(rects, count);
    if (region == NULL) return -1;
    int32_t err = SLSSetWindowShape(cid, wid, (float)origin.x, (float)origin.y, region);
    CGSReleaseRegion(region);
    return err;
}
