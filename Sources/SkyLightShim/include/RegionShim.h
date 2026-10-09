// RegionShim — the SkyLight calls that take a CoreFoundation region.
//
// A region is an unannotated CF type crossing a private API, and Swift cannot
// know who owns one handed back through an out-parameter (releasing it from
// Swift as well is a double free). So a region is created, used and released
// here, in C, and never crosses into Swift.
//
// Only the private-API self-test uses this: it creates one 1×1 window of its
// own, off every display, to prove moves and transactions land (PrivateAPI).

#pragma once

#include "SkyLightShim.h"

static inline CFTypeRef weft_region_from_rects(const CGRect *rects, int count) {
    CFTypeRef region = NULL;
    if (count <= 0 || CGSNewRegionWithRectList(rects, count, &region) != 0) return NULL;
    return region;
}

/// A window of this process's own at global `origin`, shaped to `rects`.
/// 0 on success; `outWID` is only meaningful then.
static inline int32_t weft_region_window_create(
    SLConnectionID cid, CGPoint origin, const CGRect *rects, int count, SLWindowID *outWID
) {
    CFTypeRef region = weft_region_from_rects(rects, count);
    if (region == NULL) return -1;
    int32_t err = SLSNewWindow(cid, 2, (float)origin.x, (float)origin.y, region, outWID);
    CGSReleaseRegion(region);
    return err;
}
