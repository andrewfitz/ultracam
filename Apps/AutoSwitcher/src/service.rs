//! Local JSON Lines control service. All state transitions share one sequence.
use anyhow::{bail, ensure, Context, Result};
use auto_switcher::{Director, StreamEvent, SwitcherConfig};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    fs::{File, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    net::{Ipv4Addr, TcpListener, TcpStream},
    os::unix::fs::OpenOptionsExt,
    path::PathBuf,
    sync::{
        mpsc::{sync_channel, SyncSender},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;

const MAX_LINE: u64 = 256 * 1024;
const CLIENT_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Deserialize)]
struct Request {
    v: u16,
    #[serde(flatten)]
    op: Operation,
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum Operation {
    State,
    Claim { hold: bool },
    Take { route: String },
    Watch,
    Event { event: StreamEvent },
}

struct Session {
    id: Uuid,
    seq: u64,
    director: Director,
    native_host: Option<(Uuid, bool)>,
    subscribers: Vec<SyncSender<Arc<Vec<u8>>>>,
    journal: File,
    bindings: Option<crate::hotkeys::Bindings>,
    failed: bool,
    clock: bool,
}

fn line(value: &Value) -> Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(value)?;
    bytes.push(b'\n');
    Ok(bytes)
}

impl Session {
    fn state(&self) -> Value {
        json!({"v":1,"type":"state","session":self.id,"seq":self.seq,"session_generation":self.director.session_generation(),
            "pending":self.director.pending(), "clock":if self.clock {"server"} else {"host"}, "hotkeys": self.bindings.is_some(), "config":self.director.config,"status":self.director.status(f64::NAN)})
    }

    fn apply(&mut self, event: StreamEvent) -> Result<Value> {
        let update = self.record(event, "host")?;
        if let Some(bindings) = &self.bindings {
            if let Some(instruction) = update["outputs"]
                .as_array()
                .and_then(|outputs| outputs.iter().find_map(|o| o.get("instruction")))
            {
                let cut: auto_switcher::CutInstruction =
                    serde_json::from_value(instruction.clone())?;
                let shortcut = &bindings[&cut.target_camera_id];
                match shortcut.post() {
                    Ok(()) => {
                        self.record(
                            StreamEvent::Acknowledge {
                                decision_id: cut.decision_id,
                                applied_at: Some(cut.cut_time),
                            },
                            "keyDispatched",
                        )?;
                    }
                    Err(error) => {
                        eprintln!("shortcut failed: {error}");
                        self.record(
                            StreamEvent::Reject {
                                decision_id: cut.decision_id,
                            },
                            "keyFailed",
                        )?;
                    }
                }
            }
        }
        Ok(update)
    }

    fn record(&mut self, event: StreamEvent, application: &str) -> Result<Value> {
        ensure!(!self.failed, "journal unavailable, restart session");
        let profile_hold = self.director.config.manual_hold;
        self.director.config.manual_hold |= self.native_host.is_some_and(|(_, hold)| hold);
        let outputs = self.director.process_event(event.clone());
        self.director.config.manual_hold = profile_hold;
        self.seq += 1;
        let value = json!({"v":1,"session":self.id,"seq":self.seq,"type":"update","session_generation":self.director.session_generation(),
            "pending":self.director.pending(), "application":application,"event":event,"outputs":outputs,"status":self.director.status(f64::NAN)});
        let bytes = Arc::new(line(&value)?);
        if let Err(error) = self.journal.write_all(&bytes) {
            self.failed = true;
            return Err(error.into());
        }
        self.subscribers
            .retain(|tx| tx.try_send(bytes.clone()).is_ok());
        Ok(value)
    }
}

struct Peer {
    id: Uuid,
    session: Arc<Mutex<Session>>,
}
impl Drop for Peer {
    fn drop(&mut self) {
        let mut session = self.session.lock().unwrap();
        if session.native_host.is_some_and(|(id, _)| id == self.id) {
            session.native_host = None;
        }
    }
}

fn connection(mut stream: TcpStream, state: Arc<Mutex<Session>>, clock: bool) -> Result<()> {
    let peer = Peer {
        id: Uuid::new_v4(),
        session: state.clone(),
    };
    stream.set_nodelay(true)?;
    stream.set_write_timeout(Some(CLIENT_TIMEOUT))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    loop {
        let mut input = Vec::new();
        if reader
            .by_ref()
            .take(MAX_LINE + 1)
            .read_until(b'\n', &mut input)?
            == 0
        {
            return Ok(());
        }
        ensure!(
            input.len() as u64 <= MAX_LINE && input.ends_with(b"\n"),
            "invalid frame"
        );
        let response = match serde_json::from_slice::<Request>(&input) {
            Ok(Request {
                v: 1,
                op: Operation::Claim { hold },
            }) => {
                let mut session = state.lock().unwrap();
                if clock || session.bindings.is_some() || session.native_host.is_some() {
                    json!({"v":1,"type":"error","message":"a native host requires an available host-clock session"})
                } else {
                    session.native_host = Some((peer.id, hold));
                    session.state()
                }
            }
            Ok(Request {
                v: 1,
                op: Operation::Watch,
            }) => {
                let (tx, rx) = sync_channel(128);
                let snapshot = {
                    let mut session = state.lock().unwrap();
                    session.subscribers.push(tx);
                    session.state()
                };
                stream.write_all(&line(&snapshot)?)?;
                // A watcher may close its write half and continue reading updates.
                for update in rx {
                    stream.write_all(&update)?;
                }
                return Ok(());
            }
            Ok(Request {
                v: 1,
                op: Operation::Take { route },
            }) => {
                let mut session = state.lock().unwrap();
                let time = session.state()["status"]["time"]
                    .as_f64()
                    .unwrap_or_default();
                session.apply(StreamEvent::Take {
                    camera_id: route,
                    time,
                })?
            }
            Ok(Request {
                v: 1,
                op: Operation::State,
            }) => state.lock().unwrap().state(),
            Ok(Request {
                v: 1,
                op: Operation::Event { event },
            }) => {
                let mut session = state.lock().unwrap();
                let other_host = session.native_host.is_some_and(|(id, _)| id != peer.id);
                let observation = matches!(
                    event,
                    StreamEvent::Audio { .. }
                        | StreamEvent::Video { .. }
                        | StreamEvent::Transcript { .. }
                        | StreamEvent::Take { .. }
                );
                if !event.has_valid_cue_values() {
                    json!({"v":1,"type":"error","message":"invalid observation values"})
                } else if other_host && !observation {
                    json!({"v":1,"type":"error","message":"native host owns routing and clock"})
                } else if clock && matches!(event, StreamEvent::Tick { .. }) {
                    json!({"v":1,"type":"error","message":"server owns the clock"})
                } else {
                    session.apply(event)?
                }
            }
            _ => json!({"v":1,"type":"error","message":"invalid v1 request"}),
        };
        stream.write_all(&line(&response)?)?;
    }
}

#[derive(Debug, PartialEq)]
enum AcceptErrorAction {
    /// The failure belongs to one connection; keep serving.
    Skip,
    /// The process or system is out of descriptors; pause, then keep serving.
    Backoff,
    /// The listener itself is unusable.
    Fatal,
}

fn accept_error_action(error: &std::io::Error) -> AcceptErrorAction {
    use std::io::ErrorKind;
    // ENFILE and EMFILE have these values on both macOS and Linux.
    const ENFILE: i32 = 23;
    const EMFILE: i32 = 24;
    match error.kind() {
        ErrorKind::ConnectionAborted
        | ErrorKind::ConnectionReset
        | ErrorKind::Interrupted
        | ErrorKind::WouldBlock => AcceptErrorAction::Skip,
        _ if matches!(error.raw_os_error(), Some(EMFILE | ENFILE)) => AcceptErrorAction::Backoff,
        _ => AcceptErrorAction::Fatal,
    }
}

pub fn serve(
    config: SwitcherConfig,
    port: u16,
    journal: Option<PathBuf>,
    clock: bool,
    keys: Option<PathBuf>,
) -> Result<()> {
    let director = Director::new(config).map_err(anyhow::Error::msg)?;
    let bindings = keys.as_deref().map(crate::hotkeys::load).transpose()?;
    if let Some(map) = &bindings {
        ensure!(
            director.config.targets().all(|id| map.contains_key(id)),
            "a shortcut is required for every route"
        );
    }
    let listener =
        TcpListener::bind((Ipv4Addr::LOCALHOST, port)).context("binding local switcher")?;
    let id = Uuid::new_v4();
    let path = journal.unwrap_or_else(|| PathBuf::from(format!("switcher-{id}.jsonl")));
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&path)?;
    let mut session = Session {
        director,
        seq: 0,
        id,
        clock,
        bindings,
        subscribers: vec![],
        native_host: None,
        journal: file,
        failed: false,
    };
    let initial = line(&session.state())?;
    session.journal.write_all(&initial)?;
    let state = Arc::new(Mutex::new(session));
    println!(
        "{}",
        json!({"v":1,"type":"listening","address":listener.local_addr()?.to_string(),"session":id,"journal":path})
    );
    if clock {
        let state = state.clone();
        thread::spawn(move || {
            let start = Instant::now();
            loop {
                thread::sleep(Duration::from_millis(100));
                if let Err(error) = state.lock().unwrap().apply(StreamEvent::Tick {
                    time: start.elapsed().as_secs_f64(),
                }) {
                    eprintln!("clock stopped: {error}");
                    break;
                }
            }
        });
    }
    let slots = Arc::new(());
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(stream) => stream,
            Err(error) => match accept_error_action(&error) {
                AcceptErrorAction::Skip => continue,
                AcceptErrorAction::Backoff => {
                    eprintln!("accept failed, retrying: {error}");
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
                AcceptErrorAction::Fatal => return Err(error.into()),
            },
        };
        if Arc::strong_count(&slots) > 32 {
            continue;
        }
        let slot = slots.clone();
        let state = state.clone();
        thread::spawn(move || {
            let _slot = slot;
            if let Err(error) = connection(stream, state, clock) {
                eprintln!("client disconnected: {error}");
            }
        });
    }
    bail!("listener stopped")
}

#[derive(Default)]
struct LevelAdapter {
    last: Option<f64>,
    silence_start: Option<f64>,
    speaking: bool,
    id: u64,
}

impl LevelAdapter {
    /// Forget timing state so the next reading starts on the current clock.
    fn reset(&mut self) {
        self.last = None;
        self.silence_start = None;
        self.speaking = false;
    }

    /// Convert capture meter readings into the same replayable cues used by PCM.
    fn input(&mut self, line: &str) -> Result<(Value, Option<Value>)> {
        let event: Value = serde_json::from_str(line)?;
        if event["type"] == "reset" {
            self.reset();
        }
        if event["type"] != "levels" {
            return Ok((event, None));
        }
        #[derive(Deserialize)]
        struct Levels {
            time: f64,
            rms: f32,
            peak: f32,
            present: bool,
        }
        let levels: Levels = serde_json::from_value(event)?;
        ensure!(
            levels.time >= 0.0 && levels.rms.is_finite() && levels.peak.is_finite(),
            "invalid meter reading"
        );
        let (energy, emphasis) = if levels.present {
            (levels.rms.clamp(0.0, 1.0), levels.peak.clamp(0.0, 1.0))
        } else {
            (0.0, 0.0)
        };
        let speaking = energy >= 0.035;
        if speaking {
            self.silence_start = None;
        } else {
            self.silence_start.get_or_insert(levels.time);
        }
        self.id += 1;
        let gap = self.last.map(|previous| levels.time - previous);
        let cue = auto_switcher::AudioCue {
            features: Default::default(),
            id: self.id,
            time: levels.time,
            duration: gap.filter(|d| *d > 0.0 && *d <= 1.0).unwrap_or(0.02),
            speech_energy: energy,
            emphasis,
            laughter: 0.0,
            pause_duration: self
                .silence_start
                .map_or(0.0, |start| (levels.time - start).max(0.0)),
            speech_start: speaking && !self.speaking,
            speech_stop: !speaking && self.speaking,
            session_generation: 0,
        };
        self.speaking = speaking;
        self.last = Some(levels.time);
        Ok((
            json!({"type":"audio","cue":cue}),
            Some(json!({"type":"audioCue","cue":cue})),
        ))
    }
}

/// Private host-owned session. Each input has exactly one array response,
/// including inputs that produce no instruction.
pub fn worker() -> Result<()> {
    let input = std::io::stdin();
    let mut lines = input.lock().lines();
    let config = serde_json::from_str(&lines.next().context("expected host configuration")??)?;
    let mut director = Director::new(config).map_err(anyhow::Error::msg)?;
    let mut out = std::io::stdout().lock();
    writeln!(out, "[]")?;
    out.flush()?;
    let mut levels = LevelAdapter::default();
    for input in lines {
        let (event, cue) = levels.input(&input?)?;
        let generation = director.session_generation();
        let outputs = director.process_event(serde_json::from_value(event)?);
        if director.session_generation() != generation {
            // The director rebased (e.g. the clock jumped backward); readings
            // from the old timeline must not shape the next pause.
            levels.reset();
        }
        if let Some(cue) = cue {
            // Audio observations are retained until a tick. They produce no immediate cut.
            serde_json::to_writer(&mut out, &[cue])?;
        } else {
            serde_json::to_writer(&mut out, &outputs)?;
        }
        writeln!(out)?;
        out.flush()?;
    }
    Ok(())
}

/// Pipe adapter for native hosts that elect to use a shared session.
pub fn attach(port: u16) -> Result<()> {
    let mut input = std::io::stdin().lock().lines();
    let host: Value = serde_json::from_str(&input.next().context("expected configuration")??)?;
    let config: SwitcherConfig = serde_json::from_value(host.clone())?;
    let mut socket = local(port, Duration::from_secs(2))?;
    let state = call(&mut socket, json!({"v":1,"op":"claim","hold":config.manual_hold}))?;
    let server: SwitcherConfig = serde_json::from_value(state["config"].clone())?;
    ensure!(
        state["hotkeys"] == false,
        "native host requires host-owned output"
    );
    ensure!(
        state["clock"] == "host",
        "select host clock when starting the server"
    );
    // External routes can be OBS scene names. Bind by editorial role so the
    // host retains its own stable feed IDs at its frame scheduler boundary.
    let mut host_routes: Vec<String> = config.targets().cloned().collect();
    if let Some(extra) = host["available_routes"].as_array() {
        for id in extra.iter().filter_map(Value::as_str) {
            if !host_routes.iter().any(|known| known == id) {
                host_routes.push(id.into());
            }
        }
    }
    let routes: Vec<_> = server.targets().zip(host_routes.iter()).collect();
    ensure!(
        routes.len() == server.targets().count(),
        "profile needs more routes than the host provides"
    );
    let mut delivered = Value::Null;
    let mut generation = state["session_generation"].as_u64();
    println!("[]");
    let mut levels = LevelAdapter::default();
    for input in input {
        let (mut event, cue) = levels.input(&input?)?;
        let field = if event["type"] == "video" {
            "/observation/camera_id"
        } else {
            "/camera_id"
        };
        if let Some(id) = event.pointer_mut(field) {
            let Some((external, _)) = routes
                .iter()
                .find(|(_, local)| id.as_str() == Some(local.as_str()))
            else {
                println!("[]");
                continue;
            };
            *id = json!(external);
        }
        let update = call(&mut socket, json!({"v":1,"op":"event","event":event}))?;
        ensure!(update["outputs"].is_array(), "server rejected event");
        let next_generation = update["session_generation"].as_u64();
        if next_generation != generation {
            levels.reset();
            generation = next_generation;
        }
        let mut outputs = update["outputs"].as_array().unwrap().clone();
        outputs.extend(cue);
        let pending = &update["pending"];
        if !pending.is_null() && pending["decision_id"] != delivered {
            delivered = pending["decision_id"].clone();
            if !outputs.iter().any(|o| o["type"] == "cut") {
                outputs.push(json!({"type":"cut","instruction":pending}));
            }
        }
        for output in &mut outputs {
            for field in ["/instruction/target_camera_id", "/current_camera_id"] {
                if let Some(id) = output.pointer_mut(field) {
                    if let Some((_, local)) = routes
                        .iter()
                        .find(|(external, _)| id.as_str() == Some(external.as_str()))
                    {
                        *id = json!(local);
                    }
                }
            }
        }
        println!("{}", Value::Array(outputs));
    }
    Ok(())
}

fn local(port: u16, timeout: Duration) -> Result<BufReader<TcpStream>> {
    let socket = TcpStream::connect((Ipv4Addr::LOCALHOST, port))?;
    socket.set_nodelay(true)?;
    socket.set_write_timeout(Some(timeout))?;
    socket.set_read_timeout(Some(timeout))?;
    Ok(BufReader::new(socket))
}

fn call(peer: &mut BufReader<TcpStream>, message: Value) -> Result<Value> {
    peer.get_mut().write_all(&line(&message)?)?;
    let mut data = Vec::new();
    peer.by_ref()
        .take(2 * MAX_LINE)
        .read_until(b'\n', &mut data)?;
    ensure!(data.ends_with(b"\n"), "incomplete response");
    let reply: Value = serde_json::from_slice(&data)?;
    ensure!(reply["type"] != "error", "{}", reply["message"]);
    Ok(reply)
}

pub fn watch(port: u16) -> Result<()> {
    let mut socket = local(port, CLIENT_TIMEOUT)?;
    let snapshot = call(&mut socket, json!({"v":1,"op":"watch"}))?;
    socket.get_mut().set_read_timeout(None)?;
    println!("{snapshot}");
    std::io::copy(&mut socket, &mut std::io::stdout().lock())?;
    Ok(())
}

pub fn take(port: u16, route: String) -> Result<()> {
    let mut peer = local(port, CLIENT_TIMEOUT)?;
    let update = call(&mut peer, json!({"v":1,"op":"take","route":route}))?;
    if let Some(error) = update["outputs"]
        .as_array()
        .and_then(|a| a.iter().find(|o| o["type"] == "error"))
    {
        bail!("{}", error["message"]);
    }
    println!("{update}");
    Ok(())
}

pub fn feed_pcm(port: u16, rate: u32, origin: f64, tick: bool) -> Result<()> {
    ensure!(origin.is_finite() && origin >= 0.0, "invalid origin");
    let mut decoder = auto_switcher::audio::PcmCueDecoder::new(rate, 20, 0.025)?;
    let mut input = std::io::stdin().lock();
    let mut socket = local(port, CLIENT_TIMEOUT)?;
    let mut buffer = [0; 4096];
    loop {
        let count = input.read(&mut buffer)?;
        let events = if count == 0 {
            decoder.finish()
        } else {
            decoder.push_pcm16le(&buffer[..count])
        };
        for mut event in events {
            if let StreamEvent::Audio { cue } = &mut event {
                cue.time += origin;
                let time = cue.time;
                call(&mut socket, json!({"v":1,"op":"event","event":event}))?;
                if tick {
                    call(
                        &mut socket,
                        json!({"v":1,"op":"event","event":{"type":"tick","time":time}}),
                    )?;
                }
            }
        }
        if count == 0 {
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Error, ErrorKind};

    #[test]
    fn accept_errors_for_one_connection_do_not_stop_the_server() {
        for kind in [
            ErrorKind::ConnectionAborted,
            ErrorKind::ConnectionReset,
            ErrorKind::Interrupted,
            ErrorKind::WouldBlock,
        ] {
            assert_eq!(
                accept_error_action(&Error::from(kind)),
                AcceptErrorAction::Skip,
                "{kind:?}"
            );
        }
        // EMFILE and ENFILE.
        for code in [24, 23] {
            assert_eq!(
                accept_error_action(&Error::from_raw_os_error(code)),
                AcceptErrorAction::Backoff,
                "errno {code}"
            );
        }
        assert_eq!(
            accept_error_action(&Error::from(ErrorKind::InvalidInput)),
            AcceptErrorAction::Fatal
        );
    }
}
