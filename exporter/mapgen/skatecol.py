import struct

import numpy as np

MAGIC = b'SK3C'
# 2: each rail also carries its retail spline (a .skate rail's native bytes,
# in Skate 3's coordinates), or nothing for a rail that's only a polyline
# 3: and each triangle its native edges: 4 bytes after the surfaces (three
# edge codes, then bit 0 = has them, bit 1 = its mesh is one-sided)
VERSION = 3
PACK_PATH = 'skategm/skate3.sk3c'
HAS_EDGES = 1 << 56
ONE_SIDED = 1 << 57


def encode(triangles, surfaces, rails):
    """`surfaces`: scene.pack_surface values (uint64), or plain surface IDs."""
    triangles = np.ascontiguousarray(triangles, '<f4').reshape(-1, 9)
    packed = np.asarray(surfaces, np.uint64).reshape(-1)
    edges = np.zeros((len(packed), 4), np.uint8)
    for k in range(3):
        edges[:, k] = (packed >> np.uint64(32 + 8 * k)) & np.uint64(0xFF)
    edges[:, 3] = (((packed & np.uint64(HAS_EDGES)) != 0).astype(np.uint8)
                   | (((packed & np.uint64(ONE_SIDED)) != 0).astype(np.uint8) << 1))
    plain = (packed & np.uint64(0xFFFFFFFF)).astype('<u4')
    out = [MAGIC, struct.pack('<III', VERSION, len(triangles), len(rails)), triangles.tobytes(), plain.tobytes(),
           edges.tobytes()]
    for rail in rails:
        points, closed = rail[0], rail[1]
        native = rail[2] if len(rail) > 2 else None
        points = np.ascontiguousarray(points, '<f4').reshape(-1, 3)
        out.append(struct.pack('<II', len(points), 1 if closed else 0))
        out.append(points.tobytes())
        native = native or b''
        out.append(struct.pack('<I', len(native)))
        out.append(native)
    return b''.join(out)


def decode(data):
    """(triangles, surfaces as scene.pack_surface values, rails)"""
    if data[:4] != MAGIC:
        raise ValueError('not a SK3C file')
    version, count, rail_count = struct.unpack_from('<III', data, 4)
    if version not in (1, 2, 3):
        raise ValueError(f'unsupported SK3C version {version}')
    at = 16
    triangles = np.frombuffer(data, '<f4', count * 9, at).reshape(-1, 3, 3)
    at += count * 36
    surfaces = np.frombuffer(data, '<u4', count, at).astype(np.uint64)
    at += count * 4
    if version >= 3:
        edges = np.frombuffer(data, np.uint8, count * 4, at).reshape(-1, 4).astype(np.uint64)
        at += count * 4
        has = (edges[:, 3] & np.uint64(1)) != 0
        codes = edges[:, 0] | edges[:, 1] << np.uint64(8) | edges[:, 2] << np.uint64(16)
        surfaces = surfaces | np.where(has, codes << np.uint64(32) | np.uint64(HAS_EDGES), np.uint64(0))
        surfaces = surfaces | np.where((edges[:, 3] & np.uint64(2)) != 0, np.uint64(ONE_SIDED), np.uint64(0))
    rails = []
    for _ in range(rail_count):
        n, closed = struct.unpack_from('<II', data, at)
        at += 8
        points = np.frombuffer(data, '<f4', n * 3, at).reshape(-1, 3)
        at += n * 12
        native = None
        if version >= 2:
            size, = struct.unpack_from('<I', data, at)
            at += 4
            native = bytes(data[at:at + size]) or None
            at += size
        rails.append((points, bool(closed), native))
    if at != len(data):
        raise ValueError('SK3C has trailing bytes')
    return triangles, surfaces, rails
