use auto_switcher::audio::decode_wav;
use auto_switcher::offline::{events_from_audio_file, events_from_pcm};
use std::io::Write;

fn wav_chunk(output: &mut Vec<u8>, id: &[u8; 4], payload: &[u8]) {
    output.extend(id);
    output.extend((payload.len() as u32).to_le_bytes());
    output.extend(payload);
    if !payload.len().is_multiple_of(2) {
        output.push(0);
    }
}

fn wav(pcm: &[u8], sample_rate: u32) -> Vec<u8> {
    let mut body = b"WAVE".to_vec();
    // The legacy loader accepts data before the format and the last data chunk.
    wav_chunk(&mut body, b"data", &[0, 0]);
    wav_chunk(&mut body, b"JUNK", b"odd");
    wav_chunk(&mut body, b"data", pcm);
    let mut format = Vec::new();
    format.extend(1_u16.to_le_bytes());
    format.extend(1_u16.to_le_bytes());
    format.extend(sample_rate.to_le_bytes());
    format.extend((sample_rate * 2).to_le_bytes());
    format.extend(2_u16.to_le_bytes());
    format.extend(16_u16.to_le_bytes());
    wav_chunk(&mut body, b"fmt ", &format);
    wav_chunk(&mut body, b"LIST", b"INFO");

    let mut output = b"RIFF".to_vec();
    output.extend((body.len() as u32).to_le_bytes());
    output.extend(body);
    output
}

#[test]
fn streamed_wav_matches_raw_pcm_across_reads_and_chunk_layouts() {
    let sample_rate = 16_000;
    let pcm: Vec<_> = (0..17_003)
        .flat_map(|sample| {
            let value: i16 = if sample % 3200 < 1600 { 0 } else { 20_000 };
            value.to_le_bytes()
        })
        .collect();
    let mut file = tempfile::Builder::new().suffix(".wav").tempfile().unwrap();
    file.write_all(&wav(&pcm, sample_rate)).unwrap();

    let expected = events_from_pcm(&pcm, sample_rate, 17, 0.025).unwrap();
    // WAV carries its own sample rate.
    assert_eq!(
        events_from_audio_file(file.path(), 8_000, 17, 0.025).unwrap(),
        expected
    );
    assert_eq!(decode_wav(file.path()).unwrap(), (sample_rate, pcm));
}

#[test]
fn streamed_wav_rejects_truncated_chunks_and_partial_samples() {
    let mut truncated = wav(&[0; 1024], 16_000);
    truncated.truncate(100);
    for (input, message) in [
        (truncated, "truncated WAV container"),
        (wav(&[0, 0, 0], 16_000), "truncated 16-bit sample"),
    ] {
        let mut file = tempfile::Builder::new().suffix(".wav").tempfile().unwrap();
        file.write_all(&input).unwrap();
        let error = events_from_audio_file(file.path(), 16_000, 20, 0.025).unwrap_err();
        assert!(format!("{error:#}").contains(message), "{error:#}");
    }
}

#[cfg(unix)]
#[test]
fn ffmpeg_drains_diagnostics_and_discards_partial_output_on_error() {
    use std::os::unix::fs::PermissionsExt;
    use std::process::Command;

    let workspace = tempfile::tempdir().unwrap();
    let ffmpeg = workspace.path().join("ffmpeg");
    let output = workspace.path().join("result.json");
    for (code, message) in [(0, "test notice"), (23, "test decode failure")] {
        std::fs::write(
            &ffmpeg,
            format!(
                "#!/bin/sh\nprintf '\\001\\000\\002\\000'\nprintf '%s\\n' '{message}' >&2\nprintf '%131072s' ' ' >&2\nexit {code}\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(&ffmpeg, std::fs::Permissions::from_mode(0o700)).unwrap();
        let result = Command::new(env!("CARGO_BIN_EXE_auto-switcher"))
            .env("PATH", workspace.path())
            .args(["offline", "--audio", "input.flac", "--output"])
            .arg(&output)
            .output()
            .unwrap();
        if code == 0 {
            assert!(result.status.success(), "{:?}", result.stderr);
            let timeline: auto_switcher::SessionTimeline =
                serde_json::from_reader(std::fs::File::open(&output).unwrap()).unwrap();
            assert_eq!(timeline.events_processed, 2);
            std::fs::remove_file(&output).unwrap();
        } else {
            assert!(!result.status.success());
            let error = String::from_utf8(result.stderr).unwrap();
            assert!(error.contains(message), "{error}");
            assert!(error.contains("23"), "{error}");
            assert!(!output.exists());
        }
    }
}
