mod audio_effect_rustortion;
mod preset_types;

use godot::prelude::*;

struct GodotRustortionExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GodotRustortionExtension {}
