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
#include <dlfcn.h>
#include <sys/stat.h>
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
    setupQtPluginPath();
    if (caBundlePath[0])
        setupQtCaCertificates(caBundlePath);

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
