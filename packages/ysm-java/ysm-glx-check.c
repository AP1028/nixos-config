#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char** argv) {
    fprintf(stderr, "[ysm-glx-check] LD_PRELOAD=%s\n", getenv("LD_PRELOAD") ?: "(unset)");
    fprintf(stderr, "[ysm-glx-check] __GLX_VENDOR_LIBRARY_NAME=%s\n", getenv("__GLX_VENDOR_LIBRARY_NAME") ?: "(unset)");
    fprintf(stderr, "[ysm-glx-check] __NV_PRIME_RENDER_OFFLOAD=%s\n", getenv("__NV_PRIME_RENDER_OFFLOAD") ?: "(unset)");
    fprintf(stderr, "[ysm-glx-check] DISPLAY=%s\n", getenv("DISPLAY") ?: "(unset)");
    fprintf(stderr, "[ysm-glx-check] LD_LIBRARY_PATH=%s\n", getenv("LD_LIBRARY_PATH") ?: "(unset)");

    void* libGL = dlopen("libGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!libGL) {
        fprintf(stderr, "[ysm-glx-check] FAIL: dlopen libGL.so.1: %s\n", dlerror());
        return 1;
    }
    fprintf(stderr, "[ysm-glx-check] loaded libGL.so.1\n");

    void* (*glXGetClientString)(void*, int) = dlsym(libGL, "glXGetClientString");
    if (!glXGetClientString) {
        fprintf(stderr, "[ysm-glx-check] FAIL: dlsym glXGetClientString: %s\n", dlerror());
        dlclose(libGL);
        return 1;
    }

    void* (*glXChooseFBConfig)(void*, int, const int*, int*) = dlsym(libGL, "glXChooseFBConfig");
    if (!glXChooseFBConfig) {
        fprintf(stderr, "[ysm-glx-check] FAIL: dlsym glXChooseFBConfig: %s\n", dlerror());
        dlclose(libGL);
        return 1;
    }

    void* display = NULL;
    void* (*XOpenDisplay)(const char*) = dlsym(RTLD_DEFAULT, "XOpenDisplay");
    if (XOpenDisplay) {
        display = XOpenDisplay(NULL);
        if (!display) {
            fprintf(stderr, "[ysm-glx-check] WARN: XOpenDisplay returned NULL (no X connection)\n");
        } else {
            fprintf(stderr, "[ysm-glx-check] XOpenDisplay OK\n");
            const char* vendor = glXGetClientString(display, 0x1F01); /* GLX_VENDOR */
            const char* version = glXGetClientString(display, 0x1F02); /* GLX_VERSION */
            fprintf(stderr, "[ysm-glx-check] GLX vendor: %s\n", vendor ?: "(null)");
            fprintf(stderr, "[ysm-glx-check] GLX version: %s\n", version ?: "(null)");

            int attribs[] = { 0x8002, /* GLX_RGBA */ 0x8010, 0x8012, 0x8013, 0, /* None */ };
            int nelements = 0;
            void* fbconfigs = glXChooseFBConfig(display, 0, attribs, &nelements);
            if (fbconfigs && nelements > 0) {
                fprintf(stderr, "[ysm-glx-check] OK: glXChooseFBConfig returned %d configs\n", nelements);
            } else {
                fprintf(stderr, "[ysm-glx-check] FAIL: glXChooseFBConfig returned no configs\n");
            }
        }
    } else {
        fprintf(stderr, "[ysm-glx-check] WARN: XOpenDisplay not found (no libX11 loaded)\n");
    }

    dlclose(libGL);
    return 0;
}
