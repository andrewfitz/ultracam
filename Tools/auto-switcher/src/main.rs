use anyhow::{Context, Result};
use auto_switcher::audio::PcmCueDecoder;
use auto_switcher::director::Director;
use auto_switcher::llm::{DecisionContext, DelayedLlmAdvisor, OllamaProvider};
use auto_switcher::model::{
    AudioCue, StreamEvent, SwitcherConfig, SwitcherOutput, TranscriptCue, VideoObservation,
};
use auto_switcher::offline::{
    analyze_events, events_from_audio_file, load_events_jsonl, load_transcript_jsonl,
    load_video_jsonl,
};
use auto_switcher::timeline::TimelineRecorder;
use clap::{Parser, Subcommand, ValueEnum};
use std::collections::VecDeque;
use std::io::{self, BufRead, BufWriter, Read, Write};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use uuid::Uuid;

#[derive(Debug, Parser)]
#[command(
    name = "auto-switcher",
    version,
    about = "Realtime and offline talking-head camera direction"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Read newline-delimited events or raw PCM16LE from stdin and emit JSONL instructions.
    Realtime {
        #[arg(long, value_enum, default_value_t = InputFormat::Jsonl)]
        input_format: InputFormat,
        #[arg(long, default_value_t = 16_000)]
        sample_rate: u32,
        #[arg(long, default_value_t = 20)]
        chunk_ms: u32,
        #[arg(long, default_value_t = 0.025)]
        speech_threshold: f32,
        #[arg(long)]
        config: Option<PathBuf>,
        /// Enable delayed Ollama advisory requests. Heuristic cuts remain authoritative.
        #[arg(long)]
        ollama: bool,
        #[arg(long, default_value = "http://127.0.0.1:11434/api/generate")]
        ollama_url: String,
        #[arg(long, default_value = "llama3.2:latest")]
        ollama_model: String,
        #[arg(long, default_value_t = 15.0)]
        llm_delay_seconds: f64,
        /// Complete replay ledger written at the end of the realtime session.
        /// A unique session filename is generated when omitted. Use `-` for stdout only.
        #[arg(long)]
        output: Option<PathBuf>,
    },
    /// Parse a complete event file or media file and emit one JSON analysis document.
    Offline {
        #[arg(long)]
        events: Option<PathBuf>,
        #[arg(long)]
        audio: Option<PathBuf>,
        #[arg(long)]
        transcript: Option<PathBuf>,
        /// JSONL video observations from a vision adapter or ffmpeg pipeline.
        #[arg(long)]
        video_cues: Option<PathBuf>,
        #[arg(long, default_value_t = 16_000)]
        sample_rate: u32,
        #[arg(long, default_value_t = 20)]
        chunk_ms: u32,
        #[arg(long, default_value_t = 0.025)]
        speech_threshold: f32,
        #[arg(long)]
        config: Option<PathBuf>,
        /// Complete replay ledger. A unique filename is generated when omitted.
        /// Use `-` to write the JSON document to stdout.
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Print the versioned JSON protocol schemas.
    Schema {
        #[arg(value_enum, default_value_t = SchemaName::All)]
        name: SchemaName,
    },
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum InputFormat {
    Jsonl,
    Pcm16le,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum SchemaName {
    StreamEvent,
    SwitcherOutput,
    SessionTimeline,
    OfflineAnalysis,
    LlmContext,
    All,
}

struct LlmRuntime {
    advisor: DelayedLlmAdvisor,
    delay: f64,
    last_submit_attempt: f64,
    audio: VecDeque<AudioCue>,
    transcript: VecDeque<TranscriptCue>,
    video: VecDeque<VideoObservation>,
}

impl LlmRuntime {
    fn new(url: String, model: String, delay: f64) -> Self {
        let provider = OllamaProvider {
            endpoint: url,
            model,
            timeout: Duration::from_secs(30),
        };
        Self {
            advisor: DelayedLlmAdvisor::new(Box::new(provider)),
            delay: delay.max(0.0),
            last_submit_attempt: -f64::INFINITY,
            audio: VecDeque::new(),
            transcript: VecDeque::new(),
            video: VecDeque::new(),
        }
    }

    fn reset(&mut self) {
        self.advisor.reset();
        self.audio.clear();
        self.transcript.clear();
        self.video.clear();
        self.last_submit_attempt = -f64::INFINITY;
    }

    fn observe(&mut self, event: &StreamEvent, generation: u64) {
        if !event.has_valid_cue_values() {
            return;
        }
        let current = |tag: u64| tag == 0 || tag == generation;
        match event {
            StreamEvent::Audio { cue } if current(cue.session_generation) => {
                self.audio.push_back(cue.clone());
            }
            StreamEvent::Transcript { cue } if current(cue.session_generation) => {
                self.transcript.push_back(cue.clone());
            }
            StreamEvent::Video { observation } if current(observation.session_generation) => {
                self.video.push_back(observation.clone());
            }
            _ => {}
        }
        while self.audio.len() > 256 {
            self.audio.pop_front();
        }
        while self.transcript.len() > 64 {
            self.transcript.pop_front();
        }
        while self.video.len() > 128 {
            self.video.pop_front();
        }
    }

    fn tick(
        &mut self,
        now: f64,
        config: &SwitcherConfig,
        current_camera_id: &str,
    ) -> Vec<SwitcherOutput> {
        if !now.is_finite() || now < 0.0 {
            return Vec::new();
        }
        let mut output = Vec::new();
        for (request_id, result) in self.advisor.poll(now) {
            match result {
                Ok(proposal) => {
                    let target_is_known =
                        proposal.target_camera_id.as_deref().is_none_or(|target| {
                            target == config.anchor_camera_id || target == config.emphasis_camera_id
                        });
                    if !target_is_known || !proposal.confidence.is_finite() {
                        output.push(SwitcherOutput::LlmAdvisory {
                            request_id,
                            available_at: now,
                            target_camera_id: None,
                            confidence: 0.0,
                            reason: "Ollama returned an invalid camera decision".to_string(),
                            hold: true,
                            error: Some("proposal target or confidence was invalid".to_string()),
                        });
                    } else {
                        output.push(SwitcherOutput::LlmAdvisory {
                            request_id,
                            available_at: now,
                            target_camera_id: proposal.target_camera_id,
                            confidence: proposal.confidence.clamp(0.0, 1.0),
                            reason: proposal.reason,
                            hold: proposal.hold,
                            error: None,
                        });
                    }
                }
                Err(error) => output.push(SwitcherOutput::LlmAdvisory {
                    request_id,
                    available_at: now,
                    target_camera_id: None,
                    confidence: 0.0,
                    reason: "Ollama advisory failed".to_string(),
                    hold: true,
                    error: Some(error),
                }),
            }
        }
        if now - self.last_submit_attempt >= 1.0 {
            let context = DecisionContext {
                request_id: Uuid::nil(),
                media_time: now,
                current_camera_id: current_camera_id.to_string(),
                anchor_camera_id: config.anchor_camera_id.clone(),
                emphasis_camera_id: config.emphasis_camera_id.clone(),
                audio: self.audio.iter().cloned().collect(),
                transcript: self.transcript.iter().cloned().collect(),
                video: self.video.iter().cloned().collect(),
            };
            self.last_submit_attempt = now;
            self.advisor
                .submit(context, now + self.delay, now + self.delay + 10.0);
        }
        output
    }
}

fn main() -> Result<()> {
    match Cli::parse().command {
        Command::Realtime {
            input_format,
            sample_rate,
            chunk_ms,
            speech_threshold,
            config,
            ollama,
            ollama_url,
            ollama_model,
            llm_delay_seconds,
            output,
        } => realtime(
            input_format,
            sample_rate,
            chunk_ms,
            speech_threshold,
            load_config(config)?,
            ollama.then(|| LlmRuntime::new(ollama_url, ollama_model, llm_delay_seconds)),
            output,
        )?,
        Command::Offline {
            events,
            audio,
            transcript,
            video_cues,
            sample_rate,
            chunk_ms,
            speech_threshold,
            config,
            output,
        } => offline(
            OfflineOptions {
                events,
                audio,
                transcript,
                video_cues,
                sample_rate,
                chunk_ms,
                speech_threshold,
                output,
            },
            load_config(config)?,
        )?,
        Command::Schema { name } => print_schema(name)?,
    }
    Ok(())
}

fn load_config(path: Option<PathBuf>) -> Result<SwitcherConfig> {
    let mut config = match path {
        Some(path) => serde_json::from_str(
            &std::fs::read_to_string(&path)
                .with_context(|| format!("failed to read config {}", path.display()))?,
        )?,
        None => SwitcherConfig::default(),
    };
    // Automatic camera jumps have a ten-second safety floor. Keep the library
    // configurable for deterministic unit tests, but never let the CLI run a
    // production session with a shorter interval.
    config.minimum_shot_duration = config.minimum_shot_duration.max(10.0);
    config.validate().map_err(anyhow::Error::msg)?;
    Ok(config)
}

fn realtime(
    input_format: InputFormat,
    sample_rate: u32,
    chunk_ms: u32,
    threshold: f32,
    config: SwitcherConfig,
    mut llm: Option<LlmRuntime>,
    output_path: Option<PathBuf>,
) -> Result<()> {
    let mut director = Director::new(config.clone()).map_err(anyhow::Error::msg)?;
    let mut timeline = if output_path.as_deref() == Some(Path::new("-")) {
        None
    } else {
        let mut timeline = TimelineRecorder::new(config, "realtime", Uuid::new_v4());
        timeline.timeline.started_at_unix_ms = Some(unix_ms());
        if matches!(input_format, InputFormat::Pcm16le) {
            timeline
                .timeline
                .metadata
                .insert("cut_application".into(), "assumed_at_requested_time".into());
        }
        Some(timeline)
    };
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let mut process = |event| {
        process_realtime_event(
            &mut output,
            &mut director,
            &mut llm,
            timeline.as_mut(),
            input_format,
            event,
        )
    };
    match input_format {
        InputFormat::Jsonl => {
            let mut input = io::stdin().lock();
            let mut line = String::new();
            let mut line_number = 1;
            while input
                .read_line(&mut line)
                .context("failed to read realtime input")?
                != 0
            {
                if !line.trim().is_empty() {
                    let event = serde_json::from_str(&line).with_context(|| {
                        format!("invalid realtime JSONL event on line {line_number}")
                    })?;
                    process(event)?;
                }
                line.clear();
                line_number += 1;
            }
        }
        InputFormat::Pcm16le => {
            let mut decoder =
                PcmCueDecoder::new(sample_rate, chunk_ms, threshold).map_err(anyhow::Error::msg)?;
            let stdin = io::stdin();
            let mut input = stdin.lock();
            let mut bytes = [0_u8; 16 * 1024];
            loop {
                let count = input.read(&mut bytes).context("failed to read PCM input")?;
                let events = if count == 0 {
                    decoder.finish()
                } else {
                    decoder.push_pcm16le(&bytes[..count])
                };
                for event in events {
                    let tick = match &event {
                        StreamEvent::Audio { cue } => Some(StreamEvent::Tick { time: cue.time }),
                        _ => None,
                    };
                    process(event)?;
                    if let Some(tick) = tick {
                        process(tick)?;
                    }
                }
                if count == 0 {
                    break;
                }
            }
        }
    }
    if let Some(mut timeline) = timeline {
        timeline.finish(Some(unix_ms()));
        write_json(
            output_path.as_deref(),
            "auto-switcher-session",
            &timeline.timeline,
        )?;
    }
    Ok(())
}

fn process_realtime_event(
    output: &mut impl Write,
    director: &mut Director,
    llm: &mut Option<LlmRuntime>,
    mut timeline: Option<&mut TimelineRecorder>,
    input_format: InputFormat,
    event: StreamEvent,
) -> Result<()> {
    let generation = director.session_generation();
    let outputs = director.process_event(event.clone());
    if let Some(runtime) = llm.as_mut() {
        if matches!(event, StreamEvent::Reset { .. }) || generation != director.session_generation()
        {
            runtime.reset();
        }
        runtime.observe(&event, director.session_generation());
    }
    let tick_time = match &event {
        StreamEvent::Tick { time } => Some(*time),
        _ => None,
    };
    emit_events(output, &outputs)?;
    if let Some(timeline) = timeline.as_deref_mut() {
        timeline.record_event(event, outputs.clone());
    }
    if matches!(input_format, InputFormat::Pcm16le) {
        for item in &outputs {
            if let SwitcherOutput::Cut { instruction } = item {
                let ack = TimelineRecorder::assumed_acknowledgement(instruction);
                let follow_up = director.process_event(ack.clone());
                if let Some(timeline) = timeline.as_deref_mut() {
                    timeline.record_event(ack, follow_up);
                }
            }
        }
    }
    if let (Some(time), Some(runtime)) = (tick_time, llm.as_mut()) {
        let advisory = runtime.tick(time, &director.config, director.current_camera_id());
        emit_events(output, &advisory)?;
        if let Some(timeline) = timeline {
            if !advisory.is_empty() {
                timeline.record_event(StreamEvent::DirectorOutput, advisory);
            }
        }
    }
    Ok(())
}

fn emit_events(writer: &mut impl Write, outputs: &[SwitcherOutput]) -> Result<()> {
    for output in outputs {
        serde_json::to_writer(&mut *writer, output)?;
        writer.write_all(b"\n")?;
        writer.flush()?;
    }
    Ok(())
}

struct OfflineOptions {
    events: Option<PathBuf>,
    audio: Option<PathBuf>,
    transcript: Option<PathBuf>,
    video_cues: Option<PathBuf>,
    sample_rate: u32,
    chunk_ms: u32,
    speech_threshold: f32,
    output: Option<PathBuf>,
}

fn offline(options: OfflineOptions, config: SwitcherConfig) -> Result<()> {
    let mut input = match (options.events, options.audio) {
        (Some(events), None) => load_events_jsonl(&events)?,
        (None, Some(audio)) => events_from_audio_file(
            &audio,
            options.sample_rate,
            options.chunk_ms,
            options.speech_threshold,
        )?,
        (Some(_), Some(_)) => anyhow::bail!("choose --events or --audio, not both"),
        (None, None) => anyhow::bail!("offline mode requires --events or --audio"),
    };
    if let Some(transcript) = options.transcript {
        input.extend(load_transcript_jsonl(&transcript)?);
    }
    if let Some(video_cues) = options.video_cues {
        input.extend(load_video_jsonl(&video_cues)?);
    }
    let mut analysis = analyze_events(input, config)?;
    analysis
        .metadata
        .insert("source_mode".to_string(), "offline".to_string());
    if options.output.as_deref() == Some(Path::new("-")) {
        let mut stdout = BufWriter::new(io::stdout().lock());
        serde_json::to_writer_pretty(&mut stdout, &analysis)?;
        stdout.write_all(b"\n")?;
        stdout.flush()?;
    } else {
        write_json(
            options.output.as_deref(),
            "auto-switcher-analysis",
            &analysis,
        )?;
    }
    Ok(())
}

fn write_json<T: serde::Serialize>(path: Option<&Path>, prefix: &str, value: &T) -> Result<()> {
    let parent = path
        .and_then(Path::parent)
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)
        .with_context(|| format!("failed to create {}", parent.display()))?;
    let mut builder = tempfile::Builder::new();
    #[cfg(unix)]
    builder.permissions(std::fs::Permissions::from_mode(0o666));
    let mut file = builder
        .tempfile_in(parent)
        .with_context(|| format!("failed to create a temporary file in {}", parent.display()))?;
    {
        let mut writer = BufWriter::new(file.as_file_mut());
        serde_json::to_writer_pretty(&mut writer, value)?;
        writer.flush()?;
    }
    if let Some(path) = path {
        file.persist_noclobber(path)
            .with_context(|| format!("failed to save output {}", path.display()))?;
        return Ok(());
    }

    let stem = format!("{prefix}-{}", utc_datetime_stem());
    for suffix in 1..10_000 {
        let filename = if suffix == 1 {
            format!("{stem}.json")
        } else {
            format!("{stem}-{suffix}.json")
        };
        match file.persist_noclobber(&filename) {
            Ok(_) => return Ok(()),
            Err(error) if error.error.kind() == io::ErrorKind::AlreadyExists => file = error.file,
            Err(error) => return Err(error).with_context(|| format!("failed to save {filename}")),
        }
    }
    let filename = format!("{stem}-{}.json", Uuid::new_v4());
    file.persist_noclobber(&filename)
        .with_context(|| format!("failed to save {filename}"))?;
    Ok(())
}

fn utc_datetime_stem() -> String {
    let millis = unix_ms();
    let total_seconds = millis.div_euclid(1_000);
    let milliseconds = millis.rem_euclid(1_000);
    let days = total_seconds.div_euclid(86_400);
    let seconds = total_seconds.rem_euclid(86_400);
    let (year, month, day) = civil_date_from_days(days);
    let hour = seconds / 3_600;
    let minute = (seconds % 3_600) / 60;
    let second = seconds % 60;
    format!("{year:04}{month:02}{day:02}-{hour:02}{minute:02}{second:02}-{milliseconds:03}")
}

fn civil_date_from_days(days_since_epoch: i64) -> (i64, i64, i64) {
    let z = days_since_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 }.div_euclid(146_097);
    let day_of_era = z - era * 146_097;
    let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524
        - day_of_era / 146_096)
        .div_euclid(365);
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_part = (5 * day_of_year + 2).div_euclid(153);
    let day = day_of_year - (153 * month_part + 2).div_euclid(5) + 1;
    let month = month_part + if month_part < 10 { 3 } else { -9 };
    let year = year + if month <= 2 { 1 } else { 0 };
    (year, month, day)
}

fn unix_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

fn print_schema(name: SchemaName) -> Result<()> {
    let schemas = [
        (
            SchemaName::StreamEvent,
            include_str!("../schemas/stream-event.schema.json"),
        ),
        (
            SchemaName::SwitcherOutput,
            include_str!("../schemas/switcher-output.schema.json"),
        ),
        (
            SchemaName::SessionTimeline,
            include_str!("../schemas/session-timeline.schema.json"),
        ),
        (
            SchemaName::OfflineAnalysis,
            include_str!("../schemas/offline-analysis.schema.json"),
        ),
        (
            SchemaName::LlmContext,
            include_str!("../schemas/llm-context.schema.json"),
        ),
    ];
    for (schema_name, schema) in schemas {
        if matches!(name, SchemaName::All) || name == schema_name {
            println!("{schema}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use auto_switcher::llm::{LlmDecisionProvider, LlmProposal};
    use std::sync::mpsc::{channel, Receiver, Sender};

    struct ControlledAdvisor {
        requests: Sender<DecisionContext>,
        release: Receiver<()>,
    }

    impl LlmDecisionProvider for ControlledAdvisor {
        fn decide(&mut self, context: &DecisionContext) -> Result<LlmProposal> {
            self.requests.send(context.clone())?;
            self.release.recv()?;
            Ok(LlmProposal {
                target_camera_id: None,
                confidence: 1.0,
                reason: "hold".into(),
                hold: true,
            })
        }
    }

    #[test]
    fn reset_discards_completed_inflight_and_queued_advice() {
        let (requests, received) = channel();
        let (release, gate) = channel();
        let mut runtime = Some(LlmRuntime {
            advisor: DelayedLlmAdvisor::new(Box::new(ControlledAdvisor {
                requests,
                release: gate,
            })),
            delay: 10.0,
            last_submit_attempt: -f64::INFINITY,
            audio: VecDeque::new(),
            transcript: VecDeque::new(),
            video: VecDeque::new(),
        });
        let config = SwitcherConfig::default();
        let mut director = Director::new(config.clone()).unwrap();
        let mut timeline = TimelineRecorder::new(config, "realtime", Uuid::new_v4());
        let mut output = Vec::new();
        let mut send = |event| {
            process_realtime_event(
                &mut output,
                &mut director,
                &mut runtime,
                Some(&mut timeline),
                InputFormat::Jsonl,
                event,
            )
            .unwrap();
        };
        let next_request = || received.recv_timeout(Duration::from_secs(5)).unwrap();
        send(StreamEvent::Tick { time: -1.0 });
        send(StreamEvent::Tick { time: 0.0 });
        assert_eq!(next_request().media_time, 0.0);
        release.send(()).unwrap();
        send(StreamEvent::Tick { time: 1.0 });
        next_request(); // The worker finished the first request and is blocked on the second.
        send(StreamEvent::Tick { time: 2.0 }); // Buffer the first reply and queue a third request.
        send(StreamEvent::Reset {
            generation: Some(2),
        });
        let observation = VideoObservation {
            camera_id: "A".into(),
            time: 2.0,
            healthy: true,
            motion: 0.0,
            scene_change: 0.0,
            session_generation: 1,
        };
        send(StreamEvent::Video {
            observation: observation.clone(),
        });
        send(StreamEvent::Video {
            observation: VideoObservation {
                session_generation: 2,
                ..observation
            },
        });
        send(StreamEvent::Tick { time: 3.0 });
        release.send(()).unwrap();
        let fresh = next_request();
        assert_eq!(fresh.media_time, 3.0);
        assert_eq!(fresh.video.len(), 1);
        assert_eq!(fresh.video[0].session_generation, 2);
        release.send(()).unwrap();
        send(StreamEvent::Tick { time: 4.0 });
        next_request(); // The fresh reply is now available for the next poll.
        send(StreamEvent::Tick { time: 13.0 });
        let ids: Vec<_> = timeline
            .timeline
            .statuses
            .iter()
            .filter_map(|item| match item {
                SwitcherOutput::LlmAdvisory { request_id, .. } => Some(*request_id),
                _ => None,
            })
            .collect();
        assert_eq!(ids, [fresh.request_id]);
        let advisory_record = timeline.timeline.events.last().unwrap();
        assert_eq!(advisory_record.event, StreamEvent::DirectorOutput);
        assert!(matches!(
            advisory_record.outputs.as_slice(),
            [SwitcherOutput::LlmAdvisory { request_id, .. }] if *request_id == fresh.request_id
        ));
    }
}
