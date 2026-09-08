// Private AX bridge: AXUIElement <-> CGWindowID.
// Not part of SkyLight; lives here so WeftPlatform never needs @_silgen_name.
#pragma once

#include <ApplicationServices/ApplicationServices.h>

extern AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *windowID);
