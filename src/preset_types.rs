use anyhow::{Result, bail};
use rustortion_core::amp::stages::preamp::PreampConfig;
use rustortion_core::preset::{InputFilterConfig, StageConfig};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct TonePresetV1 {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    #[serde(default)]
    pub name: String,
    pub preamp_chain: Vec<PreampConfig>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AmplifierPresetV1 {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub input_filters: InputFilterConfig,
    #[serde(default)]
    pub amp_chain: Vec<StageConfig>,
}

fn default_schema_version() -> u32 {
    1
}

impl TonePresetV1 {
    pub fn parse(json: &str) -> Result<Self> {
        let preset: Self = serde_json::from_str(json)?;
        if preset.schema_version != 1 {
            bail!("unsupported TonePreset schema_version {}", preset.schema_version);
        }
        Ok(preset)
    }

    pub fn preamp_stages(&self) -> Vec<StageConfig> {
        self.preamp_chain
            .iter()
            .copied()
            .map(StageConfig::Preamp)
            .collect()
    }
}

impl AmplifierPresetV1 {
    pub fn parse(json: &str) -> Result<Self> {
        let preset: Self = serde_json::from_str(json)?;
        if preset.schema_version != 1 {
            bail!(
                "unsupported AmplifierPreset schema_version {}",
                preset.schema_version
            );
        }
        if preset
            .amp_chain
            .iter()
            .any(|stage| matches!(stage, StageConfig::Preamp(_)))
        {
            bail!("AmplifierPreset v1 amp_chain cannot contain Preamp stages");
        }
        Ok(preset)
    }
}
