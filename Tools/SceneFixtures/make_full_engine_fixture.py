#!/usr/bin/env python3
"""Generates KineticTests/Fixtures/scene-full-sample (Module 28.3 complete-engine acceptance).
All content is self-made: solid colors, generated PNG stripes and sparks, built-in effect families."""
import json, os, struct, zlib, shutil, math, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'KineticTests', 'Fixtures', 'scene-full-sample')

def png(path, w, h, pixel):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(pixel(x, y))
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    data += chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(data)

def write(folder, rel, obj):
    p = os.path.join(folder, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w') as f:
        json.dump(obj, f, indent=2, sort_keys=True); f.write('\n')

MOVE_X = "'use strict';\nexport function update(value) {\n\tvalue.x = 480 + 160 * Math.sin(engine.runtime);\n\treturn value;\n}\n"
MOVE_Y = "'use strict';\nexport function update(value) {\n\tvalue.y = 270 + 90 * Math.sin(engine.runtime * 1.3);\n\treturn value;\n}\n"
RUNAWAY = "'use strict';\nexport function update(value) {\n\twhile (true) {}\n\treturn value;\n}\n"

def project(name, title, background, panel_rgb, spark_rgb, script, panel_model='models/panel.json'):
    folder = os.path.join(ROOT, name)
    write(folder, 'project.json', {'type': 'scene', 'file': 'scene.json', 'title': title})
    write(folder, 'models/background.json', {'material': 'materials/background.json'})
    write(folder, 'materials/background.json', {'passes': [{'shader': 'solidcolor', 'blending': 'disabled',
        'constantshadervalues': {'g_Color': background + [1]}}]})
    if panel_model == 'models/panel.json':
        write(folder, 'models/panel.json', {'material': 'materials/panel.json'})
    write(folder, 'materials/panel.json', {'passes': [{'shader': 'commands/copy', 'blending': 'translucent',
        'textures': ['panel']}]})
    # Built-in effect families (effect_waterwaves) — no engine shader source required.
    write(folder, 'effects/waterwaves/effect.json', {'name': 'waterwaves', 'passes': [{'material': 'materials/effects/waterwaves.json'}]})
    write(folder, 'materials/effects/waterwaves.json', {'passes': [{'shader': 'effects/waterwaves', 'blending': 'normal'}]})
    write(folder, 'particles/sparks.json', {'material': 'materials/spark.json', 'maxcount': 160,
        'emitter': [{'name': 'boxrandom', 'rate': 40, 'distancemax': '420 220 0', 'distancemin': '0 0 0', 'origin': '0 0 0'}],
        'initializer': [{'name': 'lifetimerandom', 'min': 1.5, 'max': 3}, {'name': 'sizerandom', 'min': 8, 'max': 20},
                        {'name': 'velocityrandom', 'min': '-20 30 0', 'max': '20 110 0'}],
        'operator': [{'name': 'movement', 'gravity': '0 0 0', 'drag': 0}, {'name': 'alphafade', 'fadeintime': 0.2, 'fadeouttime': 0.5}]})
    write(folder, 'materials/spark.json', {'passes': [{'shader': 'genericparticle', 'blending': 'additive', 'textures': ['spark']}]})
    pr, pg, pb = panel_rgb
    def panel(x, y):
        t = x / 127.0
        stripe = 1.0 if (y // 8) % 2 == 0 else 0.82
        return bytes([int(min(255, pr * (0.65 + 0.35 * t) * stripe)), int(min(255, pg * (0.65 + 0.35 * t) * stripe)),
                      int(min(255, pb * (0.65 + 0.35 * t) * stripe)), 255])
    png(os.path.join(folder, 'materials/panel.png'), 128, 64, panel)
    sr, sg, sb = spark_rgb
    def spark(x, y):
        d = math.hypot(x - 15.5, y - 15.5) / 15.5
        a = max(0.0, 1.0 - d) ** 1.5
        return bytes([sr, sg, sb, int(255 * a)])
    png(os.path.join(folder, 'materials/spark.png'), 32, 32, spark)
    scene = {'camera': {'center': '0 0 0'},
        'general': {'clearcolor': '0 0 0', 'orthogonalprojection': {'width': 960, 'height': 540}},
        'objects': [
            {'id': 1, 'name': 'Background', 'image': 'models/background.json', 'origin': '480 270 0', 'size': '960 540 0'},
            {'id': 2, 'name': 'Scripted waving panel', 'image': panel_model, 'size': '512 256 0',
             'origin': {'value': '480 270 0', 'script': script, 'scriptproperties': {}},
             'effects': [{'id': 3, 'file': 'effects/waterwaves/effect.json',
                          'passes': [{'constantshadervalues': {'speed': 3, 'scale': 25, 'strength': 0.25, 'direction': 1.5708}}]}]},
            {'id': 4, 'name': 'Sparks', 'particle': 'particles/sparks.json', 'origin': '480 270 0'}]}
    write(folder, 'scene.json', scene)

if os.path.exists(ROOT): shutil.rmtree(ROOT)
project('warm', 'Kinetic complete engine warm', [0.62, 0.22, 0.08], (255, 214, 150), (255, 220, 120), MOVE_X)
project('cool', 'Kinetic complete engine cool', [0.06, 0.22, 0.48], (150, 214, 255), (170, 230, 255), MOVE_Y)
project('invalid', 'Kinetic complete engine missing model', [0.2, 0.2, 0.2], (200, 200, 200), (255, 255, 255), MOVE_X,
        panel_model='models/missing-full-engine-panel.json')
project('looping', 'Kinetic complete engine runaway script', [0.3, 0.1, 0.3], (230, 180, 255), (255, 200, 255), RUNAWAY)
print('ok')
