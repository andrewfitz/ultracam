use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

pub type MediaTime = f64;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AudioCue {
    pub id: u64,
    pub time: MediaTime,
    #[serde(default = "default_audio_duration")]
    pub duration: f64,
    pub speech_energy: f32,
    #[serde(default)]
    pub pause_duration: f64,
    #[serde(default)]
    pub emphasis: f32,
    #[serde(default)]
    pub laughter: f32,
    #[serde(default)]
    pub speech_start: bool,
    #[serde(default)]
    pub speech_stop: bool,
    #[serde(default)]
    pub session_generation: u64,
}

fn default_audio_duration() -> f64 {
    0.02
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CueKind {
    PhraseEnd,
    SentenceEnd,
    Question,
    Transition,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TranscriptCue {
    pub segment_id: String,
    pub revision: u32,
    pub start: MediaTime,
    pub end: MediaTime,
    pub kind: CueKind,
    pub confidence: f32,
    pub is_final: bool,
    #[serde(default)]
    pub session_generation: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VideoObservation {
    pub time: MediaTime,
    pub camera_id: String,
    #[serde(default = "default_true")]
    pub healthy: bool,
    #[serde(default)]
    pub motion: f32,
    #[serde(default)]
    pub scene_change: f32,
    #[serde(default)]
    pub session_generation: u64,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum StreamEvent {
    /// Ledger-only output observation. Replaying it never drives the director.
    DirectorOutput,
    Audio {
        cue: AudioCue,
    },
    Transcript {
        cue: TranscriptCue,
    },
    Video {
        observation: VideoObservation,
    },
    Tick {
        time: MediaTime,
    },
    Acknowledge {
        decision_id: Uuid,
        applied_at: Option<MediaTime>,
    },
    Reject {
        decision_id: Uuid,
    },
    ManualOverride {
        camera_id: String,
        time: MediaTime,
    },
    Reset {
        generation: Option<u64>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SwitcherConfig {
    pub anchor_camera_id: String,
    pub emphasis_camera_id: String,
    #[serde(default = "default_minimum_shot")]
    pub minimum_shot_duration: f64,
    #[serde(default = "default_cooldown")]
    pub cooldown: f64,
    #[serde(default = "default_emphasis_hold")]
    pub emphasis_hold: f64,
    #[serde(default = "default_soft_maximum")]
    pub soft_maximum_shot_duration: f64,
    #[serde(default = "default_hard_maximum")]
    pub maximum_shot_duration: f64,
    #[serde(default = "default_forced_grace")]
    pub forced_cut_grace_period: f64,
    #[serde(default = "default_forced_lookback")]
    pub forced_boundary_lookback: f64,
    #[serde(default = "default_boundary_window")]
    pub boundary_window: f64,
    #[serde(default = "default_candidate_dwell")]
    pub candidate_dwell: f64,
    #[serde(default = "default_transcript_threshold")]
    pub transcript_confidence_threshold: f32,
    #[serde(default = "default_pause_boundary")]
    pub pause_boundary_duration: f64,
    #[serde(default = "default_cut_threshold")]
    pub cut_threshold: f32,
    #[serde(default = "default_hysteresis")]
    pub hysteresis_margin: f32,
    #[serde(default = "default_transcript_output_delay")]
    pub transcript_output_delay: f64,
    #[serde(default = "default_director_mode")]
    pub mode: String,
    #[serde(default)]
    pub manual_hold: bool,
    #[serde(default)]
    pub session_generation: u64,
}

impl Default for SwitcherConfig {
    fn default() -> Self {
        Self {
            anchor_camera_id: "A".to_string(),
            emphasis_camera_id: "B".to_string(),
            minimum_shot_duration: default_minimum_shot(),
            cooldown: default_cooldown(),
            emphasis_hold: default_emphasis_hold(),
            soft_maximum_shot_duration: default_soft_maximum(),
            maximum_shot_duration: default_hard_maximum(),
            forced_cut_grace_period: default_forced_grace(),
            forced_boundary_lookback: default_forced_lookback(),
            boundary_window: default_boundary_window(),
            candidate_dwell: default_candidate_dwell(),
            transcript_confidence_threshold: default_transcript_threshold(),
            pause_boundary_duration: default_pause_boundary(),
            cut_threshold: default_cut_threshold(),
            hysteresis_margin: default_hysteresis(),
            transcript_output_delay: default_transcript_output_delay(),
            mode: default_director_mode(),
            manual_hold: false,
            session_generation: 1,
        }
    }
}

impl SwitcherConfig {
    pub fn validate(&self) -> Result<(), String> {
        if self.anchor_camera_id.is_empty() || self.emphasis_camera_id.is_empty() {
            return Err("anchor and emphasis camera IDs are required".to_string());
        }
        if self.anchor_camera_id == self.emphasis_camera_id {
            return Err("anchor and emphasis camera IDs must differ".to_string());
        }
        for (name, value) in [
            ("minimum_shot_duration", self.minimum_shot_duration),
            ("cooldown", self.cooldown),
            ("emphasis_hold", self.emphasis_hold),
            (
                "soft_maximum_shot_duration",
                self.soft_maximum_shot_duration,
            ),
            ("maximum_shot_duration", self.maximum_shot_duration),
            ("forced_cut_grace_period", self.forced_cut_grace_period),
            ("forced_boundary_lookback", self.forced_boundary_lookback),
            ("boundary_window", self.boundary_window),
            ("candidate_dwell", self.candidate_dwell),
            ("pause_boundary_duration", self.pause_boundary_duration),
            ("transcript_output_delay", self.transcript_output_delay),
        ] {
            if !value.is_finite() || value < 0.0 {
                return Err(format!("{name} must be finite and non-negative"));
            }
        }
        if self.maximum_shot_duration <= self.minimum_shot_duration
            || self.maximum_shot_duration <= self.cooldown
        {
            return Err("maximum_shot_duration must exceed minimum shot and cooldown".to_string());
        }
        if self.soft_maximum_shot_duration > self.maximum_shot_duration {
            return Err(
                "soft_maximum_shot_duration must not exceed maximum_shot_duration".to_string(),
            );
        }
        if !matches!(self.mode.as_str(), "lowLatency" | "transcriptAssisted") {
            return Err("mode must be lowLatency or transcriptAssisted".to_string());
        }
        for (name, value) in [
            (
                "transcript_confidence_threshold",
                self.transcript_confidence_threshold,
            ),
            ("cut_threshold", self.cut_threshold),
            ("hysteresis_margin", self.hysteresis_margin),
        ] {
            if !value.is_finite() || !(0.0..=1.0).contains(&value) {
                return Err(format!("{name} must be between 0 and 1"));
            }
        }
        Ok(())
    }
}

fn default_minimum_shot() -> f64 {
    10.0
}
fn default_cooldown() -> f64 {
    1.5
}
fn default_emphasis_hold() -> f64 {
    5.0
}
fn default_soft_maximum() -> f64 {
    20.0
}
fn default_hard_maximum() -> f64 {
    30.0
}
fn default_forced_grace() -> f64 {
    2.0
}
fn default_forced_lookback() -> f64 {
    1.0
}
fn default_boundary_window() -> f64 {
    0.24
}
fn default_candidate_dwell() -> f64 {
    0.30
}
fn default_transcript_threshold() -> f32 {
    0.72
}
fn default_pause_boundary() -> f64 {
    0.22
}
fn default_cut_threshold() -> f32 {
    0.68
}
fn default_hysteresis() -> f32 {
    0.12
}
fn default_transcript_output_delay() -> f64 {
    0.35
}
fn default_director_mode() -> String {
    "transcriptAssisted".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CutReason {
    EmphasisBoundary,
    EmphasisResolved,
    AudioDegradedFallback,
    CameraHealthFallback,
    ForcedMaximumShotDuration,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CutInstruction {
    pub decision_id: Uuid,
    pub session_generation: u64,
    pub target_camera_id: String,
    pub cut_time: MediaTime,
    pub expires_at: MediaTime,
    pub confidence: f32,
    pub reason: CutReason,
    pub forced: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum SwitcherOutput {
    Cut {
        instruction: CutInstruction,
    },
    Status {
        time: MediaTime,
        state: String,
        current_camera_id: String,
        shot_age: f64,
        hard_deadline: f64,
        pending_decision_id: Option<Uuid>,
    },
    LlmAdvisory {
        request_id: Uuid,
        available_at: MediaTime,
        target_camera_id: Option<String>,
        confidence: f32,
        reason: String,
        hold: bool,
        error: Option<String>,
    },
    DecisionExpired {
        decision_id: Uuid,
    },
    Error {
        message: String,
    },
}

pub const SESSION_TIMELINE_SCHEMA_VERSION: u32 = 3;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SessionTimebase {
    pub kind: String,
    pub units: String,
    pub timescale: i32,
    pub epoch: i64,
    pub origin: String,
}

impl Default for SessionTimebase {
    fn default() -> Self {
        Self {
            kind: "media".to_string(),
            units: "seconds".to_string(),
            timescale: 240_000,
            epoch: 0,
            origin: "source_pts".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SessionSource {
    pub camera_id: String,
    pub role: String,
    pub label: Option<String>,
    pub media_file: Option<String>,
    pub media_start: Option<MediaTime>,
    pub media_end: Option<MediaTime>,
    pub timebase: SessionTimebase,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RecordingArtifact {
    pub recording_id: Uuid,
    pub camera_id: String,
    pub path: String,
    pub kind: String,
    pub format: Option<String>,
    pub media_start: Option<MediaTime>,
    pub media_end: Option<MediaTime>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TimelineEvent {
    pub sequence: u64,
    pub media_time: Option<MediaTime>,
    pub media_time_ticks: Option<i64>,
    pub event: StreamEvent,
    pub outputs: Vec<SwitcherOutput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CutRecord {
    pub decision_id: Option<Uuid>,
    pub session_generation: u64,
    pub from_camera_id: Option<String>,
    pub target_camera_id: String,
    pub requested_cut_time: Option<MediaTime>,
    pub requested_cut_time_ticks: Option<i64>,
    pub applied_source_time: Option<MediaTime>,
    pub applied_source_time_ticks: Option<i64>,
    pub applied_program_time: Option<MediaTime>,
    pub applied_program_time_ticks: Option<i64>,
    pub expires_at: Option<MediaTime>,
    pub confidence: Option<f32>,
    pub reason: String,
    pub forced: bool,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SessionTimeline {
    pub schema_version: u32,
    pub session_id: Uuid,
    pub mode: String,
    pub timebase: SessionTimebase,
    pub started_at_unix_ms: Option<i64>,
    pub ended_at_unix_ms: Option<i64>,
    pub duration: MediaTime,
    pub config: SwitcherConfig,
    pub sources: Vec<SessionSource>,
    pub recordings: Vec<RecordingArtifact>,
    pub events: Vec<TimelineEvent>,
    pub events_processed: usize,
    pub cuts: Vec<CutRecord>,
    pub instructions: Vec<CutInstruction>,
    pub statuses: Vec<SwitcherOutput>,
    pub metadata: HashMap<String, String>,
}

/// Backwards-compatible name for callers that used the original offline
/// result type. The current result is a complete replay ledger rather than just a
/// list of proposed cuts.
pub type OfflineAnalysis = SessionTimeline;
