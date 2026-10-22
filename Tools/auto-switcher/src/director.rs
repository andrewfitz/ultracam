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
    health: HashMap<String, bool>,
}

impl Director {
    pub fn new(mut config: SwitcherConfig) -> Result<Self, String> {
        config.session_generation = config.session_generation.max(1);
        config.validate()?;
        let mut health = HashMap::new();
        health.insert(config.anchor_camera_id.clone(), true);
        health.insert(config.emphasis_camera_id.clone(), true);
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

    pub fn process_event(&mut self, event: StreamEvent) -> Vec<SwitcherOutput> {
        match event {
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
                if let Some(pending) = self.pending.clone() {
                    let time_ok = time.is_finite() && time >= 0.0;
                    let discontinuous = time_ok
                        && self
                            .last_media_time
                            .is_some_and(|last| time + 1e-6 < last);
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

    pub fn ingest_audio(&mut self, mut cue: AudioCue) {
        if cue.session_generation == 0 {
            cue.session_generation = self.session_generation;
        }
        if cue.session_generation != self.session_generation
            || !cue.time.is_finite()
            || cue.time < 0.0
            || !cue.duration.is_finite()
            || cue.duration < 0.0
            || !cue.speech_energy.is_finite()
            || !cue.pause_duration.is_finite()
            || !cue.emphasis.is_finite()
            || !cue.laughter.is_finite()
        {
            return;
        }
        cue.speech_energy = cue.speech_energy.clamp(0.0, 1.0);
        cue.emphasis = cue.emphasis.clamp(0.0, 1.0);
        cue.laughter = cue.laughter.clamp(0.0, 1.0);
        cue.pause_duration = cue.pause_duration.max(0.0);
        if self.audio.back().is_some_and(|last| cue.time < last.time) {
            return;
        }
        self.audio.push_back(cue);
        self.prune(self.last_media_time.unwrap_or(0.0));
    }

    pub fn ingest_transcript(&mut self, mut cue: TranscriptCue) {
        if cue.session_generation == 0 {
            cue.session_generation = self.session_generation;
        }
        if cue.session_generation != self.session_generation
            || cue.segment_id.is_empty()
            || !cue.start.is_finite()
            || !cue.end.is_finite()
            || cue.start < 0.0
            || cue.end < cue.start
            || !cue.confidence.is_finite()
        {
            return;
        }
        cue.confidence = cue.confidence.clamp(0.0, 1.0);
        if let Some(existing) = self.transcripts.get(&cue.segment_id) {
            let same_revision_finalization =
                cue.revision == existing.revision && !existing.is_final && cue.is_final;
            if existing.is_final && !cue.is_final
                || (cue.revision < existing.revision && !same_revision_finalization)
                || (cue.revision == existing.revision && !same_revision_finalization)
            {
                return;
            }
        }
        self.transcripts.insert(cue.segment_id.clone(), cue);
        self.prune(self.last_media_time.unwrap_or(0.0));
    }

    pub fn ingest_video(&mut self, observation: VideoObservation) {
        if observation.session_generation != 0
            && observation.session_generation != self.session_generation
        {
            return;
        }
        if !observation.time.is_finite() || observation.time < 0.0 {
            return;
        }
        if observation.camera_id.is_empty() {
            return;
        }
        if observation.camera_id == self.config.anchor_camera_id
            || observation.camera_id == self.config.emphasis_camera_id
        {
            self.health
                .insert(observation.camera_id, observation.healthy);
        }
        if self
            .last_media_time
            .is_none_or(|last| observation.time >= last)
        {
            self.last_media_time = Some(observation.time);
        }
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
        self.last_media_time = Some(now);
        self.prune(now);

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
            return None;
        }
        if let Some(instruction) = self.health_fallback(now) {
            return Some(instruction);
        }

        let shot_age = (now - self.shot_started_at).max(0.0);
        let cooldown_ready = self
            .last_cut_at
            .is_none_or(|last| now - last >= self.config.cooldown);
        if self.current_camera_id == self.config.emphasis_camera_id
            && self.latest_audio(now).is_none()
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
            self.state = DirectorState::RequestPending;
            return Some(instruction);
        }
        if shot_age >= self.config.maximum_shot_duration {
            self.state = DirectorState::ForcedCutPending;
            return self.forced_cut(now);
        }

        if shot_age < self.config.minimum_shot_duration || !cooldown_ready {
            return None;
        }

        let Some(audio) = self.latest_audio(now) else {
            self.state = self.state_for_current();
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
                return None;
            }
            return self.consider_candidate(now, boundary, score, false);
        }

        if self.current_camera_id == self.config.emphasis_camera_id {
            let boundary = boundary?;
            if shot_age < self.config.emphasis_hold
                || !self.is_healthy(&self.config.anchor_camera_id)
            {
                return None;
            }
            let resolved = matches!(
                boundary.kind,
                Some(CueKind::SentenceEnd | CueKind::Transition)
            ) || audio.pause_duration >= self.config.pause_boundary_duration;
            if !resolved || audio.emphasis > 0.5 {
                return None;
            }
            let score = (boundary.confidence * 0.6
                + (1.0 - audio.emphasis) * 0.25
                + (audio.pause_duration / 0.5).clamp(0.0, 1.0) as f32 * 0.15)
                .clamp(0.0, 1.0);
            if score < self.config.cut_threshold - 0.08 {
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

    pub fn manual_override(&mut self, camera_id: String, time: MediaTime) {
        self.apply_manual_override(camera_id, time);
    }

    fn apply_manual_override(&mut self, camera_id: String, time: MediaTime) -> Option<MediaTime> {
        if !time.is_finite()
            || time < 0.0
            || (camera_id != self.config.anchor_camera_id
                && camera_id != self.config.emphasis_camera_id)
        {
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
            .insert(self.config.anchor_camera_id.clone(), true);
        self.health
            .insert(self.config.emphasis_camera_id.clone(), true);
    }

    fn rebase_after_clock_discontinuity(&mut self, now: MediaTime) {
        let current = self.current_camera_id.clone();
        let health = self.health.clone();
        self.reset(None);
        self.current_camera_id = current;
        self.health = health;
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
        let boundary = self
            .boundaries()
            .into_iter()
            .filter(|b| {
                b.time >= deadline - self.config.forced_boundary_lookback
                    && b.time <= grace_deadline + self.config.boundary_window
            })
            .min_by(|a, b| {
                (a.time - deadline)
                    .abs()
                    .total_cmp(&(b.time - deadline).abs())
            });
        let (cut_time, confidence) = match boundary {
            Some(boundary) if boundary.time <= now + self.config.boundary_window => {
                (boundary.time.max(self.shot_started_at), boundary.confidence)
            }
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
            self.config.anchor_camera_id.clone()
        } else {
            self.config.emphasis_camera_id.clone()
        };
        let same = self.candidate.as_ref().is_some_and(|candidate| {
            candidate.target == target
                && candidate.return_to_anchor
                && return_to_anchor
                && (candidate.boundary.time - boundary.time).abs() < self.config.boundary_window
                || candidate.target == target
                    && !candidate.return_to_anchor
                    && !return_to_anchor
                    && (candidate.boundary.time - boundary.time).abs() < self.config.boundary_window
        });
        if same {
            if let Some(candidate) = self.candidate.as_mut() {
                candidate.score = candidate.score.max(score);
                if score >= candidate.score {
                    candidate.boundary = boundary;
                }
            }
        } else {
            self.candidate = Some(Candidate {
                target,
                boundary: boundary.clone(),
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
        if candidate.boundary.time <= self.shot_started_at + 1e-6
            || self
                .last_cut_at
                .is_some_and(|last| candidate.boundary.time <= last + 1e-6)
        {
            return None;
        }
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

    fn latest_audio(&self, now: MediaTime) -> Option<&AudioCue> {
        self.audio
            .iter()
            .rev()
            .find(|cue| cue.time <= now + self.config.boundary_window && now - cue.time <= 1.2)
    }

    fn nearest_boundary(&self, now: MediaTime) -> Option<Boundary> {
        self.boundaries()
            .into_iter()
            .filter(|b| {
                let window = if b.kind.is_some() && self.config.mode == "transcriptAssisted" {
                    self.config.boundary_window + self.config.transcript_output_delay
                } else {
                    self.config.boundary_window
                };
                (b.time - now).abs() <= window
            })
            .min_by(|a, b| (a.time - now).abs().total_cmp(&(b.time - now).abs()))
    }

    fn boundaries(&self) -> Vec<Boundary> {
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
            .iter()
            .filter(|cue| cue.pause_duration >= self.config.pause_boundary_duration)
            .map(|cue| Boundary {
                time: cue.time,
                confidence: (cue.pause_duration / 0.5).clamp(0.0, 1.0) as f32,
                kind: None,
            });
        transcripts.chain(pauses).collect()
    }

    fn is_healthy(&self, camera_id: &str) -> bool {
        self.health.get(camera_id).copied().unwrap_or(false)
    }

    fn state_for_current(&self) -> DirectorState {
        if self.current_camera_id == self.config.anchor_camera_id {
            DirectorState::HoldAnchor
        } else {
            DirectorState::HoldNewShot
        }
    }

    fn prune(&mut self, now: MediaTime) {
        let keep_from =
            (now - self.config.maximum_shot_duration - self.config.forced_boundary_lookback - 2.0)
                .max(0.0);
        while self.audio.front().is_some_and(|cue| cue.time < keep_from) {
            self.audio.pop_front();
        }
        self.transcripts.retain(|_, cue| cue.end >= keep_from);
    }
}
