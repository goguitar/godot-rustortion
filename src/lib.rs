mod amp_chain_state;
mod amp_chain_store;
mod audio_effect_gate;
mod audio_effect_rustortion;

use godot::prelude::*;

struct GodotRustortionExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GodotRustortionExtension {}
