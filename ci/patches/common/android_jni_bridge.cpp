/*
 * JNI bridge for qBittorrent Android.
 * This file is compiled into libqbt.so and provides the nativeMain() JNI function
 * that the Java QBittorrentService calls after loading all Qt5 libraries via System.loadLibrary().
 *
 * Loading Qt5 libs via System.loadLibrary() triggers their JNI_OnLoad (in qjnihelpers.cpp),
 * which sets the global JavaVM pointer. This allows QCoreApplication to access Android JNI
 * services (QStandardPaths, etc.) without crashing.
 */

#include <jni.h>
#include <cstring>
#include <cstdlib>
#include <climits>
#include <cstdio>
#include <ctime>
#include <dirent.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/system_properties.h>
#include <sys/types.h>

#include <QList>
#include <QSslCertificate>
#include <QSslConfiguration>

// Set OpenSSL CA certificate paths as early as possible (when .so is loaded)
// This ensures the env vars are set before any SSL context is created
__attribute__((constructor))
static void set_openssl_env() {
    // These will be overridden in nativeMain with app-specific paths
    setenv("SSL_CERT_DIR", "/system/etc/security/cacerts", 1);
}

// 告诉 Qt 去哪里找插件: Qt 默认用编译期的 prefix (设备上不存在), 于是
// libplugins_tls_* / libplugins_sqldrivers_* 从来没有被加载过 —— 表现为
// "qt.network.ssl: No functional TLS backend was found", 进而 qb 里所有走 Qt 网络栈的
// https 请求都失败 (例如"按 URL 添加种子"需要先下载那个 .torrent)。
// 必须在第一次用到插件之前完成, 所以在调用 main() 之前设置。
static void setupQtPluginPath() {
    Dl_info info {};
    if (dladdr(reinterpret_cast<void *>(&setupQtPluginPath), &info) == 0 || !info.dli_fname)
        return;

    char dir[PATH_MAX] = {0};
    strncpy(dir, info.dli_fname, sizeof(dir) - 1);
    char *const slash = strrchr(dir, '/');
    if (!slash)
        return;
    *slash = '\0';
    if (dir[0] != '\0')
        setenv("QT_PLUGIN_PATH", dir, 1);
}

// x86_64 模拟器是把 arm64 代码经 ndk_translation 翻译执行的, 而翻译器没有实现
// ARMv8 的加密指令 (SHA/AES 那一类)。OpenSSL 的运行时能力检测会把它们当成可用,
// 一旦执行到就 SIGILL 直接杀进程 —— 例如 WebUI 读 preferences 时要渲染 HTTPS 证书
// (走 SHA256)。这里只在模拟器上关掉 OpenSSL 的运行时加速 (退回纯 C 实现),
// 真机保持原样, 性能不受影响。
static void disableOpenSslAccelerationOnEmulator() {
    char value[PROP_VALUE_MAX] = {0};
    if (__system_property_get("ro.kernel.qemu", value) <= 0)
        return;
    if (value[0] != '1')
        return;
    // 0 = 关闭全部运行时检测到的能力 (OpenSSL 支持用环境变量覆盖)
    setenv("OPENSSL_armcap", "0", 1);
}

// ===== dev: HTTPS tracker 证书校验问题的自检 =====
// 背景: tracker 走 libtorrent 自己的静态 OpenSSL, 它仍然验证不过 https tracker
// (打开 ValidateHTTPSTrackerCertificate 就报 asio.ssl error, 关掉就能问到服务器)。
// 这里把关键事实写到 /sdcard 上, 用 adb 就能读, 并且用 dlopen 调 libcrypto 直接
// 验证那个 CA bundle 到底能不能被加载。
static void writeCaSelfCheck(const char *profileDir, const char *cacertsDir,
                             const char *caBundlePath) {
    FILE *out = fopen("/storage/emulated/0/Download/qbt-ca-selfcheck.txt", "w");
    if (!out)
        out = stderr;

    time_t now = time(nullptr);
    fprintf(out, "=== qBittorrent CA self-check (%ld) ===\n", static_cast<long>(now));

    const char *envDir = getenv("SSL_CERT_DIR");
    const char *envFile = getenv("SSL_CERT_FILE");
    fprintf(out, "profileDir      = %s\n", profileDir ? profileDir : "(null)");
    fprintf(out, "SSL_CERT_DIR    = %s\n", envDir ? envDir : "(unset)");
    fprintf(out, "SSL_CERT_FILE   = %s\n", envFile ? envFile : "(unset)");
    fprintf(out, "getenv(OPENSSL_CONF)= %s\n", getenv("OPENSSL_CONF") ? getenv("OPENSSL_CONF") : "(unset)");

    // 目录里有多少个文件 (OpenSSL 的 CA 目录要求哈希文件名, 这里顺便看看名字样式)
    int dirCount = 0;
    if (DIR *d = opendir(cacertsDir)) {
        struct dirent *e = nullptr;
        char first[256] = {0};
        while ((e = readdir(d)) != nullptr) {
            if (e->d_name[0] == '.')
                continue;
            if (first[0] == 0)
                snprintf(first, sizeof(first), "%s", e->d_name);
            ++dirCount;
        }
        closedir(d);
        fprintf(out, "cacerts dir     = %s (%d 个文件, 首个: %s)\n", cacertsDir, dirCount, first);
    } else {
        fprintf(out, "cacerts dir     = %s (打不开!)\n", cacertsDir);
    }

    // bundle: 大小 + PEM 张数
    long bundleSize = -1;
    int pemCount = 0;
    if (FILE *f = fopen(caBundlePath, "rb")) {
        fseek(f, 0, SEEK_END);
        bundleSize = ftell(f);
        fseek(f, 0, SEEK_SET);
        char buf[4096];
        size_t n = 0;
        const char needle[] = "BEGIN CERTIFICATE";
        size_t matched = 0;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
            for (size_t i = 0; i < n; ++i) {
                if (buf[i] == needle[matched]) {
                    if (++matched == sizeof(needle) - 1) {
                        ++pemCount;
                        matched = 0;
                    }
                } else {
                    matched = (buf[i] == needle[0]) ? 1 : 0;
                }
            }
        }
        fclose(f);
        fprintf(out, "ca bundle       = %s (%ld 字节, 含 %d 张证书)\n", caBundlePath, bundleSize, pemCount);
    } else {
        fprintf(out, "ca bundle       = %s (打不开!)\n", caBundlePath);
    }

    // 直接问 libcrypto: 这个 bundle 它认不认
    void *lib = dlopen("libcrypto.so", RTLD_NOW);
    if (!lib)
        lib = dlopen("libcrypto.so.3", RTLD_NOW);
    if (lib) {
        typedef void *(*store_new_t)(void);
        typedef int (*store_load_file_t)(void *, const char *);
        typedef int (*store_load_loc_t)(void *, const char *, const char *);
        typedef void (*store_free_t)(void *);
        auto store_new = reinterpret_cast<store_new_t>(dlsym(lib, "X509_STORE_new"));
        auto store_load_file = reinterpret_cast<store_load_file_t>(dlsym(lib, "X509_STORE_load_file"));
        auto store_load_loc = reinterpret_cast<store_load_loc_t>(dlsym(lib, "X509_STORE_load_locations"));
        auto store_free = reinterpret_cast<store_free_t>(dlsym(lib, "X509_STORE_free"));
        if (store_new && store_free && (store_load_file || store_load_loc)) {
            void *store = store_new();
            int ok = 0;
            if (store_load_file)
                ok = store_load_file(store, caBundlePath);
            else
                ok = store_load_loc(store, caBundlePath, nullptr);
            fprintf(out, "libcrypto 加载 bundle: %s (via %s)\n", ok == 1 ? "成功" : "失败",
                    store_load_file ? "X509_STORE_load_file" : "X509_STORE_load_locations");
            store_free(store);
        } else {
            fprintf(out, "libcrypto 符号缺失\n");
        }
    } else {
        fprintf(out, "dlopen libcrypto.so 失败: %s\n", dlerror() ? dlerror() : "?");
    }

    fprintf(out, "=== 结束 ===\n");
    if (out != stderr)
        fclose(out);
}

// 把 Java 侧已经复制好的 CA 证书灌给 Qt。
// Qt 在 Android 上取系统证书只能走 QtNative (本 APK 不含该 Java 类), 而 Qt6 的 OpenSSL
// 后端又不读 SSL_CERT_FILE/SSL_CERT_DIR (那是给 libtorrent 的静态 OpenSSL 用的),
// 所以 QSslConfiguration 的 CA 列表默认是空的 -> 即使 TLS 插件加载成功, https 也会因为
// 证书验证失败而连不上。
static void setupQtCaCertificates(const char *caBundlePath) {
    if (!caBundlePath || (caBundlePath[0] == '\0'))
        return;

    const QList<QSslCertificate> certs = QSslCertificate::fromPath(QString::fromUtf8(caBundlePath)
                                                                  , QSsl::Pem);
    if (certs.isEmpty())
        return;

    QSslConfiguration conf = QSslConfiguration::defaultConfiguration();
    conf.setCaCertificates(certs);
    QSslConfiguration::setDefaultConfiguration(conf);
}

// Suppress -Wmain: we intentionally call main() from the JNI bridge
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmain"

// The main() function from main.cpp
extern int main(int argc, char *argv[]);

extern "C" {

JNIEXPORT jint JNICALL
Java_com_qbittorrent_android_QBittorrentService_nativeMain(
    JNIEnv *env,
    jobject /* this */,
    jobjectArray argsArray)
{
    int argc = env->GetArrayLength(argsArray);
    if (argc <= 0) return -1;

    auto **argv = static_cast<char **>(malloc(sizeof(char *) * (argc + 1)));
    if (!argv) return -1;

    for (int i = 0; i < argc; i++) {
        auto jarg = static_cast<jstring>(env->GetObjectArrayElement(argsArray, i));
        if (jarg) {
            const char *arg = env->GetStringUTFChars(jarg, nullptr);
            argv[i] = strdup(arg);
            env->ReleaseStringUTFChars(jarg, arg);
        } else {
            argv[i] = strdup("");
        }
    }
    argv[argc] = nullptr;

    // Set HOME and TMPDIR from --profile arg if present
    char profileDir[512] = {0};
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "--profile=", 10) == 0) {
            strncpy(profileDir, argv[i] + 10, sizeof(profileDir) - 1);
            setenv("HOME", profileDir, 1);
            break;
        }
    }
    // TMPDIR must be app-writable: /data/local/tmp is not accessible to apps
    // on modern Android, so prefer <profile>/tmp
    if (!getenv("TMPDIR")) {
        if (profileDir[0]) {
            char tmpDir[600] = {0};
            snprintf(tmpDir, sizeof(tmpDir), "%s/tmp", profileDir);
            mkdir(tmpDir, 0700);
            setenv("TMPDIR", tmpDir, 1);
        } else {
            setenv("TMPDIR", "/data/local/tmp", 1);
        }
    }

    // Point OpenSSL to CA certificates
    // Try the app's cacerts directory first (copied by Java), then system
    char cacertsPath[600] = {0};
    char caBundlePath[600] = {0};
    if (profileDir[0]) {
        snprintf(cacertsPath, sizeof(cacertsPath), "%s/cacerts", profileDir);
        snprintf(caBundlePath, sizeof(caBundlePath), "%s/ca-certificates.crt", profileDir);
    }
    if (cacertsPath[0]) {
        setenv("SSL_CERT_DIR", cacertsPath, 1);
    } else {
        setenv("SSL_CERT_DIR", "/system/etc/security/cacerts", 1);
    }
    if (caBundlePath[0]) {
        setenv("SSL_CERT_FILE", caBundlePath, 1);
    }

    // Qt 侧: 插件搜索路径 (tls/sqldrivers) + CA 证书, 都必须在 qb 的 main() 之前就绪。
    // 前者决定 QSslSocket 能不能有 TLS 后端, 后者决定 https 证书能不能验证通过。
    // 注意顺序: 模拟器上先关掉 OpenSSL 加速, 再做任何会用到 OpenSSL 的事情。
    disableOpenSslAccelerationOnEmulator();
    setupQtPluginPath();
    if (caBundlePath[0])
        setupQtCaCertificates(caBundlePath);
    writeCaSelfCheck(profileDir, cacertsPath, caBundlePath);

    // Call qBittorrent's main()
    int result = main(argc, argv);

    // Cleanup
    for (int i = 0; i < argc; i++) {
        free(argv[i]);
    }
    free(argv);

    return result;
}

} // extern "C"

#pragma GCC diagnostic pop
