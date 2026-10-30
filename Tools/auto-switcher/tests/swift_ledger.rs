use auto_switcher::model::{SessionTimeline, StreamEvent, SwitcherConfig};
use auto_switcher::Director;

fn ledger() -> SessionTimeline {
    let data = std::env::var("ULTRACAM_SWITCHER_LEDGER_FIXTURE")
        .map(|path| std::fs::read_to_string(path).unwrap())
        .unwrap_or_else(|_| include_str!("fixtures/swift-live-ledger.json").to_string());
    serde_json::from_str(&data).expect("actual Swift ledger must match the shared Rust protocol")
}

#[test]
fn swift_ledger_deserializes_and_input_records_replay() {
    let ledger = ledger();
    assert_eq!(ledger.schema_version, 3);
    let mut director = Director::new(ledger.config.clone()).unwrap();
    assert!(matches!(ledger.events[0].event, StreamEvent::Transcript { .. }));
    assert!(matches!(ledger.events[1].event, StreamEvent::DirectorOutput));
    assert!(matches!(ledger.events[2].event, StreamEvent::Reject { .. }));
    assert!(matches!(ledger.events[3].event, StreamEvent::Acknowledge { applied_at: None, .. }));
    for record in ledger.events {
        director.process_event(record.event);
    }
}

#[test]
fn swift_ack_matches_live_director_clock_despite_camera_clocks() {
    let ledger = ledger();
    assert_eq!(ledger.cuts[0].applied_source_time, Some(5.0));
    assert_eq!(ledger.cuts[0].applied_program_time, Some(1000.0));
    let applied_at = match ledger.events.last().unwrap().event {
        StreamEvent::Acknowledge { applied_at, .. } => applied_at,
        _ => panic!("expected persisted ack"),
    };
    let config = SwitcherConfig { minimum_shot_duration: 0.0, cooldown: 0.0,
        maximum_shot_duration: 3.0, soft_maximum_shot_duration: 2.0,
        forced_cut_grace_period: 0.0, ..SwitcherConfig::default() };
    let mut live = Director::new(config.clone()).unwrap();
    let mut replay = Director::new(config).unwrap();
    let live_cut = live.tick(100.0).expect("forced cut");
    let replay_cut = replay.tick(100.0).expect("forced cut");
    assert!(live.acknowledge(live_cut.decision_id, None));
    assert!(replay.acknowledge(replay_cut.decision_id, applied_at));
    assert_eq!(live.current_camera_id(), replay.current_camera_id());
    assert!(live.pending().is_none() && replay.pending().is_none());
    assert_eq!(live.status(101.0), replay.status(101.0));
}
