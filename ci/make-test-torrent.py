#!/usr/bin/env python3
"""生成一个最小的、无 tracker 的单文件 .torrent，供 emulator 冒烟测试使用。

用法:
    python3 ci/make-test-torrent.py <输出文件> [内容字节数] [web_seed_url]

最后一个参数可选：给定时写入 `url-list`（BEP 19 web seed），
配合本机 http.server 就能做一次完全离线的真实下载测试。

stdout 打印 info-hash（40 位十六进制），方便调用方断言种子已加入。
"""
import hashlib
import sys

PIECE_LENGTH = 16384


def bencode(obj):
    if isinstance(obj, int):
        return b"i%de" % obj
    if isinstance(obj, bytes):
        return b"%d:%s" % (len(obj), obj)
    if isinstance(obj, str):
        return bencode(obj.encode("utf-8"))
    if isinstance(obj, list):
        return b"l" + b"".join(bencode(item) for item in obj) + b"e"
    if isinstance(obj, dict):
        out = b"d"
        for key in sorted(obj.keys()):
            out += bencode(key) + bencode(obj[key])
        return out + b"e"
    raise TypeError(f"不支持的类型: {type(obj)}")


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "test.torrent"
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 4096
    web_seed = sys.argv[3] if len(sys.argv) > 3 else None

    # 可预测的内容，便于下载完成后校验
    data = bytes((i * 7 + 13) % 256 for i in range(size))
    pieces = b"".join(
        hashlib.sha1(data[i:i + PIECE_LENGTH]).digest()
        for i in range(0, len(data), PIECE_LENGTH)
    )

    info = {
        "length": len(data),
        "name": "qbittorrent-android-smoke.bin",
        "piece length": PIECE_LENGTH,
        "pieces": pieces,
    }
    torrent = {
        "info": info,
        "comment": "qbittorrent-android emulator smoke test",
        "created by": "ci/make-test-torrent.py",
    }
    if web_seed:
        torrent["url-list"] = [web_seed]

    with open(out_path, "wb") as f:
        f.write(bencode(torrent))

    # 调用方可能还需要原始内容做校验
    with open(out_path + ".content", "wb") as f:
        f.write(data)

    print(hashlib.sha1(bencode(info)).hexdigest())


if __name__ == "__main__":
    main()
