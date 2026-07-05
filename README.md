# qBittorrent for Android

将 [qBittorrent](https://www.qbittorrent.org/) 4.6.7 移植到 Android 平台，通过 WebView 访问 WebUI 进行操作。

## 功能特性

- 完整的 qBittorrent 功能，通过 WebUI 访问
- 支持 ARM64 架构（arm64-v8a）
- 支持多语言界面（含中文）
- 自动初始化配置和密码设置
- 本地 HTTP 服务器（端口 8080）
- 支持 BT/磁力链接下载

## 技术架构

### 核心组件

1. **Qt5 框架**（从源码编译，禁用 JNI）
   - 版本：Qt 5.15.2
   - 编译选项：`-no-gui -no-widgets -openssl-runtime`
   - 特殊处理：选择性禁用 JNI_OnLoad 避免崩溃

2. **libtorrent**（版本 2.0.11）
   - 交叉编译目标：`aarch64-linux-android35`
   - 使用 C++17 标准

3. **qBittorrent**（版本 4.6.7）
   - 编译为共享库（libqbt.so）
   - 通过 JNI 桥接在 Android 进程内运行
   - 包含完整的 WebUI 翻译文件

### 关键技术问题及解决方案

#### 1. JNI_OnLoad 崩溃问题

**问题**：Qt5 的 `androidjnimain.cpp` 中的 `JNI_OnLoad` 初始化 GUI 平台插件，在无 GUI 环境下会崩溃。

**解决方案**：
- 禁用 `androidjnimain.cpp` 中的 `JNI_OnLoad`
- 在 `qjnihelpers.cpp` 中添加简单的 `JNI_OnLoad`，仅设置 JavaVM 指针
- 通过 JNI 桥接在 Android 进程内调用 qBittorrent main()

#### 2. TLS 对齐问题（Android 16/API 36）

**问题**：NDK r27 用 API 24 编译的二进制 TLS 对齐只有 8 字节，Android 16 linker 要求至少 64 字节。

**解决方案**：使用 `--target=aarch64-linux-android35` 编译，自动获得 64 字节 TLS 对齐。

#### 3. C++ 运行时不匹配

**问题**：静态链接 libc++ 和动态链接 libc++_shared.so 的 type_info 不兼容，导致 `std::bad_cast`。

**解决方案**：统一使用共享 `libc++_shared.so`。

#### 4. WebUI 翻译文件

**问题**：LinguistTools 不可用导致翻译文件未编译。

**解决方案**：
- 在 Docker 容器中安装 `qt5-tools`（提供 `lrelease`）
- 编译所有 `.ts` 文件为 `.qm` 文件
- 生成正确的 QRC 文件（前缀 `/www/translations`）
- 重新编译 qBittorrent 使翻译嵌入二进制文件

## 构建指南

### 环境要求

- Windows 10/11
- Docker Desktop
- Android Studio（用于 Gradle 构建）
- Android SDK（API 34）
- Android NDK r27b

### 构建步骤

#### 1. 准备 Docker 环境

```bash
# 构建 Docker 镜像
docker build -t qbt-builder -f Dockerfile .

# 启动容器
docker run -d --name qbt-qt5 qbt-builder tail -f /dev/null
```

#### 2. 编译依赖库（在 Docker 容器内）

```bash
# 进入容器
docker exec -it qbt-qt5 bash

# 执行完整构建脚本
bash /build/rebuild_all.sh
```

#### 3. 编译翻译文件

```bash
# 安装 lrelease 工具
apt-get update && apt-get install -y qt5-tools

# 编译翻译并重新构建 qBittorrent
bash /build/rebuild_with_translations.sh
```

#### 4. 收集产物

```bash
# 从容器复制 libqbt.so
docker cp qbt-qt5:/output/libqbt.so ./apk-project/app/src/main/jniLibs/arm64-v8a/

# 复制其他依赖库
docker cp qbt-qt5:/opt/qt5-custom/lib/libQt5Core_arm64-v8a.so ./apk-project/app/src/main/jniLibs/arm64-v8a/
docker cp qbt-qt5:/opt/qt5-custom/lib/libQt5Network_arm64-v8a.so ./apk-project/app/src/main/jniLibs/arm64-v8a/
docker cp qbt-qt5:/opt/qt5-custom/lib/libQt5Sql_arm64-v8a.so ./apk-project/app/src/main/jniLibs/arm64-v8a/
docker cp qbt-qt5:/opt/qt5-custom/lib/libQt5Xml_arm64-v8a.so ./apk-project/app/src/main/jniLibs/arm64-v8a/
docker cp qbt-qt5:/opt/openssl-arm64/lib/libssl.so ./apk-project/app/src/main/jniLibs/arm64-v8a/
docker cp qbt-qt5:/opt/openssl-arm64/lib/libcrypto.so ./apk-project/app/src/main/jniLibs/arm64-v8a/
docker cp qbt-qt5:/opt/boost-arm64/lib/libboost_system.so ./apk-project/app/src/main/jniLibs/arm64-v8a/
docker cp qbt-qt5:/opt/libtorrent-arm64/lib/libtorrent-rasterbar.so ./apk-project/app/src/main/jniLibs/arm64-v8a/
```

#### 5. 构建 APK

```bash
cd apk-project
./gradlew assembleDebug
```

## 使用说明

### 首次启动

1. 安装 APK 到 Android 设备
2. 打开应用，等待初始化完成（约 10-30 秒）
3. 日志区域会显示默认密码：`adminadmin`
4. 点击"打开 WebUI"按钮访问界面

### WebUI 访问

- **本地访问**：http://localhost:8080
- **用户名**：admin
- **密码**：adminadmin（首次启动后显示在日志中）

### 语言设置

1. 打开 WebUI
2. 进入 设置 → WebUI → 语言
3. 选择"简体中文"或其他语言

## 目录结构

```
qbittorrent-android/
├── Dockerfile                 # Docker 构建环境
├── rebuild_all.sh             # 完整构建脚本
├── rebuild_with_translations.sh # 翻译编译脚本
├── docker-sources/            # 源码和补丁
│   ├── qbittorrent/          # qBittorrent 源码
│   ├── qt-everywhere-src-5.15.2/  # Qt5 源码
│   └── libtorrent/           # libtorrent 源码
└── apk-project/              # Android 项目
    ├── app/
    │   ├── src/main/
    │   │   ├── java/         # Java 源码
    │   │   ├── jniLibs/      # 原生库
    │   │   └── res/          # 资源文件
    │   └── build.gradle
    └── build.gradle
```

## 已知问题

1. **启动较慢**：首次启动需要 10-30 秒初始化
2. **内存占用**：Qt5 和 libtorrent 较大，建议设备至少 2GB RAM
3. **Android 版本**：仅支持 Android 8.0+（API 26+）
4. **架构限制**：仅支持 ARM64 设备

## 版本历史

### v1.0.0 (2026-07-05)

- 初始发布
- qBittorrent 4.6.7 移植到 Android
- 支持 WebUI 中文界面
- 自动配置和密码设置

## 致谢

- [qBittorrent](https://www.qbittorrent.org/) - 原始 BitTorrent 客户端
- [Qt](https://www.qt.io/) - 跨平台应用框架
- [libtorrent](https://libtorrent.org/) - BitTorrent 库
- [OpenSSL](https://www.openssl.org/) - 加密库

## 许可证

本项目遵循 [GPL-2.0 License](LICENSE)。

qBittorrent 本身是自由软件，遵循 GPLv2+ 许可证。
