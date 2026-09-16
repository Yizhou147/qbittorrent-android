# v1.1 时期的构建/调试脚本（已不再使用）

这些脚本是 v1.1 阶段在本地容器里手工编译 Qt5 / qBittorrent 时写的，路径写死为容器内的
`/build/...`，只适用于当时的临时环境。

现在的构建方式：

- CI：`build-android.yml`（主构建）/ `build-qt.yml`（Qt 运行时库）/ `build-apk-prebuilt.yml`（零编译出包）
- 本地：`scripts/prepare-sources.sh` 准备源码 → `docker build -f Dockerfile ...`

保留它们只为查阅历史（如当初怎么定位 JNI_OnLoad / OpenSSL 链接问题）。
