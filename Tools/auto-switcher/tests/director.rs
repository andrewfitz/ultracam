use auto_switcher::audio::PcmCueDecoder;
use auto_switcher::director::DirectorState;
use auto_switcher::model::{
    AudioCue, CueKind, CutReason, StreamEvent, SwitcherConfig, TranscriptCue,
};
use auto_switcher::{Director, SwitcherOutput, TimelineRecorder};
use uuid::Uuid;

fn config() -> SwitcherConfig {
    SwitcherConfig {
        minimum_shot_duration: 0.0,
        cooldown: 0.0,
        emphasis_hold: 0.0,
        soft_maximum_shot_duration: 2.0,
        candidate_dwell: 0.0,
        boundary_window: 0.3,
        maximum_shot_duration: 3.0,
        forced_cut_grace_period: 1.0,
        forced_boundary_lookback: 0.5,
        ..SwitcherConfig::default()
    }
}

#[test]
fn default_minimum_shot_duration_is_ten_seconds() {
    assert_eq!(SwitcherConfig::default().minimum_shot_duration, 10.0);
}

fn audio(time: f64, emphasis: f32, pause_duration: f64) -> StreamEvent {
    StreamEvent::Audio {
        cue: AudioCue {
            id: (time * 100.0) as u64,
            time,
            duration: 0.02,
            speech_energy: emphasis,
            pause_duration,
            emphasis,
            laughter: 0.0,
            speech_start: false,
            speech_stop: false,
            session_generation: 0,
        },
    }
}

#[test]
fn normal_cut_is_emitted_and_acknowledged_once() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(audio(1.0, 1.0, 0.0));
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.95,
            is_final: true,
            session_generation: 0,
        },
    });
    let output = director.process_event(StreamEvent::Tick { time: 1.0 });
    let instruction = match &output[0] {
        auto_switcher::SwitcherOutput::Cut { instruction } => instruction.clone(),
        other => panic!("unexpected output: {other:?}"),
    };
    assert_eq!(instruction.target_camera_id, "B");
    assert!(!instruction.forced);
    assert!(director.acknowledge(instruction.decision_id, Some(1.0)));
    assert!(!director.acknowledge(instruction.decision_id, Some(1.0)));
    assert_eq!(director.current_camera_id(), "B");
}

#[test]
fn hard_maximum_prefers_nearest_gap_then_uses_absolute_cap() {
    let mut director = Director::new(config()).expect("valid config");
    assert!(director.tick(3.0).is_none());
    assert_eq!(director.state(), DirectorState::ForcedCutPending);
    director.process_event(audio(3.5, 0.0, 0.3));
    let instruction = director.tick(3.5).expect("gap in forced grace should cut");
    assert!(instruction.forced);
    assert_eq!(instruction.reason, CutReason::ForcedMaximumShotDuration);
    assert_eq!(instruction.cut_time, 3.5);
    assert!(director.acknowledge(instruction.decision_id, Some(3.5)));

    let mut second = Director::new(config()).expect("valid config");
    assert!(
        second.tick(4.1).is_some(),
        "absolute cap must not wait indefinitely"
    );
}

#[test]
fn revised_transcript_replaces_non_final_cue_without_duplicate_cut() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.5,
            is_final: false,
            session_generation: 0,
        },
    });
    director.process_event(audio(1.0, 1.0, 0.0));
    assert!(director.tick(1.0).is_none());
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 2,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.95,
            is_final: true,
            session_generation: 0,
        },
    });
    let instruction = director
        .tick(1.0)
        .expect("final revision should become eligible");
    assert!(director.acknowledge(instruction.decision_id, Some(1.0)));
    assert!(director.tick(1.1).is_none());
}

#[test]
fn pcm_decoder_handles_arbitrary_realtime_read_boundaries() {
    let mut decoder = PcmCueDecoder::new(1_000, 20, 0.01).expect("valid decoder");
    let sample = 20_000_i16.to_le_bytes();
    let bytes: Vec<u8> = std::iter::repeat_n(sample, 40).flatten().collect();
    let mut events = Vec::new();
    for byte in bytes {
        events.extend(decoder.push_pcm16le(&[byte]));
    }
    assert_eq!(events.len(), 2);
    assert!(matches!(
        events[0],
        auto_switcher::StreamEvent::Audio { .. }
    ));
}

#[test]
fn stale_audio_falls_back_from_emphasis_to_anchor() {
    let mut director = Director::new(config()).expect("valid config");
    director.manual_override("B".to_string(), 1.0);
    let instruction = director.tick(3.0).expect("stale audio should fallback");
    assert_eq!(instruction.target_camera_id, "A");
    assert_eq!(instruction.reason, CutReason::AudioDegradedFallback);
}

#[test]
fn invalid_video_and_ack_times_do_not_poison_director_state() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(StreamEvent::Video {
        observation: auto_switcher::VideoObservation {
            time: f64::NAN,
            camera_id: "A".into(),
            healthy: false,
            motion: 0.0,
            scene_change: 0.0,
            session_generation: 0,
        },
    });
    assert!(director.tick(1.0).is_none());
    director.manual_override("B".into(), 1.0);
    let instruction = director.tick(4.0).expect("stale audio fallback");
    assert!(!director.acknowledge(instruction.decision_id, Some(f64::NAN)));
    assert!(director.pending().is_some());
    assert!(director.acknowledge(instruction.decision_id, Some(4.0)));
}

#[test]
fn candidate_dwell_starts_when_candidate_is_observed() {
    let mut cfg = config();
    cfg.candidate_dwell = 1.0;
    let mut director = Director::new(cfg).expect("valid config");
    director.process_event(audio(1.1, 1.0, 0.0));
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "late".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 1.0,
            is_final: true,
            session_generation: 0,
        },
    });
    assert!(director.tick(1.1).is_none());
    assert!(director.tick(1.9).is_none());
    assert!(director.tick(2.2).is_some());
}

#[test]
fn backward_clock_keeps_the_current_camera_and_shot_age() {
    let mut cfg = config();
    cfg.maximum_shot_duration = 30.0;
    cfg.soft_maximum_shot_duration = 20.0;
    cfg.forced_cut_grace_period = 2.0;
    let mut director = Director::new(cfg).expect("valid config");
    director.manual_override("B".to_string(), 1.0);
    // Keep a live audio cue so the emphasis camera is not treated as silent.
    director.process_event(audio(25.0, 0.1, 0.0));
    assert!(director.tick(25.0).is_none());
    assert_eq!(director.current_camera_id(), "B");
    assert!(
        director.tick(24.5).is_none(),
        "a small backward step must not manufacture a cut"
    );
    assert_eq!(director.current_camera_id(), "B");
    assert_eq!(director.session_generation(), 2);
    director.process_event(audio(34.0, 0.1, 0.0));
    assert!(
        director.tick(34.0).is_none(),
        "shot age restarts at the discontinuity, not at zero"
    );
}

#[test]
fn backward_clock_expires_a_pending_cut_without_replacing_it() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(audio(1.0, 1.0, 0.0));
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.95,
            is_final: true,
            session_generation: 0,
        },
    });
    let first = director.process_event(StreamEvent::Tick { time: 1.0 });
    assert!(matches!(
        first.first(),
        Some(auto_switcher::SwitcherOutput::Cut { .. })
    ));
    let output = director.process_event(StreamEvent::Tick { time: 0.2 });
    assert!(
        output.iter().any(|item| matches!(
            item,
            auto_switcher::SwitcherOutput::DecisionExpired { .. }
        )),
        "the pending decision belongs to the old clock: {output:?}"
    );
    assert!(
        output
            .iter()
            .all(|item| !matches!(item, auto_switcher::SwitcherOutput::Cut { .. })),
        "a discontinuity must not immediately request another cut: {output:?}"
    );
    assert_eq!(director.current_camera_id(), "A");
    assert!(director.pending().is_none());
}

#[test]
fn unhealthy_current_camera_cuts_to_the_other_camera() {
    let mut director = Director::new(config()).expect("valid config");
    director.manual_override("B".to_string(), 1.0);
    director.ingest_video(auto_switcher::VideoObservation {
        time: 1.2,
        camera_id: "B".into(),
        healthy: false,
        motion: 0.0,
        scene_change: 0.0,
        session_generation: 0,
    });
    let instruction = director.tick(1.2).expect("health fallback");
    assert_eq!(instruction.target_camera_id, "A");
    assert_eq!(instruction.reason, CutReason::CameraHealthFallback);
    assert!(instruction.forced);
}

#[test]
fn unhealthy_pending_target_is_dropped_instead_of_cut() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(audio(1.0, 1.0, 0.0));
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.95,
            is_final: true,
            session_generation: 0,
        },
    });
    assert!(matches!(
        director
            .process_event(StreamEvent::Tick { time: 1.0 })
            .first(),
        Some(auto_switcher::SwitcherOutput::Cut { .. })
    ));
    director.ingest_video(auto_switcher::VideoObservation {
        time: 1.0,
        camera_id: "B".into(),
        healthy: false,
        motion: 0.0,
        scene_change: 0.0,
        session_generation: 0,
    });
    let output = director.process_event(StreamEvent::Tick { time: 1.0 });
    assert!(output.iter().any(|item| matches!(
        item,
        auto_switcher::SwitcherOutput::DecisionExpired { .. }
    )));
    assert!(output
        .iter()
        .all(|item| !matches!(item, auto_switcher::SwitcherOutput::Cut { .. })));
    assert_eq!(director.current_camera_id(), "A");
}

#[test]
fn acknowledge_does_not_pull_the_live_clock_forward() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(audio(1.0, 1.0, 0.0));
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.95,
            is_final: true,
            session_generation: 0,
        },
    });
    let instruction = director.tick(1.0).expect("cut");
    assert!(director.acknowledge(instruction.decision_id, Some(5.0)));
    assert!(director.tick(1.2).is_none());
    assert_eq!(
        director.session_generation(),
        1,
        "acking a later boundary must not make the next cue discontinuous"
    );
}

#[test]
fn manual_override_accepts_a_recent_lagging_clock() {
    let mut cfg = config();
    cfg.maximum_shot_duration = 30.0;
    cfg.soft_maximum_shot_duration = 20.0;
    let mut director = Director::new(cfg).expect("valid config");
    assert!(director.tick(10.0).is_none());
    director.manual_override("B".to_string(), 9.5);
    assert_eq!(director.current_camera_id(), "B");
}

#[test]
fn clock_reset_accepts_generation_zero_cues_after_advancing_session() {
    let mut director = Director::new(config()).expect("valid config");
    assert!(director.tick(1.0).is_none());
    assert!(director.tick(0.5).is_none());
    assert_eq!(director.session_generation(), 2);
    director.ingest_audio(auto_switcher::AudioCue {
        id: 1,
        time: 0.5,
        duration: 0.02,
        speech_energy: 0.5,
        pause_duration: 0.0,
        emphasis: 0.5,
        laughter: 0.0,
        speech_start: true,
        speech_stop: false,
        session_generation: 0,
    });
    assert!(director.tick(0.5).is_none());
}

fn record_with_director(
    director: &mut Director,
    recorder: &mut TimelineRecorder,
    event: StreamEvent,
) -> Vec<SwitcherOutput> {
    let outputs = director.process_event(event.clone());
    recorder.record_event(event, outputs.clone());
    outputs
}

#[test]
fn recorder_matches_accepted_and_rejected_manual_overrides() {
    for (camera, requested, applied) in [
        ("B", 12.0, Some(12.0)),
        ("B", 10.0, Some(10.0)),
        ("B", 9.5, Some(10.0)),
        ("B", 8.0, Some(10.0)), // Exactly two seconds behind is accepted.
        ("A", 9.5, Some(10.0)), // Same-camera acceptance still clears pending.
        ("B", 7.99, None),
        ("A", 7.99, None),
        ("B", 0.0, None),
        ("unknown", 10.0, None),
        ("B", -1.0, None),
        ("B", f64::NAN, None),
        ("B", f64::INFINITY, None),
    ] {
        let cfg = config();
        let mut director = Director::new(cfg.clone()).unwrap();
        let mut recorder = TimelineRecorder::new(cfg, "realtime", Uuid::new_v4());
        record_with_director(
            &mut director,
            &mut recorder,
            StreamEvent::Tick { time: 10.0 },
        );
        let pending = director.pending().expect("forced cut").clone();
        assert_eq!(recorder.timeline.cuts.len(), 1);

        let outputs = record_with_director(
            &mut director,
            &mut recorder,
            StreamEvent::ManualOverride {
                camera_id: camera.into(),
                time: requested,
            },
        );
        if let Some(time) = applied {
            assert!(matches!(outputs.as_slice(), [SwitcherOutput::Status {
                time: applied_at, current_camera_id, pending_decision_id: None, ..
            }] if *applied_at == time && current_camera_id == camera));
            assert_eq!(director.current_camera_id(), camera);
            assert!(director.pending().is_none());
            assert_eq!(recorder.timeline.cuts[0].status, "cancelled");
            assert_eq!(recorder.timeline.cuts.len(), 2);
            let cut = &recorder.timeline.cuts[1];
            assert_eq!(cut.from_camera_id.as_deref(), Some("A"));
            assert_eq!(cut.target_camera_id, camera);
            assert_eq!(cut.status, "applied");
            assert_eq!(cut.requested_cut_time, Some(time));
            assert_eq!(cut.applied_source_time, Some(time));
            assert_eq!(cut.applied_program_time, Some(time));
            let ticks = Some(auto_switcher::timeline::to_ticks(time, 60_000));
            assert_eq!(cut.requested_cut_time_ticks, ticks);
            assert_eq!(cut.applied_source_time_ticks, ticks);
            assert_eq!(cut.applied_program_time_ticks, ticks);
        } else {
            assert!(
                outputs.is_empty(),
                "rejected override: {camera} at {requested}"
            );
            assert_eq!(director.current_camera_id(), "A");
            assert_eq!(director.pending().unwrap().decision_id, pending.decision_id);
            assert_eq!(recorder.timeline.cuts.len(), 1);
            assert_eq!(recorder.timeline.cuts[0].status, "proposed");
        }

        record_with_director(
            &mut director,
            &mut recorder,
            StreamEvent::Acknowledge {
                decision_id: pending.decision_id,
                applied_at: Some(10.0),
            },
        );
        assert_eq!(
            recorder.timeline.cuts[0].status,
            if applied.is_some() {
                "cancelled"
            } else {
                "applied"
            },
            "a late acknowledgement must not resurrect a cancelled cut"
        );
        let current = director.current_camera_id().to_string();
        record_with_director(
            &mut director,
            &mut recorder,
            StreamEvent::Tick { time: 20.0 },
        );
        assert_eq!(
            recorder
                .timeline
                .cuts
                .last()
                .unwrap()
                .from_camera_id
                .as_deref(),
            Some(current.as_str()),
            "recorder and director must retain the same current camera"
        );
    }
}

#[test]
fn recorder_drops_pending_cuts_when_director_resets_or_expires_them() {
    for cause in ["reset", "deadline", "clock", "health"] {
        let cfg = config();
        let mut director = Director::new(cfg.clone()).unwrap();
        let mut recorder = TimelineRecorder::new(cfg, "realtime", Uuid::new_v4());
        record_with_director(
            &mut director,
            &mut recorder,
            StreamEvent::Tick { time: 10.0 },
        );
        let pending = director.pending().unwrap().clone();
        if cause == "health" {
            record_with_director(
                &mut director,
                &mut recorder,
                StreamEvent::Video {
                    observation: auto_switcher::VideoObservation {
                        time: 10.0,
                        camera_id: "B".into(),
                        healthy: false,
                        motion: 0.0,
                        scene_change: 0.0,
                        session_generation: 0,
                    },
                },
            );
        }
        let event = match cause {
            "reset" => StreamEvent::Reset { generation: None },
            "deadline" => StreamEvent::Tick {
                time: pending.expires_at + 0.1,
            },
            "clock" => StreamEvent::Tick { time: 9.0 },
            "health" => StreamEvent::Tick { time: 10.0 },
            _ => unreachable!(),
        };
        record_with_director(&mut director, &mut recorder, event);
        let status = if cause == "reset" {
            "cancelled"
        } else {
            "expired"
        };
        assert_eq!(recorder.timeline.cuts[0].status, status, "{cause}");
        assert_ne!(
            director.pending().map(|cut| cut.decision_id),
            Some(pending.decision_id)
        );
        record_with_director(
            &mut director,
            &mut recorder,
            StreamEvent::Acknowledge {
                decision_id: pending.decision_id,
                applied_at: Some(10.0),
            },
        );
        assert_eq!(recorder.timeline.cuts[0].status, status, "{cause}");
        assert_eq!(director.current_camera_id(), "A", "{cause}");
    }
}

#[test]
fn offline_sorts_untimed_events_after_timed_events_and_preserves_time_zero() {
    let unknown_decision = Uuid::new_v4();
    let untimed = vec![
        StreamEvent::Reset {
            generation: Some(7),
        },
        StreamEvent::Acknowledge {
            decision_id: unknown_decision,
            applied_at: None,
        },
        StreamEvent::Reject {
            decision_id: unknown_decision,
        },
        StreamEvent::Reset { generation: None },
    ];
    let mut events = untimed.clone();
    events.extend([
        StreamEvent::Tick { time: 1.0 },
        StreamEvent::ManualOverride {
            camera_id: "B".into(),
            time: 0.0,
        },
    ]);
    let timeline =
        auto_switcher::offline::analyze_events(events, SwitcherConfig::default()).unwrap();
    let first = &timeline.events[0];
    assert!(matches!(
        first.event,
        StreamEvent::ManualOverride { time: 0.0, .. }
    ));
    assert_eq!(first.media_time, Some(0.0));
    assert_eq!(first.media_time_ticks, Some(0));
    assert_eq!(timeline.cuts.len(), 1);
    assert_eq!(timeline.cuts[0].session_generation, 1);
    assert_eq!(timeline.cuts[0].applied_source_time, Some(0.0));
    assert_eq!(timeline.cuts[0].applied_program_time_ticks, Some(0));
    assert_eq!(timeline.cuts[0].status, "applied");
    let first_untimed = timeline
        .events
        .iter()
        .position(|event| event.media_time.is_none())
        .unwrap();
    assert!(timeline.events[..first_untimed]
        .iter()
        .all(|event| event.media_time.is_some()));
    assert_eq!(
        timeline.events[first_untimed..]
            .iter()
            .map(|event| event.event.clone())
            .collect::<Vec<_>>(),
        untimed,
        "untimed events retain their input order"
    );
    assert!(timeline.events[first_untimed..]
        .iter()
        .all(|event| event.media_time_ticks.is_none()));
    assert_eq!(
        timeline.config.session_generation, 8,
        "both resets must execute"
    );
}

#[test]
fn reset_at_clock_zero_still_resets_the_director_and_recorder() {
    let cfg = SwitcherConfig::default();
    let mut director = Director::new(cfg.clone()).unwrap();
    let mut recorder = TimelineRecorder::new(cfg, "realtime", Uuid::new_v4());
    record_with_director(
        &mut director,
        &mut recorder,
        StreamEvent::ManualOverride {
            camera_id: "B".into(),
            time: 0.0,
        },
    );
    assert_eq!(director.current_camera_id(), "B");
    record_with_director(
        &mut director,
        &mut recorder,
        StreamEvent::Reset { generation: None },
    );
    assert_eq!(director.current_camera_id(), "A");
    assert_eq!(director.session_generation(), 2);
    assert_eq!(recorder.timeline.config.session_generation, 2);
    let reset = recorder.timeline.events.last().unwrap();
    assert!(matches!(reset.event, StreamEvent::Reset { .. }));
    assert_eq!(reset.media_time, None);
    record_with_director(
        &mut director,
        &mut recorder,
        StreamEvent::ManualOverride {
            camera_id: "B".into(),
            time: 0.0,
        },
    );
    let cut = recorder.timeline.cuts.last().unwrap();
    assert_eq!(cut.from_camera_id.as_deref(), Some("A"));
    assert_eq!(cut.applied_source_time, Some(0.0));
    assert_eq!(cut.session_generation, 2);
}
