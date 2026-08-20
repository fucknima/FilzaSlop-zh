#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#define ST_NOINSTR __attribute__((no_instrument_function))
#define ST_MAX_DEPTH 1024
#define ST_MIN_DURATION_MS 5.0
#define ST_PROFILE_WINDOW_MS 15000.0

typedef struct {
    void *function;
    uint64_t started;
} STFrame;

static STFrame gSTFrames[ST_MAX_DEPTH];
static int gSTDepth = 0;
static int gSTFd = -2;
static uint64_t gSTZero = 0;
static mach_timebase_info_data_t gSTTimebase = {0, 0};

static ST_NOINSTR double STMilliseconds(uint64_t ticks)
{
    if (gSTTimebase.denom == 0) mach_timebase_info(&gSTTimebase);
    long double nanos = (long double)ticks *
        (long double)gSTTimebase.numer / (long double)gSTTimebase.denom;
    return (double)(nanos / 1000000.0L);
}

static ST_NOINSTR void STWriteRaw(const char *text, size_t length)
{
    if (gSTFd < 0 || !text || length == 0) return;
    while (length > 0) {
        ssize_t written = write(gSTFd, text, length);
        if (written <= 0) return;
        text += written;
        length -= (size_t)written;
    }
}

static ST_NOINSTR void STEnsureLog(void)
{
    if (gSTFd != -2) return;
    const char *home = getenv("HOME");
    if (!home || home[0] != '/') {
        gSTFd = -1;
        return;
    }

    char path[1024];
    int count = snprintf(path, sizeof(path), "%s/Documents/startup-timing.log", home);
    if (count <= 0 || (size_t)count >= sizeof(path)) {
        gSTFd = -1;
        return;
    }

    gSTFd = open(path, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0600);
    if (gSTFd < 0) return;

    char header[1200];
    int length = snprintf(header, sizeof(header),
        "FilzaSlop cold-start timing probe\n"
        "Only main-thread functions taking >= %.1f ms are recorded.\n"
        "Profiling window: %.0f ms. Times are relative to the first instrumented call.\n"
        "Log path: %s\n\n",
        ST_MIN_DURATION_MS, ST_PROFILE_WINDOW_MS, path);
    if (length > 0) STWriteRaw(header, (size_t)length);
}

static ST_NOINSTR void STLogFunction(void *function, uint64_t started,
                                     uint64_t ended, int depth)
{
    if (gSTZero == 0 || ended <= started) return;
    double durationMs = STMilliseconds(ended - started);
    if (durationMs < ST_MIN_DURATION_MS) return;

    double endMs = STMilliseconds(ended - gSTZero);
    if (endMs > ST_PROFILE_WINDOW_MS) return;

    Dl_info info = {0};
    dladdr(function, &info);
    uintptr_t offset = 0;
    if (info.dli_fbase)
        offset = (uintptr_t)function - (uintptr_t)info.dli_fbase;

    const char *symbol = info.dli_sname ? info.dli_sname : "<local-or-stripped>";
    const char *image = info.dli_fname ? info.dli_fname : "<unknown-image>";
    const char *leaf = strrchr(image, '/');
    if (leaf) image = leaf + 1;

    char line[1536];
    int length = snprintf(line, sizeof(line),
        "+%9.3f ms  dur=%9.3f ms  depth=%3d  off=0x%llx  %s  [%s]\n",
        endMs, durationMs, depth, (unsigned long long)offset, symbol, image);
    if (length > 0) STWriteRaw(line, (size_t)length);
}

void __cyg_profile_func_enter(void *this_fn, void *call_site) ST_NOINSTR;
void __cyg_profile_func_exit(void *this_fn, void *call_site) ST_NOINSTR;

void __cyg_profile_func_enter(void *this_fn, __unused void *call_site)
{
    if (!pthread_main_np()) return;

    uint64_t now = mach_continuous_time();
    if (gSTZero == 0) {
        gSTZero = now;
        STEnsureLog();
    }

    int depth = gSTDepth++;
    if (depth >= 0 && depth < ST_MAX_DEPTH) {
        gSTFrames[depth].function = this_fn;
        gSTFrames[depth].started = now;
    }
}

void __cyg_profile_func_exit(void *this_fn, __unused void *call_site)
{
    if (!pthread_main_np()) return;
    if (gSTDepth <= 0) return;

    int depth = --gSTDepth;
    if (depth < 0 || depth >= ST_MAX_DEPTH) return;

    STFrame frame = gSTFrames[depth];
    if (frame.started == 0) return;
    uint64_t ended = mach_continuous_time();
    STLogFunction(frame.function ? frame.function : this_fn,
                  frame.started, ended, depth);
    gSTFrames[depth].started = 0;
    gSTFrames[depth].function = NULL;
}
