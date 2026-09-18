#!/usr/bin/env python3
"""给 libtorrent 打补丁: 在 session 启动时显式加载应用指定的 CA 证书。

背景（qbittorrent-android）:
    tracker 的 https 通告走 libtorrent 自带的（静态链接的）OpenSSL。libtorrent 在
    session_impl::start_session() 里确实调用了 ssl::context::set_default_verify_paths()，
    但 OpenSSL 的"默认路径"来自编译期的 OPENSSLDIR（我们的构建里是容器内的 prefix，
    设备上不存在），而 libtorrent 自己的平台分支又是按桌面 Linux 的路径写死的
    （/etc/ssl/certs/ca-certificates.crt 等），Android 上都不存在。
    于是验证存储是空的 → 打开"验证 HTTPS tracker 证书"后所有 https tracker 都报
    asio.ssl error（关掉校验才能连上，等于放弃证书验证，中间人可窃取 PT passkey）。

补丁内容:
    在 set_default_verify_paths() 之后，若环境变量 SSL_CERT_FILE / SSL_CERT_DIR 存在
    （由本项目的 JNI 桥接设置，指向 app 复制出来的 CA bundle 与哈希名目录），则显式
    把它们加载进验证存储。

兼容性（本地已对各版本源码验证锚点唯一命中）:
    - 2.0.x（v2.0.10 / v2.0.14）: 锚点为 "#if TORRENT_USE_SSL" 分支
    - 1.2.x（v1.2.20，qBittorrent 4.3.9 用）: 锚点为 "#ifdef TORRENT_USE_OPENSSL" 分支，
      且 set_verify_mode 在 set_default_verify_paths 之前、后跟日志块

用法: patch-libtorrent.py <libtorrent 源码目录>
"""
import sys

MARKER = "qbittorrent-android: explicit CA loading"

# libtorrent >= 2.0
ANCHOR_20 = """#if TORRENT_USE_SSL
\t\terror_code ec;
\t\tm_ssl_ctx.set_default_verify_paths(ec);
"""

# libtorrent 1.2.x
ANCHOR_12 = """#ifdef TORRENT_USE_OPENSSL
\t\terror_code ec;
\t\tm_ssl_ctx.set_verify_mode(boost::asio::ssl::context::verify_none, ec);
\t\tm_ssl_ctx.set_default_verify_paths(ec);
#ifndef TORRENT_DISABLE_LOGGING
\t\tif (ec) session_log("SSL set_default verify_paths failed: %s", ec.message().c_str());
\t\tec.clear();
#endif
"""


def ca_loading_code():
    return """\t\t// qbittorrent-android: explicit CA loading
\t\t// 桌面发行版的默认路径在 Android 上不存在, 应用通过环境变量指向自己复制的
\t\t// CA bundle/目录; 这里显式加载, 保证验证存储非空。
\t\tif (const char* caFile = std::getenv("SSL_CERT_FILE"))
\t\t{
\t\t\terror_code caEc;
\t\t\tm_ssl_ctx.load_verify_file(caFile, caEc);
#ifndef TORRENT_DISABLE_LOGGING
\t\t\tif (caEc) session_log("SSL load_verify_file(%s) failed: %s", caFile, caEc.message().c_str());
#endif
\t\t}
\t\tif (const char* caDir = std::getenv("SSL_CERT_DIR"))
\t\t{
\t\t\terror_code caEc;
\t\t\tm_ssl_ctx.add_verify_path(caDir, caEc);
#ifndef TORRENT_DISABLE_LOGGING
\t\t\tif (caEc) session_log("SSL add_verify_path(%s) failed: %s", caDir, caEc.message().c_str());
#endif
\t\t}
"""


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    root = sys.argv[1].rstrip("/")
    path = f"{root}/src/session_impl.cpp"
    with open(path) as f:
        content = f.read()

    if MARKER in content:
        print("libtorrent 已经打过这个补丁, 跳过")
        return 0

    for name, anchor in (("2.0.x", ANCHOR_20), ("1.2.x", ANCHOR_12)):
        if content.count(anchor) == 1:
            content = content.replace(anchor, anchor + ca_loading_code(), 1)
            break
    else:
        print("警告: 未找到 set_default_verify_paths 锚点, 本版本未打补丁 (源码版本不匹配?)")
        return 0

    # 确保 <cstdlib> 可用 (std::getenv)
    if "#include <cstdlib>" not in content:
        for inc_anchor in ("#include <cstdint>",
                           "#include <cstdio> // for snprintf",
                           "#include <cstdio>"):
            if inc_anchor in content:
                content = content.replace(inc_anchor, inc_anchor + "\n#include <cstdlib>", 1)
                break
        else:
            content = "#include <cstdlib>\n" + content

    with open(path, "w") as f:
        f.write(content)
    print(f"已给 {path} 打上显式 CA 加载补丁")
    return 0


if __name__ == "__main__":
    sys.exit(main())
