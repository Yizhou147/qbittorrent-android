# qBittorrent Android APK

将 qBittorrent 编译为 Android APK，通过 WebUI 在手机上管理下载。

## 功能

- ✅ qBittorrent headless (无 GUI，通过浏览器 WebUI 控制)
- ✅ 前台服务保持后台运行
- ✅ 支持 magnet 链接和 .torrent 文件
- ✅ 自动释放 native binary
- ✅ 支持 arm64 (arm64-v8a) 架构

## 方式一：GitHub Actions 云编译 (最简单，无需本地环境)

1. **Fork 本项目** 到你的 GitHub 账号
2. 进入仓库 → **Actions** 标签页
3. 选择 **"Build qBittorrent Android"** 工作流
4. 点击 **"Run workflow"**
5. 等待约 30-60 分钟，完成后在 Artifacts 下载产物

或者直接用命令行：
```bash
# 如果你有 gh CLI
gh repo create qbittorrent-android --public
git clone https://github.com/你的用户名/qbittorrent-android.git
cd qbittorrent-android
cp -r /path/to/qbittorrent-android/* .
git add . && git commit -m "init" && git push
gh workflow run build-android.yml
```

## 方式二：本地 Docker 构建

### 前提条件

- Docker (用于交叉编译)
- Android SDK (用于构建 APK，可选)

## 快速开始

### 方式一：完整构建 (推荐)

```bash
# 1. 克隆项目
cd qbittorrent-android

# 2. 运行构建脚本
chmod +x build.sh
./build.sh

# 3. APK 位置
ls -la apk-project/app/build/outputs/apk/release/
```

### 方式二：仅编译 native binary

```bash
# 1. 用 Docker 编译
docker build -t qbittorrent-android .
docker create --name qbt qbittorrent-android
docker cp qbt:/output/qbittorrent-nox ./output/
docker rm qbt

# 2. 手动安装到手机
adb push output/qbittorrent-nox /data/local/qbt/
adb shell chmod 755 /data/local/qbt/qbittorrent-nox
adb shell /data/local/qbt/qbittorrent-nox --webui-port=8080 --daemon
```

### 方式三：使用 Android Studio

1. 用 Docker 编译 native binary
2. 用 Android Studio 打开 `apk-project` 目录
3. 将 `qBittorrent-nox` 复制到 `app/src/main/assets/`
4. 构建并运行

## 使用说明

1. 安装 APK 到手机
2. 首次运行会请求存储权限
3. 应用会自动启动 qBittorrent 后台服务
4. 内置 WebView 打开 WebUI: `http://localhost:8080`
5. 默认账号: `admin` / `adminadmin`
6. **首次登录后请立即修改密码!**

## 支持的 Intent

- `magnet:` 链接 → 自动添加到下载队列
- `.torrent` 文件 → 自动添加到下载队列

## 目录结构

```
qbittorrent-android/
├── Dockerfile          # 交叉编译环境
├── build.sh            # 一键构建脚本
├── README.md           # 本文件
└── apk-project/        # Android 项目
    ├── app/
    │   ├── build.gradle
    │   └── src/main/
    │       ├── AndroidManifest.xml
    │       ├── java/com/qbittorrent/android/
    │       │   ├── MainActivity.java
    │       │   └── QBittorrentService.java
    │       └── res/
    │           ├── layout/
    │           ├── values/
    │           └── xml/
    ├── build.gradle
    ├── settings.gradle
    └── gradlew
```

## 技术细节

- **编译工具链**: Android NDK r27c (clang 18)
- **目标架构**: arm64-v8a (aarch64)
- **最低 Android 版本**: 7.0 (API 24)
- **依赖库**:
  - OpenSSL 3.3.2 (静态编译)
  - Boost 1.86.0 (静态编译)
  - libtorrent 2.0.10 (静态编译)
  - zlib (使用 NDK 内置)

## 故障排除

### qBittorrent 无法启动

```bash
# 查看日志
adb logcat -s QBittorrentService

# 手动测试
adb shell
cd /data/data/com.qbittorrent.android/files
./qbittorrent-nox --profile=config --webui-port=8080
```

### WebUI 无法访问

1. 确认 qBittorrent 进程正在运行: `ps aux | grep qbittorrent`
2. 检查端口: `netstat -tlnp | grep 8080`
3. 检查防火墙设置

### 存储权限问题

- Android 11+ 需要 "所有文件访问" 权限
- 在设置中手动授予: 设置 → 应用 → qBittorrent → 权限 → 文件和媒体

## 许可证

- qBittorrent: GPL-2.0
- libtorrent: BSD
- 本项目: MIT
