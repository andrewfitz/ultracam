//! Stream the journal into a cut list without re-running the director.
use anyhow::{ensure, Context, Result};
use serde_json::Value;
use std::{
    fs::File,
    io::{BufRead, BufReader, Write},
    path::Path,
};

fn field(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

pub fn csv(path: &Path, mut out: impl Write) -> Result<()> {
    let mut lines = BufReader::new(File::open(path)?).lines();
    let state: Value = serde_json::from_str(&lines.next().context("empty journal")??)?;
    ensure!(
        state["type"] == "state" && state["v"] == 1,
        "expected a v1 session journal"
    );
    let session = state["session"].as_str().context("missing session ID")?;
    let mut current = state["status"]["current_camera_id"].clone();
    let mut pending = Value::Null;
    writeln!(out,"session,sequence,media_seconds,media_ticks_240000,route,application,time_source,decision_id")?;
    for (index, line) in lines.enumerate() {
        let update: Value = serde_json::from_str(&line?)?;
        ensure!(
            update["seq"] == index + 1 && update["session"] == session,
            "journal sequence mismatch"
        );
        let event = &update["event"];
        let target = &update["status"]["current_camera_id"];
        if target != &current {
            let timing = match event["type"].as_str() {
                Some("acknowledge") if pending["decision_id"] == event["decision_id"] => event
                    ["applied_at"]
                    .as_f64()
                    .map(|t| (t, "applied"))
                    .or_else(|| pending["cut_time"].as_f64().map(|t| (t, "requested"))),
                Some("manualOverride") => {
                    update["status"]["time"].as_f64().map(|t| (t, "override"))
                }
                _ => None,
            };
            if let Some((time, source)) = timing {
                let application = update["application"]
                    .as_str()
                    .context("missing application")?;
                let source = if application == "keyDispatched" {
                    "requested"
                } else {
                    source
                };
                writeln!(
                    out,
                    "{session},{},{time},{},{},{application},{source},{}",
                    index + 1,
                    (time * 240000.0).round() as i64,
                    field(target.as_str().context("missing route")?),
                    event["decision_id"].as_str().unwrap_or("")
                )?;
            }
        }
        current = target.clone();
        pending = update["pending"].clone();
    }
    Ok(())
}
