# 移植笔记

本项目不是把 qBittorrent 编译成可执行文件再 fork/exec，而是编译成共享库 `libqbt.so`，
由 Android 应用进程通过 JNI 在进程内加载。以下记录移植过程中必须处理的问题。

## 组件构成

1. **Qt 运行时库**（源码重编，产物入库复用）
   - 4.3.9 / 4.6.7 使用 Qt 5.15.2；5.2.3 / 5.2.4 / 5.3.0 / 5.3.1 使用 Qt 6.6.3
     （qb 5.x 要求 Qt ≥ 6.6，交叉编译需 `QT_HOST_PATH`）
   - 运行库由 `build-qt.yml` + `Dockerfile.qt` 从源码编译 qtbase（只编 Core/Network/Sql/Xml
     + tls/sqldrivers 插件），产物提交在 `third-party/qt5|qt6/arm64-v8a/`，
     主构建直接拷进 jniLibs，**不再重编 Qt**
   - 必须源码重编的原因见下文「JNI_OnLoad 崩溃」：预编译 Qt 的 `JNI_OnLoad` 依赖 Activity 上下文
   - 主构建的 `Dockerfile` 只用 aqtinstall 拉同版本 Qt 的**头文件 / CMake config / 宿主工具**
     （moc/rcc/uic）来编 libqbt，运行期用的是 `third-party/` 里那份

2. **libtorrent**
   - qb 4.3.9 → 1.2.20；qb 4.6.7 → 2.0.10；qb 5.2.3 / 5.2.4 / 5.3.0 / 5.3.1 → 2.0.14
   - 必须用 `git clone --recursive` 获取源码（release tarball 缺 try_signal 等子模块）
   - 交叉编译目标 `arm64-v8a`，动态链接 `libc++_shared.so`

3. **qBittorrent**
   - 编译为共享库（`libqbt.so`），通过 JNI 桥接在 Android 进程内运行
   - 源码取自官方 release tag，移植补丁见 `ci/patches/<版本>/`
   - 包含完整的 WebUI 翻译文件（宿主机 lrelease 预编译 .qm + qrc）

4. **OpenSSL 3.3.2 + Boost 1.86.0**
   - 静态链接进 libtorrent 与 libqbt（`libqbt.so` 不依赖 libssl）
   - Qt 侧 TLS 插件是动态链接的，所以 `third-party/*/arm64-v8a/` 里仍随包提供
     `libssl.so` / `libcrypto.so`

## 1. JNI_OnLoad 崩溃问题

**问题**：Qt5 的 `androidjnimain.cpp` 中的 `JNI_OnLoad` 会初始化 GUI 平台插件，在无 GUI
环境下崩溃。

**解决**：
- 禁用 `androidjnimain.cpp` 中的 `JNI_OnLoad`
- 在 `qjnihelpers.cpp` 中添加最小 `JNI_OnLoad`，仅设置 JavaVM 指针
- 通过 JNI 桥接在 Android 进程内调用 qBittorrent `main()`
- Java 层动态扫描加载 `libQt5*` / `libQt6*`，同一份代码兼容两种 Qt

## 2. TLS 对齐问题（Android 16 / API 36）

**问题**：NDK r27 用 API 24 编译的二进制 TLS 对齐只有 8 字节，Android 16 linker 要求至少 64 字节。

**解决**：libtorrent 与 qBittorrent 用 `ANDROID_PLATFORM=android-35` 编译，自动获得 64 字节对齐。

## 3. C++ 运行时不匹配

**问题**：静态链接 libc++ 与动态链接 `libc++_shared.so` 的 `type_info` 不兼容，导致 `std::bad_cast`。

**解决**：统一使用共享 `libc++_shared.so`。

## 4. WebUI 翻译文件

**问题**：LinguistTools 不可用导致翻译文件未编译。

**解决**：
- 容器内安装 `qttools5-dev-tools` / `qt6-l10n-tools`（提供宿主机 `lrelease`）
- 在 cmake configure 之前把 `.ts` 编成 `.qm`
- 生成 QRC 文件让 cmake 自动包含翻译资源（补丁把 LinguistTools 变为可选依赖）

## 5. Android 进程内的 JNI 崩溃（Qt6 / JNI_OnLoad）

**问题**：预编译 Qt（5.15.2 与 6.6.3 均如此）的 `libQt*Core` 在 `System.loadLibrary` 时执行
`JNI_OnLoad`，对本项目这种非 Qt-Activity 进程有两层崩溃：

1. APK 里没有 Qt 的 Java 类时，`JNI_OnLoad` 内 `RegisterNatives` 抛 `ClassNotFoundException`
   返回 `JNI_ERR`，库加载失败，WebUI 永远起不来；
2. 若把 Qt 的 Java 类打进 APK 让 `JNI_OnLoad` 成功，Qt 的 Android 帮手代码被真正激活，
   运行期会执行依赖 Activity/ClassLoader 的 JNI 调用，在真机上以
   `GetStaticMethodID(java_class == null)` 等 abort 闪退。

**解决**：Docker 内从源码重编 qtbase（5.15.2 / 6.6.3），补丁见 `ci/build-qt5.sh` / `ci/build-qt6.sh`：

- `JNI_OnLoad` 最小化：只设置 JavaVM 指针，不注册任何 natives；
- **缓存 app 的 ClassLoader 到 `g_jClassLoader`**：Qt 原本只在原版 `JNI_OnLoad` 里从
  `org.qtproject.qt.android.QtNative` 取值，而本 APK 不含那个 Java 类，于是
  `QJniObject::loadClass()` 对任何按类名的查找都返回 null——连 `android/os/Environment`、
  `java/util/TimeZone` 这类系统类也拿不到。改为从加载本库的
  `com.qbittorrent.android/QBittorrentService` 取（带系统 ClassLoader 兜底）。
  运行时向 logcat 打一行 `QtJNI: JNI_OnLoad: classLoader=ok`，用于区分「守卫兜住」和
  「类解析真的修好了」；
- **`qjniobject.cpp` 的 `getMethodID()` / `getFieldID()` 增加 NULL `jclass` 守卫**：
  Qt6 把 Android 实现改写成类型化模板 `callStaticMethod<T>`，不再判空；Qt5 的 varargs API
  一直有判空，所以同样是「类解析不到」，Qt5（4.3.9 / 4.6.7）能静默降级，Qt6 直接被 ART
  判为致命错误（`java_class == null in call to GetStaticMethodID`）。
  5.2.3 的第一现场是启动末期首次构造 `QMimeDatabase`
  → `QStandardPaths::locateAll(GenericDataLocation, "mime")`
  → `writableLocation(GenericDataLocation)` → `getExternalStorageDirectory()`；
- `qjnienvironment.cpp` 增加 NULL `javaVM` 守卫。

**验证**：CI 模拟器冒烟与真机实测均通过。

## 6. Qt6 资源 zstd 压缩（qb 5.x）

**问题**：Qt 6 的 rcc 默认用 zstd 压缩资源，生成的代码引用 `qt_resourceFeatureZstd` 符号，
链接 Android 预编译 QtCore 时报 undefined symbol。

**解决**：补丁在 `CommonConfig.cmake` 给 `CMAKE_AUTORCC_OPTIONS` 追加 `--no-zstd`，回退 zlib 压缩。

## 7. 旧版 qb 与新工具链的兼容

- **qb 4.3.9**：新 clang 将 narrowing 聚合初始化视为错误，libtorrent 1.2.20 追加
  `-Wno-error=c++11-narrowing*`；`execinfo.h` 在 Android 不可用，关闭 STACKTRACE
- **qb 5.2.3 / 5.2.4 / 5.3.0 / 5.3.1**：使用 boost::stacktrace（未编译该模块），关闭 STACKTRACE

## 8. 添加种子闪退（Boost 异常跨 DSO 未捕获）

**问题**：在 5.2.3 上，按 URL 添加种子、添加畸形磁力、上传损坏的 `.torrent` 都会立刻 SIGABRT：

```
Abort message: 'terminating due to uncaught exception of type
boost::system::system_error: unsupported URL protocol [libtorrent:24]'
backtrace: TorrentDescriptor::parse / load  <-  TorrentsController::addAction
```

**根因**：libtorrent 抛出的 `boost::system::system_error` 跨 DSO
（`libtorrent-rasterbar.so` → `libqbt.so`）时，qb 里的 `catch (const lt::system_error &)`
匹配不上（两个 DSO 各自静态链接了 Boost.System，异常类型身份不一致），异常逃出 `noexcept`
函数即 `std::terminate` → abort。qb 5.2.3 的 `TorrentDescriptor` 五个入口
（`parse` / `load` / `loadFromFile` / `saveToFile` / `saveToBuffer`）都是这个形状。

**为什么 4.3.9 / 4.6.7 不受影响**：它们没有 `TorrentDescriptor`，取种子/磁力用的是 libtorrent
的 error_code 版本 API（`lt::parse_magnet_uri(url, params, ec)`、`lt::bdecode(data, ec, ...)`），
不抛异常；只有 qb 5.x 新引入的 `TorrentDescriptor` 用的是抛异常的封装
（`lt::parse_magnet_uri(string)` / `lt::load_torrent_buffer(...)`），才踩到静态 Boost 构建下
「跨 DSO 异常类型身份不一致」的坑。补丁加在 5.2.3 / 5.2.4 / 5.3.0 / 5.3.1 上
（`ci/patches/<版本>/050-torrentdescriptor-catchall.patch`）。

**解决**：给这五处各补 `catch (const std::exception &)` + `catch (...)`。
`catch (...)` 不依赖类型匹配，是绕开跨 DSO 类型身份问题的确定性兜底；异常退化为返回错误信息，
WebUI 报错而不是进程崩溃。

**真机修复前后对照**：

| 输入 | 修复前 | 修复后 |
|---|---|---|
| 正常磁力 | 正常添加 | 正常添加 |
| `https://…torrent` | SIGABRT | 有响应（错误码或成功，取决于 TLS 后端） |
| `http://…torrent` | — | 种子正常加入 |
| 畸形磁力（`btih:not_a_valid_hash`） | SIGABRT | HTTP 409 |
| 随机字节的 `.torrent` | SIGABRT | HTTP 415 + 明确错误提示 |

CI 侧由 `test.yml` 的「非法输入只报错不崩溃」步骤做回归。

## 9. HTTPS：TLS 插件、系统 CA 与 tracker 证书

Android 上有三个独立的问题会表现成「https 用不了」，现已全部修复：

1. **TLS / SQLite 插件找不到**：Qt 默认用编译期 prefix 找插件（设备上不存在）。
   桥接在 qb `main()` 之前 `setenv("QT_PLUGIN_PATH", <nativeLibraryDir>, 1)`，
   `libplugins_tls_*`、`libplugins_sqldrivers_*` 正常加载。
2. **Qt 栈拿不到系统 CA**：Qt 在 Android 上取系统证书依赖缺失的 QtNative。
   把 Java 侧复制好的 `ca-certificates.crt` 注入 `QSslConfiguration::defaultConfiguration()`，
   按 URL 添加种子、GeoIP 下载等 Qt 网络请求恢复可用。
3. **libtorrent 的验证存储是空的**：`set_default_verify_paths()` 依赖编译期 OPENSSLDIR
   （设备上不存在）；系统 CA 目录的文件名是旧式 MD5 subject hash，OpenSSL 1.0+ 按 SHA1
   查找永远命不中。构建时用 `ci/patch-libtorrent.py` 给 libtorrent 打补丁，session 启动时
   显式 `load_verify_file()` 加载同一份 CA bundle。

`ValidateHTTPSTrackerCertificate` 默认 **true**（真机已验证 4.3.9 / 4.6.7 / 5.2.3 等变体的
https tracker 通告正常）。v1.2.0 及更早的包默认关闭校验，覆盖安装后需在 WebUI 手动打开。
