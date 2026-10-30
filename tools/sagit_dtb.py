#!/usr/bin/env python3
"""Assemble the Qualcomm appended-DTB tail for a Xiaomi Mi 6 (sagit) boot image.

ABL scans the DTB tail of the boot image, picks the entry whose qcom,board-id
matches the phone and passes it to the next stage (our shim in x0, Android's
kernel normally). sagit is board-id 30 0.

  sagit_dtb.py DTB_DIR OUT
  sagit_dtb.py --from-boot BOOT_IMG OUT

DTB_DIR holds whole .dtb files (dtb/sagit/*.dtb, compiled from the MiCode
msm8998 device trees).  --from-boot parses an Android boot image,
decompresses its gzip kernel and keeps everything after it, so a stock Mi 6
boot.img can be reused verbatim.

Both modes print model/board-id/msm-id and the continuous-splash region so
the shim/ADT constants can be checked against the DT actually shipped.
"""
import glob, os, struct, sys, zlib

FDT_MAGIC = b'\xd0\x0d\xfe\xed'
SAGIT_BOARD_ID = (30, 0)
SAGIT_SPLASH = 0x9d600000


def be32(b, off):
    return struct.unpack_from('>I', b, off)[0]


def root_props(b):
    off = be32(b, 8)			# off_dt_struct
    strings = be32(b, 12)
    assert be32(b, off) == 1
    p = off + 4
    e = b.index(b'\0', p)			# root name (usually empty)
    p = (e + 1 + 3) & ~3
    props = {}
    while be32(b, p) == 3:
        ln, nameoff = struct.unpack_from('>II', b, p + 4)
        val = b[p + 12:p + 12 + ln]
        name = b[strings + nameoff:b.index(b'\0', strings + nameoff)].decode()
        props[name] = val
        p = (p + 12 + ln + 3) & ~3
    return props


def find_splash(b):
    """First reg of a node whose name contains splash_region, or None."""
    off = be32(b, 8)
    strings = be32(b, 12)
    p = off + 4
    e = b.index(b'\0', p)
    p = (e + 1 + 3) & ~3
    stack = []
    while True:
        tag = be32(b, p)
        if tag == 1:				# FDT_BEGIN_NODE
            e = b.index(b'\0', p + 4)
            stack.append(b[p + 4:e].decode(errors='replace'))
            p = (e + 1 + 3) & ~3
        elif tag == 2:				# FDT_END_NODE
            stack.pop()
            p += 4
        elif tag == 3:				# FDT_PROP
            ln, nameoff = struct.unpack_from('>II', b, p + 4)
            name = b[strings + nameoff:b.index(b'\0', strings + nameoff)].decode()
            val = b[p + 12:p + 12 + ln]
            if name == 'reg' and stack and 'splash' in stack[-1]:
                if len(val) >= 16:			# 2 address cells + 2 size cells
                    addr = (struct.unpack_from('>I', val, 0)[0] << 32) | struct.unpack_from('>I', val, 4)[0]
                    size = (struct.unpack_from('>I', val, 8)[0] << 32) | struct.unpack_from('>I', val, 12)[0]
                    return addr, size
                if len(val) >= 8:			# 1 + 1 cells
                    return struct.unpack_from('>II', val, 0)
            p = (p + 12 + ln + 3) & ~3
        elif tag == 4:				# FDT_END
            return None
        else:
            raise SystemExit('corrupt FDT structure')


def cells(val):
    return ' '.join(hex(x) for x in struct.unpack('>%dI' % (len(val) // 4), val)) if val else '-'


def dtb_chain(buf, start):
    p = start
    n = 0
    while p < len(buf):
        if buf[p:p + 4] != FDT_MAGIC or p + 8 > len(buf):
            return None
        total = be32(buf, p + 4)
        if total < 0x30 or p + total > len(buf):
            return None
        p += total
        n += 1
    return n if p == len(buf) else None


def split_dtbs(tail):
    if tail[:4] == FDT_MAGIC:
        n = dtb_chain(tail, 0)
        if n:
            starts, p = [], 0
            for _ in range(n):
                starts.append(p)
                p += be32(tail, p + 4)
            return starts
    i = 0
    while True:
        i = tail.find(FDT_MAGIC, i)
        if i < 0:
            return None
        if dtb_chain(tail, i):
            starts, p = [], i
            while p < len(tail):
                starts.append(p)
                p += be32(tail, p + 4)
            return starts
        i += 4


def kernel_of_boot(path):
    b = open(path, 'rb').read()
    if b[:8] != b'ANDROID!':
        raise SystemExit(f'{path}: not an Android boot image')
    ks, ka, rs, ra, ss, sa, ta, ps = struct.unpack_from('<8I', b, 8)
    if ps < 512 or ps & (ps - 1) or ps > len(b):
        raise SystemExit(f'{path}: bad page size {ps}')
    return b[ps:ps + ks]


def tail_of_boot(path):
    k = kernel_of_boot(path)
    if k[:2] == b'\x1f\x8b':
        d = zlib.decompressobj(31)
        d.decompress(k)
        if not d.eof:
            raise SystemExit(f'{path}: truncated gzip kernel')
        tail = d.unused_data
        print(f'kernel: gzip, tail {len(tail)} bytes', file=sys.stderr)
    else:
        tail = k
        print(f'kernel: raw, scanning {len(tail)} bytes', file=sys.stderr)
    starts = split_dtbs(tail)
    if not starts:
        raise SystemExit(f'{path}: no appended DTB chain found')
    return tail, starts


def report_tail(tail, starts):
    ids = []
    for i, s in enumerate(starts):
        b = tail[s:s + be32(tail, s + 4)]
        props = root_props(b)
        model = props.get('model', b'').split(b'\0')[0].decode(errors='replace')
        board = struct.unpack('>II', props['qcom,board-id'][:8]) if props.get('qcom,board-id') else ()
        splash = find_splash(b)
        spl = hex(splash[0]) if splash else '-'
        ids.append(board)
        print(f'{i:2d} {len(b):8d}  {model:48s} board-id={cells(props.get("qcom,board-id"))} '
              f'msm-id={cells(props.get("qcom,msm-id"))} splash={spl}',
              file=sys.stderr)
    if ids and all(i == SAGIT_BOARD_ID for i in ids):
        print(f'board-id {SAGIT_BOARD_ID[0]} {SAGIT_BOARD_ID[1]} present on all {len(ids)} DTBs', file=sys.stderr)
    elif ids and SAGIT_BOARD_ID not in ids:
        raise SystemExit(f'no DTB with sagit board-id {SAGIT_BOARD_ID}')


def main():
    if len(sys.argv) == 4 and sys.argv[1] == '--from-boot':
        tail, starts = tail_of_boot(sys.argv[2])
        report_tail(tail, starts)
        tail = tail[starts[0]:]
        out = sys.argv[3]
        n = len(starts)
    elif len(sys.argv) == 3:
        src, out = sys.argv[1], sys.argv[2]
        files = sorted(glob.glob(os.path.join(src, '*.dtb')))
        if not files:
            raise SystemExit(f'{src}: no *.dtb')
        chunks, starts, off = [], [], 0
        for path in files:
            b = open(path, 'rb').read()
            if b[:4] != FDT_MAGIC:
                raise SystemExit(f'{path}: not a DTB')
            total = be32(b, 4)
            if total != len(b):
                raise SystemExit(f'{path}: size mismatch ({total} != {len(b)})')
            chunks.append(b)
            starts.append(off)
            off += len(b)
        tail = b''.join(chunks)
        report_tail(tail, starts)
        n = len(files)
    else:
        raise SystemExit('usage: sagit_dtb.py DTB_DIR OUT | --from-boot BOOT_IMG OUT')

    open(out, 'wb').write(tail)
    print(f'{out}: {len(tail)} bytes, {n} DTBs', file=sys.stderr)


if __name__ == '__main__':
    main()
