#!/usr/bin/env python3
"""Register new Swift files in Kinetic.xcodeproj (the project uses hand-numbered object IDs).

Usage: Tools/add_to_xcodeproj.py <group> <file name> [<group> <file name> ...]
group: App | Steam | Library | Runtime | CoreDomain | SceneRenderer | VideoRenderer | WebRenderer | Overlay | SystemMonitor | Tests
App-side files join the Kinetic target; Tests files join KineticTests.
"""
import re
import sys

PROJECT = "Kinetic.xcodeproj/project.pbxproj"
GROUPS = {
    "App": "C00000000000000000000003",
    "CoreDomain": "C00000000000000000000004",
    "Steam": "C0000000000000000000001C",
    "SceneRenderer": "C0000000000000000000001E",
    "VideoRenderer": "C00000000000000000000011",
    "WebRenderer": "C0000000000000000000001B",
    "Runtime": "C00000000000000000000012",
    "Library": "C00000000000000000000014",
    "Tests": "C00000000000000000000007",
    "Overlay": "C0000000000000000000001F",
    "SystemMonitor": "C00000000000000000000018",
}
APP_PHASE = "E00000000000000000000001"
TEST_PHASE = "E00000000000000000000004"


def next_id(text, letter):
    numbers = [int(m, 16) for m in re.findall(r"\b" + letter + r"(0{16}[0-9A-F]{7})\b", text)]
    return letter + format(max(numbers) + 1, "023X")


def add(text, group, name):
    if f"path = {name};" in text:
        print(f"skip {name}: already registered")
        return text
    build = next_id(text, "A")
    ref = "B" + build[1:]
    assert ref not in text, ref
    text = text.replace("/* Begin PBXBuildFile section */\n",
                        f"/* Begin PBXBuildFile section */\n\t\t{build} /* {name} in Sources */ = "
                        f"{{isa = PBXBuildFile; fileRef = {ref}; }};\n", 1)
    text = text.replace("/* Begin PBXFileReference section */\n",
                        f"/* Begin PBXFileReference section */\n\t\t{ref} /* {name} */ = "
                        f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; "
                        f"sourceTree = \"<group>\"; }};\n", 1)
    group_id = GROUPS[group]
    pattern = re.compile(re.escape(group_id) + r"( /\* [^*]+ \*/)? = \{\s*isa = PBXGroup;\s*children = \(")
    match = pattern.search(text)
    assert match, group
    text = text[:match.end()] + f"{ref} /* {name} */, " + text[match.end():]
    phase = TEST_PHASE if group == "Tests" else APP_PHASE
    pattern = re.compile(re.escape(phase) + r" = \{\s*isa = PBXSourcesBuildPhase;\s*buildActionMask = \d+;\s*files = \(")
    match = pattern.search(text)
    assert match, phase
    text = text[:match.end()] + f"{build} /* {name} in Sources */, " + text[match.end():]
    print(f"added {name} ({group}) as {ref}")
    return text


def main(argv):
    if len(argv) < 2 or len(argv) % 2:
        print(__doc__)
        return 1
    with open(PROJECT, encoding="utf-8") as handle:
        text = handle.read()
    for index in range(0, len(argv), 2):
        text = add(text, argv[index], argv[index + 1])
    with open(PROJECT, "w", encoding="utf-8") as handle:
        handle.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
