#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <link.h>
#include <jni.h>

static void* (*real_dlsym)(void*, const char*) = 0;
static jint (*real_JNI_OnLoad)(JavaVM*, void*) = 0;
static int replay_done = 0;

__attribute__((constructor)) static void init(void) {
    real_dlsym = (void* (*)(void*, const char*))dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.2.5");
    if (!real_dlsym)
        real_dlsym = (void* (*)(void*, const char*))dlsym(RTLD_NEXT, "dlsym");
}

static void do_replay(JNIEnv* env, void* base) {
    if (replay_done) return;
    replay_done = 1;
    typedef struct { const char* c; const char* m; const char* s; unsigned long o; } E;
    E entries[] = {
        {"com/elfmcys/yesstevemodel/O0Ooo000O0ooO00Oooo00oOO","oOo0OO0O0o000OO0O000oo0o","(Ljava/lang/String;Ljava/lang/String;Ljava/util/function/Consumer;)V",0x3c2b30},
        {"com/elfmcys/yesstevemodel/O0Ooo000O0ooO00Oooo00oOO","oOo0OO0O0o000OO0O000oo0o","(Ljava/lang/Object;)Z",0x3c53a0},
        {"com/elfmcys/yesstevemodel/O0Ooo000O0ooO00Oooo00oOO","oOo0OO0O0o000OO0O000oo0o","([Ljava/util/UUID;[Ljava/lang/String;[Ljava/lang/Object;)V",0x3c5710},
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

static jint JNICALL wrapper_JNI_OnLoad(JavaVM* vm, void* reserved) {
    jint result = JNI_VERSION_21;
    JNIEnv* env = 0;

    struct timespec ts = {1, 500000000L};
    nanosleep(&ts, 0);

    if (real_JNI_OnLoad)
        result = real_JNI_OnLoad(vm, reserved);

    if ((*vm)->GetEnv(vm, (void**)&env, JNI_VERSION_21) == JNI_OK && env) {
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            result = JNI_VERSION_21;
        }
        Dl_info info;
        if (real_JNI_OnLoad && dladdr((void*)real_JNI_OnLoad, &info) && info.dli_fbase)
            do_replay(env, info.dli_fbase);
    }

    return (result != JNI_ERR) ? result : JNI_VERSION_21;
}

void* dlsym(void* handle, const char* name) {
    if (!real_dlsym) return NULL;
    void* result = real_dlsym(handle, name);

    if (result && name && !strcmp(name, "JNI_OnLoad") && !real_JNI_OnLoad) {
        Dl_info info;
        if (!dladdr(result, &info) || !info.dli_fname) return result;
        if (!strstr(info.dli_fname, "ysm-core") && !strstr(info.dli_fname, "libysm-core"))
            return result;
        real_JNI_OnLoad = (jint (*)(JavaVM*, void*))result;
        return (void*)wrapper_JNI_OnLoad;
    }

    return result;
}
