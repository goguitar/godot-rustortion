use std::ffi::c_void;
use std::slice;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};

use godot::classes::native::AudioFrame;
use godot::classes::{AudioEffect, AudioEffectInstance, AudioServer, IAudioEffect, IAudioEffectInstance};
use godot::meta::conv::RawPtr;
use godot::prelude::*;

const DEFAULT_THRESHOLD_DB: f32 = -50.0;
const DEFAULT_ATTACK_MS: f32 = 5.0;
const DEFAULT_HOLD_MS: f32 = 100.0;
const DEFAULT_RELEASE_MS: f32 = 50.0;
const MIN_THRESHOLD_DB: f32 = -100.0;
const MAX_THRESHOLD_DB: f32 = 0.0;
const MIN_TIME_MS: f32 = 1.0;
const MAX_TIME_MS: f32 = 2000.0;
const LINEAR_DB_FLOOR: f32 = -80.0;

fn linear_to_db(linear: f32) -> f32 {
    if linear <= 0.0 {
        LINEAR_DB_FLOOR
    } else {
        20.0 * linear.log10()
    }
}

fn db_to_linear(db: f32) -> f32 {
    10.0f32.powf(db / 20.0)
}

struct GateParams {
    threshold_db_bits: AtomicU32,
    attack_ms_bits: AtomicU32,
    hold_ms_bits: AtomicU32,
    release_ms_bits: AtomicU32,
}

impl GateParams {
    fn new() -> Self {
        Self {
            threshold_db_bits: AtomicU32::new(DEFAULT_THRESHOLD_DB.to_bits()),
            attack_ms_bits: AtomicU32::new(DEFAULT_ATTACK_MS.to_bits()),
            hold_ms_bits: AtomicU32::new(DEFAULT_HOLD_MS.to_bits()),
            release_ms_bits: AtomicU32::new(DEFAULT_RELEASE_MS.to_bits()),
        }
    }

    fn threshold_db(&self) -> f32 {
        f32::from_bits(self.threshold_db_bits.load(Ordering::Relaxed))
    }

    fn attack_ms(&self) -> f32 {
        f32::from_bits(self.attack_ms_bits.load(Ordering::Relaxed))
    }

    fn hold_ms(&self) -> f32 {
        f32::from_bits(self.hold_ms_bits.load(Ordering::Relaxed))
    }

    fn release_ms(&self) -> f32 {
        f32::from_bits(self.release_ms_bits.load(Ordering::Relaxed))
    }

    fn set_threshold_db(&self, threshold_db: f32) -> f32 {
        let value = sanitize_threshold_db(threshold_db);
        self.threshold_db_bits.store(value.to_bits(), Ordering::Relaxed);
        value
    }

    fn set_attack_ms(&self, attack_ms: f32) -> f32 {
        let value = sanitize_time_ms(attack_ms, DEFAULT_ATTACK_MS);
        self.attack_ms_bits.store(value.to_bits(), Ordering::Relaxed);
        value
    }

    fn set_hold_ms(&self, hold_ms: f32) -> f32 {
        let value = sanitize_time_ms(hold_ms, DEFAULT_HOLD_MS);
        self.hold_ms_bits.store(value.to_bits(), Ordering::Relaxed);
        value
    }

    fn set_release_ms(&self, release_ms: f32) -> f32 {
        let value = sanitize_time_ms(release_ms, DEFAULT_RELEASE_MS);
        self.release_ms_bits.store(value.to_bits(), Ordering::Relaxed);
        value
    }
}

fn sanitize_threshold_db(threshold_db: f32) -> f32 {
    if threshold_db.is_finite() {
        threshold_db.clamp(MIN_THRESHOLD_DB, MAX_THRESHOLD_DB)
    } else {
        DEFAULT_THRESHOLD_DB
    }
}

fn sanitize_time_ms(time_ms: f32, default_ms: f32) -> f32 {
    if time_ms.is_finite() {
        time_ms.clamp(MIN_TIME_MS, MAX_TIME_MS)
    } else {
        default_ms
    }
}

#[derive(GodotClass)]
#[class(tool, init, base = AudioEffect)]
pub struct AudioEffectGate {
    #[init(val = Arc::new(GateParams::new()))]
    shared: Arc<GateParams>,
    #[var(
        get = "get_threshold_db",
        set = "set_threshold_db",
        default = -50.0,
        hint = "range",
        hint_string = "-100,0,0.01,suffix:dB"
    )]
    threshold_db: f32,
    #[var(
        get = "get_attack_ms",
        set = "set_attack_ms",
        default = 5.0,
        hint = "range",
        hint_string = "1,2000,1,suffix:ms"
    )]
    attack_ms: f32,
    #[var(
        get = "get_hold_ms",
        set = "set_hold_ms",
        default = 100.0,
        hint = "range",
        hint_string = "1,2000,1,suffix:ms"
    )]
    hold_ms: f32,
    #[var(
        get = "get_release_ms",
        set = "set_release_ms",
        default = 50.0,
        hint = "range",
        hint_string = "1,2000,1,suffix:ms"
    )]
    release_ms: f32,
    base: Base<AudioEffect>,
}

#[godot_api]
impl IAudioEffect for AudioEffectGate {
    fn instantiate(&mut self) -> Option<Gd<AudioEffectInstance>> {
        self.sync_shared();

        let shared = Arc::clone(&self.shared);
        let instance: Gd<AudioEffectGateInstance> = Gd::from_init_fn(move |base| {
            AudioEffectGateInstance::new(base, shared)
        });
        Some(instance.upcast())
    }
}

#[godot_api]
impl AudioEffectGate {
    #[func]
    fn set_threshold_db(&mut self, threshold_db: f32) {
        let value = self.shared.set_threshold_db(threshold_db);
        self.threshold_db = value;
        self.base_mut().emit_changed();
    }

    #[func]
    fn get_threshold_db(&self) -> f32 {
        self.shared.threshold_db()
    }

    #[func]
    fn set_attack_ms(&mut self, attack_ms: f32) {
        let value = self.shared.set_attack_ms(attack_ms);
        self.attack_ms = value;
        self.base_mut().emit_changed();
    }

    #[func]
    fn get_attack_ms(&self) -> f32 {
        self.shared.attack_ms()
    }

    #[func]
    fn set_hold_ms(&mut self, hold_ms: f32) {
        let value = self.shared.set_hold_ms(hold_ms);
        self.hold_ms = value;
        self.base_mut().emit_changed();
    }

    #[func]
    fn get_hold_ms(&self) -> f32 {
        self.shared.hold_ms()
    }

    #[func]
    fn set_release_ms(&mut self, release_ms: f32) {
        let value = self.shared.set_release_ms(release_ms);
        self.release_ms = value;
        self.base_mut().emit_changed();
    }

    #[func]
    fn get_release_ms(&self) -> f32 {
        self.shared.release_ms()
    }
}

impl AudioEffectGate {
    fn sync_shared(&self) {
        self.shared.set_threshold_db(self.threshold_db);
        self.shared.set_attack_ms(self.attack_ms);
        self.shared.set_hold_ms(self.hold_ms);
        self.shared.set_release_ms(self.release_ms);
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum GateState {
    Closed,
    Attack,
    Open,
    Hold,
    Release,
}

#[derive(GodotClass)]
#[class(tool, no_init, base = AudioEffectInstance)]
pub struct AudioEffectGateInstance {
    base: Base<AudioEffectInstance>,
    shared: Arc<GateParams>,
    gate_state: GateState,
    last_envelope_value: f32,
    samples_since_below_threshold: u32,
    below_threshold: bool,
}

impl AudioEffectGateInstance {
    fn new(base: Base<AudioEffectInstance>, shared: Arc<GateParams>) -> Self {
        Self {
            base,
            shared,
            gate_state: GateState::Closed,
            last_envelope_value: 0.0,
            samples_since_below_threshold: 0,
            below_threshold: true,
        }
    }

    fn process_frames(&mut self, src: &[AudioFrame], dst: &mut [AudioFrame]) {
        if src.is_empty() {
            return;
        }

        let sample_rate = AudioServer::singleton().get_mix_rate().max(1.0);
        let mut signal_total_l_sqr = 0.0f32;
        let mut signal_total_r_sqr = 0.0f32;

        for frame in src {
            signal_total_l_sqr += frame.left * frame.left;
            signal_total_r_sqr += frame.right * frame.right;
        }

        let frame_count = src.len() as f32;
        let rms_l = (signal_total_l_sqr / frame_count).sqrt();
        let rms_r = (signal_total_r_sqr / frame_count).sqrt();
        let rms = rms_l.max(rms_r);
        let db_rms = linear_to_db(rms);

        let threshold_db = self.shared.threshold_db();
        let threshold_linear = db_to_linear(threshold_db);
        let now_below_threshold = db_rms < threshold_db && rms < threshold_linear;

        if now_below_threshold && !self.below_threshold {
            if self.gate_state == GateState::Attack {
                self.gate_state = GateState::Release;
            } else {
                self.gate_state = GateState::Hold;
                self.samples_since_below_threshold = 0;
            }
        } else if !now_below_threshold && self.below_threshold {
            if self.gate_state == GateState::Hold {
                self.gate_state = GateState::Open;
                self.samples_since_below_threshold = 0;
            } else {
                self.gate_state = GateState::Attack;
            }
        }

        for (index, frame) in src.iter().enumerate() {
            let envelope = self.next_envelope_value(sample_rate);
            dst[index].left = frame.left * envelope;
            dst[index].right = frame.right * envelope;
        }

        self.below_threshold = now_below_threshold;
    }

    fn next_envelope_value(&mut self, sample_rate: f32) -> f32 {
        let attack_ms = self.shared.attack_ms().max(MIN_TIME_MS);
        let hold_ms = self.shared.hold_ms().max(MIN_TIME_MS);
        let release_ms = self.shared.release_ms().max(MIN_TIME_MS);
        let sample_rate = sample_rate.max(1.0);

        let mut next_env_value = match self.gate_state {
            GateState::Closed => 0.0,
            GateState::Attack => {
                self.last_envelope_value + (1000.0 / sample_rate / attack_ms)
            }
            GateState::Open => 1.0,
            GateState::Hold => {
                self.samples_since_below_threshold = self.samples_since_below_threshold.saturating_add(1);
                if self.samples_since_below_threshold == u32::MAX {
                    self.gate_state = GateState::Release;
                    self.samples_since_below_threshold = 0;
                }
                1.0
            }
            GateState::Release => {
                self.last_envelope_value - (1000.0 / sample_rate / release_ms)
            }
        };

        if self.gate_state == GateState::Attack && next_env_value >= 1.0 {
            self.gate_state = GateState::Open;
            next_env_value = 1.0;
        } else if self.gate_state == GateState::Hold
            && (1000.0 * self.samples_since_below_threshold as f32) / sample_rate >= hold_ms
        {
            self.gate_state = GateState::Release;
            self.samples_since_below_threshold = 0;
        } else if self.gate_state == GateState::Release && next_env_value <= 0.0 {
            self.gate_state = GateState::Closed;
            next_env_value = 0.0;
        }

        self.last_envelope_value = next_env_value;
        next_env_value
    }
}

#[godot_api]
impl IAudioEffectInstance for AudioEffectGateInstance {
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
        self.process_frames(src, dst);
    }

    fn process_silence(&self) -> bool {
        true
    }
}
