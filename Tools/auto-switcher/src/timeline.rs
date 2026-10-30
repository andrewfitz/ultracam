use crate::model::{
    CutInstruction, CutRecord, MediaTime, RecordingArtifact, SessionSource, SessionTimebase,
    SessionTimeline, StreamEvent, SwitcherConfig, SwitcherOutput, TimelineEvent,
    SESSION_TIMELINE_SCHEMA_VERSION,
};
use std::collections::HashMap;
use uuid::Uuid;

/// Builds the durable replay ledger used by both realtime and offline modes.
/// Media timestamps remain in the same source/Program clock as the director;
/// integer ticks are included alongside seconds so an editor can reconstruct
/// cuts without accumulating floating-point rounding error.
pub struct TimelineRecorder {
    pub timeline: SessionTimeline,
    next_sequence: u64,
    current_camera_id: String,
    pending: HashMap<Uuid, usize>,
}

impl TimelineRecorder {
    pub fn new(mut config: SwitcherConfig, mode: impl Into<String>, session_id: Uuid) -> Self {
        config.session_generation = config.session_generation.max(1);
        let current_camera_id = config.anchor_camera_id.clone();
        let anchor_camera_id = config.anchor_camera_id.clone();
        let emphasis_camera_id = config.emphasis_camera_id.clone();
        Self {
            timeline: SessionTimeline {
                schema_version: SESSION_TIMELINE_SCHEMA_VERSION,
                session_id,
                mode: mode.into(),
                timebase: SessionTimebase::default(),
                started_at_unix_ms: None,
                ended_at_unix_ms: None,
                duration: 0.0,
                config,
                sources: vec![
                    SessionSource {
                        camera_id: anchor_camera_id,
                        role: "anchor".to_string(),
                        label: None,
                        media_file: None,
                        media_start: None,
                        media_end: None,
                        timebase: SessionTimebase::default(),
                    },
                    SessionSource {
                        camera_id: emphasis_camera_id,
                        role: "emphasis".to_string(),
                        label: None,
                        media_file: None,
                        media_start: None,
                        media_end: None,
                        timebase: SessionTimebase::default(),
                    },
                ],
                recordings: Vec::new(),
                events: Vec::new(),
                events_processed: 0,
                cuts: Vec::new(),
                instructions: Vec::new(),
                statuses: Vec::new(),
                metadata: HashMap::new(),
            },
            next_sequence: 1,
            current_camera_id,
            pending: HashMap::new(),
        }
    }

    pub fn add_source(&mut self, source: SessionSource) {
        self.timeline
            .sources
            .retain(|existing| existing.camera_id != source.camera_id);
        self.timeline.sources.push(source);
    }

    pub fn add_recording(&mut self, recording: RecordingArtifact) {
        if let Some(source) = self
            .timeline
            .sources
            .iter_mut()
            .find(|source| source.camera_id == recording.camera_id)
        {
            source.media_file = Some(recording.path.clone());
            source.media_start = recording.media_start;
            source.media_end = recording.media_end;
        } else {
            self.timeline.sources.push(SessionSource {
                camera_id: recording.camera_id.clone(),
                role: "source".to_string(),
                label: None,
                media_file: Some(recording.path.clone()),
                media_start: recording.media_start,
                media_end: recording.media_end,
                timebase: self.timeline.timebase.clone(),
            });
        }
        self.timeline
            .recordings
            .retain(|existing| existing.recording_id != recording.recording_id);
        self.timeline.recordings.push(recording);
    }

    pub fn update_recording<F>(&mut self, recording_id: Uuid, update: F)
    where
        F: FnOnce(&mut RecordingArtifact),
    {
        if let Some(recording) = self
            .timeline
            .recordings
            .iter_mut()
            .find(|recording| recording.recording_id == recording_id)
        {
            update(recording);
        }
    }

    pub fn record_event(&mut self, event: StreamEvent, outputs: Vec<SwitcherOutput>) {
        if serde_json::to_value(&event).is_err()
            || serde_json::to_value(&outputs).is_err()
            || event_time(&event).is_some_and(|time| !time.is_finite() || time < 0.0)
        {
            self.timeline.statuses.push(SwitcherOutput::Error {
                message: "invalid event omitted from timeline".to_string(),
            });
            return;
        }
        let media_time = event_time(&event).filter(|time| time.is_finite() && *time >= 0.0);
        self.timeline.duration = self
            .timeline
            .duration
            .max(media_time.unwrap_or(0.0))
            .max(outputs.iter().filter_map(output_time).fold(0.0, f64::max));
        let media_time_ticks =
            media_time.map(|time| to_ticks(time, self.timeline.timebase.timescale));
        for output in &outputs {
            self.record_output(output.clone());
        }
        self.apply_event_state(&event, &outputs);
        self.timeline.events.push(TimelineEvent {
            sequence: self.next_sequence,
            media_time,
            media_time_ticks,
            event,
            outputs,
        });
        self.timeline.events_processed = self.timeline.events.len();
        self.next_sequence = self.next_sequence.saturating_add(1);
    }

    pub fn record_output(&mut self, output: SwitcherOutput) {
        match output {
            SwitcherOutput::Cut { instruction } => self.record_instruction(instruction),
            SwitcherOutput::DecisionExpired { decision_id } => {
                if let Some(index) = self.pending.remove(&decision_id) {
                    if let Some(cut) = self.timeline.cuts.get_mut(index) {
                        cut.status = "expired".to_string();
                    }
                }
                self.timeline
                    .statuses
                    .push(SwitcherOutput::DecisionExpired { decision_id });
            }
            other => self.timeline.statuses.push(other),
        }
    }

    pub fn finish(&mut self, ended_at_unix_ms: Option<i64>) {
        self.timeline.ended_at_unix_ms = ended_at_unix_ms;
        self.cancel_pending();
    }

    fn cancel_pending(&mut self) {
        for index in self.pending.values() {
            if let Some(cut) = self.timeline.cuts.get_mut(*index) {
                cut.status = "cancelled".to_string();
            }
        }
        self.pending.clear();
    }

    fn record_instruction(&mut self, instruction: CutInstruction) {
        if self
            .timeline
            .instructions
            .iter()
            .any(|existing| existing.decision_id == instruction.decision_id)
        {
            return;
        }
        let from_camera_id = Some(self.current_camera_id.clone());
        let cut = CutRecord {
            decision_id: Some(instruction.decision_id),
            session_generation: instruction.session_generation,
            from_camera_id,
            target_camera_id: instruction.target_camera_id.clone(),
            requested_cut_time: Some(instruction.cut_time),
            requested_cut_time_ticks: Some(to_ticks(
                instruction.cut_time,
                self.timeline.timebase.timescale,
            )),
            applied_source_time: None,
            applied_source_time_ticks: None,
            applied_program_time: None,
            applied_program_time_ticks: None,
            expires_at: Some(instruction.expires_at),
            confidence: Some(instruction.confidence),
            reason: serde_json::to_string(&instruction.reason)
                .unwrap_or_else(|_| "\"unknown\"".to_string())
                .trim_matches('"')
                .to_string(),
            forced: instruction.forced,
            status: "proposed".to_string(),
        };
        self.pending
            .insert(instruction.decision_id, self.timeline.cuts.len());
        self.timeline.instructions.push(instruction);
        self.timeline.cuts.push(cut);
    }

    fn apply_event_state(&mut self, event: &StreamEvent, outputs: &[SwitcherOutput]) {
        match event {
            StreamEvent::Acknowledge {
                decision_id,
                applied_at,
            } => {
                if let Some(&index) = self.pending.get(decision_id) {
                    if let Some(cut) = self.timeline.cuts.get_mut(index) {
                        let requested = cut.requested_cut_time.unwrap_or(0.0);
                        let valid_applied = applied_at
                            .map(|time| time.is_finite() && time >= requested)
                            .unwrap_or(true);
                        if !valid_applied {
                            self.timeline.statuses.push(SwitcherOutput::Error {
                                message: "acknowledgement precedes requested cut time".to_string(),
                            });
                        } else {
                            self.pending.remove(decision_id);
                            let applied = applied_at.or(cut.requested_cut_time);
                            cut.status = "applied".to_string();
                            cut.applied_source_time = applied;
                            cut.applied_source_time_ticks = applied
                                .map(|time| to_ticks(time, self.timeline.timebase.timescale));
                            cut.applied_program_time = applied;
                            cut.applied_program_time_ticks = applied
                                .map(|time| to_ticks(time, self.timeline.timebase.timescale));
                            self.current_camera_id = cut.target_camera_id.clone();
                        }
                    }
                }
            }
            StreamEvent::Reject { decision_id } => {
                if let Some(index) = self.pending.remove(decision_id) {
                    if let Some(cut) = self.timeline.cuts.get_mut(index) {
                        cut.status = "rejected".to_string();
                    }
                }
            }
            StreamEvent::ManualOverride { camera_id, .. } => {
                // Only the director can accept an override and resolve a
                // lagging timestamp. Its status carries that applied time.
                let Some(time) = outputs.iter().find_map(|output| match output {
                    SwitcherOutput::Status {
                        time,
                        current_camera_id,
                        pending_decision_id: None,
                        ..
                    } if current_camera_id == camera_id => Some(*time),
                    _ => None,
                }) else {
                    return;
                };
                self.cancel_pending();
                self.timeline.cuts.push(CutRecord {
                    decision_id: None,
                    session_generation: self.timeline.config.session_generation.max(1),
                    from_camera_id: Some(self.current_camera_id.clone()),
                    target_camera_id: camera_id.clone(),
                    requested_cut_time: Some(time),
                    requested_cut_time_ticks: Some(to_ticks(
                        time,
                        self.timeline.timebase.timescale,
                    )),
                    applied_source_time: Some(time),
                    applied_source_time_ticks: Some(to_ticks(
                        time,
                        self.timeline.timebase.timescale,
                    )),
                    applied_program_time: Some(time),
                    applied_program_time_ticks: Some(to_ticks(
                        time,
                        self.timeline.timebase.timescale,
                    )),
                    expires_at: None,
                    confidence: None,
                    reason: "manualOverride".to_string(),
                    forced: false,
                    status: "applied".to_string(),
                });
                self.current_camera_id = camera_id.clone();
            }
            StreamEvent::Reset { generation } => {
                self.current_camera_id = self.timeline.config.anchor_camera_id.clone();
                let requested = generation
                    .unwrap_or(self.timeline.config.session_generation.saturating_add(1))
                    .max(1);
                self.timeline.config.session_generation =
                    requested.max(self.timeline.config.session_generation);
                self.cancel_pending();
            }
            _ => {}
        }
    }
}

pub fn to_ticks(time: MediaTime, timescale: i32) -> i64 {
    if !time.is_finite() || timescale <= 0 {
        return 0;
    }
    (time * f64::from(timescale)).round() as i64
}

fn event_time(event: &StreamEvent) -> Option<MediaTime> {
    match event {
        StreamEvent::Audio { cue } => Some(cue.time),
        StreamEvent::Transcript { cue } => Some(cue.end),
        StreamEvent::Video { observation } => Some(observation.time),
        StreamEvent::Tick { time } => Some(*time),
        StreamEvent::Acknowledge { applied_at, .. } => *applied_at,
        StreamEvent::DirectorOutput | StreamEvent::Reject { .. } => None,
        StreamEvent::ManualOverride { time, .. } => Some(*time),
        StreamEvent::Reset { .. } => None,
    }
}

fn output_time(output: &SwitcherOutput) -> Option<MediaTime> {
    match output {
        SwitcherOutput::Cut { instruction } => Some(instruction.cut_time),
        SwitcherOutput::Status { time, .. } => Some(*time),
        SwitcherOutput::LlmAdvisory { available_at, .. } => Some(*available_at),
        SwitcherOutput::DecisionExpired { .. } | SwitcherOutput::Error { .. } => None,
    }
}
