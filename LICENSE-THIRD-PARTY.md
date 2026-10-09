# Third-party material in this repository

| Path | From | Licence |
|---|---|---|
| `exporter/tools/` (except the vendored folders below) | [SK8-ENGINE/skate-3-rust-engine](https://github.com/SK8-ENGINE/skate-3-rust-engine) `tools/`, commit `cb7968930f14dad38457e98720d1a274e469eec2` | |
| `gm_skategm/src/hud/` | ported from [SK8-ENGINE/skate-3-rust-engine](https://github.com/SK8-ENGINE/skate-3-rust-engine)'s trick display (APT player) by renchdedsex | |
| `engine/crates/skate-audio/`, `engine/crates/skate-audio-fma/` | [SK8-ENGINE/skate-3-rust-engine](https://github.com/SK8-ENGINE/skate-3-rust-engine) `crates/`, commit `b3c96793` (Skate 3's sound engine; the installer's `aems_render` renders the foot-brake loops with it) | GPL-3.0 (`LICENSE`) |
| `exporter/tools/asset_pipeline/audio_formats.py`, `audio_export.py` | [SK8-ENGINE/skate-3-rust-engine](https://github.com/SK8-ENGINE/skate-3-rust-engine) `tools/asset_pipeline/`, commit `b3c96793` | GPL-3.0 (`LICENSE`) |
| `vgmstream` (the installer; fetched by `tools/fetch_vgmstream.py`) | [vgmstream](https://github.com/vgmstream/vgmstream) r2117, decodes Skate 3's sounds on the player's PC | ISC-style (`vgmstream-COPYING.txt`) |
| `exporter/tools/vendor/utt/` | UTT, duckyinnit | MIT (`exporter/tools/vendor/utt/LICENSE`) |
| `exporter/tools/vendor/university/`, `exporter/tools/owned_game/` | Skate 3 Custom Engine Layer contributors | MIT (`exporter/tools/vendor/university/LICENSE-PROJECT.md`; `owned_game/NOTICE.md`) |
| `exporter/tools/vendor/skate3_ui/` | | MIT (`exporter/tools/vendor/skate3_ui/LICENSE`) |
| `exporter/tools/vendor/skate3_anim/` | [chasmlol/skate-3-trick-toolkit](https://github.com/chasmlol/skate-3-trick-toolkit) commit `85d9d679` | see `exporter/tools/vendor/skate3_anim/PROVENANCE.md` |
| `exporter/convert.py`, `exporter/build.ps1` | adapted from [2010 Rust Rewrite Mashup](https://github.com/chasmlol/2010-rust-rewrite-mashup) `skate/converter` | Apache-2.0 |
| `engine/` | [2010 Rust Rewrite Mashup](https://github.com/chasmlol/2010-rust-rewrite-mashup) `skate/` (`Cargo.toml`, `crates/`), commit `65d9e117`; its crates from [SK8-ENGINE/skate-3-rust-engine](https://github.com/SK8-ENGINE/skate-3-rust-engine) `cb79689`. Changed by us (marked `gm_sk8 addition`; `engine/CHANGES.patch`) | Apache-2.0 (`engine/LICENSE`, `engine/NOTICE-mashup`) |
| `harness/win/luajit.exe`, `harness/win/lua51.dll` | [LuaJIT](https://luajit.org) | MIT |
| `skategm_sdl2.dll` (release archives and the installer; fetched by `tools/fetch_sdl.py`) | [SDL2](https://github.com/libsdl-org/SDL) 2.32.10, for non-Xbox controllers | zlib (`SDL2-LICENSE.txt`) |
| `skategm_gamecontrollerdb.txt` (same) | [SDL_GameControllerDB](https://github.com/mdqinc/SDL_GameControllerDB) commit `c1d5289a` | zlib (`SDL_GameControllerDB-LICENSE.txt`) |

The engine's source is in `engine/`; the built module (the DLL) is not kept
in the repository, only in release archives, which carry `engine/LICENSE` and
`engine/NOTICE-mashup` with it. No Electronic Arts code or data is included
anywhere: the engine and the exporter read the player's own game files.
