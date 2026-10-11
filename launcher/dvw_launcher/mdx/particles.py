"""Dota 2 particle systems (.vpcf, decompiled by VRF as KV3) -> Warcraft III
effect models, classic MDX 800.

An approximation that reads as the Dota effect, not an exact port: Source 2
particles run operators per frame, WC3 emitters have three colour, alpha and
size keys over a particle's life. Every system of the tree (root and
children, recursively) becomes at most one emitter:

  RenderSprites   ParticleEmitter2, head particles (XYQuad if world-Z aligned)
  RenderTrails    ParticleEmitter2, tail particles stretched along their speed
  RenderRopes     RibbonEmitter
  other renderers (models, lights, screen shake, sounds) are dropped

Values: lifetime, radius (= PRE2 scaling, half the quad), colour, alpha,
emission (bursts are "squirt" keys, continuous emission a rate), spawn speed,
direction and spread (latitude), gravity, InterpolateRadius, ColorInterpolate
and the fade operators; particles locked to their control point (or the
projectile itself) are emitted in model space.

Phases are sequences. An effect is used as:
  "missile"   Stand (flight, looping), Birth (the launch burst at the
              attacker), Death (the endcap children: the impact)
  "attached"  Birth (bursts), Stand (continuous parts, looping), Death (endcap)
  "oneshot"   one non-looping Stand holding everything; the game plays it to
              its end after DestroyEffect(AddSpecialEffect(...)), like
              ThunderClapCaster
The game doubles particle emission at the High setting (mdx-m3-viewer's
SETTING_PARTICLES_HIGH), so counts and rates are halved.
"""
import math
import struct

from . import writer

VERSION = 1   # bump on any change that alters the produced bytes

# PRE2 filter modes (not the layer ones)
P_BLEND, P_ADD, P_MOD, P_MOD2X = 0, 1, 2, 3
# generic object flags
F_PRE2, F_RIBBON = 0x1000, 0x4000
F_UNSHADED, F_SORT_FAR, F_LINE, F_UNFOGGED, F_MODEL_SPACE, F_XY_QUAD = (
    0x8000, 0x10000, 0x20000, 0x40000, 0x80000, 0x100000)

RENDERERS = {"C_OP_RenderSprites": "sprite", "C_OP_RenderTrails": "trail", "C_OP_RenderRopes": "rope"}
LIFE, RADIUS, ROLL, ALPHA, COLOR = 1, 3, 4, 7, 6
HIGH_SETTING = 2.0
MAX_BURST = 64
MAX_ALIVE = 96
SUSTAIN_LIFE = 0.25          # life of the particles that stand for a Dota particle living until the endcap
SEQ_GAP = 100


class ConvertError(Exception):
    pass


# Control point values of the effect being converted (specs/effects.json "cp"):
# Dota code sets them at run time (CP1 = Rot's radius, Mana Void's area...).
_CPS = {}
DEFAULT_CP = (100.0, 100.0, 100.0)


# ------------------------------------------------------------------ KV3 values

def num(v, default=0.0):
    """A Source 2 float input as one number: literal, the middle of a random
    range or of a remap's output range; anything driven at run time -> default."""
    lo, hi = num_range(v, default)
    if lo is None or hi is None:
        return default
    return (lo + hi) / 2


def num_range(v, default=0.0):
    if v is None:
        return default, default
    if isinstance(v, bool):
        return float(v), float(v)
    if isinstance(v, (int, float)):
        return float(v), float(v)
    if isinstance(v, dict):
        t = v.get("m_nType", "")
        if t == "PF_TYPE_CONTROL_POINT_COMPONENT":
            cp = _CPS.get(int(v.get("m_nControlPoint", 0)), DEFAULT_CP)
            x = float(cp[min(2, max(0, int(v.get("m_nVectorComponent", 0))))])
            if v.get("m_nMapType") == "PF_MAP_TYPE_REMAP":
                i0, i1 = float(v.get("m_flInput0", 0.0)), float(v.get("m_flInput1", 1.0))
                o0, o1 = float(v.get("m_flOutput0", 0.0)), float(v.get("m_flOutput1", 1.0))
                k = 0.0 if i1 == i0 else min(1.0, max(0.0, (x - i0) / (i1 - i0)))
                x = o0 + (o1 - o0) * k
            else:
                x *= float(v.get("m_flMultFactor", 1.0))
            return x, x
        if t == "PF_TYPE_LITERAL" or "m_flLiteralValue" in v:
            x = float(v.get("m_flLiteralValue", default))
            return x, x
        if t in ("PF_TYPE_RANDOM_UNIFORM", "PF_TYPE_RANDOM_BIASED"):
            return float(v.get("m_flRandomMin", 0.0)), float(v.get("m_flRandomMax", 1.0))
        if "m_flOutput0" in v or "m_flOutput1" in v:
            a, b = float(v.get("m_flOutput0", 0.0)), float(v.get("m_flOutput1", 1.0))
            return min(a, b), max(a, b)
    return default, default


def vec(v, default=(0.0, 0.0, 0.0)):
    if isinstance(v, (list, tuple)) and len(v) >= 3 and all(isinstance(x, (int, float)) for x in v[:3]):
        return [float(x) for x in v[:3]]
    if isinstance(v, dict):
        for key in ("m_vLiteralValue", "m_LiteralColor"):
            if key in v:
                return vec(v[key], default)
        if "m_vRandomMin" in v or "m_vRandomMax" in v:
            a, b = vec(v.get("m_vRandomMin"), default), vec(v.get("m_vRandomMax"), default)
            return [(x + y) / 2 for x, y in zip(a, b)]
    return list(default)


def color(v, default=(255, 255, 255, 255)):
    if isinstance(v, (list, tuple)) and len(v) >= 3:
        c = [float(x) for x in v[:4]] + [255.0] * (4 - len(v[:4]))
        return c
    if isinstance(v, dict):
        if "m_LiteralColor" in v:
            return color(v["m_LiteralColor"], default)
        if "m_vLiteralValue" in v:
            return [x * 255 for x in vec(v["m_vLiteralValue"])] + [255.0]
    return [float(x) for x in default]


def compiled(path):
    """materials/x.vtex -> materials/x.vtex_c (the VPK name)."""
    p = str(path).replace("\\", "/").lower()
    return p if p.endswith("_c") else p + "_c"


def _cls(op):
    return op.get("_class", "")


def _active(op):
    return not op.get("m_bDisableOperator", False)


def _endcap(op):
    return op.get("m_nOpEndCapState", "") == "PARTICLE_ENDCAP_ENDCAP_ON"


def _ops(sysdef, group):
    return [o for o in sysdef.get(group, []) if isinstance(o, dict) and _active(o)]


# ------------------------------------------------------------------ one system

class Spec:
    """What one Dota system looks like, in WC3 terms."""

    def __init__(self, path):
        self.path = path
        self.kind = None
        self.texture = None
        self.sequence = 0
        self.filter = P_BLEND
        self.overbright = 1.0
        self.xy_quad = False
        self.cp = 0
        self.life = 1.0
        self.radius = (5.0, 5.0, 5.0)
        self.colors = [(1.0, 1.0, 1.0)] * 3
        self.alphas = (255, 255, 255)
        self.time_middle = 0.5
        self.burst = 0
        self.rate = 0.0
        self.start = 0.0
        self.duration = 0.0
        self.sustained = False
        self.speed = 0.0
        self.variation = 0.0
        self.latitude = 0.0
        self.direction = (0.0, 0.0, 1.0)
        self.gravity = 0.0
        self.area = 0.0
        self.locked = False
        self.inherit = 0.0
        self.trail_length = 0.0
        self.max_particles = 1000
        self.notes = []


def analyze(path, d):
    """Spec of one decompiled CParticleSystemDefinition, or None when it draws
    nothing WC3 can show."""
    s = Spec(path)
    renderer = None
    for r in _ops(d, "m_Renderers"):
        if _cls(r) in RENDERERS:
            renderer = r
            break
    if renderer is None:
        return None
    s.kind = RENDERERS[_cls(renderer)]
    textures = renderer.get("m_vecTexturesInput") or []
    tex = textures[0].get("m_hTexture") if textures and isinstance(textures[0], dict) else None
    tex = tex or renderer.get("m_hTexture")
    if not tex:
        return None
    s.texture = compiled(tex)
    blend = renderer.get("m_nOutputBlendMode", "")
    if "ADD" in blend or renderer.get("m_bAdditive"):
        s.filter = P_ADD
    elif "MOD" in blend:
        return None                  # screen darkening / distortion helpers: WC3's modulate tints the ground solid
    s.overbright = max(1.0, num(renderer.get("m_flOverbrightFactor"), 1.0))
    if s.filter == P_BLEND and num(renderer.get("m_flAddSelfAmount"), 0.0) > 0:
        s.filter = P_ADD             # "add self" draws the sprite over itself: reads as additive
    s.xy_quad = "WORLD_Z" in str(renderer.get("m_nOrientationType", "")) or "GROUND" in str(
        renderer.get("m_nOrientationType", ""))
    s.max_particles = int(d.get("m_nMaxParticles", 1000) or 1000)
    radius_scale = num(renderer.get("m_flRadiusScale"), 1.0) if s.kind in ("trail", "rope") else 1.0
    s.sequence = int(d.get("m_nConstantSequenceNumber", 0) or 0)

    life = float(d.get("m_flConstantLifespan", 1.0))
    radius = float(d.get("m_flConstantRadius", 5.0))
    rgba = color(d.get("m_ConstantColor"))
    alpha_init = 1.0
    speed_sphere, local_speed, local_spread = 0.0, [0.0, 0.0, 0.0], 0.0
    sphere_spread = 0.0
    for o in _ops(d, "m_Initializers"):
        c = _cls(o)
        if c == "C_INIT_InitFloat":
            field = o.get("m_nOutputField", RADIUS)
            value = num(o.get("m_InputValue"), None)
            if value is None:
                continue
            scale = o.get("m_nSetMethod", "") == "PARTICLE_SET_SCALE_INITIAL_VALUE"
            if field == LIFE:
                life = life * value if scale else value
            elif field == RADIUS:
                radius = radius * value if scale else value
            elif field in (ALPHA, 16):
                alpha_init = alpha_init * value if scale else value
        elif c == "C_INIT_RandomLifeTime":
            life = (float(o.get("m_fLifetimeMin", 0.0)) + float(o.get("m_fLifetimeMax", 0.0))) / 2 or life
        elif c == "C_INIT_RandomRadius":
            radius = (float(o.get("m_flRadiusMin", 1.0)) + float(o.get("m_flRadiusMax", 1.0))) / 2
        elif c == "C_INIT_RandomAlpha":
            alpha_init = (float(o.get("m_nAlphaMin", 255)) + float(o.get("m_nAlphaMax", 255))) / 510
        elif c == "C_INIT_RandomColor":
            a, b = color(o.get("m_ColorMin")), color(o.get("m_ColorMax"))
            rgba = [x * (y + z) / 510 for x, y, z in zip(rgba, a, b)]
        elif c == "C_INIT_InitVec" and o.get("m_nOutputField") == COLOR:
            rgba[:3] = [x * 255 for x in vec(o.get("m_InputValue"), (1.0, 1.0, 1.0))]
        elif c in ("C_INIT_CreateWithinSphere", "C_INIT_CreateWithinSphereTransform"):
            s.cp = int(o.get("m_nControlPointNumber", (o.get("m_TransformInput") or {}).get("m_nControlPoint", 0)))
            s.area = max(s.area, num(o.get("m_fRadiusMax"), 0.0))
            lo, hi = num_range(o.get("m_fSpeedMin"), 0.0)[0], num_range(o.get("m_fSpeedMax"), 0.0)[1]
            speed_sphere, sphere_spread = (lo + hi) / 2, abs(hi - lo) / 2
            a = vec(o.get("m_LocalCoordinateSystemSpeedMin"))
            b = vec(o.get("m_LocalCoordinateSystemSpeedMax"))
            local_speed = [(x + y) / 2 for x, y in zip(a, b)]
            local_spread = max(abs(x - y) for x, y in zip(a, b)) / 2
        elif c in ("C_INIT_CreateOnModel", "C_INIT_CreateOnModelAtHeight"):
            s.cp = int(o.get("m_nControlPointNumber", 0))
            s.area = max(s.area, 32.0)
        elif c == "C_INIT_RingWave":
            s.cp = int(o.get("m_nControlPointNumber", 0))
            s.area = max(s.area, num(o.get("m_flInitialRadius"), 0.0))
            speed_sphere = max(speed_sphere, (num(o.get("m_flInitialSpeedMin"), 0.0)
                                              + num(o.get("m_flInitialSpeedMax"), 0.0)) / 2)
        elif c == "C_INIT_VelocityRandom":
            lo, hi = num(o.get("m_fSpeedMin"), 0.0), num(o.get("m_fSpeedMax"), 0.0)
            speed_sphere, sphere_spread = max(speed_sphere, (lo + hi) / 2), max(sphere_spread, abs(hi - lo) / 2)
            a = vec(o.get("m_LocalCoordinateSystemSpeedMin"))
            b = vec(o.get("m_LocalCoordinateSystemSpeedMax"))
            local_speed = [x + (y + z) / 2 for x, y, z in zip(local_speed, a, b)]
        elif c == "C_INIT_InitialVelocityNoise":
            a, b = vec(o.get("m_vecOutputMin")), vec(o.get("m_vecOutputMax"))
            sphere_spread = max(sphere_spread, max(abs(y - x) for x, y in zip(a, b)) / 2)
        elif c == "C_INIT_InheritVelocity":
            s.inherit = max(s.inherit, float(o.get("m_flVelocityScale", 1.0)))
        elif c == "C_INIT_RandomSequence":
            s.sequence = int(o.get("m_nSequenceMin", 0))
        elif c == "C_INIT_RandomTrailLength":
            s.trail_length = (float(o.get("m_flMinLength", 0.1)) + float(o.get("m_flMaxLength", 0.1))) / 2
        elif c == "C_INIT_CreationNoise" and o.get("m_nFieldOutput", RADIUS) == RADIUS:
            radius = (float(o.get("m_flOutputMin", radius)) + float(o.get("m_flOutputMax", radius))) / 2

    scale = [1.0, 1.0, 1.0]
    fade_in, fade_out = 0.0, 0.0
    end_rgb = None
    decays = False
    gravity, drag = 0.0, 0.0
    for o in _ops(d, "m_Operators"):
        c = _cls(o)
        if _endcap(o):
            continue
        if c == "C_OP_BasicMovement":
            gravity = -vec(o.get("m_Gravity"))[2]
            drag = num(o.get("m_fDrag"), 0.0)
        elif c == "C_OP_InterpolateRadius" and scale == [1.0, 1.0, 1.0]:
            a, b = num(o.get("m_flStartScale"), 1.0), num(o.get("m_flEndScale"), 1.0)
            t0, t1 = float(o.get("m_flStartTime", 0.0)), float(o.get("m_flEndTime", 1.0))
            mid = 0.5 if t1 <= t0 else min(1.0, max(0.0, (0.5 - t0) / (t1 - t0)))
            end = 1.0 if t1 <= t0 else min(1.0, max(0.0, (1.0 - t0) / (t1 - t0)))
            scale = [a if t0 <= 0 else a if t0 < 1 else a, a + (b - a) * mid, a + (b - a) * end]
        elif c == "C_OP_FadeInSimple":
            fade_in = max(fade_in, float(o.get("m_flFadeInTime", 0.25)))
        elif c == "C_OP_FadeIn":
            fade_in = max(fade_in, (float(o.get("m_flFadeInTimeMin", 0.25)) + float(o.get("m_flFadeInTimeMax", 0.25))) / 2)
        elif c == "C_OP_FadeOutSimple":
            fade_out = max(fade_out, float(o.get("m_flFadeOutTime", 0.25)))
        elif c == "C_OP_FadeOut":
            fade_out = max(fade_out, (float(o.get("m_flFadeOutTimeMin", 0.25)) + float(o.get("m_flFadeOutTimeMax", 0.25))) / 2)
        elif c == "C_OP_FadeAndKill":
            decays = True
            fade_in = max(fade_in, float(o.get("m_flEndFadeInTime", 0.5)) - float(o.get("m_flStartFadeInTime", 0.0)))
            fade_out = max(fade_out, float(o.get("m_flEndFadeOutTime", 1.0)) - float(o.get("m_flStartFadeOutTime", 0.5)))
        elif c == "C_OP_ColorInterpolate" and end_rgb is None:
            end_rgb = color(o.get("m_ColorFade"))[:3]
        elif c in ("C_OP_Decay", "C_OP_DecayMaintainCount", "C_OP_DecayClampCount", "C_OP_RadiusDecay",
                   "C_OP_FadeAndKillForTracers", "C_OP_PercentageBetweenCPs"):
            decays = decays or c != "C_OP_PercentageBetweenCPs"
        elif c in ("C_OP_PositionLock", "C_OP_LockToBone", "C_OP_LockToSavedSequentialPath"):
            end_lock = (float(o.get("m_flEndTime_min", 1.0)) + float(o.get("m_flEndTime_max", 1.0))) / 2
            if c != "C_OP_PositionLock" or end_lock >= 0.5 * life or end_lock < 0:
                s.locked = True
    s.gravity = gravity

    # Emission
    for o in _ops(d, "m_Emitters"):
        c = _cls(o)
        s.start = max(0.0, num(o.get("m_flStartTime"), 0.0))
        if c == "C_OP_InstantaneousEmitter":
            s.burst = max(1, int(round(num(o.get("m_nParticlesToEmit"), 100.0))))
        elif c in ("C_OP_ContinuousEmitter", "C_OP_NoiseEmitter"):
            if c == "C_OP_ContinuousEmitter":
                s.rate = num(o.get("m_flEmitRate"), 100.0)
            else:
                s.rate = (float(o.get("m_flOutputMin", 0.0)) + float(o.get("m_flOutputMax", 100.0))) / 2
            s.duration = max(0.0, num(o.get("m_flEmissionDuration"), 0.0))
        elif c == "C_OP_MaintainEmitter":
            s.burst = max(1, int(round(num(o.get("m_nParticlesToMaintain"), 100.0))))
            decays = False
        break
    initial = int(d.get("m_nInitialParticles", 0) or 0)
    if not s.burst and not s.rate:
        if not initial:
            return None
        s.burst = initial
    s.sustained = bool(s.burst) and not decays

    s.life = max(0.03, life)
    r = max(0.5, radius * radius_scale)
    s.radius = tuple(max(0.0, r * k) for k in scale)

    # Speed and direction: Dota adds a random direction (sphere) to a vector in
    # the control point's frame (x forward, z up); WC3 has one cone.
    drag_factor = max(0.25, 1.0 - min(drag, 1.0) * 2.5)
    local_len = math.sqrt(sum(x * x for x in local_speed))
    if local_len > max(speed_sphere, 1.0):
        s.direction = tuple(x / local_len for x in local_speed)
        s.speed = local_len * drag_factor
        s.latitude = min(180.0, math.degrees(math.atan2(speed_sphere + local_spread + sphere_spread, local_len)))
        s.variation = min(1.0, local_spread / local_len) if local_len else 0.0
    elif speed_sphere > 0 or sphere_spread > 0:
        s.speed = (speed_sphere + sphere_spread * 0.5) * drag_factor
        s.latitude = 180.0
        s.variation = min(1.0, sphere_spread / s.speed) if s.speed else 0.0

    # Colour and alpha over life; overbright brightens (clamped).
    gain = min(s.overbright, 4.0) if s.filter == P_ADD else 1.0

    def bright(rgb):
        # Overbright without bloom: brighten up to full intensity, keeping the hue.
        c = [max(0.0, x / 255) for x in rgb]
        top = max(c) or 1.0
        return [min(1.0, x * min(gain, 1.0 / top)) for x in c]

    c0 = bright(rgba[:3])
    c2 = bright(end_rgb or rgba[:3])
    s.colors = [tuple(c0), tuple((a + b) / 2 for a, b in zip(c0, c2)), tuple(c2)]
    a = max(0.0, min(1.0, rgba[3] / 255 * alpha_init))
    if s.filter == P_ADD:
        a = min(1.0, a * max(1.0, min(s.overbright, 4.0) / 2))
    peak = int(round(255 * a))
    if s.sustained:
        s.alphas, s.time_middle = (peak, peak, peak), 0.5
    else:
        fade_in = min(0.9, max(0.0, fade_in))
        s.time_middle = fade_in if fade_in > 0.02 else 0.5
        tail = peak if fade_out <= 0.02 else 0
        head = 0 if fade_in > 0.02 else peak
        if fade_in <= 0.02 and fade_out > 0.02:
            s.time_middle = max(0.05, min(0.95, 1.0 - fade_out))
        s.alphas = (head, peak, tail)
    return s


# ------------------------------------------------------------------ the tree

class Node:
    """A system in the tree: its spec, the phase it plays in and its delay."""

    def __init__(self, spec, phase, delay, depth):
        self.spec, self.phase, self.delay, self.depth = spec, phase, delay, depth


LAUNCH_CPS = {0, 9}


def walk(tree, root, usage, log=None, drop=(), cps=None):
    """[Node] of the systems under `root` (VPK path of the .vpcf_c) that draw
    something, in tree order. `drop`: name parts of systems to leave out;
    `cps`: {control point: (x, y, z)} values the Dota code would set."""
    out = []
    _CPS.clear()
    _CPS.update({int(k): tuple(float(x) for x in v) for k, v in (cps or {}).items()})

    def visit(path, phase, delay, depth, parent_cp):
        d = tree.get(path)
        if d is None:
            if log:
                log(f"effects: {path} was not decompiled, skipped")
            return
        if any(part in path for part in drop):
            return
        spec = analyze(path, d)
        cp = parent_cp
        if spec is not None:
            for o in _ops(d, "m_Initializers"):
                if _cls(o) == "C_INIT_CreateFromParentParticles":
                    spec.cp = parent_cp
            cp = spec.cp
            own = phase
            if usage == "missile" and depth > 0 and phase == "stand" and spec.cp in LAUNCH_CPS:
                own = "birth" if not spec.rate or spec.duration else phase
            out.append(Node(spec, own, delay, depth))
        for child in d.get("m_Children", []) or []:
            if not isinstance(child, dict) or child.get("m_bDisableChild"):
                continue
            ref = child.get("m_ChildRef")
            if not ref:
                continue
            child_phase = "death" if child.get("m_bEndCap") else phase
            visit(compiled(ref), child_phase, delay + float(child.get("m_flDelay", 0.0) or 0.0), depth + 1, cp)

    visit(compiled(root), "stand", 0.0, 0, 0)
    # A child listed several times (beams around a projectile, one per offset)
    # becomes one emitter with the summed emission.
    merged = {}
    for n in out:
        key = (n.spec.path, n.phase, round(n.delay, 3))
        if key in merged:
            first = merged[key]
            first.spec.burst += n.spec.burst
            first.spec.rate += n.spec.rate
        else:
            merged[key] = n
    return list(merged.values())


# ------------------------------------------------------------------ emitters

class Emitter:
    def __init__(self, name, kind):
        self.name = name
        self.kind = kind              # "pre2" | "ribbon"
        self.flags = 0
        self.speed = self.variation = self.latitude = self.gravity = 0.0
        self.life = 1.0
        self.rate = 0.0
        self.width = self.length = 0.0
        self.filter = P_BLEND
        self.rows = self.cols = 1
        self.head_or_tail = 0
        self.tail_length = 0.0
        self.time_middle = 0.5
        self.colors = [(1.0, 1.0, 1.0)] * 3
        self.alphas = (255, 255, 255)
        self.scaling = (10.0, 10.0, 10.0)
        self.head = (0, 0, 1)
        self.texture_id = 0
        self.squirt = 0
        self.rotation = None          # static quaternion of the node
        self.tracks = []              # [(tag, keys, interpolation)]
        # ribbon
        self.height = 10.0
        self.alpha = 1.0
        self.color = (1.0, 1.0, 1.0)
        self.material_id = 0


def _quat_from_z(direction):
    """Quaternion (x, y, z, w) turning +Z onto `direction`."""
    x, y, z = direction
    n = math.sqrt(x * x + y * y + z * z) or 1.0
    x, y, z = x / n, y / n, z / n
    if z > 0.9999:
        return None
    if z < -0.9999:
        return (1.0, 0.0, 0.0, 0.0)
    ax, ay = -y, x          # z x d
    s = math.sqrt(ax * ax + ay * ay)
    angle = math.acos(max(-1.0, min(1.0, z)))
    h = math.sin(angle / 2)
    return (ax / s * h, ay / s * h, 0.0, math.cos(angle / 2))


class Layout:
    """Sequence intervals (ms) for a usage."""

    def __init__(self, usage, flight_ms=1000, birth_ms=100, death_ms=1000, oneshot_ms=1000):
        self.usage = usage
        if usage == "oneshot":
            # Death repeats Stand: DestroyEffect right after AddSpecialEffect plays it.
            self.seqs = [("Stand", 0, oneshot_ms, False),
                         ("Death", oneshot_ms + SEQ_GAP, 2 * oneshot_ms + SEQ_GAP, False)]
        else:
            stand = (0, flight_ms)
            birth = (stand[1] + SEQ_GAP, stand[1] + SEQ_GAP + birth_ms)
            death = (birth[1] + SEQ_GAP, birth[1] + SEQ_GAP + death_ms)
            self.seqs = [("Stand", *stand, True), ("Birth", *birth, False), ("Death", *death, False)]

    def interval(self, name):
        for n, a, b, _loop in self.seqs:
            if n == name:
                return a, b
        return None


def _visibility(layout, phases):
    """KP2V keys: 1 in the sequences of `phases`, 0 elsewhere."""
    keys = []
    for name, a, _b, _loop in layout.seqs:
        keys.append((a, (1.0 if name.lower() in phases else 0.0,)))
    return keys


def build_emitters(nodes, usage, textures, log=None, scale=1.0, speed_scale=1.0):
    """[Emitter] and the Layout for `nodes` (from walk). `textures` maps a
    (vtex, sequence) pair to (texture index, rows, cols, frames) or None."""
    death_ms, birth_ms, oneshot_ms = 300, 100, 300
    if usage == "oneshot":
        # Endcap children play when the main part has run its course.
        main = max([n.delay + n.spec.start + (n.spec.duration if n.spec.rate else 0.0)
                    for n in nodes if n.phase != "death"] or [0.0])
        for n in nodes:
            if n.phase == "death":
                n.delay += main
    for n in nodes:
        s = n.spec
        span = n.delay + s.start + (s.duration if s.rate else 0.0) + s.life
        if n.phase == "death":
            death_ms = max(death_ms, int(span * 1000) + 50)
        elif n.phase == "birth":
            birth_ms = max(birth_ms, 100)
        oneshot_ms = max(oneshot_ms, int((span if not s.sustained else n.delay + s.start + 1.0) * 1000) + 50)
    layout = Layout(usage, death_ms=min(death_ms, 3000), birth_ms=birth_ms, oneshot_ms=min(oneshot_ms, 4000))
    emitters = []
    for i, n in enumerate(nodes):
        s = n.spec
        tex = textures.get((s.texture, s.sequence, s.kind in ("trail", "rope")))
        if tex is None:
            if log:
                log(f"effects: {s.path}: texture {s.texture} missing, system skipped")
            continue
        tex_id, rows, cols, frames = tex
        stem = s.path.rsplit("/", 1)[-1].replace(".vpcf_c", "")
        if s.kind == "rope":
            e = Emitter(f"Ribbon{i:02d}_{stem}"[:79], "ribbon")
            e.material_id = tex_id
            e.height = s.radius[0] * scale
            e.alpha = s.alphas[1] / 255
            e.color = s.colors[0]
            e.life = min(s.life, 1.5)
            e.rate = max(20.0, min(60.0, s.rate or 30.0))
            e.gravity = 0.0
            e.filter = s.filter
        else:
            e = Emitter(f"Emitter{i:02d}_{stem}"[:79], "pre2")
            e.flags = F_PRE2 | F_UNSHADED | (F_XY_QUAD if s.xy_quad else 0)
            e.texture_id = tex_id
            e.rows, e.cols = rows, cols
            e.head = (0, frames, 1) if frames > 1 else (0, 0, 1)
            e.filter = s.filter
            e.colors = s.colors
            e.alphas = s.alphas
            e.time_middle = s.time_middle
            e.scaling = tuple(r * scale for r in s.radius)
            e.gravity = s.gravity * scale
            e.speed = s.speed * scale * speed_scale
            e.variation = s.variation
            e.latitude = s.latitude
            if s.xy_quad:
                # The game skips XY quads without speed or latitude (mdx-m3-viewer's sanity test).
                e.speed, e.latitude = max(e.speed, 1.0), max(e.latitude, 1.0)
            e.width = e.length = 2 * s.area * scale
            model_space = s.locked or s.inherit >= 0.5 or (usage == "missile" and n.depth == 0)
            if usage == "missile" and n.phase == "birth":
                model_space = False          # the launch flash stays at the attacker
            if s.sustained:
                model_space = model_space or usage != "oneshot"
            if model_space:
                e.flags |= F_MODEL_SPACE
            e.rotation = _quat_from_z(s.direction)
            if s.kind == "trail":
                if usage == "missile" and n.depth == 0:
                    # The projectile's own streak: a tail behind the head.
                    length = min(s.trail_length or 48.0, 64.0) * scale
                    e.speed, e.latitude, e.variation = 100.0, 0.0, 0.0
                    e.rotation = _quat_from_z((1.0, 0.0, 0.0))
                    e.tail_length = length / 100.0
                    e.head_or_tail = 1
                elif e.speed > 1.0:
                    e.head_or_tail = 1
                    e.tail_length = min(64.0 * scale, 0.1 * e.speed) / e.speed
            if s.sustained:
                e.life = SUSTAIN_LIFE if s.kind != "trail" else 0.1
                count = min(s.burst, 8)
                e.rate = 2 * count / e.life / HIGH_SETTING     # twice: never a frame without one
            else:
                e.life = s.life
            emitters.append(e)
            _emission(e, n, s, layout, usage)
            continue
        emitters.append(e)
        _ribbon_phase(e, n, layout)
    return emitters, layout


def _phases(n, usage):
    if usage == "oneshot":
        return {"stand", "death"}
    if n.phase == "stand":
        return {"stand", "birth"} if usage == "missile" else {"stand"}
    return {n.phase}


def _emission(e, n, s, layout, usage):
    phases = _phases(n, usage)
    if s.sustained:
        e.tracks.append(("KP2V", _visibility(layout, phases), writer.INTERP_NONE))
        return
    if s.rate:
        rate = s.rate
        if s.max_particles and rate * s.life > s.max_particles:
            rate = s.max_particles / s.life
        rate = min(rate, MAX_ALIVE / max(s.life, 0.05)) / HIGH_SETTING
        e.rate = rate
        windows = []
        for name, a, b, _loop in layout.seqs:
            if name.lower() not in phases:
                windows.append((a, 0.0))
                continue
            start = a + int((n.delay + s.start) * 1000)
            windows.append((a, 0.0 if start > a else 1.0))
            if start > a:
                windows.append((min(start, b), 1.0))
            if s.duration > 0:
                stop = start + int(s.duration * 1000)
                if stop < b:
                    windows.append((stop, 0.0))
        e.tracks.append(("KP2V", sorted(windows), writer.INTERP_NONE))
        return
    # A burst: squirt keys, the count once per sequence of its phase.
    count = max(1.0, min(s.burst, s.max_particles or s.burst, MAX_BURST) / HIGH_SETTING)
    e.squirt = 1
    e.rate = 0.0
    keys = []
    for name, a, b, _loop in layout.seqs:
        keys.append((a, 0.0))
        if name.lower() in phases:
            t = min(b - 1, a + 1 + int((n.delay + s.start) * 1000))
            keys.append((t, count))
            keys.append((min(b, t + 34), 0.0))
    dedup = {}
    for t, v in keys:
        dedup[t] = v
    e.tracks.append(("KP2E", sorted(dedup.items()), writer.INTERP_NONE))
    e.tracks.append(("KP2V", _visibility(layout, phases), writer.INTERP_NONE))


def _ribbon_phase(e, n, layout):
    e.tracks.append(("KRVS", _visibility(layout, _phases(n, layout.usage)), writer.INTERP_NONE))


# ------------------------------------------------------------------ MDX

def _track(tag, keys, interpolation):
    width = len(keys[0][1])
    out = [tag.encode("ascii"), struct.pack("<IIi", len(keys), interpolation, -1)]
    fmt = struct.Struct(f"<i{width}f")
    for frame, value in keys:
        out.append(fmt.pack(int(frame), *value))
    return b"".join(out)


def _node(e, object_id, extra_flags, starts=(0,)):
    tracks = b""
    if e.rotation:
        # A key at every sequence start: a sequence without keys reads the default.
        tracks = _track("KGRT", [(t, e.rotation) for t in starts], writer.INTERP_NONE)
    return struct.pack("<I", 96 + len(tracks)) + writer._name(e.name, 80) + struct.pack(
        "<iiI", object_id, -1, e.flags | extra_flags) + tracks


def _pre2(e, object_id, starts):
    body = _node(e, object_id, 0, starts)
    body += struct.pack("<8f", e.speed, e.variation, e.latitude, e.gravity, e.life, e.rate, e.width, e.length)
    body += struct.pack("<4I", e.filter, e.rows, e.cols, e.head_or_tail)
    body += struct.pack("<2f", e.tail_length, e.time_middle)
    for c in e.colors:
        body += struct.pack("<3f", *c)
    body += bytes(max(0, min(255, int(a))) for a in e.alphas)
    body += struct.pack("<3f", *e.scaling)
    body += struct.pack("<3I", *e.head) + struct.pack("<3I", 0, 0, 1) + struct.pack("<3I", 0, 0, 1) * 2
    body += struct.pack("<iIiI", e.texture_id, e.squirt, 0, 0)
    order = ["KP2S", "KP2R", "KP2L", "KP2G", "KP2E", "KP2N", "KP2W", "KP2V"]
    for tag in order:
        for t, keys, interp in e.tracks:
            if t == tag and keys:
                body += _track(t, [(f, v if isinstance(v, tuple) else (v,)) for f, v in keys], interp)
    return struct.pack("<I", 4 + len(body)) + body


def _ribbon(e, object_id, starts):
    body = _node(e, object_id, F_RIBBON, starts)
    body += struct.pack("<3f", e.height, e.height, e.alpha) + struct.pack("<3f", *e.color)
    body += struct.pack("<fIIIIif", e.life, 0, int(round(e.rate)), 1, 1, e.material_id, e.gravity)
    for t, keys, interp in e.tracks:
        if t == "KRVS" and keys:
            body += _track(t, [(f, v if isinstance(v, tuple) else (v,)) for f, v in keys], interp)
    return struct.pack("<I", 4 + len(body)) + body


LAYER_FILTER = {P_BLEND: writer.FILTER_BLEND, P_ADD: writer.FILTER_ADDITIVE, P_MOD: 5, P_MOD2X: 6}


def write(name, emitters, layout, texture_paths, extent=150.0):
    """MDX 800 bytes of an effect model. `texture_paths`: map paths of the
    textures, by texture index. Ribbons get one material per texture and
    filter mode."""
    out = [b"MDLX", writer._chunk("VERS", struct.pack("<I", writer.VERSION))]
    ext = writer.Extent((-extent, -extent, -extent), (extent, extent, extent))
    out.append(writer._chunk("MODL", writer._name(name, 80) + writer._name("", 260) + ext.pack()
                             + struct.pack("<I", 150)))
    seqs = b""
    for n, a, b, loop in layout.seqs:
        seqs += writer._name(n, 80) + struct.pack("<IIfIfI", a, b, 0.0, 0 if loop else 1, 0.0, 0) + ext.pack()
    out.append(writer._chunk("SEQS", seqs))
    ribbons = [e for e in emitters if e.kind == "ribbon"]
    materials = []
    for e in ribbons:
        key = (e.material_id, e.filter)
        if key not in materials:
            materials.append(key)
        e.material_index = materials.index(key)
    if materials:
        body = b""
        for tex, filt in materials:
            layer = struct.pack("<IIIiiIf", 28, LAYER_FILTER.get(filt, writer.FILTER_BLEND),
                                writer.SHADE_UNSHADED | writer.SHADE_TWO_SIDED, tex, -1, 0, 1.0)
            mat = struct.pack("<iI", 0, 0) + b"LAYS" + struct.pack("<I", 1) + layer
            body += struct.pack("<I", 4 + len(mat)) + mat
        out.append(writer._chunk("MTLS", body))
    if texture_paths:
        out.append(writer._chunk("TEXS", b"".join(
            struct.pack("<I", 0) + writer._name(p, 260) + struct.pack("<I", writer.WRAP_WIDTH | writer.WRAP_HEIGHT)
            for p in texture_paths)))
    pre2 = [e for e in emitters if e.kind == "pre2"]
    starts = sorted(a for _n, a, _b, _loop in layout.seqs)
    count = len(pre2) + len(ribbons)
    if count:
        out.append(writer._chunk("PIVT", struct.pack(f"<{3 * count}f", *([0.0] * 3 * count))))
    if pre2:
        out.append(writer._chunk("PRE2", b"".join(_pre2(e, i, starts) for i, e in enumerate(pre2))))
    if ribbons:
        for e in ribbons:
            e.material_id = e.material_index
        out.append(writer._chunk("RIBB", b"".join(_ribbon(e, len(pre2) + i, starts) for i, e in enumerate(ribbons))))
    return b"".join(out)
