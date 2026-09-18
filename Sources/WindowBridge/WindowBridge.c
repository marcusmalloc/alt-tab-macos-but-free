#include "WindowBridge.h"
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

// macOS has no public way to map an Accessibility element to its WindowServer ID, nor to bring
// another app's window forward without waiting for that app. Both come from private functions in
// HIServices and SkyLight. They are resolved once at runtime and everything fails closed if a
// future macOS removes them.

typedef AXError (*WindowIDFunction)(AXUIElementRef, CGWindowID *);
typedef CGError (*SetFrontProcessFunction)(ProcessSerialNumber *, CGWindowID, uint32_t);
typedef CGError (*PostEventRecordFunction)(ProcessSerialNumber *, uint8_t *);

static WindowIDFunction windowID;
static SetFrontProcessFunction setFrontProcess;
static PostEventRecordFunction postEventRecord;
static pthread_once_t resolveOnce = PTHREAD_ONCE_INIT;

static void resolve(void) {
    windowID = (WindowIDFunction)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    setFrontProcess = (SetFrontProcessFunction)dlsym(RTLD_DEFAULT, "_SLPSSetFrontProcessWithOptions");
    postEventRecord = (PostEventRecordFunction)dlsym(RTLD_DEFAULT, "SLPSPostEventRecordTo");
}

bool BareTabWindowIDAvailable(void) {
    pthread_once(&resolveOnce, resolve);
    return windowID != NULL;
}

AXError BareTabWindowID(AXUIElementRef element, CGWindowID *outWindowID) {
    if (!BareTabWindowIDAvailable()) return kAXErrorNotImplemented;
    return windowID(element, outWindowID);
}

bool BareTabBringWindowToFront(pid_t pid, CGWindowID window) {
    pthread_once(&resolveOnce, resolve);
    if (setFrontProcess == NULL || postEventRecord == NULL) return false;

    ProcessSerialNumber psn;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (GetProcessForPID(pid, &psn) != noErr) return false;
#pragma clang diagnostic pop

    // kCPSUserGenerated: treat the switch as if the user had clicked the window.
    const uint32_t userGenerated = 0x200;
    if (setFrontProcess(&psn, window, userGenerated) != kCGErrorSuccess) return false;

    // The "window activated" event pair the Dock posts, so the window becomes key and not merely
    // front. The layout is undocumented; the offsets are the ones the Dock has used for years.
    for (uint8_t type = 1; type <= 2; type++) {
        uint8_t record[0xf8] = {0};
        record[0x04] = 0xF8;
        record[0x08] = type;
        record[0x3a] = 0x10;
        memset(&record[0x20], 0xFF, 0x10);
        memcpy(&record[0x3c], &window, sizeof window);
        postEventRecord(&psn, record);
    }
    return true;
}
