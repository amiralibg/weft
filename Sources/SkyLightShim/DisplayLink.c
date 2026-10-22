// The frame clock (DisplayLinkShim.h).

#include "DisplayLinkShim.h"

#include <CoreVideo/CoreVideo.h>
#include <stdlib.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

struct weft_display_link {
    CVDisplayLinkRef link;
    weft_display_link_fn fn;
    void *context;
    uint32_t display;
};

static CVReturn weft_display_link_tick(
    CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *output,
    CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *info
) {
    (void)link; (void)now; (void)output; (void)flagsIn; (void)flagsOut;
    struct weft_display_link *l = info;
    l->fn(l->context, l->display);
    return kCVReturnSuccess;
}

weft_display_link *weft_display_link_start(
    CGDirectDisplayID display, weft_display_link_fn fn, void *context
) {
    struct weft_display_link *l = calloc(1, sizeof(*l));
    if (l == NULL) return NULL;
    l->fn = fn;
    l->context = context;
    l->display = display;
    if (CVDisplayLinkCreateWithCGDisplay(display, &l->link) != kCVReturnSuccess || l->link == NULL) {
        free(l);
        return NULL;
    }
    CVDisplayLinkSetOutputCallback(l->link, weft_display_link_tick, l);
    if (CVDisplayLinkStart(l->link) != kCVReturnSuccess) {
        CVDisplayLinkRelease(l->link);
        free(l);
        return NULL;
    }
    return l;
}

void weft_display_link_stop(weft_display_link *l) {
    if (l == NULL) return;
    CVDisplayLinkStop(l->link);
    CVDisplayLinkRelease(l->link);
    free(l);
}

#pragma clang diagnostic pop
