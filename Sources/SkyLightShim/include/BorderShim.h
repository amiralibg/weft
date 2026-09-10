// BorderShim — the two SkyLight calls that need a CoreFoundation region.
//
// A `CGSRegionRef` is an unannotated CF type crossing a private API, and Swift
// has no way to know who owns one. Rather than guess at the bridging rule for
// an out-parameter on every macOS release, the region is created, used and
// released here, in C, and never crosses into Swift at all.

#pragma once

#include "SkyLightShim.h"

/// Create an overlay window covering `frame`. 0 on success; `outWID` is only
/// meaningful then.
static inline int32_t weft_border_window_create(
    SLConnectionID cid, CGRect frame, SLWindowID *outWID
) {
    CGRect local = CGRectMake(0, 0, frame.size.width, frame.size.height);
    CFTypeRef region = NULL;
    if (CGSNewRegionWithRect(&local, &region) != 0 || region == NULL) return -1;
    int32_t err = SLSNewWindow(
        cid, 2, (float)frame.origin.x, (float)frame.origin.y, region, outWID
    );
    CGSReleaseRegion(region);
    return err;
}

/// Move and resize an existing overlay window, in one call.
///
/// `SLSSetWindowShape`'s (x, y) is the window's *global* origin, not an offset
/// within it — passing 0,0 to "just resize" teleports the window to the corner
/// of the main display for a frame before the follow-up move puts it back.
static inline int32_t weft_border_window_set_frame(
    SLConnectionID cid, SLWindowID wid, CGRect frame
) {
    CGRect local = CGRectMake(0, 0, frame.size.width, frame.size.height);
    CFTypeRef region = NULL;
    if (CGSNewRegionWithRect(&local, &region) != 0 || region == NULL) return -1;
    int32_t err = SLSSetWindowShape(
        cid, wid, (float)frame.origin.x, (float)frame.origin.y, region
    );
    CGSReleaseRegion(region);
    return err;
}
