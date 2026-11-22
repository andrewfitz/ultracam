use auto_switcher::{SessionTimeline, StreamEvent, SwitcherOutput};
use std::io::{Seek, Write};

fn pcm_input(bytes: &[u8]) -> Stdio {
    let mut file = tempfile::tempfile().unwrap();
    file.write_all(bytes).unwrap();
    file.rewind().unwrap();
    Stdio::from(file)
}
use std::process::{Command, Stdio};

fn realtime(format: &str, input: &[u8]) -> (SessionTimeline, Vec<SwitcherOutput>) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let child = Command::new(env!("CARGO_BIN_EXE_auto-switcher"))
        .args([
            "realtime",
            "--input-format",
            format,
            "--sample-rate",
            "100",
            "--output",
        ])
        .arg(&path)
        .stdin(pcm_input(input))
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let timeline = serde_json::from_reader(std::fs::File::open(path).unwrap()).unwrap();
    let outputs = serde_json::Deserializer::from_slice(&output.stdout)
        .into_iter::<SwitcherOutput>()
        .collect::<Result<_, _>>()
        .unwrap();
    (timeline, outputs)
}

#[test]
fn raw_pcm_advances_each_cut_and_records_its_assumed_application() {
    let (timeline, outputs) = realtime("pcm16le", &vec![0; 75 * 100 * 2]);
    assert_eq!(
        timeline.metadata["cut_application"],
        "assumed_at_requested_time"
    );
    assert!(outputs.len() >= 2);
    assert_eq!(outputs.len(), timeline.cuts.len());
    let acks: Vec<_> = timeline
        .events
        .iter()
        .filter_map(|entry| match entry.event {
            StreamEvent::Acknowledge {
                decision_id,
                applied_at,
            } => Some((decision_id, applied_at)),
            _ => None,
        })
        .collect();
    assert_eq!(acks.len(), timeline.cuts.len());
    for (index, cut) in timeline.cuts.iter().enumerate() {
        let SwitcherOutput::Cut { instruction } = &outputs[index] else {
            panic!("expected a cut");
        };
        assert_eq!(cut.target_camera_id, if index % 2 == 0 { "B" } else { "A" });
        assert_eq!(cut.status, "applied");
        assert_eq!(cut.decision_id, Some(instruction.decision_id));
        assert_eq!(cut.applied_program_time, Some(instruction.cut_time));
        assert_eq!(
            acks[index],
            (instruction.decision_id, Some(instruction.cut_time))
        );
    }
}

#[test]
fn realtime_jsonl_leaves_cut_application_to_host() {
    let (timeline, outputs) = realtime("jsonl", b"{\"type\":\"tick\",\"time\":75}\n");
    assert_eq!(outputs.len(), 1);
    assert!(matches!(outputs[0], SwitcherOutput::Cut { .. }));
    assert!(!timeline.metadata.contains_key("cut_application"));
    assert_eq!(timeline.events.len(), 1);
    assert_eq!(timeline.cuts[0].status, "cancelled");
    assert!(timeline.cuts[0].applied_program_time.is_none());
}

#[test]
fn offline_reports_an_existing_path_without_overwriting_it() {
    let dir = tempfile::tempdir().unwrap();
    let input = dir.path().join("events.jsonl");
    let output = dir.path().join("session.json");
    std::fs::write(&input, b"{\"type\":\"tick\",\"time\":0}\n").unwrap();
    std::fs::write(&output, b"existing result").unwrap();
    let run = Command::new(env!("CARGO_BIN_EXE_auto-switcher"))
        .args(["offline", "--events"])
        .arg(input)
        .arg("--output")
        .arg(&output)
        .output()
        .unwrap();
    assert!(!run.status.success());
    assert_eq!(std::fs::read(output).unwrap(), b"existing result");
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 2);
}

#[test]
fn pcm_stdout_only_still_applies_each_simulated_cut() {
    let child = Command::new(env!("CARGO_BIN_EXE_auto-switcher"))
        .args([
            "realtime",
            "--input-format",
            "pcm16le",
            "--sample-rate",
            "100",
            "--output",
            "-",
        ])
        .stdin(pcm_input(&vec![0; 75 * 100 * 2]))
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let targets: Vec<_> = serde_json::Deserializer::from_slice(&output.stdout)
        .into_iter::<SwitcherOutput>()
        .map(|item| match item.unwrap() {
            SwitcherOutput::Cut { instruction } => instruction.target_camera_id,
            _ => panic!("expected only JSONL cut instructions"),
        })
        .collect();
    assert!(targets.len() >= 2);
    assert_eq!(&targets[..2], ["B", "A"]);
}

#[test]
fn jsonl_cue_that_overflows_float_does_not_corrupt_the_ledger() {
    let (timeline, _) = realtime(
        "jsonl",
        br#"{"type":"audio","cue":{"id":1,"time":0,"speech_energy":1e50}}
{"type":"tick","time":0}
"#,
    );
    assert_eq!(timeline.events.len(), 1);
    assert_eq!(timeline.events[0].event, StreamEvent::Tick { time: 0.0 });
    assert!(matches!(
        timeline.statuses.as_slice(),
        [SwitcherOutput::Error { .. }]
    ));
}

#[test]
fn invalid_jsonl_line_still_saves_the_ledger_received_before_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let output = Command::new(env!("CARGO_BIN_EXE_auto-switcher"))
        .args(["realtime", "--input-format", "jsonl", "--output"])
        .arg(&path)
        .stdin(pcm_input(b"{\"type\":\"tick\",\"time\":75}\n{\"type\":\"unknown\"}\n"))
        .output()
        .unwrap();
    assert!(!output.status.success(), "the invalid line is still reported");
    let timeline: SessionTimeline =
        serde_json::from_reader(std::fs::File::open(&path).expect("ledger saved")).unwrap();
    assert_eq!(timeline.events.len(), 1);
    assert_eq!(timeline.events[0].event, StreamEvent::Tick { time: 75.0 });
    assert_eq!(timeline.cuts.len(), 1);
    assert_eq!(timeline.cuts[0].status, "cancelled");
    assert!(timeline.ended_at_unix_ms.is_some());
}
