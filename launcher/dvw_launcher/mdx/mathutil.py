"""Small vector, quaternion and affine-matrix helpers in pure Python.

Determinism: only +, -, *, / and sqrt are used (all correctly rounded in
IEEE 754), always in the same order, so every PC computes bit-identical
results. No sin/cos/acos/atan2: their last bit may differ between C runtime
versions, which would change the model bytes and break map identity between
players.

Conventions:
  vec3  (x, y, z)
  quat  (x, y, z, w), unit length
  mat   affine 3x4, row-major tuple of 12: the 4x4 matrix
        [[m0 m1 m2 m3] [m4 m5 m6 m7] [m8 m9 m10 m11] [0 0 0 1]]
"""
from math import sqrt

IDENTITY = (1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0)
QUAT_IDENTITY = (0.0, 0.0, 0.0, 1.0)


def mat_from_gltf(m):
    """glTF column-major 4x4 (16 floats) -> affine 3x4."""
    return (m[0], m[4], m[8], m[12],
            m[1], m[5], m[9], m[13],
            m[2], m[6], m[10], m[14])


def mat_from_trs(t, q, s):
    x, y, z, w = q
    xx, yy, zz = x * x, y * y, z * z
    xy, xz, yz = x * y, x * z, y * z
    wx, wy, wz = w * x, w * y, w * z
    sx, sy, sz = s
    return ((1.0 - 2.0 * (yy + zz)) * sx, (2.0 * (xy - wz)) * sy, (2.0 * (xz + wy)) * sz, t[0],
            (2.0 * (xy + wz)) * sx, (1.0 - 2.0 * (xx + zz)) * sy, (2.0 * (yz - wx)) * sz, t[1],
            (2.0 * (xz - wy)) * sx, (2.0 * (yz + wx)) * sy, (1.0 - 2.0 * (xx + yy)) * sz, t[2])


def mat_mul(a, b):
    a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11 = a
    b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11 = b
    return (a0 * b0 + a1 * b4 + a2 * b8, a0 * b1 + a1 * b5 + a2 * b9, a0 * b2 + a1 * b6 + a2 * b10,
            a0 * b3 + a1 * b7 + a2 * b11 + a3,
            a4 * b0 + a5 * b4 + a6 * b8, a4 * b1 + a5 * b5 + a6 * b9, a4 * b2 + a5 * b6 + a6 * b10,
            a4 * b3 + a5 * b7 + a6 * b11 + a7,
            a8 * b0 + a9 * b4 + a10 * b8, a8 * b1 + a9 * b5 + a10 * b9, a8 * b2 + a9 * b6 + a10 * b10,
            a8 * b3 + a9 * b7 + a10 * b11 + a11)


def mat_inv(m):
    a, b, c, tx, d, e, f, ty, g, h, i, tz = m
    c0, c1, c2 = e * i - f * h, f * g - d * i, d * h - e * g
    det = a * c0 + b * c1 + c * c2
    if det == 0.0:
        raise ValueError("singular matrix")
    r = 1.0 / det
    i00, i01, i02 = c0 * r, (c * h - b * i) * r, (b * f - c * e) * r
    i10, i11, i12 = c1 * r, (a * i - c * g) * r, (c * d - a * f) * r
    i20, i21, i22 = c2 * r, (b * g - a * h) * r, (a * e - b * d) * r
    return (i00, i01, i02, -(i00 * tx + i01 * ty + i02 * tz),
            i10, i11, i12, -(i10 * tx + i11 * ty + i12 * tz),
            i20, i21, i22, -(i20 * tx + i21 * ty + i22 * tz))


def mat_apply(m, v):
    x, y, z = v
    return (m[0] * x + m[1] * y + m[2] * z + m[3],
            m[4] * x + m[5] * y + m[6] * z + m[7],
            m[8] * x + m[9] * y + m[10] * z + m[11])


def mat_apply_dir(m, v):
    x, y, z = v
    return (m[0] * x + m[1] * y + m[2] * z,
            m[4] * x + m[5] * y + m[6] * z,
            m[8] * x + m[9] * y + m[10] * z)


def mat_max_abs_diff(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


def normalize(v):
    x, y, z = v
    n = sqrt(x * x + y * y + z * z)
    if n == 0.0:
        return (0.0, 0.0, 1.0)
    return (x / n, y / n, z / n)


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def quat_normalize(q):
    x, y, z, w = q
    n = sqrt(x * x + y * y + z * z + w * w)
    if n == 0.0:
        return QUAT_IDENTITY
    return (x / n, y / n, z / n, w / n)


def quat_nlerp(a, b, t):
    """Normalized linear interpolation along the shorter arc."""
    if a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3] < 0.0:
        b = (-b[0], -b[1], -b[2], -b[3])
    u = 1.0 - t
    return quat_normalize((a[0] * u + b[0] * t, a[1] * u + b[1] * t, a[2] * u + b[2] * t, a[3] * u + b[3] * t))


def quat_from_mat3(m):
    """Rotation part of an affine matrix (columns must be orthonormal)."""
    m00, m01, m02, m10, m11, m12, m20, m21, m22 = m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]
    tr = m00 + m11 + m22
    if tr > 0.0:
        s = sqrt(tr + 1.0) * 2.0
        q = ((m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s)
    elif m00 > m11 and m00 > m22:
        s = sqrt(1.0 + m00 - m11 - m22) * 2.0
        q = (0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s)
    elif m11 > m22:
        s = sqrt(1.0 + m11 - m00 - m22) * 2.0
        q = ((m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s)
    else:
        s = sqrt(1.0 + m22 - m00 - m11) * 2.0
        q = ((m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s)
    q = quat_normalize(q)
    if q[3] < 0.0:
        q = (-q[0], -q[1], -q[2], -q[3])
    return q


def decompose(m):
    """Affine matrix -> (translation, rotation quat, scale). Shear is dropped:
    the scale is the column length, the rotation the normalized columns."""
    sx = sqrt(m[0] * m[0] + m[4] * m[4] + m[8] * m[8])
    sy = sqrt(m[1] * m[1] + m[5] * m[5] + m[9] * m[9])
    sz = sqrt(m[2] * m[2] + m[6] * m[6] + m[10] * m[10])
    det = (m[0] * (m[5] * m[10] - m[6] * m[9]) - m[1] * (m[4] * m[10] - m[6] * m[8])
           + m[2] * (m[4] * m[9] - m[5] * m[8]))
    if det < 0.0:
        sx = -sx
    t = (m[3], m[7], m[11])
    if abs(sx) < 1e-8 or abs(sy) < 1e-8 or abs(sz) < 1e-8:
        # Collapsed bone (scale 0 hides geometry in Dota): keep the scale,
        # no meaningful rotation can be recovered.
        return t, QUAT_IDENTITY, (sx, sy, sz)
    r = (m[0] / sx, m[1] / sy, m[2] / sz, 0.0,
         m[4] / sx, m[5] / sy, m[6] / sz, 0.0,
         m[8] / sx, m[9] / sy, m[10] / sz, 0.0)
    r = orthonormalize(r)
    return t, quat_from_mat3(r), (sx, sy, sz)


def orthonormalize(r):
    """Gram-Schmidt on the columns of a 3x3 (in a 3x4) matrix."""
    c0 = normalize((r[0], r[4], r[8]))
    c1 = (r[1], r[5], r[9])
    d = dot(c0, c1)
    c1 = normalize((c1[0] - c0[0] * d, c1[1] - c0[1] * d, c1[2] - c0[2] * d))
    c2 = cross(c0, c1)
    if dot(c2, (r[2], r[6], r[10])) < 0.0:
        c2 = (-c2[0], -c2[1], -c2[2])
    return (c0[0], c1[0], c2[0], 0.0,
            c0[1], c1[1], c2[1], 0.0,
            c0[2], c1[2], c2[2], 0.0)
