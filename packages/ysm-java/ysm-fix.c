#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <link.h>
#include <sys/mman.h>
#include <jni.h>

#define REG_NAT_OFFSET 1720

static void* (*real_dlopen)(const char*, int) = 0;
static int initialized = 0;
static unsigned char saved[16];
static void* jni_onload_addr = 0;
static int replay_done = 0;

static void do_replay(JNIEnv* env, void* base) {
    if (replay_done) return;
    replay_done = 1;
    typedef struct { const char* c; const char* m; const char* s; unsigned long o; } E;
    E entries[] = {
        {"com/elfmcys/yesstevemodel/O0Ooo000O0ooO00Oooo00oOO","oOo0OO0O0o000OO0O000oo0o","(Ljava/lang/String;Ljava/lang/String;Ljava/util/function/Consumer;)V",0x3c2b30},
        {"com/elfmcys/yesstevemodel/O0Ooo000O0ooO00Oooo00oOO","oOo0OO0O0o000OO0O000oo0o","(Ljava/lang/Object;)Z",0x3c53a0},
        {"com/elfmcys/yesstevemodel/O0Ooo000O0ooO00Oooo00oOO","oOo0OO0O0o000OO0O000oo0o","([Ljava/util/UUID;[Ljava/lang/String;[Ljava/lang/String;Ljava/lang/Object;)V",0x3c5710},
        {"com/elfmcys/yesstevemodel/O0Ooo000O0ooO00Oooo00oOO","oOo0OO0O0o000OO0O000oo0o","(Ljava/util/UUID;Ljava/nio/ByteBuffer;)V",0x3c6c50},
        {"com/elfmcys/yesstevemodel/oo0OooOo00000oo0o0o0oOoo","oOoo00O0o0oO0o0oO00OO0O0","()Ljava/lang/Object;",0x3c23b0},
        {"com/elfmcys/yesstevemodel/oo0OooOo00000oo0o0o0oOoo","OO000o0ooOooooOOOOO0Ooo0","()V",0x3c2520},
    };
    int n = sizeof(entries)/sizeof(entries[0]);
    for (int i=0; i<n; ) {
        const char* cls = entries[i].c; int s=i;
        while (i<n && !strcmp(entries[i].c, cls)) i++;
        int c = i-s;
        jclass cl = (*env)->FindClass(env, cls);
        if (!cl) { if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env); continue; }
        JNINativeMethod m[10];
        for (int j=0; j<c && j<10; j++) {
            m[j].name = (char*)entries[s+j].m;
            m[j].signature = (char*)entries[s+j].s;
            m[j].fnPtr = (void*)((char*)base + entries[s+j].o);
        }
        (*env)->RegisterNatives(env, cl, m, c);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    }
}

static jint JNICALL jni_onload_wrapper(JavaVM* vm, void* reserved) {
    jint result = JNI_VERSION_21;
    JNIEnv* env = 0;

    // Sleep 1.5s: err:56 is time-dependent, passes after ~1s JVM uptime
    struct timespec ts = {1, 500000000L};
    nanosleep(&ts, 0);

    if (jni_onload_addr) {
        long pgsz = sysconf(_SC_PAGESIZE);
        void* page = (void*)((long)jni_onload_addr & ~(pgsz - 1));
        mprotect(page, pgsz, PROT_READ|PROT_WRITE|PROT_EXEC);
        memcpy(jni_onload_addr, saved, 12);
        mprotect(page, pgsz, PROT_READ|PROT_EXEC);

        jint (*real_fn)(JavaVM*, void*) = (jint (*)(JavaVM*, void*))jni_onload_addr;
        result = real_fn(vm, reserved);
    }

    if ((*vm)->GetEnv(vm, (void**)&env, JNI_VERSION_21) == JNI_OK && env) {
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            result = JNI_VERSION_21;
        }
        Dl_info info;
        if (jni_onload_addr && dladdr(jni_onload_addr, &info) && info.dli_fbase)
            do_replay(env, info.dli_fbase);
    }

    return (result != JNI_ERR) ? result : JNI_VERSION_21;
}

void* dlopen(const char* filename, int flags) {
    if (!initialized || !real_dlopen)
        return dlvsym(RTLD_NEXT, "dlopen", "GLIBC_2.2.5");
    void* handle = real_dlopen(filename, flags);
    if (!handle || !filename) return handle;
    if (strstr(filename, "libysm-core") || strstr(filename, "ysm-core")) {
        void* jni_onload = dlsym(handle, "JNI_OnLoad");
        if (jni_onload) {
            jni_onload_addr = jni_onload;
            memcpy(saved, jni_onload, 12);
            unsigned char trampoline[12] = {0x48,0xb8,0,0,0,0,0,0,0,0,0xff,0xe0};
            void* wrapper = (void*)jni_onload_wrapper;
            memcpy(trampoline+2, &wrapper, 8);
            long pgsz = sysconf(_SC_PAGESIZE);
            void* page = (void*)((long)jni_onload & ~(pgsz - 1));
            mprotect(page, pgsz, PROT_READ|PROT_WRITE|PROT_EXEC);
            memcpy(jni_onload, trampoline, 12);
            mprotect(page, pgsz, PROT_READ|PROT_EXEC);
        }
    }
    return handle;
}

__attribute__((constructor))
static void init(void) {
    real_dlopen = dlvsym(RTLD_NEXT, "dlopen", "GLIBC_2.2.5");
    if (!real_dlopen) real_dlopen = dlvsym(RTLD_NEXT, "dlopen", "GLIBC_2.34");
    initialized = 1;
}
