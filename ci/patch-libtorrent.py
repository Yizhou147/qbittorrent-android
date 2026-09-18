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

用法: patch-libtorrent.py <libtorrent 源码目录>
"""
import sys

MARKER = "qbittorrent-android: explicit CA loading"

ANCHOR = """#if TORRENT_USE_SSL
		error_code ec;
		m_ssl_ctx.set_default_verify_paths(ec);
"""

PATCH = """#if TORRENT_USE_SSL
		error_code ec;
		m_ssl_ctx.set_default_verify_paths(ec);
		// qbittorrent-android: explicit CA loading
		// 桌面发行版的默认路径在 Android 上不存在, 应用通过环境变量指向自己复制的
		// CA bundle/目录; 这里显式加载, 保证验证存储非空。
		if (const char* caFile = std::getenv("SSL_CERT_FILE"))
		{
			error_code caEc;
			m_ssl_ctx.load_verify_file(caFile, caEc);
#ifndef TORRENT_DISABLE_LOGGING
			if (caEc) session_log("SSL load_verify_file(%s) failed: %s", caFile, caEc.message().c_str());
#endif
		}
		if (const char* caDir = std::getenv("SSL_CERT_DIR"))
		{
			error_code caEc;
			m_ssl_ctx.add_verify_path(caDir, caEc);
#ifndef TORRENT_DISABLE_LOGGING
			if (caEc) session_log("SSL add_verify_path(%s) failed: %s", caDir, caEc.message().c_str());
#endif
		}
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

    if content.count(ANCHOR) != 1:
        # libtorrent 1.2.x 的 session_impl.cpp 结构不同; 这里只告警, 不中断构建,
        # 由工作流日志里能看到是否真的打上了 (补丁标记检查)。
        print("警告: 未找到 set_default_verify_paths 锚点, 本版本未打补丁 (源码版本不匹配?)")
        return 0
    content = content.replace(ANCHOR, PATCH, 1)

    # 确保 <cstdlib> 可用 (std::getenv)
    if "#include <cstdlib>" not in content:
        inc_anchor = "#include <cstdint>"
        if inc_anchor in content:
            content = content.replace(inc_anchor, "#include <cstdint>\n#include <cstdlib>", 1)
        else:
            content = "#include <cstdlib>\n" + content

    with open(path, "w") as f:
        f.write(content)
    print(f"已给 {path} 打上显式 CA 加载补丁")
    return 0


if __name__ == "__main__":
    sys.exit(main())
