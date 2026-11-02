#!/usr/bin/env python3
"""Check the shipped native libs against a target Android API level.

Usage: check-native-compat.py <jniLibs/arm64-v8a> <minSdk>

Fails the build when a library has a *strong* (GLOBAL) undefined reference to a
libc symbol that the target Android version does not export. Weak undefined
symbols are allowed: the loader resolves them to NULL and the fallback path is
the library's responsibility.

libqbt.so must not leave the C++ unwinder as a strong undefined reference: the
libqbt code uses _Unwind_* via exception cleanup and boost::stacktrace, and
bionic only exports those from API 30. The legacy build links the NDK's static
libunwind.a, so these symbols end up either defined (possibly hidden by
--exclude-libs, in which case they are absent from .dynsym) or absent entirely.
"""

import os
import struct
import sys

# Curated list of bionic libc symbols introduced after the oldest API we care
# about. Extend when a new API-level dependency shows up in a shipped lib.
HIGH_API_SYMBOLS = {
    "getentropy": 28,
    "getrandom": 28,
    "arc4random": 28,
    "arc4random_buf": 28,
    "arc4random_uniform": 28,
    "aligned_alloc": 28,
    "__ppoll64_chk": 28,
    "memfd_create": 30,
    "statx": 30,
    "pthread_cond_clockwait": 30,
    "pthread_mutex_clocklock": 30,
    "pthread_rwlock_clockrdlock": 30,
    "pthread_rwlock_clockwrlock": 30,
    "_Unwind_Resume": 30,
    "_Unwind_Backtrace": 30,
    "_Unwind_GetIP": 30,
    "_Unwind_GetIPInfo": 30,
    "_Unwind_GetCFA": 30,
    "_Unwind_RaiseException": 30,
    "_Unwind_SetIP": 30,
    "_Unwind_SetGR": 30,
}

REQUIRED_UNWINDER_SYMBOLS = ("_Unwind_Resume", "_Unwind_Backtrace", "_Unwind_GetIP")


class ElfError(Exception):
    pass


def parse_elf(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise ElfError("not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise ElfError("only little-endian ELF64 is supported")

    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize = struct.unpack_from("<H", data, 58)[0]
    e_shnum = struct.unpack_from("<H", data, 60)[0]
    e_shstrndx = struct.unpack_from("<H", data, 62)[0]

    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, stype, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from(
            "<IIQQQQIIQQ", data, off
        )
        sections.append(
            {
                "type": stype,
                "flags": flags,
                "offset": offset,
                "size": size,
                "link": link,
                "entsize": entsize,
            }
        )

    loads = []
    tls = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", data, off)[0]
        p_align = struct.unpack_from("<Q", data, off + 48)[0]
        if p_type == 1:
            loads.append(p_align)
        elif p_type == 7:
            tls.append(p_align)

    dynsym = next((s for s in sections if s["type"] == 11), None)
    if dynsym is None:
        raise ElfError("no .dynsym section")

    strtab = sections[dynsym["link"]]["offset"]
    symbols = {}
    for i in range(dynsym["size"] // 24):
        off = dynsym["offset"] + i * 24
        st_name, st_info, _st_other, st_shndx = struct.unpack_from("<IBBH", data, off)
        if st_name == 0:
            continue
        end = data.index(b"\0", strtab + st_name)
        name = data[strtab + st_name:end].decode("utf-8", "replace")
        symbols[name] = {
            "binding": st_info >> 4,  # 0 local, 1 global, 2 weak
            "defined": st_shndx != 0,
        }

    return {"loads": loads, "tls": tls, "symbols": symbols}


def check_library(path, min_sdk):
    name = os.path.basename(path)
    errors = []
    warnings = []
    info = parse_elf(path)

    for align in sorted(set(info["loads"])):
        if align < 0x4000:
            warnings.append(
                "PT_LOAD p_align=%#x < 0x4000 (16 KB page devices 无法加载)" % align
            )
    for align in sorted(set(info["tls"])):
        if align < 0x40:
            errors.append("PT_TLS p_align=%#x < 0x40 (Android 16 linker 要求 >=64)" % align)

    is_qbt = name.startswith("libqbt")
    for sym, entry in info["symbols"].items():
        api = HIGH_API_SYMBOLS.get(sym)
        if api is None or api <= min_sdk:
            continue
        if is_qbt and sym in REQUIRED_UNWINDER_SYMBOLS:
            continue  # 下面用更明确的提示单独检查
        if entry["defined"] or entry["binding"] == 2:
            continue
        errors.append(
            "GLOBAL undefined symbol '%s' (需要 API %d > minSdk %d)" % (sym, api, min_sdk)
        )

    if is_qbt:
        for sym in REQUIRED_UNWINDER_SYMBOLS:
            entry = info["symbols"].get(sym)
            # 静态链入后符号可能是 hidden-defined（被 strip 后直接从 .dynsym 消失），
            # 所以「不存在」是正常结果；只有强未定义才是问题。
            if entry is not None and not entry["defined"] and entry["binding"] != 2:
                errors.append(
                    "%s 仍是 GLOBAL 未定义: 需要 LEGACY_UNWIND=1 静态链接 libunwind.a" % sym
                )

    return errors, warnings


def main():
    if len(sys.argv) != 3:
        print("用法: check-native-compat.py <jniLibs/arm64-v8a> <minSdk>", file=sys.stderr)
        return 2

    lib_dir = sys.argv[1]
    try:
        min_sdk = int(sys.argv[2])
    except ValueError:
        print("minSdk 必须是整数: %s" % sys.argv[2], file=sys.stderr)
        return 2

    libs = sorted(
        os.path.join(lib_dir, f) for f in os.listdir(lib_dir) if f.endswith(".so")
    )
    if not libs:
        print("ERROR: %s 下没有 .so 文件" % lib_dir, file=sys.stderr)
        return 1

    total_errors = 0
    print("=== native 兼容性检查 (minSdk=%d, %d 个库) ===" % (min_sdk, len(libs)))
    for path in libs:
        try:
            errors, warnings = check_library(path, min_sdk)
        except ElfError as exc:
            print("[%s] ERROR: %s" % (os.path.basename(path), exc))
            total_errors += 1
            continue
        except Exception as exc:  # pragma: no cover - defensive
            print("[%s] ERROR: 解析失败: %s" % (os.path.basename(path), exc))
            total_errors += 1
            continue

        name = os.path.basename(path)
        if errors:
            total_errors += len(errors)
            for msg in errors:
                print("[%s] FAIL: %s" % (name, msg))
        else:
            print("[%s] OK" % name)
        for msg in warnings:
            print("[%s] WARN: %s" % (name, msg))

    if total_errors:
        print("=== 检查失败: %d 个问题 ===" % total_errors)
        return 1
    print("=== 检查通过 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
