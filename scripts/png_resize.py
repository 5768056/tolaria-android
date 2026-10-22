import struct, sys, zlib

def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos = 8
    idat = b''
    w = h = bd = ct = None
    while pos < len(data):
        ln, typ = struct.unpack('>I4s', data[pos:pos+8])
        chunk = data[pos+8:pos+8+ln]
        if typ == b'IHDR':
            w, h, bd, ct, comp, filt, inter = struct.unpack('>IIBBBBB', chunk)
            assert inter == 0, 'interlaced not supported'
        elif typ == b'IDAT':
            idat += chunk
        elif typ == b'IEND':
            break
        pos += 12 + ln
    raw = zlib.decompress(idat)
    ch = {0:1, 2:3, 3:1, 4:2, 6:4}[ct]
    bpp = ch * (bd // 8)
    stride = w * bpp
    out = bytearray(w * h * bpp)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        if f == 1:
            for i in range(bpp, stride): line[i] = (line[i] + line[i-bpp]) & 255
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i-bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i-bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i-bpp] if i >= bpp else 0
                pp = a + b - c
                pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        out[y*stride:(y+1)*stride] = line
        prev = line
    return w, h, ch, bytes(out)

def write_png(path, w, h, ch, px):
    raw = b''.join(b'\x00' + px[y*w*ch:(y+1)*w*ch] for y in range(h))
    def chunk(typ, d):
        return struct.pack('>I', len(d)) + typ + d + struct.pack('>I', zlib.crc32(typ+d) & 0xffffffff)
    hdr = struct.pack('>IIBBBBB', w, h, 8, {1:0, 3:2, 2:2, 4:6}[ch], 0, 0, 0)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', hdr) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))

def main():
    src, dst, factor = sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 4
    w, h, ch, px = read_png(src)
    nw, nh = w // factor, h // factor
    out = bytearray(nw * nh * ch)
    for y in range(nh):
        for x in range(nw):
            acc = [0]*ch
            for dy in range(factor):
                for dx in range(factor):
                    o = ((y*factor+dy)*w + (x*factor+dx))*ch
                    for c in range(ch): acc[c] += px[o+c]
            for c in range(ch): out[(y*nw+x)*ch+c] = acc[c] // (factor*factor)
    write_png(dst, nw, nh, ch, bytes(out))
    print(f'{w}x{h} -> {nw}x{nh} ch={ch}')

if __name__ == '__main__':
    main()
