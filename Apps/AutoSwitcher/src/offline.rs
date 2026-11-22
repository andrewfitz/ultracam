use crate::audio::{open_wav_pcm, with_media_audio, PcmCueDecoder};
use crate::director::Director;
use crate::model::{OfflineAnalysis, StreamEvent, SwitcherConfig, TranscriptCue, VideoObservation};
use crate::timeline::{event_time, TimelineRecorder};
use anyhow::{Context, Result};
use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use uuid::Uuid;

pub fn load_events_jsonl(path: &Path) -> Result<Vec<StreamEvent>> {
    load_jsonl(path, "stream event", |event| event)
}

pub fn load_transcript_jsonl(path: &Path) -> Result<Vec<StreamEvent>> {
    load_jsonl(path, "transcript", |cue: TranscriptCue| {
        StreamEvent::Transcript { cue }
    })
}

pub fn load_video_jsonl(path: &Path) -> Result<Vec<StreamEvent>> {
    load_jsonl(
        path,
        "video observation",
        |observation: VideoObservation| StreamEvent::Video { observation },
    )
}

fn load_jsonl<T: serde::de::DeserializeOwned>(
    path: &Path,
    kind: &str,
    wrap: impl Fn(T) -> StreamEvent,
) -> Result<Vec<StreamEvent>> {
    let file = File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let mut events = Vec::new();
    let mut line_number = 1;
    while reader
        .read_line(&mut line)
        .with_context(|| format!("failed to read {} on line {line_number}", path.display()))?
        != 0
    {
        if !line.trim().is_empty() {
            let value = serde_json::from_str(&line).with_context(|| {
                format!("invalid {kind} in {} on line {line_number}", path.display())
            })?;
            events.push(wrap(value));
        }
        line.clear();
        line_number += 1;
    }
    Ok(events)
}

pub fn events_from_pcm(
    bytes: &[u8],
    sample_rate: u32,
    chunk_ms: u32,
    threshold: f32,
) -> Result<Vec<StreamEvent>> {
    let decoder = PcmCueDecoder::new(sample_rate, chunk_ms, threshold)?;
    events_from_pcm_reader(bytes, decoder)
}

fn events_from_pcm_reader(
    mut reader: impl Read,
    mut decoder: PcmCueDecoder,
) -> Result<Vec<StreamEvent>> {
    let mut ordered = Vec::new();
    let mut push_event = |event| {
        let time = event_time(&event);
        ordered.push(event);
        if let Some(time) = time {
            ordered.push(StreamEvent::Tick { time });
        }
    };
    let mut buffer = [0; 16 * 1024];
    loop {
        let count = match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error).context("failed to read decoded PCM"),
        };
        decoder
            .push_pcm16le(&buffer[..count])
            .into_iter()
            .for_each(&mut push_event);
    }
    decoder.finish().into_iter().for_each(push_event);
    Ok(ordered)
}

pub fn events_from_audio_file(
    path: &Path,
    sample_rate: u32,
    chunk_ms: u32,
    threshold: f32,
) -> Result<Vec<StreamEvent>> {
    if path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("wav"))
    {
        let wav = open_wav_pcm(path)?;
        let decoder = PcmCueDecoder::new(wav.sample_rate, chunk_ms, threshold)?;
        events_from_pcm_reader(wav, decoder)
    } else {
        let decoder = PcmCueDecoder::new(sample_rate, chunk_ms, threshold)?;
        with_media_audio(path, sample_rate, |reader| {
            events_from_pcm_reader(reader, decoder)
        })
    }
}

pub fn analyze_events(events: Vec<StreamEvent>, config: SwitcherConfig) -> Result<OfflineAnalysis> {
    let mut director = Director::new(config.clone()).map_err(anyhow::Error::msg)?;
    let mut timeline = TimelineRecorder::new(config, "offline", Uuid::new_v4());
    timeline
        .timeline
        .metadata
        .insert("cut_application".into(), "assumed_at_requested_time".into());
    let mut ordered = events;
    // Controls stay where they arrived even when they report an application time.
    // A reset may restart the clock for the following run.
    for run in ordered.split_mut(|event| observation_time(event).is_none()) {
        run.sort_by(|a, b| {
            observation_time(a)
                .unwrap()
                .total_cmp(&observation_time(b).unwrap())
                .then_with(|| event_rank(a).cmp(&event_rank(b)))
        });
    }

    let mut ordered = ordered.into_iter().peekable();
    while let Some(event) = ordered.next() {
        let explicit_tick = matches!(event, StreamEvent::Tick { .. });
        let time = observation_time(&event);
        let outputs = director.process_event(event.clone());
        timeline.record_event(event, outputs.clone());
        timeline.assume_cut_applications(&mut director, &outputs);
        // Wait for every observation at this time, including any explicit tick.
        let next_time = ordered.peek().and_then(observation_time);
        if !explicit_tick && time != next_time {
            if let Some(time) = time {
                let tick = StreamEvent::Tick { time };
                let outputs = director.process_event(tick.clone());
                timeline.record_event(tick, outputs.clone());
                timeline.assume_cut_applications(&mut director, &outputs);
            }
        }
    }
    Ok(timeline.timeline)
}

fn event_rank(event: &StreamEvent) -> u8 {
    matches!(event, StreamEvent::Tick { .. }) as u8
}

fn observation_time(event: &StreamEvent) -> Option<f64> {
    match event {
        StreamEvent::Audio { .. }
        | StreamEvent::Transcript { .. }
        | StreamEvent::Video { .. }
        | StreamEvent::Tick { .. } => event_time(event),
        _ => None,
    }
}
