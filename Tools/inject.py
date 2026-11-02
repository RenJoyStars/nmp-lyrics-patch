#!/usr/bin/env python3
"""给 fat Mach-O 的每个 slice 追加一条 LC_LOAD_DYLIB。

原理：
- 64 位 Mach-O 的 load commands 结束后到第一个 section 之间有 2–3KB 对齐填充，
  直接把新 load command 写进这段填充即可（不用移动任何内容、不改文件大小）。
- LC_LOAD_DYLIB 指向 @executable_path/../Frameworks/libNMPLyrics.dylib，
  该文件由 build.sh 放进 bundle，启动即由 dyld 加载。
- 重复运行不会重复注入（同路径已存在则跳过）。

用法: python3 Tools/inject.py "/Applications/Neural Mix Pro.app/Contents/MacOS/Neural Mix Pro"
"""
import struct
import sys
from pathlib import Path

LC_LOAD_DYLIB = 0x0C
LC_SEGMENT_64 = 0x19
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
DYLIB_PATH = b"@executable_path/../Frameworks/libNMPLyrics.dylib"


def align8(n: int) -> int:
    return (n + 7) & ~7


def patch_slice(data: bytearray, off: int) -> tuple[bool, str]:
    if off + 32 > len(data):
        return False, "slice 越界"
    magic = struct.unpack_from("<I", data, off)[0]
    if magic != MH_MAGIC_64:
        return False, f"不是 64 位 Mach-O（magic=0x{magic:08x}）"

    ncmds, sizeofcmds = struct.unpack_from("<II", data, off + 16)
    lc_start = off + 32
    lc_end = lc_start + sizeofcmds

    # 扫 load commands：①是否已注入；②找第一个 section 的文件偏移（= 可用填充区下界）
    first_section_off = None
    p = lc_start
    for _ in range(ncmds):
        if p + 8 > len(data):
            return False, "load command 越界"
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmdsize < 8:
            return False, "cmdsize 非法"
        if cmd == LC_LOAD_DYLIB:
            str_off = struct.unpack_from("<I", data, p + 8)[0]
            name = bytes(data[p + str_off:p + cmdsize]).split(b"\0", 1)[0]
            if DYLIB_PATH in name:
                return True, "已注入过，跳过"
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, p + 64)[0]
            seg_fileoff = struct.unpack_from("<Q", data, p + 40)[0]
            sp = p + 72
            for _ in range(nsects):
                if sp + 80 > p + cmdsize:
                    break
                sect_off = struct.unpack_from("<I", data, sp + 48)[0]
                segname = bytes(data[sp + 16:sp + 32]).split(b"\0", 1)[0]
                if segname == b"__TEXT" and sect_off > 0:
                    if first_section_off is None or sect_off < first_section_off:
                        first_section_off = sect_off
                sp += 80
            _ = seg_fileoff
        p += cmdsize

    if first_section_off is None:
        return False, "没找到 __TEXT section，无法判定填充区"

    # 本 slice 的第一个 section 偏移是相对 slice 起点的（thin 切片内坐标）
    padding = first_section_off - (lc_end - off)
    if padding < 0:
        return False, f"load commands 与 section 重叠（{padding}）"

    cmdsize = align8(24 + len(DYLIB_PATH) + 1)
    if cmdsize > padding:
        return False, f"填充区不够：需要 {cmdsize}，只有 {padding}"

    # 注入位置必须 8 字节对齐
    if (lc_end % 8) != 0:
        return False, "load commands 末尾未 8 字节对齐，放弃"

    # 确认填充区确实是零（不是被其他数据占用）
    if any(data[lc_end:lc_end + min(padding, cmdsize)]):
        return False, "填充区非零，存在数据，放弃（保守）"

    # 写入 LC_LOAD_DYLIB：cmd, cmdsize, name_off, timestamp, cur_ver, compat_ver + 路径
    payload = struct.pack("<6I", LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000)
    payload += DYLIB_PATH + b"\0" * (cmdsize - 24 - len(DYLIB_PATH))
    data[lc_end:lc_end + cmdsize] = payload
    struct.pack_into("<I", data, off + 16, ncmds + 1)
    struct.pack_into("<I", data, off + 20, sizeofcmds + cmdsize)
    return True, f"注入成功（填充区 {padding}B，新命令 {cmdsize}B）"


def patch_fat(path: Path) -> int:
    data = bytearray(path.read_bytes())
    fat_magic_be = struct.unpack_from(">I", data, 0)[0]
    if fat_magic_be != FAT_MAGIC:
        raise SystemExit("不是 fat binary，本项目预期 universal app")

    nfat = struct.unpack_from(">I", data, 4)[0]
    results = []
    for i in range(nfat):
        arch_off = 8 + i * 20
        cputype, cpusubtype, offset, size, align = struct.unpack_from(">5I", data, arch_off)
        ok, msg = patch_slice(data, offset)
        arch = {0x01000007: "x86_64", 0x0100000C: "arm64"}.get(cputype, hex(cputype))
        results.append(ok)
        print(f"  [{arch}] {msg}")
        _ = (cpusubtype, size, align)

    if not any(results):
        raise SystemExit("所有 slice 都注入失败")
    path.write_bytes(bytes(data))
    return 0


if __name__ == "__main__":
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        "/Applications/Neural Mix Pro.app/Contents/MacOS/Neural Mix Pro"
    )
    print(f"目标：{target}")
    sys.exit(patch_fat(target))
