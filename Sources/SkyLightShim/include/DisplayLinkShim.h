// DisplayLinkShim — a frame clock for the placement animator.
//
// The glide steps once per compositor refresh of the display it runs on, on
// that display's own clock: a timer that merely runs at about the refresh
// rate drifts against it, and every drift is a frame shown twice or skipped,
// which reads as judder. CVDisplayLink is that clock. It is deprecated in
// Swift from macOS 15 in favour of a CADisplayLink, which needs a view or a
// screen object and the main run loop; weftd has neither to spare, so the
// link lives here, with its deprecation contained to one file.

#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

typedef struct weft_display_link weft_display_link;

/// Called on the link's own high-priority thread, once per refresh of
/// `display`.
typedef void (*weft_display_link_fn)(void *context, uint32_t display);

/// Start a link on `display`. NULL when CoreVideo has no link for it.
weft_display_link *weft_display_link_start(
    CGDirectDisplayID display, weft_display_link_fn fn, void *context
);

/// Stop and free. Blocks until a callback in progress has returned, so never
/// call it from inside the callback.
void weft_display_link_stop(weft_display_link *link);
