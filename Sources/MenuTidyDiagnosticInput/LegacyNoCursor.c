#include "MenuTidyDiagnosticInput.h"
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>
#include <sys/sysctl.h>

int32_t MenuTidyDiagnosticLegacyMouseButton(double x, double y, bool down) {
    // Use the public C declaration, including its varargs calling convention.
    // The API is obsolete; this shim exists only to measure its behavior in a
    // separately selected, self-owned-window diagnostic. No private ABI is used.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CGError result = CGPostMouseEvent(CGPointMake(x, y), false, 1, down);
#pragma clang diagnostic pop
    return (int32_t)result;
}

#if defined(__arm64__)
// Machine ABI verified statically on macOS build 26A428, not a recovered Apple
// source declaration. The third argument is consumed as a 32-bit transport
// value. Only zero is allowed here, avoiding assumptions about bool typedefs.
typedef uint32_t (*DiagnosticMainConnection)(void);
typedef int32_t (*DiagnosticPostEvent)(uint32_t, CGEventRef, uint32_t);
static DiagnosticMainConnection private_main_connection;
static DiagnosticPostEvent private_post_event;
static pthread_once_t private_record_once = PTHREAD_ONCE_INIT;

static void initialize_private_record(void) {
    char build[64] = {0};
    size_t build_size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &build_size, NULL, 0) != 0 ||
        build_size == 0 || build_size > sizeof(build) ||
        build[build_size - 1] != '\0' || strcmp(build, "26A428") != 0) {
        return;
    }

    // Retain this system-only image for the lifetime of these function pointers.
    void *image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                         RTLD_LOCAL | RTLD_NOW);
    if (image == NULL) return;
    void *post = dlsym(image, "SLSPostEvent");
    void *record = dlsym(image, "SLSPostEventRecord");
    void *connection = dlsym(image, "SLSMainConnectionID");
    if (post == NULL || record == NULL || connection == NULL) return;
    Dl_info post_info, record_info, connection_info;
    if (dladdr(post, &post_info) == 0 || dladdr(record, &record_info) == 0 ||
        dladdr(connection, &connection_info) == 0 ||
        post_info.dli_fbase != record_info.dli_fbase ||
        post_info.dli_fbase != connection_info.dli_fbase ||
        post_info.dli_fname == NULL ||
        strcmp(post_info.dli_fname,
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight") != 0) {
        return;
    }

    // x1 is CGEventRef: public CGEventGetType/GetFlags/GetTimestamp on this build
    // use the same +24 record pointer. The wrapper forwards x0, record, record
    // length, and x2 to SLSPostEventRecord, returning its low-32-bit error.
    uint32_t code[8];
    memcpy(code, post, sizeof(code));
    if (code[0] != 0xb40000c1 || code[1] != 0xf9400c21 ||
        code[2] != 0xb4000081 || code[3] != 0xaa0203e3 ||
        code[4] != 0xb9400422 || (code[5] & 0xfc000000) != 0x14000000 ||
        code[6] != 0x52807d00 || code[7] != 0xd65f03c0) {
        return;
    }
    int64_t displacement = (int64_t)(code[5] & 0x03ffffff);
    if ((displacement & 0x02000000) != 0) displacement -= 0x04000000;
    uintptr_t branch_target = (uintptr_t)post + 20 + displacement * 4;
    if (branch_target != (uintptr_t)record) return;

    private_main_connection = (DiagnosticMainConnection)connection;
    private_post_event = (DiagnosticPostEvent)post;
}
#endif

bool MenuTidyDiagnosticPrivateRecordAvailable(void) {
#if defined(__arm64__)
    pthread_once(&private_record_once, initialize_private_record);
    return private_main_connection != NULL && private_post_event != NULL;
#else
    return false;
#endif
}

static int32_t private_record_mouse_button(CGEventRef event, CGEventFlags required_flags) {
    if (event == NULL || CGEventGetFlags(event) != required_flags) return kCGErrorIllegalArgument;
    CGEventType type = CGEventGetType(event);
    if (type != kCGEventLeftMouseDown && type != kCGEventLeftMouseUp) {
        return kCGErrorIllegalArgument;
    }
    if (!MenuTidyDiagnosticPrivateRecordAvailable()) return kCGErrorNotImplemented;
#if defined(__arm64__)
    uint32_t connection = private_main_connection();
    if (connection == 0) return kCGErrorInvalidConnection;
    // Record's context+4 becomes Mach-message+32, the same update-cursor
    // transport field used by CGPostMouseEvent(..., false, ...).
    return private_post_event(connection, event, 0);
#else
    return kCGErrorNotImplemented;
#endif
}

int32_t MenuTidyDiagnosticPrivateRecordPost(CGEventRef event) {
    return private_record_mouse_button(event, 0);
}
