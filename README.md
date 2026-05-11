# AudioEffectRustortion (Godot Addon)

`AudioEffectRustortion` is a Godot 4.5 GDExtension audio effect written in Rust.

It is designed for guitar-style real-time processing with a simple data-driven API:
- the game loads preset JSON and IR WAV resources
- the game decodes IR WAV resources to float PCM samples
- the addon receives parsed tone/amp JSON strings and decoded PCM buffers
- processing runs in Rust on the audio thread

## What it does

- Applies tone preamp chains (`TonePresetV1` JSON)
- Applies amplifier chains and input filters (`AmplifierPresetV1` JSON)
- Applies cabinet impulse responses from decoded PCM samples
- Crossfades runtime config updates to avoid preset-switch clicks

## IR PCM loading API

`AudioEffectRustortion` supports decoded PCM IR loading from Godot:

```gdscript
rustortion_effect.load_ir_samples(samples, sample_rate, channels)
```

- `samples`: `PackedFloat32Array` PCM data
- `sample_rate`: source sample rate in Hz
- `channels`: `1` (mono) or `2` (stereo interleaved)

Expected sample layout:

- mono: `[s0, s1, s2, ...]`
- stereo interleaved: `[L0, R0, L1, R1, ...]`

The Rust DSP side consumes this PCM data directly, requires IR sample rate at 48 kHz, downmixes stereo IR to mono, and rebuilds the convolver kernel.

## Project layout

- `src/` — Godot extension implementation
- `rustortion-core` — git dependency from `https://github.com/goguitar/rustortion` (branch `main`)
- `godot-rustortion-demo/` — demo project using live input and preset lists

## Development

`rustortion-core` is fetched automatically by Cargo from GitHub on build.

Build release library and copy it into the demo project:

```bash
cargo build --release
cp target/release/libgodot_rustortion.so godot-rustortion-demo/addons/godot_rustortion/bin/libgodot_rustortion.so
```

Demo binaries are not committed; rebuild/copy as part of local testing.

Run a headless demo bus-output smoke test:

```bash
godot --headless --path godot-rustortion-demo --script res://demo_test.gd
```

## Demo

![Demo Scene](screenshots/demo_scene.png)
