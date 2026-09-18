#pragma once
#include <ApplicationServices/ApplicationServices.h>

bool BareTabWindowIDAvailable(void);
AXError BareTabWindowID(AXUIElementRef element, CGWindowID *windowID);

/// Brings a window to the front at the WindowServer level, without a round trip to its app.
/// Returns false if the private functions are unavailable; callers then fall back to AppKit activation.
bool BareTabBringWindowToFront(pid_t pid, CGWindowID windowID);
