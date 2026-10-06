#!/usr/bin/env python3
"""Kinetic 引导用演示壁纸（原创、程序生成、无缝循环）。

每段视频的所有运动都是周期 T 的整数倍频率，第 T 秒的画面与第 0 秒相同，循环播放没有跳变。
用法：python3 render_demos.py <输出目录> [名称...]
需要 numpy 与带 libx265 的 ffmpeg。输出放到 Kinetic/Resources/Demos/。
引导页缩略图取第一帧：ffmpeg -i aurora.mp4 -frames:v 1 -vf scale=960:540:flags=lanczos -q:v 3 aurora.jpg
"""
import math
import subprocess
import sys

import numpy as np

FPS = 30
SECONDS = 12
FRAMES = FPS * SECONDS
OUT_W, OUT_H = 2560, 1440
TAU = 2 * math.pi


def hex_rgb(value):
    value = value.lstrip('#')
    return np.array([int(value[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=np.float32)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


class Aurora:
    """夜空中的极光：三道随时间起伏的光带，底部轮廓清晰、向上渐隐，背景有少量闪烁的星星。"""
    name = 'aurora'
    render_size = (1280, 720)

    def __init__(self):
        w, h = self.render_size
        self.x = np.linspace(0, 1, w, dtype=np.float32)[None, :]
        self.y = np.linspace(0, 1, h, dtype=np.float32)[:, None]
        top, bottom = hex_rgb('#060B1F'), hex_rgb('#15264A')
        self.sky = top + (bottom - top) * self.y[..., None] ** 1.3
        rng = np.random.default_rng(7)
        n = 220
        self.stars = (rng.integers(0, w, n), rng.integers(0, int(h * 0.8), n),
                      rng.uniform(0.25, 0.9, n), rng.integers(1, 4, n), rng.uniform(0, TAU, n))
        self.bands = [
            # 基线高度、振幅、空间频率、时间频率、颜色、厚度
            (0.66, 0.07, 1.6, 1, hex_rgb('#39E6B8'), 0.26),
            (0.56, 0.05, 2.3, 2, hex_rgb('#58BFDA'), 0.20),
            (0.47, 0.04, 3.1, 1, hex_rgb('#8C6CFF'), 0.16),
        ]
        # 远近两层山脊剪影（静止），让画面有地平线。
        xs = self.x[0]
        far = 0.80 + 0.035 * np.sin(TAU * 1.3 * xs + 0.4) + 0.02 * np.sin(TAU * 3.7 * xs + 1.1)
        near = 0.88 + 0.04 * np.sin(TAU * 0.9 * xs + 2.0) + 0.015 * np.sin(TAU * 5.3 * xs)
        self.far_mask = smoothstep(-0.002, 0.002, self.y - far[None, :])[..., None]
        self.near_mask = smoothstep(-0.002, 0.002, self.y - near[None, :])[..., None]
        self.far_color = hex_rgb('#0B1630')
        self.near_color = hex_rgb('#050A18')

    def frame(self, t):
        phase = TAU * t / SECONDS
        img = self.sky.copy()
        x, y = self.x, self.y
        for i, (base, amp, fx, ft, color, thick) in enumerate(self.bands):
            curve = (base
                     + amp * np.sin(TAU * fx * x + ft * phase + i * 1.7)
                     + amp * 0.35 * np.sin(TAU * fx * 2.3 * x - 2 * ft * phase + i))
            d = curve - y  # >0：光带底边之上
            glow = np.where(d > 0, np.exp(-d / thick), np.exp(d / 0.012))
            ripple = 0.55 + 0.45 * np.sin(TAU * (7 + i * 3) * x - (i + 1) * phase + 0.8 * np.sin(TAU * 2 * x + phase))
            fade = 0.6 + 0.4 * np.sin(TAU * (1 + i) * x * 0.5 + (2 - i % 2) * phase + i)
            intensity = (glow * ripple * fade * 0.85)[..., None]
            img = img + color * intensity * (1 - img * 0.35)
        sx, sy, sa, sf, sp = self.stars
        twinkle = sa * (0.6 + 0.4 * np.sin(sf * phase + sp))
        img[sy, sx] = np.maximum(img[sy, sx], twinkle[:, None])
        img = img * (1 - self.far_mask) + self.far_color * self.far_mask
        img = img * (1 - self.near_mask) + self.near_color * self.near_mask
        return img


class Dawn:
    """柔和的暖色渐变：几团大面积色块沿闭合轨迹缓慢游移、互相融合。"""
    name = 'dawn'
    render_size = (640, 360)

    def __init__(self):
        w, h = self.render_size
        self.x = np.linspace(0, 16 / 9, w, dtype=np.float32)[None, :]
        self.y = np.linspace(0, 1, h, dtype=np.float32)[:, None]
        self.base = hex_rgb('#FBE3D2')
        self.blobs = [
            # 颜色、中心、轨迹半径、时间频率(x, y)、相位、大小
            (hex_rgb('#FF8E7A'), (0.35, 0.30), (0.22, 0.12), (1, 1), 0.0, 0.42),
            (hex_rgb('#FFC56E'), (1.25, 0.25), (0.20, 0.10), (1, 2), 1.3, 0.40),
            (hex_rgb('#B99CFF'), (1.35, 0.80), (0.25, 0.14), (1, 1), 2.4, 0.45),
            (hex_rgb('#FF9FC2'), (0.55, 0.85), (0.18, 0.12), (2, 1), 3.9, 0.38),
            (hex_rgb('#8FD3E8'), (0.95, 0.55), (0.30, 0.18), (1, 1), 5.1, 0.30),
        ]

    def frame(self, t):
        phase = TAU * t / SECONDS
        weight_sum = np.full((len(self.y[:, 0]), len(self.x[0])), 0.25, dtype=np.float32)
        color_sum = self.base * weight_sum[..., None]
        for color, (cx, cy), (rx, ry), (fx, fy), ph, size in self.blobs:
            px = cx + rx * math.sin(fx * phase + ph)
            py = cy + ry * math.cos(fy * phase + ph * 0.7)
            d2 = (self.x - px) ** 2 + (self.y - py) ** 2
            wgt = np.exp(-d2 / (size * size))
            weight_sum += wgt
            color_sum += color * wgt[..., None]
        img = color_sum / weight_sum[..., None]
        # 轻微的整体明暗呼吸，保持画面有生命感。
        return img * (0.97 + 0.03 * math.sin(phase))


class Drift:
    """深海蓝绿背景中，柔和的光点缓慢上浮并左右摇曳。"""
    name = 'drift'
    render_size = (2560, 1440)

    def __init__(self):
        w, h = self.render_size
        yy = np.linspace(0, 1, h, dtype=np.float32)[:, None]
        xx = np.linspace(0, 1, w, dtype=np.float32)[None, :]
        top, bottom = hex_rgb('#062B3A'), hex_rgb('#03121F')
        vignette = 1 - 0.35 * ((xx - 0.5) ** 2 + (yy - 0.45) ** 2)
        self.bg = (top + (bottom - top) * yy[..., None]) * vignette[..., None]
        rng = np.random.default_rng(11)
        n = 70
        self.px = rng.uniform(0, w, n)
        self.py = rng.uniform(0, h, n)
        self.radius = rng.uniform(10, 70, n) ** 1.0
        self.alpha = rng.uniform(0.08, 0.35, n)
        self.loops = rng.integers(1, 3, n)          # 一个周期内上浮整屏的圈数
        self.sway = rng.uniform(10, 50, n)
        self.sway_f = rng.integers(1, 3, n)
        self.sway_p = rng.uniform(0, TAU, n)
        palette = [hex_rgb('#7FE0D6'), hex_rgb('#58BFDA'), hex_rgb('#A9E8FF'), hex_rgb('#C7B8FF')]
        self.color = [palette[i % len(palette)] for i in rng.integers(0, len(palette), n)]

    def frame(self, t):
        w, h = self.render_size
        phase = TAU * t / SECONDS
        img = self.bg.copy()
        margin = 160
        span = h + 2 * margin
        for i in range(len(self.px)):
            r = self.radius[i]
            y = (self.py[i] - self.loops[i] * span * t / SECONDS) % span - margin
            x = self.px[i] + self.sway[i] * math.sin(self.sway_f[i] * phase + self.sway_p[i])
            ext = int(r * 2.2)
            x0, x1 = max(0, int(x) - ext), min(w, int(x) + ext)
            y0, y1 = max(0, int(y) - ext), min(h, int(y) + ext)
            if x0 >= x1 or y0 >= y1:
                continue
            gx = np.arange(x0, x1, dtype=np.float32)[None, :] - x
            gy = np.arange(y0, y1, dtype=np.float32)[:, None] - y
            dist = np.sqrt(gx * gx + gy * gy)
            # 散景光点：内部均匀、边缘柔和，外圈微弱光晕。
            disc = smoothstep(r, r * 0.8, dist) * 0.8 + np.exp(-(dist / (r * 1.3)) ** 2) * 0.35
            twinkle = 0.75 + 0.25 * math.sin((1 + i % 3) * phase + self.sway_p[i])
            img[y0:y1, x0:x1] += self.color[i] * (disc * self.alpha[i] * twinkle)[..., None]
        return img


SCENES = {cls.name: cls for cls in (Aurora, Dawn, Drift)}


def render(scene, path):
    w, h = scene.render_size
    cmd = ['ffmpeg', '-y', '-loglevel', 'error',
           '-f', 'rawvideo', '-pix_fmt', 'rgb48le', '-s', f'{w}x{h}', '-r', str(FPS), '-i', '-',
           '-vf', f'scale={OUT_W}:{OUT_H}:flags=lanczos,format=yuv420p10le',
           # 平滑渐变容易出现色带：10-bit + aq-mode=3 + 较低 CRF。
           '-c:v', 'libx265', '-preset', 'medium', '-crf', '11',
           '-x265-params', 'log-level=error:keyint=60:aq-mode=3:psy-rd=2:deblock=-1,-1',
           '-tag:v', 'hvc1', '-movflags', '+faststart', '-an', path]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for f in range(FRAMES):
        img = np.clip(scene.frame(f / FPS), 0, 1)
        proc.stdin.write((img * 65535 + 0.5).astype('<u2').tobytes())
    proc.stdin.close()
    if proc.wait() != 0:
        raise SystemExit(f'ffmpeg failed for {path}')


if __name__ == '__main__':
    out = sys.argv[1]
    names = sys.argv[2:] or list(SCENES)
    for name in names:
        render(SCENES[name](), f'{out}/{name}.mp4')
        print('rendered', name, flush=True)
