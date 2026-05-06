use std::ffi::c_void;
use std::slice;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::Once;
use std::sync::atomic::AtomicU32;
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result, bail};
use arc_swap::ArcSwap;
use godot::classes::native::AudioFrame;
use godot::classes::{AudioEffect, AudioEffectInstance, AudioServer, IAudioEffect, IAudioEffectInstance};
use godot::meta::conv::RawPtr;
use godot::prelude::*;
use rustortion_core::amp::chain::AmplifierChain;
use rustortion_core::amp::stages::Stage;
use rustortion_core::amp::stages::clipper;
use rustortion_core::amp::stages::filter::{FilterStage, FilterType};
use rustortion_core::audio::engine::{Engine, EngineHandle, PreparedIr};
use rustortion_core::ir::convolver::Convolver;
use rustortion_core::ir::loader::IrLoader;
use rustortion_core::preset::{InputFilterConfig, StageConfig};

static PREWARM_CLIPPER_TABLES: Once = Once::new();
const DEFAULT_BUFFER_FRAMES: usize = 512;
const MAX_IR_MS: f32 = 35.0;
const PRESET_CROSSFADE_MS: f32 = 40.0;
const DEFAULT_OVERSAMPLE_FACTOR: f64 = 1.0;
const METER_FLOOR_DB: f32 = -70.0;
const INPUT_TRIM_SMOOTHING: f32 = 0.22;

struct SharedRuntimeState {
    current: ArcSwap<RuntimeConfig>,
    generation: AtomicU64,
    input_trim_db_bits: AtomicU32,
    pending_param_updates: Mutex<Vec<PendingParamUpdate>>,
    input_peak_linear_bits: AtomicU32,
    output_peak_linear_bits: AtomicU32,
}

#[derive(Clone, Copy)]
struct PendingParamUpdate {
    stage_idx: usize,
    name: &'static str,
    value: f32,
}

impl SharedRuntimeState {
    fn new() -> Self {
        Self {
            current: ArcSwap::from_pointee(RuntimeConfig::default()),
            generation: AtomicU64::new(1),
            input_trim_db_bits: AtomicU32::new(0.0f32.to_bits()),
            pending_param_updates: Mutex::new(Vec::new()),
            input_peak_linear_bits: AtomicU32::new(0.0f32.to_bits()),
            output_peak_linear_bits: AtomicU32::new(0.0f32.to_bits()),
        }
    }

    fn load(&self) -> Arc<RuntimeConfig> {
        self.current.load_full()
    }

    fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }

    fn store(&self, config: RuntimeConfig) {
        self.current.store(Arc::new(config));
        self.generation.fetch_add(1, Ordering::AcqRel);
    }

    fn set_input_trim_db(&self, input_trim_db: f32) {
        let value = if input_trim_db.is_finite() { input_trim_db } else { 0.0 };
        self.input_trim_db_bits.store(value.to_bits(), Ordering::Relaxed);
    }

    fn input_trim_db(&self) -> f32 {
        f32::from_bits(self.input_trim_db_bits.load(Ordering::Relaxed))
    }

    fn enqueue_param_update(&self, update: PendingParamUpdate) {
        if let Ok(mut queue) = self.pending_param_updates.lock() {
            queue.push(update);
        }
    }

    fn take_param_updates(&self) -> Vec<PendingParamUpdate> {
        if let Ok(mut queue) = self.pending_param_updates.lock() {
            return queue.drain(..).collect();
        }
        Vec::new()
    }

    fn update_input_peak_linear(&self, peak_linear: f32) {
        update_peak_linear_max(&self.input_peak_linear_bits, peak_linear);
    }

    fn update_output_peak_linear(&self, peak_linear: f32) {
        update_peak_linear_max(&self.output_peak_linear_bits, peak_linear);
    }

    fn take_input_peak_linear(&self) -> f32 {
        f32::from_bits(self.input_peak_linear_bits.swap(0.0f32.to_bits(), Ordering::Relaxed))
    }

    fn take_output_peak_linear(&self) -> f32 {
        f32::from_bits(self.output_peak_linear_bits.swap(0.0f32.to_bits(), Ordering::Relaxed))
    }
}

fn update_peak_linear_max(peak_bits: &AtomicU32, candidate_peak: f32) {
    if !candidate_peak.is_finite() {
        return;
    }

    let candidate = candidate_peak.max(0.0);
    loop {
        let current_bits = peak_bits.load(Ordering::Relaxed);
        let current = f32::from_bits(current_bits);
        if candidate <= current {
            break;
        }

        if peak_bits
            .compare_exchange_weak(current_bits, candidate.to_bits(), Ordering::Relaxed, Ordering::Relaxed)
            .is_ok()
        {
            break;
        }
    }
}

fn linear_peak_to_db(peak_linear: f32) -> f32 {
    if peak_linear > 1e-10 {
        (20.0 * peak_linear.log10()).max(METER_FLOOR_DB)
    } else {
        METER_FLOOR_DB
    }
}

fn db_to_linear(gain_db: f32) -> f32 {
    10.0f32.powf(gain_db / 20.0)
}

#[derive(Clone, Default)]
struct RuntimeConfig {
    stages: Vec<StageConfig>,
    input_filters: InputFilterConfig,
    ir: Option<IrPayload>,
}

impl RuntimeConfig {
    fn stages(&self) -> &[StageConfig] {
        &self.stages
    }
}

#[derive(Clone)]
struct IrPayload {
    name: String,
    gain: f32,
    bytes: Arc<Vec<u8>>,
}

struct ChannelRuntime {
    engine: Engine,
    handle: EngineHandle,
    _rt_drop_rx: rustortion_core::audio::rt_drop::RtDropReceiver,
    sample_rate: f32,
}

impl ChannelRuntime {
    fn new(sample_rate: f32, buffer_frames: usize) -> Result<Self> {
        let (engine, handle, rt_drop_rx) =
            Engine::new_for_plugin(sample_rate as usize, buffer_frames, None, DEFAULT_OVERSAMPLE_FACTOR)?;

        Ok(Self {
            engine,
            handle,
            _rt_drop_rx: rt_drop_rx,
            sample_rate,
        })
    }

    fn ensure_buffer_size(&mut self, frame_count: usize) {
        if let Err(err) = self.engine.update_buffer_size(frame_count) {
            godot_error!("AudioEffectRustortion buffer resize failed: {err}");
        }
    }

    fn apply_config(&self, config: &RuntimeConfig) {
        let effective_sample_rate = self.sample_rate * DEFAULT_OVERSAMPLE_FACTOR as f32;
        let mut chain = AmplifierChain::new();
        let stages = config.stages();

        for stage in stages {
            chain.add_stage(stage.to_runtime(effective_sample_rate));
        }

        for (index, stage) in stages.iter().enumerate() {
            if stage.bypassed() {
                chain.set_bypassed(index, true);
            }
        }

        self.handle.set_amp_chain(chain);
        let filters = config.input_filters;
        self.handle.set_input_filters(
            make_filter_stage(filters.hp_enabled, FilterType::Highpass, filters.hp_cutoff, self.sample_rate),
            make_filter_stage(filters.lp_enabled, FilterType::Lowpass, filters.lp_cutoff, self.sample_rate),
        );

        if let Some(ir) = &config.ir {
            self.handle.set_ir_gain(ir.gain);

            if let Some(prepared_ir) = build_prepared_ir(ir, self.sample_rate) {
                self.handle.swap_ir_convolver(prepared_ir);
                self.handle.set_ir_bypass(false);
            } else {
                self.handle.clear_ir();
            }
        } else {
            self.handle.clear_ir();
        }
    }
}

fn make_filter_stage(
    enabled: bool,
    filter_type: FilterType,
    cutoff: f32,
    sample_rate: f32,
) -> Option<Box<dyn Stage>> {
    enabled.then(|| Box::new(FilterStage::new(filter_type, cutoff, sample_rate)) as Box<dyn Stage>)
}

fn build_prepared_ir(ir: &IrPayload, sample_rate: f32) -> Option<PreparedIr> {
    let samples = match decode_ir_samples(ir.bytes.as_slice(), sample_rate) {
        Ok(samples) => samples,
        Err(err) => {
            godot_error!(
                "AudioEffectRustortion failed to decode IR '{}' for {:.0} Hz: {err}",
                ir.name,
                sample_rate
            );
            return None;
        }
    };

    let max_ir_len = ((sample_rate * MAX_IR_MS) / 1000.0).max(1.0) as usize;
    let truncated_len = samples.len().min(max_ir_len);
    let mut convolver = Convolver::new_fir(truncated_len);

    if let Err(err) = convolver.set_ir(&samples[..truncated_len]) {
        godot_error!("AudioEffectRustortion failed to set IR '{}': {err}", ir.name);
        return None;
    }

    Some(PreparedIr {
        name: ir.name.clone(),
        convolver,
    })
}

#[derive(GodotClass)]
#[class(tool, init, base = AudioEffect)]
pub struct AudioEffectRustortion {
    #[init(val = Arc::new(SharedRuntimeState::new()))]
    shared: Arc<SharedRuntimeState>,
    #[init(val = String::new())]
    last_error: String,
    base: Base<AudioEffect>,
}

#[godot_api]
impl IAudioEffect for AudioEffectRustortion {
    fn instantiate(&mut self) -> Option<Gd<AudioEffectInstance>> {
        PREWARM_CLIPPER_TABLES.call_once(clipper::init);

        let shared = Arc::clone(&self.shared);
        let instance: Gd<AudioEffectRustortionInstance> = Gd::from_init_fn(move |base| {
            AudioEffectRustortionInstance::new(base, shared)
        });
        Some(instance.upcast())
    }
}

#[godot_api]
impl AudioEffectRustortion {
    #[func]
    fn get_last_error(&self) -> GString {
        self.last_error.as_str().into()
    }

    #[func]
    fn get_input_peak_db(&self) -> f32 {
        linear_peak_to_db(self.shared.take_input_peak_linear())
    }

    #[func]
    fn get_output_peak_db(&self) -> f32 {
        linear_peak_to_db(self.shared.take_output_peak_linear())
    }

    #[func]
    fn set_input_trim_db(&mut self, input_trim_db: f32) -> bool {
        self.shared.set_input_trim_db(input_trim_db);
        self.last_error.clear();
        true
    }

    #[func]
    fn get_input_trim_db(&self) -> f32 {
        self.shared.input_trim_db()
    }

    #[func]
    fn set_amp_chain(&mut self, stages_json: GString, input_filters_json: GString) -> bool {
        self.apply_update(|config| {
            config.stages = parse_stages_json(&stages_json.to_string())?;
            config.input_filters = parse_input_filters_json(&input_filters_json.to_string())?;
            Ok(())
        })
    }

    #[func]
    fn set_ir_data(&mut self, ir_name: GString, ir_bytes: PackedByteArray, ir_gain: f32) -> bool {
        self.apply_update(|config| {
            let payload = decode_ir_payload(ir_name.to_string(), ir_bytes.as_slice(), ir_gain)?;
            config.ir = Some(payload);
            Ok(())
        })
    }

    #[func]
    fn set_stage_parameter(&mut self, stage_idx: i32, name: GString, value: f32) -> bool {
        let idx = match usize::try_from(stage_idx) {
            Ok(idx) => idx,
            Err(_) => {
                self.last_error = "stage index must be >= 0".to_string();
                return false;
            }
        };

        let config = self.shared.load();
        let Some(stage) = config.stages.get(idx) else {
            self.last_error = format!("stage index {idx} out of range");
            return false;
        };

        let stage_name = name.to_string();
        let (mapped_name, mapped_value) = match validate_stage_parameter(stage, &stage_name, value) {
            Ok(mapped) => mapped,
            Err(err) => {
                self.last_error = err.to_string();
                return false;
            }
        };

        self.shared.enqueue_param_update(PendingParamUpdate {
            stage_idx: idx,
            name: mapped_name,
            value: mapped_value,
        });
        self.last_error.clear();
        true
    }

    #[func]
    fn add_stage(&mut self, parent_stage_idx: i32, stage_json: GString, insert_after: bool) -> bool {
        self.apply_update(|config| {
            let stage = parse_stage_json(&stage_json.to_string())?;
            if parent_stage_idx == -1 {
                config.stages.push(stage);
                return Ok(());
            }

            let parent_idx = usize::try_from(parent_stage_idx).context("parent_stage_idx must be >= -1")?;
            if parent_idx >= config.stages.len() {
                bail!("parent stage index {parent_idx} out of range");
            }

            let insert_idx = if insert_after { parent_idx + 1 } else { parent_idx };
            config.stages.insert(insert_idx, stage);
            Ok(())
        })
    }

    #[func]
    fn remove_stage(&mut self, stage_idx: i32) -> bool {
        self.apply_update(|config| {
            let idx = usize::try_from(stage_idx).context("stage index must be >= 0")?;
            if idx >= config.stages.len() {
                bail!("stage index {idx} out of range");
            }
            config.stages.remove(idx);
            Ok(())
        })
    }

    #[func]
    fn swap_stages(&mut self, stage_a: i32, stage_b: i32) -> bool {
        self.apply_update(|config| {
            let a = usize::try_from(stage_a).context("stage_a must be >= 0")?;
            let b = usize::try_from(stage_b).context("stage_b must be >= 0")?;
            if a >= config.stages.len() || b >= config.stages.len() {
                bail!("swap indexes out of range: {a}, {b}");
            }
            config.stages.swap(a, b);
            Ok(())
        })
    }

    #[func]
    fn rebuild_stage(&mut self, stage_idx: i32, stage_json: GString) -> bool {
        self.apply_update(|config| {
            let idx = usize::try_from(stage_idx).context("stage index must be >= 0")?;
            if idx >= config.stages.len() {
                bail!("stage index {idx} out of range");
            }
            config.stages[idx] = parse_stage_json(&stage_json.to_string())?;
            Ok(())
        })
    }

    #[func]
    fn clear_data(&mut self) -> bool {
        self.apply_update(|config| {
            config.stages.clear();
            config.input_filters = InputFilterConfig::default();
            config.ir = None;
            Ok(())
        })
    }
}

impl AudioEffectRustortion {
    fn apply_update<F>(&mut self, update: F) -> bool
    where
        F: FnOnce(&mut RuntimeConfig) -> Result<()>,
    {
        let mut config = (*self.shared.load()).clone();

        match update(&mut config) {
            Ok(()) => {
                self.last_error.clear();
                self.shared.store(config);
                self.base_mut().emit_changed();
                true
            }
            Err(err) => {
                self.last_error = err.to_string();
                godot_error!("AudioEffectRustortion update failed: {}", self.last_error);
                false
            }
        }
    }
}

fn parse_stages_json(json: &str) -> Result<Vec<StageConfig>> {
    let stages: Vec<StageConfig> = serde_json::from_str(json).context("failed to parse stages JSON")?;
    Ok(stages)
}

fn parse_stage_json(json: &str) -> Result<StageConfig> {
    let stage: StageConfig = serde_json::from_str(json).context("failed to parse stage JSON")?;
    Ok(stage)
}

fn parse_input_filters_json(json: &str) -> Result<InputFilterConfig> {
    let filters: InputFilterConfig =
        serde_json::from_str(json).context("failed to parse input filters JSON")?;
    Ok(filters)
}

fn validate_stage_parameter(stage: &StageConfig, name: &str, value: f32) -> Result<(&'static str, f32)> {
    if !value.is_finite() {
        bail!("parameter value must be finite");
    }

    match stage {
        StageConfig::ToneStack(_) => match name {
            "bass" => Ok(("bass", value.clamp(0.0, 2.0))),
            "mid" => Ok(("mid", value.clamp(0.0, 2.0))),
            "treble" => Ok(("treble", value.clamp(0.0, 2.0))),
            "presence" => Ok(("presence", value.clamp(0.0, 2.0))),
            _ => bail!("unsupported ToneStack parameter '{name}'"),
        },
        StageConfig::Level(_) => match name {
            "gain" => Ok(("gain", value.clamp(0.0, 2.0))),
            _ => bail!("unsupported Level parameter '{name}'"),
        },
        _ => bail!("set_stage_parameter is only supported for ToneStack and Level stages"),
    }
}

#[derive(GodotClass)]
#[class(tool, no_init, base = AudioEffectInstance)]
pub struct AudioEffectRustortionInstance {
    base: Base<AudioEffectInstance>,
    shared: Arc<SharedRuntimeState>,
    applied_generation: u64,
    sample_rate: f32,
    left: Option<ChannelRuntime>,
    right: Option<ChannelRuntime>,
    prev_left: Option<ChannelRuntime>,
    prev_right: Option<ChannelRuntime>,
    in_left: Vec<f32>,
    in_right: Vec<f32>,
    out_left: Vec<f32>,
    out_right: Vec<f32>,
    prev_out_left: Vec<f32>,
    prev_out_right: Vec<f32>,
    crossfade_total_frames: usize,
    crossfade_remaining_frames: usize,
    input_trim_linear: f32,
}

impl AudioEffectRustortionInstance {
    fn new(base: Base<AudioEffectInstance>, shared: Arc<SharedRuntimeState>) -> Self {
        Self {
            base,
            shared,
            applied_generation: 0,
            sample_rate: 0.0,
            left: None,
            right: None,
            prev_left: None,
            prev_right: None,
            in_left: Vec::new(),
            in_right: Vec::new(),
            out_left: Vec::new(),
            out_right: Vec::new(),
            prev_out_left: Vec::new(),
            prev_out_right: Vec::new(),
            crossfade_total_frames: 0,
            crossfade_remaining_frames: 0,
            input_trim_linear: 1.0,
        }
    }

    fn ensure_runtime(&mut self, frame_count: usize) -> Result<()> {
        let mix_rate = AudioServer::singleton().get_mix_rate();
        if self.left.is_none() || self.right.is_none() || (self.sample_rate - mix_rate).abs() > f32::EPSILON {
            self.sample_rate = mix_rate;
            self.left = Some(ChannelRuntime::new(mix_rate, frame_count.max(DEFAULT_BUFFER_FRAMES))?);
            self.right = Some(ChannelRuntime::new(mix_rate, frame_count.max(DEFAULT_BUFFER_FRAMES))?);
            self.prev_left = None;
            self.prev_right = None;
            self.crossfade_total_frames = 0;
            self.crossfade_remaining_frames = 0;
            self.applied_generation = 0;
        }

        if let Some(left) = &mut self.left {
            left.ensure_buffer_size(frame_count);
        }
        if let Some(right) = &mut self.right {
            right.ensure_buffer_size(frame_count);
        }

        self.ensure_scratch_buffers(frame_count);
        self.apply_pending_updates(frame_count)?;
        Ok(())
    }

    fn ensure_scratch_buffers(&mut self, frame_count: usize) {
        self.in_left.resize(frame_count, 0.0);
        self.in_right.resize(frame_count, 0.0);
        self.out_left.resize(frame_count, 0.0);
        self.out_right.resize(frame_count, 0.0);
        self.prev_out_left.resize(frame_count, 0.0);
        self.prev_out_right.resize(frame_count, 0.0);
    }

    fn apply_pending_updates(&mut self, frame_count: usize) -> Result<()> {
        let generation = self.shared.generation();
        if generation == self.applied_generation {
            return Ok(());
        }

        let config = self.shared.load();

        let mut next_left = ChannelRuntime::new(self.sample_rate, frame_count.max(DEFAULT_BUFFER_FRAMES))?;
        let mut next_right = ChannelRuntime::new(self.sample_rate, frame_count.max(DEFAULT_BUFFER_FRAMES))?;
        next_left.ensure_buffer_size(frame_count);
        next_right.ensure_buffer_size(frame_count);
        next_left.apply_config(&config);
        next_right.apply_config(&config);

        self.prev_left = self.left.take();
        self.prev_right = self.right.take();
        self.left = Some(next_left);
        self.right = Some(next_right);

        if self.prev_left.is_some() && self.prev_right.is_some() {
            let fade_frames = ((self.sample_rate * PRESET_CROSSFADE_MS) / 1000.0).round() as usize;
            self.crossfade_total_frames = fade_frames.max(1);
            self.crossfade_remaining_frames = self.crossfade_total_frames;
        } else {
            self.crossfade_total_frames = 0;
            self.crossfade_remaining_frames = 0;
        }

        self.applied_generation = generation;
        Ok(())
    }

    fn smooth_value(current: f32, target: f32) -> f32 {
        current + (target - current) * INPUT_TRIM_SMOOTHING
    }

    fn apply_input_trim(&mut self) {
        let target_input_trim_linear = db_to_linear(self.shared.input_trim_db());
        self.input_trim_linear = Self::smooth_value(self.input_trim_linear, target_input_trim_linear);
    }

    fn apply_pending_param_updates(&mut self) {
        let updates = self.shared.take_param_updates();
        if updates.is_empty() {
            return;
        }

        for update in updates {
            if let Some(left) = &self.left {
                left.handle.set_parameter(update.stage_idx, update.name, update.value);
            }
            if let Some(right) = &self.right {
                right.handle.set_parameter(update.stage_idx, update.name, update.value);
            }
        }
    }

    fn process_frames(&mut self, src: &[AudioFrame], dst: &mut [AudioFrame]) -> Result<()> {
        self.ensure_runtime(src.len())?;
        self.apply_pending_param_updates();
        self.apply_input_trim();

        let mut input_peak_linear = 0.0f32;

        for (index, frame) in src.iter().enumerate() {
            let trimmed_left = frame.left * self.input_trim_linear;
            let trimmed_right = frame.right * self.input_trim_linear;
            self.in_left[index] = trimmed_left;
            self.in_right[index] = trimmed_right;
            let frame_peak = trimmed_left.abs().max(trimmed_right.abs());
            if frame_peak > input_peak_linear {
                input_peak_linear = frame_peak;
            }
        }

        let left = self.left.as_mut().context("left runtime missing")?;
        let right = self.right.as_mut().context("right runtime missing")?;

        left.engine.process(&self.in_left, &mut self.out_left)?;
        right.engine.process(&self.in_right, &mut self.out_right)?;

        if self.crossfade_remaining_frames > 0 {
            let prev_left = self.prev_left.as_mut().context("previous left runtime missing")?;
            let prev_right = self.prev_right.as_mut().context("previous right runtime missing")?;

            prev_left.engine.process(&self.in_left, &mut self.prev_out_left)?;
            prev_right.engine.process(&self.in_right, &mut self.prev_out_right)?;
        }

        let mut output_peak_linear = 0.0f32;
        for (index, frame) in dst.iter_mut().enumerate() {
	            if self.crossfade_remaining_frames > 0 {
	                let old_weight = self.crossfade_remaining_frames as f32 / self.crossfade_total_frames as f32;
	                let new_weight = 1.0 - old_weight;
	                frame.left = self.prev_out_left[index] * old_weight + self.out_left[index] * new_weight;
                frame.right = self.prev_out_right[index] * old_weight + self.out_right[index] * new_weight;
                self.crossfade_remaining_frames -= 1;
            } else {
                frame.left = self.out_left[index];
                frame.right = self.out_right[index];
            }

            let frame_peak = frame.left.abs().max(frame.right.abs());
            if frame_peak > output_peak_linear {
                output_peak_linear = frame_peak;
            }
        }

	        if self.crossfade_remaining_frames == 0 {
	            self.prev_left = None;
	            self.prev_right = None;
	        }

        self.shared.update_input_peak_linear(input_peak_linear);
        self.shared.update_output_peak_linear(output_peak_linear);

        Ok(())
    }
}

#[godot_api]
impl IAudioEffectInstance for AudioEffectRustortionInstance {
    unsafe fn process_rawptr(
        &mut self,
        src_buffer: RawPtr<*const c_void>,
        dst_buffer: RawPtr<*mut AudioFrame>,
        frame_count: i32,
    ) {
        if frame_count <= 0 {
            return;
        }

        let frame_count = frame_count as usize;
        let src_ptr = src_buffer.ptr() as *const AudioFrame;
        let dst_ptr = dst_buffer.ptr();

        if src_ptr.is_null() || dst_ptr.is_null() {
            return;
        }

        let src = unsafe { slice::from_raw_parts(src_ptr, frame_count) };
        let dst = unsafe { slice::from_raw_parts_mut(dst_ptr, frame_count) };

        if let Err(err) = self.process_frames(src, dst) {
            godot_error!("AudioEffectRustortion process failed: {err}");
            dst.clone_from_slice(src);
        }
    }

    fn process_silence(&self) -> bool {
        true
    }
}

fn decode_ir_samples(bytes: &[u8], sample_rate: f32) -> Result<Vec<f32>> {
    let target_sample_rate = sample_rate.round().max(1.0) as usize;
    let loader = IrLoader::new(std::path::Path::new("."), target_sample_rate)?;
    Ok(loader.load_ir_from_bytes(bytes)?)
}

fn decode_ir_payload(name: String, bytes: &[u8], ir_gain: f32) -> Result<IrPayload> {
    let mix_rate = AudioServer::singleton().get_mix_rate();
    let _ = decode_ir_samples(bytes, mix_rate)?;

    Ok(IrPayload {
        name,
        gain: ir_gain,
        bytes: Arc::new(bytes.to_vec()),
    })
}
