<p align="center">
  <img src="logo.png" width="128" height="128" alt="qBittorrent Android Logo">
</p>

<h1 align="center">qBittorrent for Android</h1>

<p align="center" style="font-size: 26px; font-weight: bold;">真正的安卓 qBittorrent 客户端！</p>


<p align="center">
  <img src="screenshot.jpg" width="100%" alt="qBittorrent Android Screenshot">
</p>

将 [qBittorrent](https://www.qbittorrent.org/) 移植到 Android 平台，通过 WebView 访问 WebUI 进行操作。

**支持三个 qBittorrent 版本**（CI 矩阵构建，任选）：

| qBittorrent | libtorrent | Qt | C++ 标准 | VueTorrent |
|---|---|---|---|---|
| 4.3.9 | 1.2.20 | 5.15.2 | 17 | v0.13.0（v1.0+ 要求 qb ≥ 4.4） |
| 4.6.7 | 2.0.10 | 5.15.2 | 17 | 最新 |
| 5.2.3 | 2.0.14 | 6.6.3 | 20 | 最新 |

不推荐进行PT下载，强行使用后果自负！

## 功能特性

- 完整的 qBittorrent 功能，通过 WebUI 访问
- 支持 ARM64 架构（arm64-v8a）
- 支持多语言界面（含中文）
- 自动初始化配置和密码设置
- 可自定义 WebUI 端口
- 可自定义默认下载路径
- 支持切换 WebUI（默认 WebUI / VueTorrent）
- 支持 BT/磁力链接下载
- 支持种子文件选择上传

## 技术架构

### 核心组件

1. **Qt 框架**（预编译包，经 aqtinstall 安装）
   - 4.3.9 / 4.6.7 使用 Qt 5.15.2 Android 版
   - 5.2.3 使用 Qt 6.6.3 Android 版（qb 5.x 要求 Qt ≥ 6.6，交叉编译需 QT_HOST_PATH）

2. **libtorrent**
   - qb 4.3.9 → libtorrent 1.2.20；qb 4.6.7 → 2.0.10；qb 5.2.3 → 2.0.14
   - 必须用 `git clone --recursive` 获取源码（release tarball 缺 try_signal 子模块）
   - 交叉编译目标 `arm64-v8a`，动态链接 `libc++_shared.so`

3. **qBittorrent**
   - 编译为共享库（libqbt.so），通过 JNI 桥接在 Android 进程内运行
   - 源码改自官方 release tag，补丁见 `ci/patches/<版本>/`
   - 包含完整的 WebUI 翻译文件（宿主机 lrelease 预编译 .qm + qrc）

4. **OpenSSL 3.3.2** + **Boost 1.86.0**
   - 静态编译，嵌入 libtorrent/libqbt，无需打包 libssl.so/libcrypto.so

### 关键技术问题及解决方案

#### 1. JNI_OnLoad 崩溃问题

**问题**：Qt5 的 `androidjnimain.cpp` 中的 `JNI_OnLoad` 初始化 GUI 平台插件，在无 GUI 环境下会崩溃。

**解决方案**：
- 禁用 `androidjnimain.cpp` 中的 `JNI_OnLoad`
- 在 `qjnihelpers.cpp` 中添加简单的 `JNI_OnLoad`，仅设置 JavaVM 指针
- 通过 JNI 桥接在 Android 进程内调用 qBittorrent main()
- Java 层动态扫描加载 `libQt5*`/`libQt6*`，同一份代码兼容两种 Qt

#### 2. TLS 对齐问题（Android 16/API 36）

**问题**：NDK r27 用 API 24 编译的二进制 TLS 对齐只有 8 字节，Android 16 linker 要求至少 64 字节。

**解决方案**：libtorrent 和 qBittorrent 用 `ANDROID_PLATFORM=android-35` 编译，自动获得 64 字节 TLS 对齐。

#### 3. C++ 运行时不匹配

**问题**：静态链接 libc++ 和动态链接 libc++_shared.so 的 type_info 不兼容，导致 `std::bad_cast`。

**解决方案**：统一使用共享 `libc++_shared.so`。

#### 4. WebUI 翻译文件

**问题**：LinguistTools 不可用导致翻译文件未编译。

**解决方案**：
- 容器内安装 `qttools5-dev-tools` / `qt6-l10n-tools`（提供宿主机 `lrelease`）
- 在 cmake configure 之前编译所有 `.ts` 文件为 `.qm` 文件
- 生成 QRC 文件，cmake 自动包含翻译资源（补丁将 LinguistTools 变为可选依赖）

#### 5. JNI_OnLoad 返回 JNI_ERR（启动卡死，模拟器冒烟测试发现）

**问题**：预编译 Qt（5.15.2 与 6.6.3 均如此）的 `libQt*Core` 在 `System.loadLibrary` 时执行
`JNI_OnLoad`，内部对 `org.qtproject.qt.android.QtNative` 做 `RegisterNatives`——APK 里没有
Qt 的 Java 类时抛 `ClassNotFoundException`，`JNI_OnLoad` 返回 `JNI_ERR`，加载库失败，
WebUI 永远不会启动（表象是卡在启动界面）。v1.1 通过本地重编 qtbase 打 JNI 补丁规避了此问题。

**解决方案**：把 Qt Android 包自带的 Java 类 jar（`QtAndroid.jar` / `Qt6Android.jar`）打包进
APK（`app/libs/`），JNI_OnLoad 注册 natives 即可成功。

#### 6. Qt6 资源 zstd 压缩（qb 5.x）

**问题**：Qt 6 的 rcc 默认用 zstd 压缩资源，生成的代码引用 `qt_resourceFeatureZstd` 符号，链接 Android 预编译 QtCore 时报 undefined symbol。

**解决方案**：补丁在 `CommonConfig.cmake` 给 `CMAKE_AUTORCC_OPTIONS` 追加 `--no-zstd`，回退 zlib 压缩。

#### 7. 旧版 qb 与新工具链的兼容

- **qb 4.3.9**：新 clang 将 narrowing 聚合初始化视为错误，libtorrent 1.2.20 编译参数追加 `-Wno-error=c++11-narrowing*`；`execinfo.h` 在 Android 不可用，关闭 STACKTRACE
- **qb 5.2.3**：使用 boost::stacktrace（未编译该模块），关闭 STACKTRACE

## 构建指南

### 方式一：GitHub Actions 自动构建（推荐，唯一支持的 CI 方式）

1. 打开仓库 Actions 页面，选择 `Build qBittorrent Android APK`
2. 点击 `Run workflow`，选择要构建的 qBittorrent 版本（`all` = 三个版本并行）
3. 等待构建完成（约 40-60 分钟）
4. 在 Artifacts 页面下载对应 APK（`qbittorrent-android-qb<版本>`）

推送 `v*` tag 会自动构建全部三个版本。

## 自动化测试

`test.yml` 工作流（与构建分开运行）：

1. **patch-check**：对 4.3.9 / 4.6.7 / 5.2.3 的官方源码试打移植补丁，断言关键标记
   （共享库化、JNI 桥接、翻译可选化、rcc `--no-zstd`），防止升级版本时补丁失效
2. **unit-tests**：JVM 单元测试（`./gradlew testReleaseUnitTest`），覆盖
   `QbtConfig` 的配置写入/改写/端口校验逻辑
3. **emulator-smoke**：构建工作流成功后自动触发，在 Android 30 模拟器（x86_64 +
   ARM 指令翻译）安装 APK，通过 `adb forward` 轮询本机 WebUI 端口并断言
   `/api/v2/app/version` 返回对应 qBittorrent 版本号；失败时上传 logcat

触发条件：push/PR 到 main 时跑 1、2；构建工作流完成后跑 3。

### 方式二：本地 Docker 构建

#### 环境要求

- Docker Desktop
- 约 10GB 磁盘空间

#### 准备源码

```bash
# 下载源码 + 应用移植补丁（同时会下载 OpenSSL/Boost）
./scripts/prepare-sources.sh 5.2.3        # 或 4.3.9 / 4.6.7
```

SDK/NDK 的三个 zip（platform-34 / build-tools 34 / NDK r27b）如未提前放入 `docker-sources/`，
请从 `dl.google.com/android/repository/` 手动下载，文件名见 `Dockerfile` 头部注释。

#### 一键构建

```bash
# qb 5.2.3 (Qt6)
docker build -t qbittorrent-android \
  --build-arg QT_KIND=qt6 --build-arg QT_VERSION=6.6.3 \
  --build-arg CXX_STANDARD=20 --build-arg EXTRA_CMAKE_FLAGS=-DSTACKTRACE=OFF .

# qb 4.3.9 / 4.6.7 (Qt5)
docker build -t qbittorrent-android \
  --build-arg QT_KIND=qt5 --build-arg QT_VERSION=5.15.2 \
  --build-arg CXX_STANDARD=17 .
```

#### 提取产物

```bash
mkdir -p build-output
docker create --name qb-out qbittorrent-android
docker cp qb-out:/output/lib/. ./build-output/
docker rm qb-out
```

#### 构建 APK

```bash
# 复制原生库到 jniLibs
cp build-output/libqbt_arm64-v8a.so apk-project/app/src/main/jniLibs/arm64-v8a/libqbt.so
cp build-output/*.so apk-project/app/src/main/jniLibs/arm64-v8a/

# 构建 APK
cd apk-project
./gradlew assembleRelease
```

APK 输出：`apk-project/app/build/outputs/apk/release/app-release.apk`（已签名，可直接安装）

## 使用说明

### 首次启动

1. 安装 APK 到 Android 设备
2. 打开应用，等待初始化完成（约 10-30 秒）
3. 默认密码：`adminadmin`
4. 点击"打开 WebUI"按钮访问界面

### WebUI 访问

- **本地访问**：http://localhost:8080（默认端口）
- **用户名**：admin
- **密码**：adminadmin（首次启动后显示在日志中）

### 设置功能

- **WebUI 切换**：支持默认 WebUI 和 VueTorrent，切换后自动重启应用
- **端口设置**：可自定义 WebUI 监听端口，重启后生效
- **下载路径**：可自定义默认下载路径，通过 API 立即生效
- **关于页面**：显示版本号、项目主页、致谢信息

### 语言设置

1. 打开 WebUI
2. 进入 设置 → WebUI → 语言
3. 选择"简体中文"或其他语言

## 目录结构

```
qbittorrent-android/
├── Dockerfile                    # Docker 构建环境（参数化: QT_KIND/QT_VERSION/CXX_STANDARD）
├── ci/
│   ├── apply-patches.sh          # 给 vanilla qbittorrent 源码应用 Android 移植补丁
│   └── patches/
│       ├── common/               # JNI 桥接（编入 libqbt.so）
│       ├── 4.3.9/                # 各版本补丁集
│       ├── 4.6.7/
│       └── 5.2.3/
├── scripts/
│   ├── prepare-sources.sh        # 本地构建: 下载源码并打补丁
│   └── ...                       # 历史构建/调试脚本
├── docker-sources/               # 构建前准备的源码（脚本生成，不入库）
├── apk-project/                  # Android 项目
│   ├── app/
│   │   ├── src/main/
│   │   │   ├── java/             # Java 源码
│   │   │   ├── assets/           # VueTorrent zip
│   │   │   ├── jniLibs/          # 原生库（CI 构建时刷新）
│   │   │   └── res/              # 资源文件
│   │   └── build.gradle
│   └── build.gradle
└── .github/workflows/
    └── build-android.yml         # CI/CD 工作流（矩阵构建三个版本）
```

## 已知问题

1. **启动较慢**：首次启动需要 10-30 秒初始化
2. **内存占用**：Qt5 和 libtorrent 较大，建议设备至少 2GB RAM
3. **Android 版本**：仅支持 Android 8.0+（API 26+）
4. **架构限制**：仅支持 ARM64 设备

## 版本历史

### v1.2 (2026-09-13)

- 支持 qBittorrent 4.3.9 / 4.6.7 / 5.2.3 三版本矩阵构建
- 5.2.3 变体升级到 Qt 6.6.3 + C++20
- libtorrent/qBittorrent 改用 API 35 target 编译（修复 Android 16 TLS 对齐问题）
- 修复 CI 构建产物缺少 Qt 库的问题
- Java 层动态加载 Qt5/Qt6 库；清理死代码；改用 nativeLibraryDir 标准 API
- CI 源码改从官方 release 下载 + 统一补丁集，移除 Git LFS 源码包

### v1.1 (2026-07-08)

- 新增设置页面：WebUI 切换、端口设置、下载路径设置
- 新增 VueTorrent WebUI 支持（默认中文）
- 新增关于页面：版本号、项目主页、致谢信息
- 修复端口设置不生效的问题
- 修复下载路径设置不生效的问题
- 修复 WebUI 切换后不生效的问题
- 优化启动流程：端口轮询 + 加载提示
- 移除日志功能

### v1.0 (2026-07-05)

- 初始发布
- qBittorrent 4.6.7 移植到 Android
- 支持 WebUI 中文界面
- 自动配置和密码设置

## 致谢

- [qBittorrent](https://www.qbittorrent.org/) - 原始 BitTorrent 客户端
- [Qt](https://www.qt.io/) - 跨平台应用框架
- [libtorrent](https://www.libtorrent.org/) - BitTorrent 库
- [OpenSSL](https://www.openssl.org/) - 加密库
- [VueTorrent](https://github.com/WDaan/VueTorrent) - Vue.js WebUI

## 许可证

本项目遵循 [GPL-3.0 License](LICENSE)。

qBittorrent 本身是自由软件，遵循 GPLv2+ 许可证。
