mod audio_effect_rustortion;

use godot::prelude::*;

struct GodotRustortionExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GodotRustortionExtension {}
