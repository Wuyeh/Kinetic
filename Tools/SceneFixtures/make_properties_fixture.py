"""Module 29's self-authored acceptance scene. Reuses our existing complete-engine demo assets."""
import json
import shutil
import struct
import zlib
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
target = repo / "KineticTests/Fixtures/scene-properties-sample"
shutil.copytree(repo / "KineticTests/Fixtures/scene-full-sample/warm", target, dirs_exist_ok=True)

properties = {
    "showpanel": {"type": "bool", "text": "显示波纹面板", "value": True, "order": 1},
    "speed": {"type": "slider", "text": "面板运动速度", "value": 1, "min": 0, "max": 5, "step": 0.1, "order": 2},
    "direction": {"type": "combo", "text": "运动方向", "value": 1, "options": [
        {"label": "正向", "value": 1}, {"label": "反向", "value": -1}], "order": 3},
    "tint": {"type": "color", "text": "背景颜色", "value": "0.62 0.22 0.08", "order": 4},
    "note": {"type": "text", "text": "点击保存并应用后，只有 A 的属性验证场景会更新。", "order": 5},
}
project = {"type": "scene", "file": "scene.json", "title": "Kinetic scene properties sample",
           "general": {"properties": properties}}
(target / "project.json").write_text(json.dumps(project, ensure_ascii=False, indent=2) + "\n")
scene = json.loads((target / "scene.json").read_text())
scene["objects"][0]["color"] = {"user": "tint", "value": "0.62 0.22 0.08"}
panel = scene["objects"][1]
panel["visible"] = {"user": "showpanel", "value": True}
panel["origin"]["script"] = "export function update(value) {\n value.x = 480 + 160 * Math.sin(engine.runtime * engine.userProperties.speed) * engine.userProperties.direction;\n return value;\n}\n"
(target / "scene.json").write_text(json.dumps(scene, indent=2) + "\n")
material = {"passes": [{"shader": "genericimage2", "blending": "disabled", "textures": ["white.png"]}]}
(target / "materials/background.json").write_text(json.dumps(material, indent=2) + "\n")

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

# A numeric, untextured white source for testing the authored image tint (no external artwork).
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"\x00\xff\xff\xff\xff")) + chunk(b"IEND", b"")
(target / "materials/white.png").write_bytes(png)
