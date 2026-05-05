use godot::classes::Json;
use godot::prelude::*;

const DEFAULT_HP_ENABLED: bool = true;
const DEFAULT_HP_CUTOFF: f32 = 100.0;
const DEFAULT_LP_ENABLED: bool = true;
const DEFAULT_LP_CUTOFF: f32 = 8000.0;
const DEFAULT_PRESET_NAME: &str = "Preset";

fn default_input_filters() -> VarDictionary {
    let mut filters = VarDictionary::new();
    filters.set("hp_enabled", DEFAULT_HP_ENABLED);
    filters.set("hp_cutoff", DEFAULT_HP_CUTOFF);
    filters.set("lp_enabled", DEFAULT_LP_ENABLED);
    filters.set("lp_cutoff", DEFAULT_LP_CUTOFF);
    filters
}

fn stringify_variant(value: Variant) -> GString {
    Json::stringify(&value, GString::new(), true, false)
}

fn variant_to_f32(value: &Variant, fallback: f32) -> f32 {
    value
        .try_to_relaxed::<f64>()
        .map(|v| v as f32)
        .unwrap_or(fallback)
}

#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct AmpChainState {
    #[init(val = GString::new())]
    preset_name: GString,
    #[init(val = VarArray::new())]
    stages: VarArray,
    #[init(val = default_input_filters())]
    input_filters: VarDictionary,
    base: Base<RefCounted>,
}

#[godot_api]
impl AmpChainState {
    #[func]
    fn clear(&mut self) {
        self.preset_name = GString::new();
        self.stages.clear();
        self.input_filters = default_input_filters();
    }

    #[func]
    fn load_from_source_preset(&mut self, preset: VarDictionary) {
        self.clear();
        self.preset_name = preset
            .get("name")
            .and_then(|value| value.try_to::<GString>().ok())
            .unwrap_or_else(|| GString::from(DEFAULT_PRESET_NAME));

        if let Some(stage_list) = preset.get("stages").and_then(|value| value.try_to::<VarArray>().ok()) {
            for entry in stage_list.iter_shared() {
                if entry.get_type() != VariantType::DICTIONARY {
                    continue;
                }
                if let Ok(dict) = entry.try_to::<VarDictionary>() {
                    let variant = dict.duplicate_deep().to_variant();
                    self.stages.push(&variant);
                }
            }
        }

        if let Some(filters) = preset
            .get("input_filters")
            .and_then(|value| value.try_to::<VarDictionary>().ok())
        {
            self.input_filters = filters.duplicate_deep();
        }
    }

    #[func]
    fn get_preset_name(&self) -> GString {
        self.preset_name.clone()
    }

    #[func]
    fn set_preset_name(&mut self, preset_name: GString) {
        self.preset_name = preset_name;
    }

    #[func]
    fn stages_json(&self) -> GString {
        stringify_variant(self.stages.to_variant())
    }

    #[func]
    fn input_filters_json(&self) -> GString {
        stringify_variant(self.input_filters.to_variant())
    }

    #[func]
    fn first_tonestack_index(&self) -> i32 {
        self.find_first_stage_index("ToneStack")
    }

    #[func]
    fn first_level_index(&self) -> i32 {
        self.find_first_stage_index("Level")
    }

    #[func]
    fn current_tonestack_values(&self) -> VarDictionary {
        let mut values = VarDictionary::new();
        let Some(stage) = self.stage_dict_at(self.first_tonestack_index()) else {
            values.set("bass", 1.0);
            values.set("mid", 1.0);
            values.set("treble", 1.0);
            return values;
        };

        let stack = stage
            .get("ToneStack")
            .and_then(|value| value.try_to::<VarDictionary>().ok())
            .unwrap_or_else(VarDictionary::new);

        values.set("bass", variant_to_f32(&stack.get_or_nil("bass"), 1.0));
        values.set("mid", variant_to_f32(&stack.get_or_nil("mid"), 1.0));
        values.set("treble", variant_to_f32(&stack.get_or_nil("treble"), 1.0));
        values
    }

    #[func]
    fn current_level_gain(&self) -> f32 {
        let Some(stage) = self.stage_dict_at(self.first_level_index()) else {
            return 1.0;
        };
        let level = stage
            .get("Level")
            .and_then(|value| value.try_to::<VarDictionary>().ok())
            .unwrap_or_else(VarDictionary::new);
        variant_to_f32(&level.get_or_nil("gain"), 1.0)
    }

    #[func]
    fn set_tonestack(&mut self, bass: f32, mid: f32, treble: f32) -> bool {
        let stage_idx = self.first_tonestack_index();
        if stage_idx < 0 {
            return false;
        }

        let Some(mut stage) = self.stage_dict_at(stage_idx) else {
            return false;
        };
        let mut stack = stage
            .get("ToneStack")
            .and_then(|value| value.try_to::<VarDictionary>().ok())
            .unwrap_or_else(VarDictionary::new);
        stack.set("bass", bass);
        stack.set("mid", mid);
        stack.set("treble", treble);
        stage.set("ToneStack", stack);

        self.set_stage_entry(stage_idx, stage);
        true
    }

    #[func]
    fn set_level_gain(&mut self, gain: f32) -> bool {
        let stage_idx = self.first_level_index();
        if stage_idx < 0 {
            return false;
        }

        let Some(mut stage) = self.stage_dict_at(stage_idx) else {
            return false;
        };
        let mut level = stage
            .get("Level")
            .and_then(|value| value.try_to::<VarDictionary>().ok())
            .unwrap_or_else(VarDictionary::new);
        level.set("gain", gain);
        stage.set("Level", level);

        self.set_stage_entry(stage_idx, stage);
        true
    }

    #[func]
    fn add_stage(&mut self, parent_stage_idx: i32, stage_entry: VarDictionary, insert_after: bool) -> i32 {
        let entry_variant = stage_entry.duplicate_deep().to_variant();
        if parent_stage_idx == -1 {
            self.stages.push(&entry_variant);
            return (self.stages.len().saturating_sub(1)) as i32;
        }

        let Ok(parent_idx) = usize::try_from(parent_stage_idx) else {
            return -1;
        };
        if parent_idx >= self.stages.len() {
            return -1;
        }

        let insert_idx = if insert_after { parent_idx + 1 } else { parent_idx };
        self.stages.insert(insert_idx, &entry_variant);
        insert_idx as i32
    }

    #[func]
    fn remove_stage(&mut self, stage_idx: i32) -> bool {
        let Ok(idx) = usize::try_from(stage_idx) else {
            return false;
        };
        if idx >= self.stages.len() {
            return false;
        }
        self.stages.remove(idx);
        true
    }

    #[func]
    fn swap_stages(&mut self, stage_a: i32, stage_b: i32) -> bool {
        let Ok(a) = usize::try_from(stage_a) else {
            return false;
        };
        let Ok(b) = usize::try_from(stage_b) else {
            return false;
        };
        if a >= self.stages.len() || b >= self.stages.len() {
            return false;
        }

        let entry_a = self.stages.at(a);
        let entry_b = self.stages.at(b);
        self.stages.set(a, &entry_b);
        self.stages.set(b, &entry_a);
        true
    }

    #[func]
    fn rebuild_stage(&mut self, stage_idx: i32, stage_entry: VarDictionary) -> bool {
        let Ok(idx) = usize::try_from(stage_idx) else {
            return false;
        };
        if idx >= self.stages.len() {
            return false;
        }
        let entry_variant = stage_entry.duplicate_deep().to_variant();
        self.stages.set(idx, &entry_variant);
        true
    }

    #[func]
    fn stage_json(&self, stage_idx: i32) -> GString {
        let Ok(idx) = usize::try_from(stage_idx) else {
            return GString::new();
        };
        if idx >= self.stages.len() {
            return GString::new();
        }
        stringify_variant(self.stages.at(idx))
    }

    #[func]
    fn stage_display_name(&self, stage_idx: i32) -> GString {
        let Ok(idx) = usize::try_from(stage_idx) else {
            return GString::new();
        };
        if idx >= self.stages.len() {
            return GString::new();
        }
        let Ok(stage) = self.stages.at(idx).try_to::<VarDictionary>() else {
            return GString::from("Unknown");
        };
        if stage.is_empty() {
            return GString::from("Unknown");
        }
        let keys = stage.keys();
        if keys.is_empty() {
            return GString::from("Unknown");
        }
        keys.at(0).try_to::<GString>().unwrap_or_else(|_| GString::from("Unknown"))
    }
}

impl AmpChainState {
    fn stage_dict_at(&self, stage_idx: i32) -> Option<VarDictionary> {
        let idx = usize::try_from(stage_idx).ok()?;
        if idx >= self.stages.len() {
            return None;
        }
        self.stages.at(idx).try_to::<VarDictionary>().ok()
    }

    fn set_stage_entry(&mut self, stage_idx: i32, entry: VarDictionary) {
        if let Ok(idx) = usize::try_from(stage_idx) {
            if idx < self.stages.len() {
                let variant = entry.duplicate_deep().to_variant();
                self.stages.set(idx, &variant);
            }
        }
    }

    fn find_first_stage_index(&self, stage_name: &str) -> i32 {
        for idx in 0..self.stages.len() {
            let Ok(stage) = self.stages.at(idx).try_to::<VarDictionary>() else {
                continue;
            };
            if stage.contains_key(stage_name) {
                return idx as i32;
            }
        }
        -1
    }
}
