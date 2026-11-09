// mdinstall: install a signed .app on a USB-connected iOS device through
// MobileDevice.framework's installation_proxy (the same channel Finder uses).
// This path does not need a Developer Disk Image.
// Usage: mdinstall <udid> <path/to/App.app>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef void *AMDeviceRef;
typedef struct {
    AMDeviceRef device;
    unsigned int msg;          // 1 = connected
    void *subscription;
} am_notification_info;

typedef void (*notif_cb)(am_notification_info *, void *);
typedef int (*progress_cb)(CFDictionaryRef, int);

static int (*AMDeviceNotificationSubscribe)(notif_cb, unsigned int, unsigned int, void *, void **);
static int (*AMDeviceConnect)(AMDeviceRef);
static int (*AMDeviceIsPaired)(AMDeviceRef);
static int (*AMDeviceValidatePairing)(AMDeviceRef);
static int (*AMDeviceStartSession)(AMDeviceRef);
static int (*AMDeviceStopSession)(AMDeviceRef);
static int (*AMDeviceDisconnect)(AMDeviceRef);
static CFStringRef (*AMDeviceCopyDeviceIdentifier)(AMDeviceRef);
static int (*AMDeviceGetInterfaceType)(AMDeviceRef);
static int (*AMDeviceSecureTransferPath)(int, AMDeviceRef, CFURLRef, CFDictionaryRef, progress_cb, int);
static int (*AMDeviceSecureInstallApplication)(int, AMDeviceRef, CFURLRef, CFDictionaryRef, progress_cb, int);
static CFStringRef (*AMDCopyErrorText)(int);

static const char *g_udid;
static const char *g_app;
static int g_started = 0;
static int g_result = 1;

static void print_err(const char *step, int rc) {
    char buf[512] = "";
    if (AMDCopyErrorText) {
        CFStringRef s = AMDCopyErrorText(rc);
        if (s) { CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(s); }
    }
    fprintf(stderr, "%s failed: 0x%x %s\n", step, (unsigned)rc, buf);
}

static int progress(CFDictionaryRef d, int arg) {
    char status[256] = "";
    int pct = -1;
    CFStringRef s = CFDictionaryGetValue(d, CFSTR("Status"));
    CFNumberRef p = CFDictionaryGetValue(d, CFSTR("PercentComplete"));
    if (s) CFStringGetCString(s, status, sizeof status, kCFStringEncodingUTF8);
    if (p) CFNumberGetValue(p, kCFNumberSInt32Type, &pct);
    printf("  [%s] %s %d%%\n", arg == 1 ? "transfer" : "install", status, pct);
    fflush(stdout);
    return 0;
}

static int open_session(AMDeviceRef dev) {
    int rc;
    if ((rc = AMDeviceConnect(dev))) { print_err("AMDeviceConnect", rc); return rc; }
    if (!AMDeviceIsPaired(dev)) { fprintf(stderr, "device is not paired with this Mac\n"); AMDeviceDisconnect(dev); return 1; }
    if ((rc = AMDeviceValidatePairing(dev))) { print_err("AMDeviceValidatePairing", rc); AMDeviceDisconnect(dev); return rc; }
    if ((rc = AMDeviceStartSession(dev))) { print_err("AMDeviceStartSession", rc); AMDeviceDisconnect(dev); return rc; }
    return 0;
}

static void close_session(AMDeviceRef dev) {
    AMDeviceStopSession(dev);
    AMDeviceDisconnect(dev);
}

static void on_device(am_notification_info *info, void *ctx) {
    (void)ctx;
    if (info->msg != 1 || g_started) return;
    AMDeviceRef dev = info->device;

    char udid[128] = "";
    CFStringRef ident = AMDeviceCopyDeviceIdentifier(dev);
    if (ident) { CFStringGetCString(ident, udid, sizeof udid, kCFStringEncodingUTF8); CFRelease(ident); }
    if (strcmp(udid, g_udid) != 0) return;
    if (AMDeviceGetInterfaceType && AMDeviceGetInterfaceType(dev) != 1) return;  // USB only
    g_started = 1;
    printf("found %s over USB\n", udid);
    fflush(stdout);

    CFStringRef path = CFStringCreateWithCString(NULL, g_app, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, true);
    const void *keys[] = { CFSTR("PackageType") };
    const void *vals[] = { CFSTR("Developer") };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    int rc = open_session(dev);
    if (!rc) {
        rc = AMDeviceSecureTransferPath(0, dev, url, opts, progress, 1);
        if (rc) print_err("AMDeviceSecureTransferPath", rc);
        close_session(dev);
    }
    if (!rc) {
        rc = open_session(dev);
        if (!rc) {
            rc = AMDeviceSecureInstallApplication(0, dev, url, opts, progress, 2);
            if (rc) print_err("AMDeviceSecureInstallApplication", rc);
            close_session(dev);
        }
    }
    if (!rc) printf("install finished\n");
    g_result = rc ? 1 : 0;

    CFRelease(opts);
    CFRelease(url);
    CFRelease(path);
    CFRunLoopStop(CFRunLoopGetMain());
}

#define LOAD(name) do { *(void **)(&name) = dlsym(h, #name); \
    if (!name) { fprintf(stderr, "missing symbol %s\n", #name); return 1; } } while (0)

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s <udid> <App.app>\n", argv[0]); return 2; }
    g_udid = argv[1];
    g_app = argv[2];

    const char *paths[] = {
        "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
        "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
        NULL };
    void *h = NULL;
    for (int i = 0; paths[i] && !h; i++) h = dlopen(paths[i], RTLD_NOW);
    if (!h) { fprintf(stderr, "cannot load MobileDevice.framework: %s\n", dlerror()); return 1; }

    LOAD(AMDeviceNotificationSubscribe);
    LOAD(AMDeviceConnect);
    LOAD(AMDeviceIsPaired);
    LOAD(AMDeviceValidatePairing);
    LOAD(AMDeviceStartSession);
    LOAD(AMDeviceStopSession);
    LOAD(AMDeviceDisconnect);
    LOAD(AMDeviceCopyDeviceIdentifier);
    LOAD(AMDeviceSecureTransferPath);
    LOAD(AMDeviceSecureInstallApplication);
    *(void **)(&AMDeviceGetInterfaceType) = dlsym(h, "AMDeviceGetInterfaceType");
    *(void **)(&AMDCopyErrorText) = dlsym(h, "AMDCopyErrorText");

    void *sub = NULL;
    int rc = AMDeviceNotificationSubscribe(on_device, 0, 0, NULL, &sub);
    if (rc) { print_err("AMDeviceNotificationSubscribe", rc); return 1; }

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 30, false);
    if (!g_started) { fprintf(stderr, "device %s not found over USB within 30 s\n", g_udid); return 1; }
    return g_result;
}
