# KineticSceneRuntime — third-party notice

`Sources/KineticWPEEngine` is adapted from **Paradox07127/macos-wallpaperengine**
(https://github.com/Paradox07127/macos-wallpaperengine, commit 3f3e2ba, MIT License,
Copyright (c) 2026 Loomscreen contributors). The full license text is in
`Sources/KineticWPEEngine/UPSTREAM_LICENSE.txt` and `REFERENCE_LICENSE.txt`.

Ported parts: the Wallpaper Engine scene schema and parsers (scene, particles, MDL puppets),
asset / package / TEX readers, the GLSL→MSL shader transpiler and Metal builtins, the render graph,
pipeline builder and Metal executor, particles, puppets, text, sound and SceneScript runtimes.
`Tests/KineticWPEEngineTests` are adapted from the upstream package tests.

Kinetic changes: macOS 13 deployment (display-link / executor fallbacks), Swift 5 language mode,
Kinetic-owned logging (system log only, no log file), app-level services replaced by small shims
(`Sources/KineticWPEEngine/Support`), module-bundle Metal library, portable binary16 readback,
and a shader disk cache enabled only with an explicit host-owned directory. Loomscreen UI, settings, Steam,
library and business layers are not included. No Wallpaper Engine assets are distributed; the
user links or downloads their own copy (Settings › Steam).

The original Kinetic runtime files in `Sources/KineticSceneRuntime` were written for Kinetic with
the same upstream used as a format reference.

Integration status (2026-10-05): the public facade keeps three tiers. Simple scenes stay on the
Kinetic bounded runtime (Worker-backed scripts); admitted scriptless image/material/effect scenes use
KineticWPEImageBackend (host-owned reads, budgets and presentation); every other scene is handed to
`KineticWPESceneHost`, which runs the complete ported `WPEMetalSceneRenderer` (effects, particles,
puppets, text, cameras, sounds) with SceneScript on the ported JavaScriptCore runtime (user decision,
2026-10-05). The host renders on a dedicated render thread paced by a display link (a run-loop timer stands in
for CADisplayLink on macOS 13),
starts muted, opens no windows and starts no audio capture; it reports missing required resources
by path, leaves missing auxiliary texture slots unbound, and mounts the Workshop items a scene
lists in `dependencies` from folders the app supplies (a missing one fails the load by its ID).
Audio-responsive scenes read one process-wide spectrum that the host supplies
(`KineticWPEAudioInput`); the engine never captures audio. Kinetic also lets the engine-assets
resolver accept the `assets` folder itself. Debug dumps stay
behind explicit defaults keys; video textures use the upstream cache in the app's own Caches folder.
This is not yet a claim of complete Wallpaper Engine compatibility. Engine assets are user-supplied.
