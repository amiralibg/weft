// Private AX bridge: AXUIElement <-> CGWindowID.
// Not part of SkyLight; lives here so WeftPlatform never needs @_silgen_name.
// Resolved at runtime like everything in SkyLightShim.h, from HIServices.
#pragma once

#include <ApplicationServices/ApplicationServices.h>
#include "SkyLightShim.h"

WEFT_PRIVATE_FN(, AXError, _AXUIElementGetWindow, kAXErrorNotImplemented,
    (AXUIElementRef element, uint32_t *windowID), (element, windowID))
