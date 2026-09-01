/*
 * NekoBox4Harmony — NAPI 桥:sing-box 内核以 c-shared 库(libsingbox.so)形式
 * 随 HAP 安装在应用原生库目录,这里 dlopen 后在进程内直接调用
 * CGoStartSingBox / CGoStopSingBox / CGoSetTunFd(架构参考 Hey 项目)。
 *
 * 注意:首次进入 Go 运行时的调用放在工作线程执行(UI/JS 线程冷调 cgo 有风险),
 * 结果通过 napi_threadsafe_function 回调 ArkTS。
 */
#include "napi/native_api.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

typedef char *(*CGoStringFunc)(void);
typedef char *(*CGoStartFunc)(char *);
typedef void (*CGoSetFdFunc)(int);
typedef void (*CGoSetBindIfnameFunc)(char *);

enum class CoreState {
    Stopped,
    Starting,
    Running,
    Stopping,
};

static std::atomic<CoreState> g_coreState{CoreState::Stopped};
static uint64_t g_coreGeneration = 0;
static uint64_t g_cancelledGeneration = 0;
static std::mutex g_stateMutex;
static std::vector<napi_threadsafe_function> g_stopWaiters;
static std::mutex g_libMutex;
static void *g_coreLib = nullptr;
static CGoStringFunc g_version = nullptr;
static CGoStartFunc g_start = nullptr;
static CGoStringFunc g_stop = nullptr;
static CGoSetFdFunc g_setTunFd = nullptr;
static CGoSetBindIfnameFunc g_setBindIfname = nullptr;

struct TsfData {
    std::string text;
};

static void CallJsString(napi_env env, napi_value jsCb, void * /*context*/, void *data)
{
    TsfData *d = static_cast<TsfData *>(data);
    napi_value argv[1];
    napi_create_string_utf8(env, d->text.c_str(), d->text.size(), &argv[0]);
    napi_value global;
    napi_get_global(env, &global);
    napi_call_function(env, global, jsCb, 1, argv, nullptr);
    delete d;
}

static void EmitString(napi_threadsafe_function tsf, const std::string &text)
{
    if (tsf == nullptr) {
        return;
    }
    auto *d = new TsfData();
    d->text = text;
    if (napi_call_threadsafe_function(tsf, d, napi_tsfn_nonblocking) != napi_ok) {
        delete d;
    }
}

static napi_threadsafe_function CreateResultTsf(napi_env env, napi_value callback)
{
    if (callback == nullptr) {
        return nullptr;
    }
    napi_threadsafe_function tsf = nullptr;
    napi_value resName;
    napi_create_string_utf8(env, "coreResult", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, callback, nullptr, resName, 0, 4, nullptr, nullptr, nullptr,
                                    CallJsString, &tsf);
    return tsf;
}

static void CompleteWaiters(const std::string &message)
{
    std::vector<napi_threadsafe_function> waiters;
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        waiters.swap(g_stopWaiters);
    }
    for (auto tsf : waiters) {
        EmitString(tsf, message);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }
}

static bool GetArgString(napi_env env, napi_callback_info info, size_t index, std::string &out)
{
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc <= index || argv[index] == nullptr) {
        return false;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, argv[index], nullptr, 0, &len) != napi_ok) {
        return false;
    }
    out.resize(len);
    if (len > 0) {
        if (napi_get_value_string_utf8(env, argv[index], &out[0], len + 1, &len) != napi_ok) {
            return false;
        }
    }
    return true;
}

static bool GetArgInt(napi_env env, napi_value value, int &out)
{
    double v = 0;
    if (napi_get_value_double(env, value, &v) != napi_ok) {
        return false;
    }
    out = static_cast<int>(v);
    return true;
}

// 本模块(libentry.so)自身路径所在目录 = 应用原生库目录
static std::string NativeLibDir()
{
    Dl_info info;
    if (dladdr(reinterpret_cast<void *>(&NativeLibDir), &info) != 0 && info.dli_fname != nullptr) {
        std::string self(info.dli_fname);
        auto pos = self.find_last_of('/');
        if (pos != std::string::npos) {
            return self.substr(0, pos);
        }
    }
    return "";
}

static bool LoadCoreLib(std::string &message)
{
    std::lock_guard<std::mutex> lock(g_libMutex);
    if (g_coreLib != nullptr && g_start != nullptr && g_stop != nullptr && g_setTunFd != nullptr) {
        return true;
    }
    std::string dir = NativeLibDir();
    std::string path = dir.empty() ? "libsingbox.so" : dir + "/libsingbox.so";
    void *handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        handle = dlopen("libsingbox.so", RTLD_NOW | RTLD_LOCAL);
    }
    if (handle == nullptr) {
        const char *err = dlerror();
        message = "加载 libsingbox.so 失败: " + std::string(err != nullptr ? err : "unknown") +
                  " (尝试路径: " + path + ")";
        return false;
    }
    dlerror();
    g_version = reinterpret_cast<CGoStringFunc>(dlsym(handle, "CGoSingBoxVersion"));
    g_start = reinterpret_cast<CGoStartFunc>(dlsym(handle, "CGoStartSingBox"));
    g_stop = reinterpret_cast<CGoStringFunc>(dlsym(handle, "CGoStopSingBox"));
    g_setTunFd = reinterpret_cast<CGoSetFdFunc>(dlsym(handle, "CGoSetTunFd"));
    g_setBindIfname = reinterpret_cast<CGoSetBindIfnameFunc>(dlsym(handle, "CGoSetBindIfname"));
    if (g_start == nullptr || g_stop == nullptr || g_setTunFd == nullptr) {
        message = "libsingbox.so 缺少导出符号(CGoStartSingBox/CGoStopSingBox/CGoSetTunFd)";
        return false;
    }
    g_coreLib = handle;
    return true;
}

// setBindIfnameNative(ifname): configure the physical interface before the
// worker thread invokes CGoStartSingBox, enabling SO_BINDTODEVICE in OHOS.
static napi_value SetBindIfnameNative(napi_env env, napi_callback_info info)
{
    std::string ifname;
    if (!GetArgString(env, info, 0, ifname)) {
        napi_throw_error(env, nullptr, "setBindIfnameNative expects (ifname)");
        return nullptr;
    }
    std::string message;
    if (!LoadCoreLib(message) || g_setBindIfname == nullptr) {
        napi_throw_error(env, nullptr, message.empty() ? "libsingbox.so missing CGoSetBindIfname" : message.c_str());
        return nullptr;
    }
    char *value = strdup(ifname.c_str());
    g_setBindIfname(value);
    free(value);
    return nullptr;
}

static void FreeGoString(char *p)
{
    if (p != nullptr) {
        free(p);
    }
}

// startCoreNative(configPath, tunFd, onResult)
static napi_value StartCoreNative(napi_env env, napi_callback_info info)
{
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_error(env, nullptr, "startCoreNative expects (configPath, tunFd, onResult)");
        return nullptr;
    }
    std::string configPath;
    int tunFd = -1;
    GetArgString(env, info, 0, configPath);
    GetArgInt(env, argv[1], tunFd);
    napi_value onResult = argv[2];

    uint64_t generation = 0;
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        if (g_coreState.load() != CoreState::Stopped) {
            napi_value global, arg;
            napi_get_global(env, &global);
            napi_create_string_utf8(env, "core is not stopped", NAPI_AUTO_LENGTH, &arg);
            napi_call_function(env, global, onResult, 1, &arg, nullptr);
            return nullptr;
        }
        g_coreState.store(CoreState::Starting);
        generation = ++g_coreGeneration;
    }

    napi_threadsafe_function tsf = nullptr;
    napi_value resName;
    napi_create_string_utf8(env, "coreResult", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, onResult, nullptr, resName, 0, 4, nullptr, nullptr, nullptr,
                                    CallJsString, &tsf);

    std::thread([configPath, tunFd, tsf]() {
        std::string message;
        do {
            if (!LoadCoreLib(message)) {
                break;
            }
            g_setTunFd(tunFd);
            char *configC = strdup(configPath.c_str());
            char *err = g_start(configC);
            free(configC);
            if (err != nullptr && err[0] != '\0') {
                message = std::string(err);
                FreeGoString(err);
                break;
            }
            FreeGoString(err);
        } while (false);
        if (message.empty()) {
            g_coreState.store(CoreState::Running);
        } else {
            g_coreState.store(CoreState::Stopped);
        }
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();

    return nullptr;
}

// stopCoreNative(onResult)
static napi_value StopCoreNative(napi_env env, napi_callback_info info)
{
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value onResult = argc >= 1 ? argv[0] : nullptr;

    CoreState expected = CoreState::Running;
    if (!g_coreState.compare_exchange_strong(expected, CoreState::Stopping)) {
        if (expected == CoreState::Starting) {
            std::lock_guard<std::mutex> lock(g_stateMutex);
            g_cancelledGeneration = g_coreGeneration;
        }
        if (onResult != nullptr) {
            napi_threadsafe_function tsf = nullptr;
            napi_value resName;
            napi_create_string_utf8(env, "coreResult", NAPI_AUTO_LENGTH, &resName);
            napi_create_threadsafe_function(env, onResult, nullptr, resName, 0, 2, nullptr, nullptr, nullptr,
                                            CallJsString, &tsf);
            EmitString(tsf, (expected == CoreState::Stopped || expected == CoreState::Starting) ? "" : "core is busy");
            napi_release_threadsafe_function(tsf, napi_tsfn_release);
        }
        return nullptr;
    }

    if (onResult == nullptr) {
        std::thread([]() {
            if (g_stop != nullptr) {
                FreeGoString(g_stop());
            }
            g_coreState.store(CoreState::Stopped);
        }).detach();
        return nullptr;
    }

    napi_threadsafe_function tsf = nullptr;
    napi_value resName;
    napi_create_string_utf8(env, "coreResult", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, onResult, nullptr, resName, 0, 2, nullptr, nullptr, nullptr,
                                    CallJsString, &tsf);
    std::thread([tsf]() {
        std::string message;
        if (g_stop != nullptr) {
            char *err = g_stop();
            if (err != nullptr) {
                message = std::string(err);
                FreeGoString(err);
            }
        }
        g_coreState.store(CoreState::Stopped);
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

static napi_value IsCoreRunning(napi_env env, napi_callback_info /*info*/)
{
    napi_value result;
    napi_get_boolean(env, g_coreState.load() == CoreState::Running, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"startCoreNative", nullptr, StartCoreNative, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCoreNative", nullptr, StopCoreNative, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isCoreRunning", nullptr, IsCoreRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setBindIfnameNative", nullptr, SetBindIfnameNative, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) { napi_module_register(&demoModule); }
