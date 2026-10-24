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
// 测速导出有两代签名。libsingbox.so 是随仓库分发的冻结产物,改签名会
// 让"新 NAPI + 旧 .so"组合崩掉(多传的参数会让 Go 侧读到野指针),
// 所以按 V2 优先、legacy 回退的方式解析,两边都能安全跑。
//   V2:    CGoTestStartSingBoxV2(configPath, bindIfname)
//          CGoTestProxySingBoxV2(tag, url, timeoutMs, expectStatus)
//   legacy:CGoTestStartSingBox(configPath)
//          CGoTestProxySingBox(tag, url, timeoutMs)
typedef char *(*CGoTestStartFunc)(char *, char *);
typedef char *(*CGoTestStartLegacyFunc)(char *);
typedef char *(*CGoTestProxyFunc)(char *, char *, int, char *);
typedef char *(*CGoTestProxyLegacyFunc)(char *, char *, int);
// K1 无副作用校验导出(CGoCheckConfigV1 / CGoValidateSRSFileV1)。
// 与测速不同代:这两个符号只存在于新编 .so,老 .so 里 dlsym 必然为空 ——
// 空即代表"能力缺失",NAPI 层回退字符串 "unsupported",ArkTS 侧据此
// 不标"已验证"(docs/p0-baseline/kernel-capabilities.md §2.2 能力探测)。
typedef char *(*CGoStringOneArgFunc)(char *);
// K2 会话化测速(V3,带 sessionId)。全部按 dlsym 解析:老 .so 上必然为空,
// 此时对应 native 方法回退 "unsupported"(能力探测语义,不得当成成功)。
typedef char *(*CGoTestStartV3Func)(char *, char *, char *);             // (sessionId, configPath, bindIfname)
typedef char *(*CGoTestProxyV3Func)(char *, char *, char *, int, char *); // (sessionId, tag, url, timeoutMs, expectStatus)
typedef char *(*CGoTestStopV3Func)(char *);                              // (sessionId)
typedef char *(*CGoTestInfoV3Func)(char *);                              // (sessionId)

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
static CGoTestStartFunc g_testStart = nullptr;
static CGoTestStartLegacyFunc g_testStartLegacy = nullptr;
static CGoTestProxyFunc g_testProxy = nullptr;
static CGoTestProxyLegacyFunc g_testProxyLegacy = nullptr;
static CGoStringFunc g_testStop = nullptr;
// K1 校验能力指针:nullptr = 内核无该导出(旧 .so),能力回退 "unsupported"
static CGoStringOneArgFunc g_checkConfig = nullptr;
static CGoStringOneArgFunc g_validateSrs = nullptr;
// true = 内核提供 V2 测速导出(支持响应状态判定 + 测速绕过隧道);
// false = 跑的是冻结 .so 的旧导出,这两项能力不可用。
static bool g_testV2 = false;
// K2 V3 会话导出(五件套齐全才算 v3:start/proxy/stop/info/active)
static CGoTestStartV3Func g_testStartV3 = nullptr;
static CGoTestProxyV3Func g_testProxyV3 = nullptr;
static CGoTestStopV3Func g_testStopV3 = nullptr;
static CGoTestInfoV3Func g_testInfoV3 = nullptr;
static CGoStringFunc g_testActiveV3 = nullptr;
static bool g_testV3 = false;

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

static bool GetArgStringAt(napi_env env, napi_value value, std::string &out)
{
    if (value == nullptr) {
        return false;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    out.resize(len);
    if (len > 0) {
        if (napi_get_value_string_utf8(env, value, &out[0], len + 1, &len) != napi_ok) {
            return false;
        }
    }
    return true;
}

static bool GetArgString(napi_env env, napi_callback_info info, size_t index, std::string &out)
{
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc <= index || argv[index] == nullptr) {
        return false;
    }
    return GetArgStringAt(env, argv[index], out);
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
    // 测速导出:V2 优先,找不到才用 legacy(冻结 .so 仍是 legacy 签名)
    g_testStart = reinterpret_cast<CGoTestStartFunc>(dlsym(handle, "CGoTestStartSingBoxV2"));
    g_testProxy = reinterpret_cast<CGoTestProxyFunc>(dlsym(handle, "CGoTestProxySingBoxV2"));
    g_testV2 = (g_testStart != nullptr) && (g_testProxy != nullptr);
    if (!g_testV2) {
        g_testStart = nullptr;
        g_testProxy = nullptr;
        g_testStartLegacy =
            reinterpret_cast<CGoTestStartLegacyFunc>(dlsym(handle, "CGoTestStartSingBox"));
        g_testProxyLegacy =
            reinterpret_cast<CGoTestProxyLegacyFunc>(dlsym(handle, "CGoTestProxySingBox"));
    }
    g_testStop = reinterpret_cast<CGoStringFunc>(dlsym(handle, "CGoTestStopSingBox"));
    // K1 校验导出:可选能力,dlsym 落空不算失败 —— 旧冻结 .so 没有这两个符号,
    // 此时 checkConfigNative/validateSrsNative 回退 "unsupported"。
    g_checkConfig = reinterpret_cast<CGoStringOneArgFunc>(dlsym(handle, "CGoCheckConfigV1"));
    g_validateSrs = reinterpret_cast<CGoStringOneArgFunc>(dlsym(handle, "CGoValidateSRSFileV1"));
    // K2 V3 会话导出:同样按"可选能力"解析。老 .so 上五个全是 nullptr,
    // 对应 native 方法回退 "unsupported",绝不会当成成功。
    g_testStartV3 = reinterpret_cast<CGoTestStartV3Func>(dlsym(handle, "CGoTestStartSingBoxV3"));
    g_testProxyV3 = reinterpret_cast<CGoTestProxyV3Func>(dlsym(handle, "CGoTestProxySingBoxV3"));
    g_testStopV3 = reinterpret_cast<CGoTestStopV3Func>(dlsym(handle, "CGoTestStopSingBoxV3"));
    g_testInfoV3 = reinterpret_cast<CGoTestInfoV3Func>(dlsym(handle, "CGoTestSessionInfoV3"));
    g_testActiveV3 = reinterpret_cast<CGoStringFunc>(dlsym(handle, "CGoTestActiveSessionsV3"));
    g_testV3 = (g_testStartV3 != nullptr) && (g_testProxyV3 != nullptr) && (g_testStopV3 != nullptr) &&
               (g_testInfoV3 != nullptr) && (g_testActiveV3 != nullptr);
    if (g_start == nullptr || g_stop == nullptr || g_setTunFd == nullptr) {
        message = "libsingbox.so 缺少导出符号(CGoStartSingBox/CGoStopSingBox/CGoSetTunFd)";
        g_version = nullptr;
        g_start = nullptr;
        g_stop = nullptr;
        g_setTunFd = nullptr;
        dlclose(handle);
        return false;
    }
    g_coreLib = handle;
    return true;
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

    std::thread([configPath, tunFd, tsf, generation]() {
        std::string message;
        do {
            if (!LoadCoreLib(message)) {
                break;
            }
            g_setTunFd(tunFd);
            char *configC = strdup(configPath.c_str());
            if (configC == nullptr) {
                message = "failed to allocate config path";
                break;
            }
            char *err = g_start(configC);
            free(configC);
            if (err != nullptr && err[0] != '\0') {
                message = std::string(err);
                FreeGoString(err);
                break;
            }
            FreeGoString(err);
        } while (false);

        bool cancelled = false;
        {
            std::lock_guard<std::mutex> lock(g_stateMutex);
            cancelled = generation <= g_cancelledGeneration;
        }
        if (message.empty() && cancelled) {
            g_coreState.store(CoreState::Stopping);
            if (g_stop != nullptr) {
                char *stopError = g_stop();
                if (stopError != nullptr && stopError[0] != '\0') {
                    message = std::string(stopError);
                }
                FreeGoString(stopError);
            }
            g_coreState.store(CoreState::Stopped);
            CompleteWaiters(message);
        } else if (message.empty()) {
            g_coreState.store(CoreState::Running);
        } else {
            g_coreState.store(CoreState::Stopped);
            CompleteWaiters(message);
        }
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();

    return nullptr;
}

// testStartNative(configPath, bindIfname, onResult) —— 启动独立测速会话(与主实例互不影响)。
// bindIfname 非空时测速出站绑定该物理网卡,绕开正在运行的隧道。
static napi_value TestStartNative(napi_env env, napi_callback_info info)
{
    std::string configPath;
    std::string bindIfname;
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    GetArgStringAt(env, argv[0], configPath);
    GetArgStringAt(env, argv[1], bindIfname);
    napi_value onResult = argc >= 3 ? argv[2] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([configPath, bindIfname, tsf]() {
        std::string message;
        do {
            std::string loadErr;
            if (!LoadCoreLib(loadErr)) {
                message = loadErr;
                break;
            }
            char *pathC = strdup(configPath.c_str());
            char *err = nullptr;
            if (g_testV2 && g_testStart != nullptr) {
                char *ifC = strdup(bindIfname.c_str());
                err = g_testStart(pathC, ifC);
                free(ifC);
            } else if (g_testStartLegacy != nullptr) {
                // legacy 内核:忽略 bindIfname(该能力依赖 SO_BINDTODEVICE,旧导出没有)
                err = g_testStartLegacy(pathC);
            } else {
                message = "内核不支持 URL 测速(libsingbox.so 缺少 CGoTestStartSingBox*)";
            }
            free(pathC);
            if (err != nullptr && err[0] != '\0') {
                message = std::string(err);
            }
            FreeGoString(err);
        } while (false);
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// testProxyNative(tag, url, timeoutMs, expectStatus, onResult) —— 对指定出站做真连接测试,
// onResult 收到 "ms" 或 "err:..."。expectStatus: "2xx" 仅 2xx 通过,"any" 任意响应码通过;
// legacy 内核忽略 expectStatus(旧导出做不了状态码判定)。
static napi_value TestProxyNative(napi_env env, napi_callback_info info)
{
    std::string tag;
    std::string url;
    std::string expectStatus = "2xx";
    int timeoutMs = 5000;
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    GetArgStringAt(env, argv[0], tag);
    GetArgStringAt(env, argv[1], url);
    GetArgInt(env, argv[2], timeoutMs);
    GetArgStringAt(env, argv[3], expectStatus);
    napi_value onResult = argc >= 5 ? argv[4] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([tag, url, timeoutMs, expectStatus, tsf]() {
        std::string message = "err:test session not started";
        do {
            std::string loadErr;
            if (!LoadCoreLib(loadErr)) {
                message = "err:" + loadErr;
                break;
            }
            char *tagC = strdup(tag.c_str());
            char *urlC = strdup(url.c_str());
            char *res = nullptr;
            if (g_testV2 && g_testProxy != nullptr) {
                char *expectC = strdup(expectStatus.c_str());
                res = g_testProxy(tagC, urlC, timeoutMs, expectC);
                free(expectC);
            } else if (g_testProxyLegacy != nullptr) {
                res = g_testProxyLegacy(tagC, urlC, timeoutMs);
            } else {
                message = "err:kernel lacks CGoTestProxySingBox";
            }
            free(tagC);
            free(urlC);
            if (res != nullptr) {
                message = std::string(res);
            }
            FreeGoString(res);
        } while (false);
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// testCapsNative(onResult) —— 回报测速能力:"v3" = 内核支持 K2 会话化测速
// (sessionId 取消/迟到回调防护);"v2" = 支持响应状态判定 + 测速绕过隧道;
// "legacy" = 跑的是冻结 .so 的旧导出,这两项不可用。
static napi_value TestCapsNative(napi_env env, napi_callback_info info)
{
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value onResult = argc >= 1 ? argv[0] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([tsf]() {
        std::string message;
        bool loaded = LoadCoreLib(message);
        if (loaded) {
            if (g_testV3) {
                message = "v3";
            } else {
                message = g_testV2 ? "v2" : "legacy";
            }
        }
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// checkConfigNative(configPath, onResult) —— K1 内核 schema 校验(无副作用:不启动、
// 不碰环境变量、不写文件)。onResult 收到 "" = 通过(或内核无该能力),否则错误文本。
// 旧 .so 没有 CGoCheckConfigV1 时回退 "unsupported":调用方据此不标"已验证"。
static napi_value CheckConfigNative(napi_env env, napi_callback_info info)
{
    std::string configPath;
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    GetArgStringAt(env, argv[0], configPath);
    napi_value onResult = argc >= 2 ? argv[1] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([configPath, tsf]() {
        std::string message;
        do {
            std::string loadErr;
            if (!LoadCoreLib(loadErr)) {
                message = "err:" + loadErr;
                break;
            }
            if (g_checkConfig == nullptr) {
                // 能力探测语义:老内核没有校验导出,调用方不得据此标"已验证"
                message = "unsupported";
                break;
            }
            char *pathC = strdup(configPath.c_str());
            if (pathC == nullptr) {
                message = "err:failed to allocate config path";
                break;
            }
            char *err = g_checkConfig(pathC);
            free(pathC);
            if (err != nullptr && err[0] != '\0') {
                message = std::string(err);
            }
            FreeGoString(err);
        } while (false);
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// validateSrsNative(path, onResult) —— K1 SRS 内容校验(纯解析,无副作用)。
// onResult 收到 "" = 通过,否则错误文本;内核无该导出时回退 "unsupported"。
static napi_value ValidateSrsNative(napi_env env, napi_callback_info info)
{
    std::string path;
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    GetArgStringAt(env, argv[0], path);
    napi_value onResult = argc >= 2 ? argv[1] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([path, tsf]() {
        std::string message;
        do {
            std::string loadErr;
            if (!LoadCoreLib(loadErr)) {
                message = "err:" + loadErr;
                break;
            }
            if (g_validateSrs == nullptr) {
                message = "unsupported";
                break;
            }
            char *pathC = strdup(path.c_str());
            if (pathC == nullptr) {
                message = "err:failed to allocate rule-set path";
                break;
            }
            char *err = g_validateSrs(pathC);
            free(pathC);
            if (err != nullptr && err[0] != '\0') {
                message = std::string(err);
            }
            FreeGoString(err);
        } while (false);
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// testStartNativeV3(sessionId, configPath, bindIfname, onResult) —— K2:以 sessionId
// 建立独立测速会话。onResult 收到 "" = 成功,否则错误文本;内核无 V3 导出时
// 回退 "unsupported"(能力探测语义:调用方不得当成成功)。
static napi_value TestStartNativeV3(napi_env env, napi_callback_info info)
{
    std::string sessionId;
    std::string configPath;
    std::string bindIfname;
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    GetArgStringAt(env, argv[0], sessionId);
    GetArgStringAt(env, argv[1], configPath);
    GetArgStringAt(env, argv[2], bindIfname);
    napi_value onResult = argc >= 4 ? argv[3] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([sessionId, configPath, bindIfname, tsf]() {
        std::string message;
        do {
            std::string loadErr;
            if (!LoadCoreLib(loadErr)) {
                message = loadErr;
                break;
            }
            if (g_testStartV3 == nullptr) {
                message = "unsupported";
                break;
            }
            char *idC = strdup(sessionId.c_str());
            char *pathC = strdup(configPath.c_str());
            char *bindC = strdup(bindIfname.c_str());
            if (idC == nullptr || pathC == nullptr || bindC == nullptr) {
                free(idC);
                free(pathC);
                free(bindC);
                message = "failed to allocate K2 start arguments";
                break;
            }
            char *err = g_testStartV3(idC, pathC, bindC);
            free(idC);
            free(pathC);
            free(bindC);
            if (err != nullptr && err[0] != '\0') {
                message = std::string(err);
            }
            FreeGoString(err);
        } while (false);
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// testProxyNativeV3(sessionId, tag, url, timeoutMs, expectStatus, onResult) —— K2:
// 只在该 sessionId 会话内探测。onResult 收到 "ms" 或 "err:...",与 V2 同构;
// 内核无 V3 导出时回退 "unsupported"。
static napi_value TestProxyNativeV3(napi_env env, napi_callback_info info)
{
    std::string sessionId;
    std::string tag;
    std::string url;
    std::string expectStatus = "2xx";
    int timeoutMs = 5000;
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    GetArgStringAt(env, argv[0], sessionId);
    GetArgStringAt(env, argv[1], tag);
    GetArgStringAt(env, argv[2], url);
    GetArgInt(env, argv[3], timeoutMs);
    GetArgStringAt(env, argv[4], expectStatus);
    napi_value onResult = argc >= 6 ? argv[5] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([sessionId, tag, url, timeoutMs, expectStatus, tsf]() {
        std::string message = "unsupported";
        do {
            std::string loadErr;
            if (!LoadCoreLib(loadErr)) {
                message = "err:" + loadErr;
                break;
            }
            if (g_testProxyV3 == nullptr) {
                message = "unsupported";
                break;
            }
            char *idC = strdup(sessionId.c_str());
            char *tagC = strdup(tag.c_str());
            char *urlC = strdup(url.c_str());
            char *expectC = strdup(expectStatus.c_str());
            if (idC == nullptr || tagC == nullptr || urlC == nullptr || expectC == nullptr) {
                free(idC);
                free(tagC);
                free(urlC);
                free(expectC);
                message = "err:failed to allocate K2 probe arguments";
                break;
            }
            char *res = g_testProxyV3(idC, tagC, urlC, timeoutMs, expectC);
            free(idC);
            free(tagC);
            free(urlC);
            free(expectC);
            if (res != nullptr) {
                message = std::string(res);
            }
            FreeGoString(res);
        } while (false);
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// testStopNativeV3(sessionId, onResult) —— K2:停止该会话;"" = 实例已确认关闭
// (含未知/已停止 id 的幂等成功);内核无 V3 导出时回退 "unsupported"。
static napi_value TestStopNativeV3(napi_env env, napi_callback_info info)
{
    std::string sessionId;
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    GetArgStringAt(env, argv[0], sessionId);
    napi_value onResult = argc >= 2 ? argv[1] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([sessionId, tsf]() {
        std::string message;
        do {
            std::string loadErr;
            if (!LoadCoreLib(loadErr)) {
                message = loadErr;
                break;
            }
            if (g_testStopV3 == nullptr) {
                message = "unsupported";
                break;
            }
            char *idC = strdup(sessionId.c_str());
            if (idC == nullptr) {
                message = "failed to allocate K2 stop argument";
                break;
            }
            char *err = g_testStopV3(idC);
            free(idC);
            if (err != nullptr && err[0] != '\0') {
                message = std::string(err);
            }
            FreeGoString(err);
        } while (false);
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// testSessionInfoNativeV3(sessionId, onResult) —— K2:会话快照 JSON("" = 未知会话;
// "unsupported" = 内核无 V3 导出)。
static napi_value TestSessionInfoNativeV3(napi_env env, napi_callback_info info)
{
    std::string sessionId;
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    GetArgStringAt(env, argv[0], sessionId);
    napi_value onResult = argc >= 2 ? argv[1] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([sessionId, tsf]() {
        std::string message = "unsupported";
        do {
            std::string loadErr;
            if (!LoadCoreLib(loadErr)) {
                message = "err:" + loadErr;
                break;
            }
            if (g_testInfoV3 == nullptr) {
                message = "unsupported";
                break;
            }
            char *idC = strdup(sessionId.c_str());
            if (idC == nullptr) {
                message = "err:failed to allocate K2 info argument";
                break;
            }
            char *res = g_testInfoV3(idC);
            free(idC);
            if (res != nullptr) {
                message = std::string(res);
            }
            FreeGoString(res);
        } while (false);
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// testActiveSessionsNative(onResult) —— K2:当前 active 的 sessionId(逗号分隔,
// 串行语义下最多一个);"" = 无;内核无 V3 导出时回退 "unsupported"。
static napi_value TestActiveSessionsNative(napi_env env, napi_callback_info info)
{
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value onResult = argc >= 1 ? argv[0] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([tsf]() {
        std::string message = "unsupported";
        do {
            std::string loadErr;
            if (!LoadCoreLib(loadErr)) {
                message = "err:" + loadErr;
                break;
            }
            if (g_testActiveV3 == nullptr) {
                message = "unsupported";
                break;
            }
            char *res = g_testActiveV3();
            if (res != nullptr) {
                message = std::string(res);
            }
            FreeGoString(res);
        } while (false);
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// testStopNative(onResult)
static napi_value TestStopNative(napi_env env, napi_callback_info info)
{
    size_t argc = 8;
    napi_value argv[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value onResult = argc >= 1 ? argv[0] : nullptr;
    napi_threadsafe_function tsf = CreateResultTsf(env, onResult);

    std::thread([tsf]() {
        std::string message;
        if (g_testStop != nullptr) {
            char *err = g_testStop();
            if (err != nullptr && err[0] != '\0') {
                message = std::string(err);
            }
            FreeGoString(err);
        }
        EmitString(tsf, message);
        usleep(200 * 1000);
        napi_release_threadsafe_function(tsf, napi_tsfn_release);
    }).detach();
    return nullptr;
}

// stopCoreNative(onResult)
static napi_value StopCoreNative(napi_env env, napi_callback_info info){
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
        {"testStartNative", nullptr, TestStartNative, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testProxyNative", nullptr, TestProxyNative, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testStopNative", nullptr, TestStopNative, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testCapsNative", nullptr, TestCapsNative, nullptr, nullptr, nullptr, napi_default, nullptr},
        // K1 无副作用校验(缺失导出时回调 "unsupported")
        {"checkConfigNative", nullptr, CheckConfigNative, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"validateSrsNative", nullptr, ValidateSrsNative, nullptr, nullptr, nullptr, napi_default, nullptr},
        // K2 会话化测速(V3;缺失导出时回调 "unsupported")
        {"testStartNativeV3", nullptr, TestStartNativeV3, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testProxyNativeV3", nullptr, TestProxyNativeV3, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testStopNativeV3", nullptr, TestStopNativeV3, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testSessionInfoNativeV3", nullptr, TestSessionInfoNativeV3, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testActiveSessionsNative", nullptr, TestActiveSessionsNative, nullptr, nullptr, nullptr, napi_default, nullptr},
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
