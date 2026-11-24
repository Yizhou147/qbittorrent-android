# 构建指南

## 支持的版本

| qBittorrent | libtorrent | Qt | C++ 标准 | Gradle flavor |
|---|---|---|---|---|
| 4.3.9 | 1.2.20 | 5.15.2 | 17 | `v439` |
| 4.6.7 | 2.0.10 | 5.15.2 | 17 | `v467` |
| 5.2.3 | 2.0.14 | 6.6.3 | 20 | `v523` |
| 5.2.4 | 2.0.14 | 6.6.3 | 20 | `v524` |
| 5.3.0 | 2.0.14 | 6.6.3 | 20 | `v530` |
| 5.3.1 | 2.0.14 | 6.6.3 | 20 | `v531` |

CI 产物命名 `qbittorrent-android-qb<版本>-<ref>.apk`；release 资产命名
`qbittorrent-android-<版本>-v<tag>.apk`。

## 方式一：GitHub Actions（推荐）

1. 打开仓库 Actions 页面，选择 `Build qBittorrent Android APK`
2. `Run workflow`，选择要构建的版本（`all` = 六个版本并行）
3. 单变体实测约 15 分钟；`all` 为矩阵并行，整体时间取决于 runner 排队与并发
4. 在 Artifacts 页面下载对应 APK

推送 `v*` tag 会自动构建全部六个版本（发版后会触发一次，按需取消）。

> **Qt 运行时库**由单独的 `Build Qt runtime libs` 工作流（`build-qt.yml`）编译，
> 实测 qt6 约 7 分钟，产物提交在 `third-party/`。**只有改动 Qt 补丁
> （`ci/build-qt*.sh`）时才需要重跑**；日常改 qb 补丁、Java 代码或 Gradle 配置都不需要动 Qt。
> 运行库必须源码重编，原因见 [移植笔记](PORTING.md)。

## 签名（正式发布必须）

release 包使用固定密钥签名；否则每次 CI 构建的 debug key 都不同，用户无法覆盖安装。

- **本地/自建**：keystore 放任意位置（**不要放进仓库**，本仓库是 public），在
  `apk-project/signing.properties` 里写（该文件已被 `.gitignore` 排除）：

  ```properties
  storeFile=/绝对路径/keystore.jks
  storePassword=...
  keyAlias=...
  keyPassword=...        # 可省略，省略时与 storePassword 相同
  ```

- **CI**：仓库 Secrets 配 `QBT_KEYSTORE_BASE64`（keystore 的 base64）、
  `QBT_KEYSTORE_PASSWORD`、`QBT_KEY_ALIAS`、`QBT_KEY_PASSWORD`，工作流解码后通过环境变量
  交给 Gradle。
- 两处都没有时回退 debug 签名（仅供调试，产物不能互相覆盖安装，日志里会有 warning）。
- 构建日志会打印 `apksigner verify --print-certs` 与 `aapt2 dump packagename`，可直接核对。

## 方式二：本地 Docker

### 环境要求

- Docker Desktop
- 约 10GB 磁盘空间

### 准备源码

```bash
# 下载源码 + 应用移植补丁（同时会下载 OpenSSL/Boost）
./scripts/prepare-sources.sh 5.3.1        # 或 4.3.9 / 4.6.7 / 5.2.3 / 5.2.4 / 5.3.0
```

SDK/NDK 的三个 zip（platform-34 / build-tools 34 / NDK r27b）如未提前放入 `docker-sources/`，
请从 `dl.google.com/android/repository/` 手动下载，文件名见 `Dockerfile` 头部注释。

### 编译原生库

```bash
# qb 5.2.3 / 5.2.4 / 5.3.0 / 5.3.1 (Qt6)
docker build -t qbittorrent-android \
  --build-arg QT_KIND=qt6 --build-arg QT_VERSION=6.6.3 \
  --build-arg CXX_STANDARD=20 --build-arg EXTRA_CMAKE_FLAGS=-DSTACKTRACE=OFF .

# qb 4.3.9 / 4.6.7 (Qt5)
docker build -t qbittorrent-android \
  --build-arg QT_KIND=qt5 --build-arg QT_VERSION=5.15.2 \
  --build-arg CXX_STANDARD=17 .
```

### 提取产物

```bash
mkdir -p build-output
docker create --name qb-out qbittorrent-android
docker cp qb-out:/output/lib/. ./build-output/
docker rm qb-out
```

### 构建 APK

```bash
cp build-output/libqbt_arm64-v8a.so apk-project/app/src/main/jniLibs/arm64-v8a/libqbt.so
cp build-output/*.so apk-project/app/src/main/jniLibs/arm64-v8a/

cd apk-project
./gradlew assembleV531Release    # 或 assembleV439Release / assembleV467Release ...
```

产物位于 `apk-project/app/build/outputs/apk/<flavor>/release/app-<flavor>-release.apk`。

## 目录结构

```
qbittorrent-android/
├── Dockerfile                    # 主构建环境: 编 libtorrent/libqbt（QT_KIND/QT_VERSION/CXX_STANDARD 参数化）
├── Dockerfile.qt                 # Qt 运行时库构建环境（build-qt.yml 使用）
├── ci/
│   ├── apply-patches.sh          # 给 vanilla qBittorrent 源码应用移植补丁
│   ├── build-qt5.sh              # 源码编译 qtbase 5.15.2 + JNI 补丁
│   ├── build-qt6.sh              # 源码编译 qtbase 6.6.3 + JNI 补丁
│   ├── build-native.sh           # libtorrent/libqbt 编译
│   ├── patch-libtorrent.py       # libtorrent CA 路径补丁
│   ├── smoke-functional.sh       # 真机功能测试
│   └── patches/
│       ├── common/               # JNI 桥接（编入 libqbt.so）
│       └── <版本>/               # 各版本补丁集
├── third-party/                  # Qt 运行时库产物（build-qt.yml 生成，入库复用）
│   ├── qt5/arm64-v8a/
│   └── qt6/arm64-v8a/
├── scripts/prepare-sources.sh    # 本地构建: 下载源码并打补丁
├── apk-project/                  # Android 项目（Java + Gradle + assets + jniLibs）
└── .github/workflows/
    ├── build-android.yml         # 主构建: 矩阵构建六版本 APK
    ├── build-qt.yml              # Qt 运行时库（产物提交进 third-party/）
    ├── build-apk-prebuilt.yml    # 零编译出包（历史遗留，不用于发布）
    └── test.yml                  # patch-check / unit-tests / emulator-smoke
```
