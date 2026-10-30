use crate::audio::{decode_media_audio, decode_wav, PcmCueDecoder};
use crate::director::Director;
use crate::model::{
    AudioCue, OfflineAnalysis, StreamEvent, SwitcherConfig, TranscriptCue, VideoObservation,
};
use crate::timeline::TimelineRecorder;
use anyhow::{Context, Result};
use std::path::Path;
use uuid::Uuid;

pub fn load_events_jsonl(path: &Path) -> Result<Vec<StreamEvent>> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read {}", path.display()))?;
    content
        .lines()
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(line_number, line)| {
            serde_json::from_str(line)
                .with_context(|| format!("invalid stream event on line {}", line_number + 1))
        })
        .collect()
}

pub fn load_transcript_jsonl(path: &Path) -> Result<Vec<StreamEvent>> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read {}", path.display()))?;
    content
        .lines()
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(line_number, line)| {
            let cue: TranscriptCue = serde_json::from_str(line)
                .with_context(|| format!("invalid transcript on line {}", line_number + 1))?;
            Ok(StreamEvent::Transcript { cue })
        })
        .collect()
}

pub fn load_video_jsonl(path: &Path) -> Result<Vec<StreamEvent>> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read {}", path.display()))?;
    content
        .lines()
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(line_number, line)| {
            let observation: VideoObservation = serde_json::from_str(line).with_context(|| {
                format!("invalid video observation on line {}", line_number + 1)
            })?;
            Ok(StreamEvent::Video { observation })
        })
        .collect()
}

pub fn events_from_pcm(
    bytes: &[u8],
    sample_rate: u32,
    chunk_ms: u32,
    threshold: f32,
) -> Result<Vec<StreamEvent>> {
    let mut decoder = PcmCueDecoder::new(sample_rate, chunk_ms, threshold)?;
    let mut events = decoder.push_pcm16le(bytes);
    events.extend(decoder.finish());
    let mut ordered = Vec::with_capacity(events.len() * 2);
    for event in events {
        let time = timeline_time(&event);
        ordered.push(event);
        if let Some(time) = time {
            ordered.push(StreamEvent::Tick { time });
        }
    }
    Ok(ordered)
}

pub fn events_from_audio_file(
    path: &Path,
    sample_rate: u32,
    chunk_ms: u32,
    threshold: f32,
) -> Result<Vec<StreamEvent>> {
    let (actual_rate, bytes) = if path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("wav"))
    {
        decode_wav(path)?
    } else {
        (sample_rate, decode_media_audio(path, sample_rate)?)
    };
    events_from_pcm(&bytes, actual_rate, chunk_ms, threshold)
}

pub fn analyze_events(events: Vec<StreamEvent>, config: SwitcherConfig) -> Result<OfflineAnalysis> {
    let mut director = Director::new(config.clone()).map_err(anyhow::Error::msg)?;
    let mut timeline = TimelineRecorder::new(config, "offline", Uuid::new_v4());
    let mut ordered = events;
    // Missing timestamps sort last; a real timestamp of zero remains timed.
    ordered.sort_by(|a, b| {
        match (timeline_time(a), timeline_time(b)) {
            (Some(a), Some(b)) => a.total_cmp(&b),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        }
        .then_with(|| event_rank(a).cmp(&event_rank(b)))
    });

    for event in ordered {
        let explicit_tick = matches!(event, StreamEvent::Tick { .. });
        let event_time = timeline_time(&event);
        let outputs = director.process_event(event.clone());
        timeline.record_event(event, outputs.clone());
        acknowledge_offline_cuts(&mut director, &mut timeline, &outputs);
        if !explicit_tick {
            if let Some(time) = event_time {
                let tick = StreamEvent::Tick { time };
                let outputs = director.process_event(tick.clone());
                timeline.record_event(tick, outputs.clone());
                acknowledge_offline_cuts(&mut director, &mut timeline, &outputs);
            }
        }
    }
    Ok(timeline.timeline)
}

fn acknowledge_offline_cuts(
    director: &mut Director,
    timeline: &mut TimelineRecorder,
    outputs: &[crate::model::SwitcherOutput],
) {
    for output in outputs {
        if let crate::model::SwitcherOutput::Cut { instruction } = output {
            let event = StreamEvent::Acknowledge {
                decision_id: instruction.decision_id,
                applied_at: Some(instruction.cut_time),
            };
            let follow_up = director.process_event(event.clone());
            timeline.record_event(event, follow_up);
        }
    }
}

fn timeline_time(event: &StreamEvent) -> Option<f64> {
    match event {
        StreamEvent::Audio {
            cue: AudioCue { time, .. },
        } => Some(*time),
        StreamEvent::Transcript {
            cue: TranscriptCue { end, .. },
        } => Some(*end),
        StreamEvent::Video { observation } => Some(observation.time),
        StreamEvent::Tick { time } => Some(*time),
        StreamEvent::Acknowledge { applied_at, .. } => *applied_at,
        StreamEvent::DirectorOutput | StreamEvent::Reject { .. } => None,
        StreamEvent::ManualOverride { time, .. } => Some(*time),
        StreamEvent::Reset { .. } => None,
    }
}

fn event_rank(event: &StreamEvent) -> u8 {
    matches!(event, StreamEvent::Tick { .. }) as u8
}
