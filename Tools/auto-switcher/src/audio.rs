use crate::model::{AudioCue, StreamEvent};
use anyhow::{bail, Context, Result};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Take};
use std::path::Path;
use std::process::{Command, Stdio};

pub struct PcmCueDecoder {
    sample_rate: u32,
    chunk_frames: usize,
    threshold: f32,
    next_frame: u64,
    next_id: u64,
    speaking: bool,
    silence_frames: u64,
    pending_bytes: Vec<u8>,
}

impl PcmCueDecoder {
    pub fn new(sample_rate: u32, chunk_ms: u32, threshold: f32) -> Result<Self> {
        if sample_rate == 0
            || chunk_ms == 0
            || !threshold.is_finite()
            || !(0.0..=1.0).contains(&threshold)
        {
            bail!("sample rate, chunk duration, and threshold must be valid");
        }
        let chunk_frames =
            usize::try_from(((u64::from(sample_rate) * u64::from(chunk_ms)) / 1_000).max(1))
                .ok()
                .filter(|frames| *frames <= usize::MAX / 2)
                .context("PCM chunk size exceeds platform limits")?;
        Ok(Self {
            sample_rate,
            chunk_frames,
            threshold,
            next_frame: 0,
            next_id: 1,
            speaking: false,
            silence_frames: 0,
            pending_bytes: Vec::new(),
        })
    }

    pub fn push_pcm16le(&mut self, bytes: &[u8]) -> Vec<StreamEvent> {
        let mut pending = std::mem::take(&mut self.pending_bytes);
        pending.extend_from_slice(bytes);
        let chunk_bytes = self.chunk_frames * 2;
        let complete_bytes = pending.len() / chunk_bytes * chunk_bytes;
        let mut events = Vec::with_capacity(complete_bytes / chunk_bytes);
        for chunk in pending[..complete_bytes].chunks_exact(chunk_bytes) {
            events.push(self.make_cue(chunk));
        }
        pending.copy_within(complete_bytes.., 0);
        pending.truncate(pending.len() - complete_bytes);
        self.pending_bytes = pending;
        events
    }

    pub fn finish(&mut self) -> Vec<StreamEvent> {
        let mut events = Vec::new();
        let mut pending = std::mem::take(&mut self.pending_bytes);
        let complete_bytes = pending.len() / 2 * 2;
        if complete_bytes > 0 {
            events.push(self.make_cue(&pending[..complete_bytes]));
        }
        // Discard any odd trailing byte after emitting complete samples.
        pending.clear();
        self.pending_bytes = pending;
        if self.speaking {
            self.speaking = false;
            let id = self.next_id;
            self.next_id += 1;
            events.push(StreamEvent::Audio {
                cue: AudioCue {
                    id,
                    time: self.next_frame as f64 / self.sample_rate as f64,
                    duration: 0.0,
                    speech_energy: 0.0,
                    pause_duration: 0.0,
                    emphasis: 0.0,
                    laughter: 0.0,
                    speech_start: false,
                    speech_stop: true,
                    session_generation: 0,
                },
            });
        }
        events
    }

    fn make_cue(&mut self, bytes: &[u8]) -> StreamEvent {
        let (samples, _) = bytes.as_chunks::<2>();
        let energy = (samples
            .iter()
            .map(|sample| (i16::from_le_bytes(*sample) as f32 / i16::MAX as f32).powi(2))
            .sum::<f32>()
            / samples.len() as f32)
            .sqrt()
            .min(1.0);
        let duration = samples.len() as f64 / self.sample_rate as f64;
        let time = self.next_frame as f64 / self.sample_rate as f64;
        self.next_frame += samples.len() as u64;
        let is_speech = energy >= self.threshold;
        let was_speaking = self.speaking;
        let speech_start = is_speech && !was_speaking;
        let speech_stop = !is_speech && was_speaking;
        if is_speech {
            self.speaking = true;
            self.silence_frames = 0;
        } else {
            self.silence_frames += samples.len() as u64;
            self.speaking = false;
        }
        let pause_duration = if !is_speech {
            self.silence_frames as f64 / self.sample_rate as f64
        } else {
            0.0
        };
        let cue = AudioCue {
            id: self.next_id,
            time,
            duration,
            speech_energy: energy,
            pause_duration,
            emphasis: energy,
            laughter: 0.0,
            speech_start,
            speech_stop,
            session_generation: 0,
        };
        self.next_id += 1;
        StreamEvent::Audio { cue }
    }
}

pub(crate) struct WavPcm {
    pcm: Take<File>,
    pub sample_rate: u32,
}

impl Read for WavPcm {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count = self.pcm.read(buffer)?;
        if count == 0 && !buffer.is_empty() && self.pcm.limit() != 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "truncated WAV data",
            ));
        }
        Ok(count)
    }
}

pub(crate) fn open_wav_pcm(path: &Path) -> Result<WavPcm> {
    let mut file =
        File::open(path).with_context(|| format!("failed to open WAV {}", path.display()))?;
    let file_len = file.metadata()?.len();
    let mut header = [0; 12];
    file.read_exact(&mut header)
        .context("truncated WAV header")?;
    if &header[..4] != b"RIFF" || &header[8..] != b"WAVE" {
        bail!("{} is not a RIFF/WAVE file", path.display());
    }
    let end = 8 + u64::from(u32::from_le_bytes(header[4..8].try_into()?));
    if end < 12 || end > file_len {
        bail!("truncated WAV container");
    }

    let mut cursor = 12;
    let mut format = None;
    let mut data = None;
    while cursor < end {
        let mut chunk_header = [0; 8];
        if end - cursor < chunk_header.len() as u64 {
            bail!("truncated WAV chunk header");
        }
        file.seek(SeekFrom::Start(cursor))?;
        file.read_exact(&mut chunk_header)
            .context("truncated WAV chunk header")?;
        let id = &chunk_header[..4];
        let size = u64::from(u32::from_le_bytes(chunk_header[4..].try_into()?));
        let offset = cursor + chunk_header.len() as u64;
        cursor = offset + size + (size % 2);
        if cursor > end {
            bail!("truncated WAV chunk");
        }
        match id {
            b"fmt " if size >= 16 => {
                let mut pcm_format = [0; 16];
                file.read_exact(&mut pcm_format)
                    .context("truncated WAV format")?;
                if u16::from_le_bytes(pcm_format[..2].try_into()?) != 1 {
                    bail!("only PCM WAV input is supported");
                }
                let channels = u16::from_le_bytes(pcm_format[2..4].try_into()?);
                let sample_rate = u32::from_le_bytes(pcm_format[4..8].try_into()?);
                let bits_per_sample = u16::from_le_bytes(pcm_format[14..16].try_into()?);
                format = Some((channels, sample_rate, bits_per_sample));
            }
            b"data" => data = Some((offset, size)),
            _ => {}
        }
    }

    let (channels, sample_rate, bits_per_sample) = format.context("WAV fmt chunk missing")?;
    if channels != 1 || bits_per_sample != 16 {
        bail!("WAV input must be mono 16-bit PCM");
    }
    if sample_rate == 0 {
        bail!("WAV sample rate must be positive");
    }
    let (offset, size) = data.context("WAV data chunk missing")?;
    if size % 2 != 0 {
        bail!("truncated 16-bit sample in WAV data");
    }
    file.seek(SeekFrom::Start(offset))?;
    Ok(WavPcm {
        pcm: file.take(size),
        sample_rate,
    })
}

pub fn decode_wav(path: &Path) -> Result<(u32, Vec<u8>)> {
    let mut wav = open_wav_pcm(path)?;
    let mut bytes = Vec::new();
    wav.read_to_end(&mut bytes)?;
    Ok((wav.sample_rate, bytes))
}

pub(crate) fn with_media_audio<T>(
    path: &Path,
    sample_rate: u32,
    consume: impl FnOnce(&mut dyn Read) -> Result<T>,
) -> Result<T> {
    let mut child = Command::new("ffmpeg")
        .args(["-v", "error", "-xerror", "-nostdin", "-i"])
        .arg(path)
        .args(["-f", "s16le", "-ac", "1", "-ar"])
        .arg(sample_rate.to_string())
        .arg("pipe:1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to start ffmpeg; install ffmpeg or use a WAV file")?;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let mut stderr = child.stderr.take().expect("piped stderr");
    let diagnostics = std::thread::Builder::new()
        .name("auto-switcher-ffmpeg-stderr".into())
        .spawn(move || -> io::Result<Vec<u8>> {
            // Drain stderr concurrently even after reaching the diagnostic limit.
            let mut message = Vec::new();
            stderr.by_ref().take(16 * 1024).read_to_end(&mut message)?;
            io::copy(&mut stderr, &mut io::sink())?;
            Ok(message)
        });
    let diagnostics = match diagnostics {
        Ok(thread) => thread,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error).context("failed to start ffmpeg diagnostic reader");
        }
    };
    let result = consume(&mut stdout);
    drop(stdout);
    if result.is_err() {
        let _ = child.kill();
    }
    let status = child.wait();
    let stderr = diagnostics.join();
    let value = result?;
    let status = status.context("failed to wait for ffmpeg")?;
    let stderr = stderr
        .map_err(|_| anyhow::anyhow!("ffmpeg diagnostic reader panicked"))?
        .context("failed to read ffmpeg diagnostics")?;
    if !status.success() {
        let message = String::from_utf8_lossy(&stderr);
        bail!("ffmpeg failed ({status}): {}", message.trim_end());
    }
    Ok(value)
}

pub fn decode_media_audio(path: &Path, sample_rate: u32) -> Result<Vec<u8>> {
    with_media_audio(path, sample_rate, |reader| {
        let mut bytes = Vec::new();
        reader.read_to_end(&mut bytes)?;
        Ok(bytes)
    })
}
