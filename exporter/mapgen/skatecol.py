import struct

import numpy as np

MAGIC = b'SK3C'
VERSION = 1
PACK_PATH = 'skategm/skate3.sk3c'


def encode(triangles, surfaces, rails):
    triangles = np.ascontiguousarray(triangles, '<f4').reshape(-1, 9)
    surfaces = np.ascontiguousarray(surfaces, '<u4').reshape(-1)
    out = [MAGIC, struct.pack('<III', VERSION, len(triangles), len(rails)), triangles.tobytes(), surfaces.tobytes()]
    for points, closed in rails:
        points = np.ascontiguousarray(points, '<f4').reshape(-1, 3)
        out.append(struct.pack('<II', len(points), 1 if closed else 0))
        out.append(points.tobytes())
    return b''.join(out)


def decode(data):
    if data[:4] != MAGIC:
        raise ValueError('not a SK3C file')
    version, count, rail_count = struct.unpack_from('<III', data, 4)
    if version != VERSION:
        raise ValueError(f'unsupported SK3C version {version}')
    at = 16
    triangles = np.frombuffer(data, '<f4', count * 9, at).reshape(-1, 3, 3)
    at += count * 36
    surfaces = np.frombuffer(data, '<u4', count, at)
    at += count * 4
    rails = []
    for _ in range(rail_count):
        n, closed = struct.unpack_from('<II', data, at)
        at += 8
        rails.append((np.frombuffer(data, '<f4', n * 3, at).reshape(-1, 3), bool(closed)))
        at += n * 12
    if at != len(data):
        raise ValueError('SK3C has trailing bytes')
    return triangles, surfaces, rails
