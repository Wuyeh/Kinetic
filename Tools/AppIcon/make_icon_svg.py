#!/usr/bin/env python3
"""Kinetic 动态轨迹 K：生成 App 图标（Icon Composer .icon）用的 SVG 图层。

几何与 App 内 `KineticLogo.swift` 相同（100×100 坐标，y 向下）：一条略带弧度的竖向主轨迹，
以及一条从右上划向中部、再展开到右下的连续弧形轨迹。线条端点为圆头。
图标中的 K 与启动动画字标里的 K 同形，线宽取菜单栏标志的 13（小尺寸略粗，规格 4），占画布约 64%。
描边转换为填充轮廓，保证 Icon Composer 渲染一致。白底、玻璃质感与主题色泛光由 icon.json 设置。
用法：python3 make_icon_svg.py <输出 svg>
"""
import sys
from shapely.geometry import LineString
from shapely.ops import unary_union

STEM = [(27, 12), (24, 40), (24, 62), (27, 88)]
TRAJECTORY = [[(74, 12), (68, 34), (54, 50), (38, 54)], [(38, 54), (56, 58), (70, 70), (76, 88)]]
WIDTH = 13.0
SCALE = 0.64


def cubic(p, n=64):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = p
    pts = []
    for i in range(n + 1):
        t = i / n
        a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3
        pts.append((a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3))
    return pts


def outline(scale=SCALE, width=WIDTH):
    stem = LineString(cubic(STEM))
    traj = LineString(cubic(TRAJECTORY[0]) + cubic(TRAJECTORY[1])[1:])
    shape = unary_union([stem.buffer(width / 2, quad_segs=16, cap_style='round', join_style='round'),
                         traj.buffer(width / 2, quad_segs=16, cap_style='round', join_style='round')])
    # 放到 1024 画布中心。
    def tr(x, y):
        return (512 + (x - 50) * 10.24 * scale, 512 + (y - 50) * 10.24 * scale)
    polys = list(shape.geoms) if hasattr(shape, 'geoms') else [shape]
    d = []
    for poly in polys:
        for ring in [poly.exterior, *poly.interiors]:
            coords = [tr(x, y) for x, y in ring.coords]
            d.append('M ' + ' L '.join(f'{x:.2f} {y:.2f}' for x, y in coords) + ' Z')
    return ' '.join(d)


if __name__ == '__main__':
    path = outline()
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
           f'<path d="{path}" fill="#58BFDA" fill-rule="nonzero"/></svg>\n')
    open(sys.argv[1], 'w').write(svg)
