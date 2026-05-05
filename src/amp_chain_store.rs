use godot::classes::file_access::ModeFlags;
use godot::classes::{DirAccess, FileAccess, Json};
use godot::prelude::*;

const PRESET_EXTENSION: &str = ".json";

#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct AmpChainStore {
    #[init(val = GString::new())]
    preset_dir: GString,
    #[init(val = GString::new())]
    last_error: GString,
    base: Base<RefCounted>,
}

#[godot_api]
impl AmpChainStore {
    #[func]
    fn set_preset_dir(&mut self, preset_dir: GString) -> bool {
        if preset_dir.is_empty() {
            self.set_error("Preset directory is empty");
            return false;
        }
        self.preset_dir = preset_dir;
        self.clear_error();
        true
    }

    #[func]
    fn get_preset_dir(&self) -> GString {
        self.preset_dir.clone()
    }

    #[func]
    fn get_last_error(&self) -> GString {
        self.last_error.clone()
    }

    #[func]
    fn list_presets(&mut self) -> PackedStringArray {
        let Some(dir) = self.open_dir() else {
            return PackedStringArray::new();
        };

        let mut files = dir.get_files().to_vec();
        files.retain(|file| file.to_string().to_lowercase().ends_with(PRESET_EXTENSION));
        files.sort_by(|a, b| a.to_string().cmp(&b.to_string()));

        self.clear_error();
        PackedStringArray::from_iter(files)
    }

    #[func]
    fn load_preset(&mut self, preset_name: GString) -> VarDictionary {
        let Some(path) = self.resolve_preset_path(preset_name) else {
            return VarDictionary::new();
        };

        let Some(file) = FileAccess::open(path.clone(), ModeFlags::READ) else {
            self.set_error(format!(
                "Failed to open preset '{}': {:?}",
                path,
                FileAccess::get_open_error()
            ));
            return VarDictionary::new();
        };

        let json_text = file.get_as_text(false);
        let parsed = Json::parse_string(json_text);
        if parsed.get_type() != VariantType::DICTIONARY {
            self.set_error(format!("Preset '{}' did not parse as dictionary", path));
            return VarDictionary::new();
        }

        match parsed.try_to::<VarDictionary>() {
            Ok(dict) => {
                self.clear_error();
                dict
            }
            Err(err) => {
                self.set_error(format!("Preset '{}' failed to convert: {err}", path));
                VarDictionary::new()
            }
        }
    }

    #[func]
    fn save_preset(&mut self, preset_name: GString, preset: VarDictionary) -> bool {
        let Some(path) = self.resolve_preset_path(preset_name) else {
            return false;
        };

        let json_text = Json::stringify(&preset.to_variant(), GString::new(), true, false);
        let Some(mut file) = FileAccess::open(path.clone(), ModeFlags::WRITE) else {
            self.set_error(format!(
                "Failed to open preset '{}' for writing: {:?}",
                path,
                FileAccess::get_open_error()
            ));
            return false;
        };

        file.store_string(json_text);
        self.clear_error();
        true
    }
}

impl AmpChainStore {
    fn set_error(&mut self, message: impl Into<GString>) {
        self.last_error = message.into();
    }

    fn clear_error(&mut self) {
        self.last_error = GString::new();
    }

    fn open_dir(&mut self) -> Option<Gd<DirAccess>> {
        if self.preset_dir.is_empty() {
            self.set_error("Preset directory not set");
            return None;
        }

        let Some(dir) = DirAccess::open(self.preset_dir.clone()) else {
            self.set_error(format!("Failed to open preset directory '{}'", self.preset_dir));
            return None;
        };
        Some(dir)
    }

    fn resolve_preset_path(&mut self, preset_name: GString) -> Option<GString> {
        let name = preset_name.to_string();
        if name.is_empty() {
            self.set_error("Preset name is empty");
            return None;
        }

        let mut file_name = name;
        if !file_name.to_lowercase().ends_with(PRESET_EXTENSION) {
            file_name.push_str(PRESET_EXTENSION);
        }

        if file_name.contains("://") {
            return Some(file_name.into());
        }

        if self.preset_dir.is_empty() {
            self.set_error("Preset directory not set");
            return None;
        }

        let base = self.preset_dir.to_string();
        Some(format!("{}/{}", base.trim_end_matches('/'), file_name).into())
    }
}
