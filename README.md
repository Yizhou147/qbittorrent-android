# qBittorrent for Android

将 [qBittorrent](https://github.com/qbittorrent/qBittorrent) 编译为 Android 原生应用，通过内置 WebUI 管理下载。

## 功能

- 📱 原生 Android APK，安装即用
- 🔄 前台服务保持后台下载不中断
- 🧲 支持 magnet 链接和 .torrent 文件点击添加
- 🌐 内置 WebView 访问 WebUI (`http://localhost:8080`)
- 📁 下载目录：`Downloads/qBittorrent/`
- 🏗️ 架构：arm64-v8a，最低支持 Android 7.0 (API 24)

## 快速开始

### 方式一：GitHub Actions 云编译（推荐，无需本地环境）

1. **Fork 本仓库** 到你的 GitHub 账号
2. 进入仓库 → **Actions** 标签页
3. 选择 **"Build qBittorrent Android"** 工作流
4. 点击 **"Run workflow"** → 等待 30-60 分钟
5. 编译完成后在 **Actions → 对应 Run → Artifacts** 下载产物

### 方式二：本地 Docker 构建

```bash
# 前提：安装 Docker
git clone https://github.com/Yizhou147/qbittorrent-android.git
cd qbittorrent-android
chmod +x build.sh
./build.sh
```

### 方式三：Android Studio

1. 用上述任一方式获取编译好的 `qbittorrent-nox` 二进制文件
2. 将其放入 `apk-project/app/src/main/assets/`
3. 用 Android Studio 打开 `apk-project` 目录
4. Build → Generate Signed APK

## 部署到手机

### 通过 APK（推荐）

安装编译好的 APK，首次运行会请求存储权限，授权后自动启动。

### 通过 ADB 手动安装

```bash
adb push qbittorrent-nox /data/local/qbt/
adb shell chmod 755 /data/local/qbt/qbittorrent-nox
adb shell /data/local/qbt/qbittorrent-nox \
  --profile=/data/local/qbt \
  --save-path=/sdcard/Downloads/qBittorrent \
  --webui-port=8080 --daemon
```

然后浏览器访问 `http://localhost:8080`。

## 使用说明

| 项目 | 说明 |
|------|------|
| WebUI 地址 | `http://localhost:8080` |
| 默认账号 | `admin` |
| 默认密码 | `adminadmin` |
| ⚠️ 首次登录后 | **请立即修改密码！** |
| 下载目录 | `/sdcard/Downloads/qBittorrent/` |

### 故障排除

```bash
# 查看运行日志
adb logcat -s QBittorrentService

# 手动测试启动
adb shell
cd /data/data/com.qbittorrent.android/files
./qbittorrent-nox --profile=config --webui-port=8080
```

## 编译细节

| 组件 | 版本 | 许可证 |
|------|------|--------|
| qBittorrent | 5.0.2 | GPL-2.0 |
| libtorrent | 2.0.10 | BSD-2-Clause |
| OpenSSL | 3.3.2 | Apache-2.0 |
| Boost | 1.86.0 | BSL-1.0 |

- 编译工具链：Android NDK r27c (Clang 18)
- 目标架构：arm64-v8a (aarch64)
- 最低 API：24 (Android 7.0)

## 项目结构

```
qbittorrent-android/
├── .github/workflows/
│   └── build-android.yml      # GitHub Actions 编译工作流
├── Dockerfile                 # 本地 Docker 编译环境
├── build.sh                   # 本地一键构建脚本
├── LICENSE                    # GPL-2.0
└── apk-project/               # Android APK 项目
    ├── app/src/main/
    │   ├── AndroidManifest.xml
    │   ├── java/.../
    │   │   ├── MainActivity.java        # WebView + 权限管理
    │   │   └── QBittorrentService.java  # 后台服务
    │   └── res/
    ├── build.gradle
    └── gradlew
```

## 许可证

本项目基于 [GPL-2.0](LICENSE) 许可证，与上游 qBittorrent 保持一致。

qBittorrent 是 [qBittorrent 项目](https://github.com/qbittorrent/qBittorrent) 的产物，其版权归 qBittorrent 贡献者所有。
