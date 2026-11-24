# 常见问题

## 首次启动要等多久？

首次启动需要初始化配置文件与 WebUI，约 10–30 秒；之后启动更快。界面会显示加载进度。

## 对设备有什么要求？

| 项目 | 要求 |
|---|---|
| 架构 | **arm64-v8a**（不支持 x86 / armeabi-v7a） |
| 安装下限 | Android 7.0（API 24，Gradle `minSdk`） |
| 实测环境 | Android 11 及以上 |

更低 Android 版本未做真机验证；如遇到启动失败，请附上 `adb logcat` 中应用进程的日志反馈。
内存建议 2GB 以上（Qt + libtorrent 占用较大）。

## 默认密码和端口是什么？

- 地址：`http://localhost:8080`（可在设置页改端口，重启应用生效）
- 用户名：`admin`
- 密码：`adminadmin`（首次启动后也会写入日志）

## 多个变体能同时安装吗？

可以。各变体包名不同，互不影响（**最新的 qb 变体使用基础包名**）：

| 变体 | 包名 | 应用名 |
|---|---|---|
| qb 4.3.9 | `com.qbittorrent.android.qb439` | qBittorrent 4.3.9 |
| qb 4.6.7 | `com.qbittorrent.android.qb467` | qBittorrent 4.6.7 |
| qb 5.2.3 | `com.qbittorrent.android.qb523` | qBittorrent 5.2.3 |
| qb 5.2.4 | `com.qbittorrent.android.qb524` | qBittorrent 5.2.4 |
| qb 5.3.0 | `com.qbittorrent.android.qb530` | qBittorrent 5.3.0 |
| qb 5.3.1（最新） | `com.qbittorrent.android` | qBittorrent |

- 约定：最新的 qb 变体使用基础包名 `com.qbittorrent.android`，后续新增的最新版本沿用；
  4.3.9 / 4.6.7 与此前的 5.x 变体保留带后缀的包名。
- 5.3.1 使用基础包名，与 v1.2.0 之前的旧版同包名；如果设备上还留着旧版，需要先卸载旧版再安装
  （旧版不是固定密钥签名，无法直接覆盖）。
- 从 v1.2.0 起 release 包使用固定密钥签名，同一包名下的新版本可直接覆盖安装。
- 各变体 WebUI 默认端口都是 8080，同时运行请改成不同端口；默认下载目录也建议分别设置
  （默认 `/storage/emulated/0/Download`）。

## 按 URL / https 链接添加种子失败？

v1.2.1 起已修复。早期的三个问题（Qt TLS 插件路径、Qt 拿不到系统 CA、libtorrent 验证存储为空）
及修复方式见[移植笔记](PORTING.md)。

- 从 **v1.2.0 及更早版本覆盖安装**的用户，配置里保存的 `ValidateHTTPSTrackerCertificate`
  仍是 `false`，需要在 WebUI 中手动打开；新装默认是 `true`。
- 如果仍然失败，先确认链接本身可访问，再用 `adb logcat` 查看应用进程日志。
