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

// Set OpenSSL CA certificate paths as early as possible (when .so is loaded)
// This ensures the env vars are set before any SSL context is created
__attribute__((constructor))
static void set_openssl_env() {
    // These will be overridden in nativeMain with app-specific paths
    setenv("SSL_CERT_DIR", "/system/etc/security/cacerts", 1);
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
    // TMPDIR defaults to /data/local/tmp if not set
    if (!getenv("TMPDIR")) {
        setenv("TMPDIR", "/data/local/tmp", 1);
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
