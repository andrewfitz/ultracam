use crate::model::Strategy;
use crate::model::{
    AudioCue, CueKind, CutInstruction, CutReason, MediaTime, StreamEvent, SwitcherConfig,
    SwitcherOutput, TranscriptCue, VideoObservation,
};
use std::collections::{HashMap, VecDeque};
use uuid::Uuid;

#[derive(Debug, Clone)]
struct Boundary {
    time: MediaTime,
    confidence: f32,
    kind: Option<CueKind>,
}

impl Boundary {
    fn matches_transcript(&self, cue: &TranscriptCue) -> bool {
        cue.is_final
            && self.time == cue.end
            && self.confidence == cue.confidence
            && self.kind.as_ref() == Some(&cue.kind)
    }
}

// Transcript storage is a HashMap: iteration order must not choose the
// evidence (and therefore the cut score or return reason) for tied boundaries.
fn boundary_order(a: &Boundary, b: &Boundary, origin: MediaTime) -> std::cmp::Ordering {
    fn kind_rank(kind: &Option<CueKind>) -> u8 {
        match kind {
            Some(CueKind::SentenceEnd) => 0,
            Some(CueKind::Transition) => 1,
            Some(CueKind::Question) => 2,
            Some(CueKind::PhraseEnd) => 3,
            None => 4,
        }
    }
    (a.time - origin)
        .abs()
        .total_cmp(&(b.time - origin).abs())
        .then_with(|| b.confidence.total_cmp(&a.confidence))
        .then_with(|| a.time.total_cmp(&b.time))
        .then_with(|| kind_rank(&a.kind).cmp(&kind_rank(&b.kind)))
}

#[derive(Debug, Clone)]
struct Candidate {
    target: String,
    boundary: Boundary,
    score: f32,
    started_at: MediaTime,
    return_to_anchor: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirectorState {
    HoldCurrent,
    CandidateCut,
    WaitForSafeBoundary,
    RequestPending,
    HoldNewShot,
    CandidateReturn,
    HoldAnchor,
    ForcedCutPending,
}

impl DirectorState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::HoldCurrent => "holdCurrent",
            Self::CandidateCut => "candidateCut",
            Self::WaitForSafeBoundary => "waitForSafeBoundary",
            Self::RequestPending => "requestPending",
            Self::HoldNewShot => "holdNewShot",
            Self::CandidateReturn => "candidateReturn",
            Self::HoldAnchor => "holdAnchor",
            Self::ForcedCutPending => "forcedCutPending",
        }
    }
}

#[derive(Clone, Copy)]
struct CameraHealth {
    score: Option<f32>,
    motion: Option<f32>,
    gaze: Option<f32>,
    provider: Option<f32>,
    healthy: bool,
    observed_at: MediaTime,
}

impl CameraHealth {
    const INITIAL: Self = Self {
        healthy: true,
        observed_at: 0.0,
        motion: None,
        gaze: None,
        provider: None,
        score: None,
    };
}

pub struct Director {
    pub config: SwitcherConfig,
    current_camera_id: String,
    shot_started_at: MediaTime,
    last_cut_at: Option<MediaTime>,
    last_media_time: Option<MediaTime>,
    session_generation: u64,
    state: DirectorState,
    pending: Option<CutInstruction>,
    candidate: Option<Candidate>,
    audio: VecDeque<AudioCue>,
    transcripts: HashMap<String, TranscriptCue>,
    health: HashMap<String, CameraHealth>,
}

impl Director {
    pub fn new(mut config: SwitcherConfig) -> Result<Self, String> {
        config.session_generation = config.session_generation.max(1);
        config.validate()?;
        let mut health = HashMap::new();
        health.insert(config.anchor_camera_id.clone(), CameraHealth::INITIAL);
        health.insert(config.emphasis_camera_id.clone(), CameraHealth::INITIAL);
        for id in &config.additional_targets {
            health.insert(id.clone(), CameraHealth::INITIAL);
        }
        Ok(Self {
            session_generation: config.session_generation.max(1),
            current_camera_id: config.anchor_camera_id.clone(),
            shot_started_at: 0.0,
            last_cut_at: None,
            last_media_time: None,
            state: DirectorState::HoldAnchor,
            pending: None,
            candidate: None,
            audio: VecDeque::with_capacity(256),
            transcripts: HashMap::new(),
            health,
            config,
        })
    }

    pub fn state(&self) -> DirectorState {
        self.state
    }
    pub fn current_camera_id(&self) -> &str {
        &self.current_camera_id
    }
    pub fn pending(&self) -> Option<&CutInstruction> {
        self.pending.as_ref()
    }
    pub fn session_generation(&self) -> u64 {
        self.session_generation
    }

    pub(crate) fn media_time(&self) -> Option<MediaTime> {
        self.last_media_time
    }

    pub fn process_event(&mut self, event: StreamEvent) -> Vec<SwitcherOutput> {
        match event {
            StreamEvent::Take { camera_id, time } => {
                if !time.is_finite()
                    || time < 0.0
                    || self.pending.is_some()
                    || camera_id == self.current_camera_id
                    || !self.is_healthy(&camera_id)
                {
                    return vec![SwitcherOutput::Error {
                        message: "route unavailable, already pending or on air".into(),
                    }];
                }
                let cut = self.make_instruction(
                    &camera_id,
                    time,
                    1.0,
                    CutReason::Operator,
                    false,
                    time + 1.0,
                );
                self.pending = Some(cut.clone());
                self.state = DirectorState::RequestPending;
                vec![SwitcherOutput::Cut { instruction: cut }]
            }
            StreamEvent::DirectorOutput => Vec::new(),
            StreamEvent::Audio { cue } => {
                self.ingest_audio(cue);
                Vec::new()
            }
            StreamEvent::Transcript { cue } => {
                self.ingest_transcript(cue);
                Vec::new()
            }
            StreamEvent::Video { observation } => {
                self.ingest_video(observation);
                Vec::new()
            }
            StreamEvent::Tick { time } => {
                let mut outputs = Vec::new();
                // Emit expiry before `tick` clears the pending decision. A
                // backward clock, an elapsed deadline, or a target that has
                // gone unhealthy all invalidate that decision.
                if let Some(pending) = &self.pending {
                    let time_ok = time.is_finite() && time >= 0.0;
                    let discontinuous =
                        time_ok && self.last_media_time.is_some_and(|last| time + 1e-6 < last);
                    let expired = time_ok && time > pending.expires_at;
                    let target_unhealthy = time_ok && !self.is_healthy(&pending.target_camera_id);
                    if discontinuous || expired || target_unhealthy {
                        outputs.push(SwitcherOutput::DecisionExpired {
                            decision_id: pending.decision_id,
                        });
                    }
                }
                if let Some(instruction) = self.tick(time) {
                    outputs.push(SwitcherOutput::Cut { instruction });
                }
                outputs
            }
            StreamEvent::Acknowledge {
                decision_id,
                applied_at,
            } => {
                self.acknowledge(decision_id, applied_at);
                Vec::new()
            }
            StreamEvent::Reject { decision_id } => {
                self.reject(decision_id);
                Vec::new()
            }
            StreamEvent::ManualOverride { camera_id, time } => {
                match self.apply_manual_override(camera_id, time) {
                    Some(applied_at) => vec![self.status(applied_at)],
                    None => Vec::new(),
                }
            }
            StreamEvent::Reset { generation } => {
                self.reset(generation);
                Vec::new()
            }
        }
    }

    pub fn status(&self, time: MediaTime) -> SwitcherOutput {
        let time = if time.is_finite() && time >= 0.0 {
            time
        } else {
            self.last_media_time.unwrap_or(self.shot_started_at)
        };
        let shot_age = (time - self.shot_started_at).max(0.0);
        SwitcherOutput::Status {
            time,
            state: self.state.as_str().to_string(),
            current_camera_id: self.current_camera_id.clone(),
            shot_age,
            hard_deadline: self.shot_started_at + self.config.maximum_shot_duration,
            pending_decision_id: self.pending.as_ref().map(|p| p.decision_id),
        }
    }

    pub fn ingest_audio(&mut self, cue: AudioCue) {
        self.accept_audio(cue);
    }

    /// Returns whether the director accepted an evidence event. Controls use process_event.
    pub(crate) fn ingest_observation(&mut self, event: &StreamEvent) -> Option<bool> {
        match event {
            StreamEvent::Audio { cue } => Some(self.accept_audio(cue.clone())),
            StreamEvent::Transcript { cue } => Some(self.accept_transcript(cue.clone())),
            StreamEvent::Video { observation } => Some(self.accept_video(observation)),
            _ => None,
        }
    }

    fn accept_audio(&mut self, mut cue: AudioCue) -> bool {
        if cue.session_generation == 0 {
            cue.session_generation = self.session_generation;
        }
        let now = self.last_media_time.unwrap_or(0.0);
        if cue.session_generation != self.session_generation
            || !cue.has_valid_values()
            || cue.time < self.keep_evidence_from(now)
            || self.audio.back().is_some_and(|last| cue.time < last.time)
        {
            return false;
        }
        cue.speech_energy = cue.speech_energy.clamp(0.0, 1.0);
        cue.emphasis = cue.emphasis.clamp(0.0, 1.0);
        cue.laughter = cue.laughter.clamp(0.0, 1.0);
        cue.pause_duration = cue.pause_duration.max(0.0);
        self.audio.push_back(cue);
        true
    }

    pub fn ingest_transcript(&mut self, cue: TranscriptCue) {
        self.accept_transcript(cue);
    }

    fn accept_transcript(&mut self, mut cue: TranscriptCue) -> bool {
        if cue.session_generation == 0 {
            cue.session_generation = self.session_generation;
        }
        if cue.session_generation != self.session_generation
            || cue.segment_id.is_empty()
            || !cue.has_valid_values()
        {
            return false;
        }
        cue.confidence = cue.confidence.clamp(0.0, 1.0);
        if let Some(existing) = self.transcripts.get(&cue.segment_id) {
            let same_revision_finalization =
                cue.revision == existing.revision && !existing.is_final && cue.is_final;
            if existing.is_final && !cue.is_final
                || cue.revision < existing.revision
                || (cue.revision == existing.revision && !same_revision_finalization)
            {
                return false;
            }
            if self.candidate.as_ref().is_some_and(|candidate| {
                let boundary = &candidate.boundary;
                boundary.matches_transcript(existing)
                    && !boundary.matches_transcript(&cue)
                    && !self.transcripts.values().any(|other| {
                        other.segment_id != cue.segment_id && boundary.matches_transcript(other)
                    })
            }) {
                self.clear_candidate();
            }
        }
        let now = self.last_media_time.unwrap_or(0.0);
        if cue.end < self.keep_evidence_from(now) {
            self.transcripts.remove(&cue.segment_id);
            false
        } else {
            self.transcripts.insert(cue.segment_id.clone(), cue);
            true
        }
    }

    pub fn ingest_video(&mut self, observation: VideoObservation) {
        self.accept_video(&observation);
    }

    fn accept_video(&mut self, observation: &VideoObservation) -> bool {
        if observation.session_generation != 0
            && observation.session_generation != self.session_generation
        {
            return false;
        }
        if !observation.has_valid_values() {
            return false;
        }
        let Some(camera) = self.health.get_mut(&observation.camera_id) else {
            return false;
        };
        if observation.time < camera.observed_at {
            return false;
        }
        *camera = CameraHealth {
            motion: Some(observation.motion),
            gaze: observation.eye_contact,
            provider: observation.provider_score,
            score: match self.config.strategy {
                Strategy::Motion => Some(observation.motion),
                Strategy::EyeContact => observation.eye_contact,
                Strategy::Provider => observation.provider_score,
                _ => None,
            }
            .filter(|score| (0.0..=1.0).contains(score)),
            healthy: observation.healthy,
            observed_at: observation.time,
        };
        if self
            .last_media_time
            .is_none_or(|last| observation.time >= last)
        {
            self.last_media_time = Some(observation.time);
        }
        true
    }

    pub fn tick(&mut self, now: MediaTime) -> Option<CutInstruction> {
        if !now.is_finite() || now < 0.0 {
            return None;
        }
        if self.last_media_time.is_some_and(|last| now + 1e-6 < last) {
            // The program output is still on `current_camera_id`. Resetting
            // the shot origin to zero would make shot age equal the absolute
            // media time and immediately force a cut after a one-microsecond
            // clock step.
            self.rebase_after_clock_discontinuity(now);
            return None;
        }
        let clock = self.last_media_time.map_or(now, |last| last.max(now));
        self.last_media_time = Some(clock);
        self.prune(clock);

        if let Some(pending) = &self.pending {
            let drop_pending =
                now > pending.expires_at || !self.is_healthy(&pending.target_camera_id);
            if drop_pending {
                self.pending = None;
                self.candidate = None;
                self.state = self.state_for_current();
            } else {
                self.state = DirectorState::RequestPending;
                return None;
            }
        }
        if self.config.manual_hold {
            if self.candidate.is_some() {
                self.clear_candidate();
            }
            return None;
        }
        if self.config.strategy != Strategy::TalkingHead {
            return self.profile_cut(now);
        }
        if let Some(instruction) = self.health_fallback(now) {
            return Some(instruction);
        }

        let shot_age = (now - self.shot_started_at).max(0.0);
        let cooldown_ready = self
            .last_cut_at
            .is_none_or(|last| now - last >= self.config.cooldown);
        if self.current_camera_id == self.config.emphasis_camera_id
            && self
                .latest_audio(now, now + self.config.boundary_window)
                .is_none()
            && shot_age >= self.config.minimum_shot_duration
            && cooldown_ready
            && self.is_healthy(&self.config.anchor_camera_id)
        {
            let instruction = self.make_instruction(
                &self.config.anchor_camera_id,
                now,
                0.35,
                CutReason::AudioDegradedFallback,
                true,
                now + 1.0,
            );
            self.pending = Some(instruction.clone());
            self.candidate = None;
            self.state = DirectorState::RequestPending;
            return Some(instruction);
        }
        if shot_age >= self.config.maximum_shot_duration {
            self.state = DirectorState::ForcedCutPending;
            return self.forced_cut(now);
        }

        if shot_age < self.config.minimum_shot_duration || !cooldown_ready {
            if self.candidate.is_some() {
                self.clear_candidate();
            }
            return None;
        }

        // A saved boundary keeps its original one-second validity window.
        // Once it expires, a fresh boundary must start a new candidate dwell.
        if self
            .candidate
            .as_ref()
            .is_some_and(|candidate| now > candidate.boundary.time + 1.0)
        {
            self.clear_candidate();
        }

        let Some(audio) = self.latest_audio(now, now + self.config.boundary_window) else {
            self.clear_candidate();
            return None;
        };
        let boundary = self.nearest_boundary(now).or_else(|| {
            self.candidate
                .as_ref()
                .map(|candidate| candidate.boundary.clone())
        });
        if self.current_camera_id == self.config.anchor_camera_id {
            let Some(boundary) = boundary else {
                self.state = DirectorState::WaitForSafeBoundary;
                return None;
            };
            let emphasis_score = (audio.emphasis.max(audio.speech_energy * 0.65)
                + audio.laughter * 0.08)
                .clamp(0.0, 1.0);
            if emphasis_score < 0.55 || !self.is_healthy(&self.config.emphasis_camera_id) {
                self.clear_candidate();
                return None;
            }
            let pause_score = (audio.pause_duration / 0.5).clamp(0.0, 1.0) as f32;
            let pacing_need = if shot_age >= self.config.soft_maximum_shot_duration {
                0.08
            } else {
                0.0
            };
            let score = (boundary.confidence * 0.48
                + emphasis_score * 0.4
                + pause_score * 0.12
                + pacing_need)
                .clamp(0.0, 1.0);
            let current_score = (0.35 + emphasis_score * 0.15).clamp(0.0, 1.0);
            if score < self.config.cut_threshold
                || score - current_score < self.config.hysteresis_margin
            {
                self.clear_candidate();
                return None;
            }
            return self.consider_candidate(now, boundary, score, false);
        }

        if self.current_camera_id == self.config.emphasis_camera_id {
            let boundary = boundary?;
            if shot_age < self.config.emphasis_hold
                || !self.is_healthy(&self.config.anchor_camera_id)
            {
                self.clear_candidate();
                return None;
            }
            let resolved = matches!(
                boundary.kind,
                Some(CueKind::SentenceEnd | CueKind::Transition)
            ) || audio.pause_duration >= self.config.pause_boundary_duration;
            if !resolved || audio.emphasis > 0.5 {
                self.clear_candidate();
                return None;
            }
            let score = (boundary.confidence * 0.6
                + (1.0 - audio.emphasis) * 0.25
                + (audio.pause_duration / 0.5).clamp(0.0, 1.0) as f32 * 0.15)
                .clamp(0.0, 1.0);
            if score < self.config.cut_threshold - 0.08 {
                self.clear_candidate();
                return None;
            }
            return self.consider_candidate(now, boundary, score, true);
        }
        None
    }

    pub fn acknowledge(&mut self, decision_id: Uuid, applied_at: Option<MediaTime>) -> bool {
        let Some(pending) = self.pending.take() else {
            return false;
        };
        if pending.decision_id != decision_id {
            self.pending = Some(pending);
            return false;
        }
        let applied = match applied_at {
            Some(value) if value.is_finite() && value >= pending.cut_time => value,
            Some(_) => {
                self.pending = Some(pending);
                self.state = DirectorState::RequestPending;
                return false;
            }
            None => pending.cut_time,
        };
        self.current_camera_id = pending.target_camera_id;
        self.shot_started_at = applied;
        self.last_cut_at = Some(applied);
        // An editorial boundary can sit slightly ahead of the newest audio
        // cue. Advancing the live clock to that boundary makes the next cue
        // look discontinuous and throws away the shot just acknowledged.
        if self.last_media_time.is_none() {
            self.last_media_time = Some(applied);
        }
        self.candidate = None;
        self.state = self.state_for_current();
        true
    }

    pub fn reject(&mut self, decision_id: Uuid) -> bool {
        let Some(pending) = self.pending.as_ref() else {
            return false;
        };
        if pending.decision_id != decision_id {
            return false;
        }
        self.pending = None;
        self.candidate = None;
        self.state = self.state_for_current();
        true
    }

    fn matching_rule(&self, now: MediaTime) -> Option<&crate::model::SwitchRule> {
        use crate::model::Signal;
        let audio = self.latest_audio(now, now);
        let question_confidence = std::cell::OnceCell::new();
        self.config.rules.iter().find(|rule| {
            let Some(camera) = self
                .health
                .get(&rule.target)
                .filter(|camera| camera.healthy)
            else {
                return false;
            };
            let video = (0.0..=1.0)
                .contains(&(now - camera.observed_at))
                .then_some(camera);
            rule.all.iter().all(|condition| {
                let value = match condition.signal {
                    Signal::Motion => video.and_then(|c| c.motion),
                    Signal::EyeContact => video.and_then(|c| c.gaze),
                    Signal::ProviderScore => video.and_then(|c| c.provider),
                    Signal::AudioFeature => audio
                        .and_then(|a| a.features.get(condition.name.as_deref()?))
                        .copied(),
                    Signal::Energy => audio.map(|a| a.speech_energy),
                    Signal::Emphasis => audio.map(|a| a.emphasis),
                    Signal::Laughter => audio.map(|a| a.laughter),
                    Signal::PauseSeconds => audio.map(|a| a.pause_duration as f32),
                    Signal::QuestionConfidence => *question_confidence.get_or_init(|| {
                        self.transcripts
                            .values()
                            .filter(|t| {
                                t.is_final
                                    && t.kind == CueKind::Question
                                    && (0.0..=1.0).contains(&(now - t.end))
                            })
                            .map(|t| t.confidence)
                            .max_by(f32::total_cmp)
                    }),
                };
                value.is_some_and(|v| v >= condition.minimum)
            })
        })
    }

    fn profile_cut(&mut self, now: MediaTime) -> Option<CutInstruction> {
        let current_ok = self.is_healthy(&self.current_camera_id);
        if current_ok
            && now - self.shot_started_at
                < self.config.minimum_shot_duration.max(self.config.cooldown)
        {
            return None;
        }
        let index = self
            .config
            .targets()
            .position(|id| id == &self.current_camera_id)?;
        let mut candidates = self
            .config
            .targets()
            .skip(index + 1)
            .chain(self.config.targets().take(index))
            .filter(|id| self.is_healthy(id));
        let score = |id: &String| {
            let camera = self.health.get(id)?;
            (camera.observed_at <= now && now - camera.observed_at <= 1.0)
                .then_some(camera.score)
                .flatten()
        };
        let (target, confidence) = if self.config.strategy == Strategy::Timer || !current_ok {
            (candidates.next()?, 1.0)
        } else if self.config.strategy == Strategy::Rules {
            let rule = self.matching_rule(now)?;
            if rule.target == self.current_camera_id {
                return None;
            }
            (&rule.target, 1.0)
        } else {
            let floor = self
                .config
                .cut_threshold
                .max(score(&self.current_camera_id).unwrap_or(0.0) + self.config.hysteresis_margin);
            candidates
                .filter_map(|id| Some((id, score(id)?)))
                .filter(|(_, s)| *s >= floor)
                .max_by(|a, b| a.1.total_cmp(&b.1))?
        };
        let cut = self.make_instruction(
            target,
            now,
            confidence,
            CutReason::ProfileRule,
            !current_ok,
            now + 1.0,
        );
        self.pending = Some(cut.clone());
        self.state = DirectorState::RequestPending;
        Some(cut)
    }

    pub fn manual_override(&mut self, camera_id: String, time: MediaTime) {
        self.apply_manual_override(camera_id, time);
    }

    fn apply_manual_override(&mut self, camera_id: String, time: MediaTime) -> Option<MediaTime> {
        if !time.is_finite() || time < 0.0 || !self.health.contains_key(&camera_id) {
            return None;
        }
        let time = if let Some(last) = self.last_media_time {
            if time < last {
                // Status time can lag the last cue by a frame. Snapping a
                // recent override forward keeps the operator cut; a large gap
                // is a different timeline and is ignored.
                if last - time > 2.0 {
                    return None;
                }
                last
            } else {
                time
            }
        } else {
            time
        };
        self.pending = None;
        self.candidate = None;
        self.current_camera_id = camera_id;
        self.shot_started_at = time;
        self.last_cut_at = Some(time);
        self.last_media_time = Some(time);
        self.state = self.state_for_current();
        Some(time)
    }

    pub fn reset(&mut self, generation: Option<u64>) {
        let next_generation = generation
            .unwrap_or(self.session_generation.saturating_add(1))
            .max(1);
        self.session_generation = next_generation.max(self.session_generation);
        self.current_camera_id = self.config.anchor_camera_id.clone();
        self.shot_started_at = 0.0;
        self.last_cut_at = None;
        self.last_media_time = None;
        self.pending = None;
        self.candidate = None;
        self.audio.clear();
        self.transcripts.clear();
        self.state = DirectorState::HoldAnchor;
        self.health
            .values_mut()
            .for_each(|camera| *camera = CameraHealth::INITIAL);
        self.health
            .insert(self.config.anchor_camera_id.clone(), CameraHealth::INITIAL);
        self.health.insert(
            self.config.emphasis_camera_id.clone(),
            CameraHealth::INITIAL,
        );
    }

    fn rebase_after_clock_discontinuity(&mut self, now: MediaTime) {
        let current = self.current_camera_id.clone();
        let health = self.health.clone();
        self.reset(None);
        self.current_camera_id = current;
        self.health = health;
        // Retain the last known health, but accept the new clock's first observation.
        for camera in self.health.values_mut() {
            *camera = CameraHealth { healthy: camera.healthy, ..CameraHealth::INITIAL };
        }
        self.shot_started_at = now;
        self.last_media_time = Some(now);
        self.state = self.state_for_current();
    }

    fn health_fallback(&mut self, now: MediaTime) -> Option<CutInstruction> {
        if self.is_healthy(&self.current_camera_id) {
            return None;
        }
        let target = if self.current_camera_id == self.config.anchor_camera_id {
            self.config.emphasis_camera_id.clone()
        } else if self.current_camera_id == self.config.emphasis_camera_id {
            self.config.anchor_camera_id.clone()
        } else {
            return None;
        };
        if !self.is_healthy(&target) {
            return None;
        }
        let instruction = self.make_instruction(
            &target,
            now,
            0.4,
            CutReason::CameraHealthFallback,
            true,
            now + 1.0,
        );
        self.pending = Some(instruction.clone());
        self.state = DirectorState::RequestPending;
        Some(instruction)
    }

    fn forced_cut(&mut self, now: MediaTime) -> Option<CutInstruction> {
        let target = if self.current_camera_id == self.config.anchor_camera_id {
            &self.config.emphasis_camera_id
        } else {
            &self.config.anchor_camera_id
        };
        if !self.is_healthy(target) {
            return None;
        }
        let deadline = self.shot_started_at + self.config.maximum_shot_duration;
        let grace_deadline = deadline + self.config.forced_cut_grace_period;
        let earliest = deadline - self.config.forced_boundary_lookback;
        let audio_start = self.audio.partition_point(|cue| cue.time < earliest);
        let boundary = self
            .boundaries(audio_start)
            .filter(|b| {
                b.time >= earliest
                    && b.time <= grace_deadline + self.config.boundary_window
                    && b.time <= now + self.config.boundary_window
                    // Sparse ticks may arrive after this boundary's decision
                    // would expire. Let the absolute-cap fallback cut at now.
                    && now <= grace_deadline.max(b.time.max(self.shot_started_at)) + 1.0
            })
            .min_by(|a, b| boundary_order(a, b, deadline));
        let (cut_time, confidence) = match boundary {
            Some(boundary) => (boundary.time.max(self.shot_started_at), boundary.confidence),
            _ if now >= grace_deadline => (now, 0.35),
            _ => return None,
        };
        let instruction = self.make_instruction(
            target,
            cut_time,
            confidence,
            CutReason::ForcedMaximumShotDuration,
            true,
            grace_deadline.max(cut_time) + 1.0,
        );
        self.pending = Some(instruction.clone());
        self.state = DirectorState::RequestPending;
        Some(instruction)
    }

    fn consider_candidate(
        &mut self,
        now: MediaTime,
        boundary: Boundary,
        score: f32,
        return_to_anchor: bool,
    ) -> Option<CutInstruction> {
        let target = if return_to_anchor {
            &self.config.anchor_camera_id
        } else {
            &self.config.emphasis_camera_id
        };
        let same = self.candidate.as_ref().is_some_and(|candidate| {
            &candidate.target == target
                && candidate.return_to_anchor == return_to_anchor
                && (candidate.boundary.time - boundary.time).abs() <= self.config.boundary_window
        });
        if same {
            if let Some(candidate) = self.candidate.as_mut() {
                if score >= candidate.score {
                    candidate.score = score;
                    candidate.boundary = boundary;
                }
            }
        } else {
            self.candidate = Some(Candidate {
                target: target.clone(),
                boundary,
                score,
                // Dwell measures how long this candidate has been observed,
                // rather than how far its boundary lies in the past.
                started_at: now,
                return_to_anchor,
            });
        }
        let candidate = self.candidate.as_ref()?;
        self.state = if return_to_anchor {
            DirectorState::CandidateReturn
        } else {
            DirectorState::CandidateCut
        };
        if now - candidate.started_at < self.config.candidate_dwell {
            return None;
        }
        let candidate = self.candidate.take()?;
        let reason = if return_to_anchor {
            CutReason::EmphasisResolved
        } else {
            CutReason::EmphasisBoundary
        };
        let instruction = self.make_instruction(
            &candidate.target,
            candidate.boundary.time,
            candidate.score,
            reason,
            false,
            candidate.boundary.time + 1.0,
        );
        self.pending = Some(instruction.clone());
        self.state = DirectorState::RequestPending;
        Some(instruction)
    }

    fn make_instruction(
        &self,
        target: &str,
        cut_time: MediaTime,
        confidence: f32,
        reason: CutReason,
        forced: bool,
        expires_at: MediaTime,
    ) -> CutInstruction {
        CutInstruction {
            decision_id: Uuid::new_v4(),
            session_generation: self.session_generation,
            target_camera_id: target.to_string(),
            cut_time,
            expires_at,
            confidence: confidence.clamp(0.0, 1.0),
            reason,
            forced,
        }
    }

    fn latest_audio(&self, now: MediaTime, latest: MediaTime) -> Option<&AudioCue> {
        let cue = self.audio.back()?;
        let cue = if cue.time <= latest {
            cue
        } else {
            let end = self.audio.partition_point(|cue| cue.time <= latest);
            self.audio.get(end.checked_sub(1)?)?
        };
        (now - cue.time <= 1.2).then_some(cue)
    }

    fn nearest_boundary(&self, now: MediaTime) -> Option<Boundary> {
        let audio_start = self
            .audio
            .partition_point(|cue| now - cue.time > self.config.boundary_window);
        self.boundaries(audio_start)
            .filter(|b| {
                let window = if b.kind.is_some() && self.config.mode == "transcriptAssisted" {
                    self.config.boundary_window + self.config.transcript_output_delay
                } else {
                    self.config.boundary_window
                };
                (b.time - now).abs() <= window
                    && now <= b.time + 1.0
                    && b.time > self.shot_started_at + 1e-6
            })
            .min_by(|a, b| boundary_order(a, b, now))
    }

    fn boundaries(&self, audio_start: usize) -> impl Iterator<Item = Boundary> + '_ {
        let transcripts = self
            .transcripts
            .values()
            .filter(|cue| {
                cue.confidence >= self.config.transcript_confidence_threshold && cue.is_final
            })
            .map(|cue| Boundary {
                time: cue.end,
                confidence: cue.confidence,
                kind: Some(cue.kind.clone()),
            });
        let pauses = self
            .audio
            .range(audio_start..)
            .filter(|cue| cue.pause_duration >= self.config.pause_boundary_duration)
            .map(|cue| Boundary {
                time: cue.time,
                confidence: (cue.pause_duration / 0.5).clamp(0.0, 1.0) as f32,
                kind: None,
            });
        transcripts.chain(pauses)
    }

    fn is_healthy(&self, camera_id: &str) -> bool {
        self.health
            .get(camera_id)
            .is_some_and(|health| health.healthy)
    }

    fn state_for_current(&self) -> DirectorState {
        if self.current_camera_id == self.config.anchor_camera_id {
            DirectorState::HoldAnchor
        } else {
            DirectorState::HoldNewShot
        }
    }

    fn clear_candidate(&mut self) {
        self.candidate = None;
        self.state = self.state_for_current();
    }

    fn keep_evidence_from(&self, now: MediaTime) -> MediaTime {
        (now - self.config.maximum_shot_duration - self.config.forced_boundary_lookback - 2.0)
            .max(0.0)
    }

    fn prune(&mut self, now: MediaTime) {
        let keep_from = self.keep_evidence_from(now);
        while self.audio.front().is_some_and(|cue| cue.time < keep_from) {
            self.audio.pop_front();
        }
        self.transcripts.retain(|_, cue| cue.end >= keep_from);
    }
}
