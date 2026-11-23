use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::process::{Child, Command, Stdio};

struct Server(Child);
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn read(reader: &mut impl BufRead) -> Value {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}
fn request(socket: &mut BufReader<TcpStream>, value: Value) -> Value {
    writeln!(socket.get_mut(), "{value}").unwrap();
    read(socket)
}

#[test]
fn half_closed_watch_receives_updates_after_idle() {
    use std::io::ErrorKind;
    use std::net::Shutdown;
    use std::time::Duration;

    let tmp = tempfile::tempdir().unwrap();
    let mut server = Server(
        Command::new(env!("CARGO_BIN_EXE_auto-switcher"))
            .args(["serve", "--port", "0", "--journal"])
            .arg(tmp.path().join("events.jsonl"))
            .stdout(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let started = read(&mut BufReader::new(server.0.stdout.take().unwrap()));
    let address = started["address"].as_str().unwrap();
    let connect = || {
        let socket = TcpStream::connect(address).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        BufReader::new(socket)
    };
    let mut watch = connect();
    let watch_request = json!({"v":1,"op":"watch"});
    writeln!(watch.get_mut(), "{watch_request}").unwrap();
    watch.get_mut().shutdown(Shutdown::Write).unwrap();
    assert_eq!(read(&mut watch)["seq"], 0);

    // Keep the host clock idle long enough to catch a premature disconnect.
    watch
        .get_mut()
        .set_read_timeout(Some(Duration::from_millis(750)))
        .unwrap();
    let error = watch.read_line(&mut String::new()).unwrap_err();
    assert!(matches!(
        error.kind(),
        ErrorKind::WouldBlock | ErrorKind::TimedOut
    ));
    watch
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();

    let update = request(
        &mut connect(),
        json!({"v":1,"op":"event","event":{"type":"tick","time":1}}),
    );
    assert_eq!(update["seq"], 1);
    assert_eq!(read(&mut watch), update);
}

#[test]
fn service_orders_observations_and_exports_only_applied_cuts() {
    let tmp = tempfile::tempdir().unwrap();
    let config = tmp.path().join("profile.json");
    let journal = tmp.path().join("events.jsonl");
    std::fs::write(&config,json!({"strategy":"eyeContact","anchor_camera_id":"wide","emphasis_camera_id":"left","additional_targets":["desk"]}).to_string()).unwrap();
    let mut server = Server(
        Command::new(env!("CARGO_BIN_EXE_auto-switcher"))
            .args(["serve", "--port", "0", "--config"])
            .arg(config)
            .arg("--journal")
            .arg(&journal)
            .stdout(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let started = read(&mut BufReader::new(server.0.stdout.take().unwrap()));
    let connect = || {
        let socket = TcpStream::connect(started["address"].as_str().unwrap()).unwrap();
        socket
            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
            .unwrap();
        BufReader::new(socket)
    };
    let mut watch = connect();
    assert_eq!(request(&mut watch, json!({"v":1,"op":"watch"}))["seq"], 0);
    let mut host = connect();
    assert_eq!(
        request(&mut host, json!({"v":9,"op":"state"}))["type"],
        "error"
    );
    let mut event = |event| request(&mut host, json!({"v":1,"op":"event","event":event}));
    for invalid in [
        json!({"type":"audio","cue":{"id":1,"time":12,"speech_energy":0.5,"features":{"tone":1e60}}}),
        json!({"type":"video","observation":{"camera_id":"desk","time":12,"eye_contact":1e60}}),
    ] {
        assert_eq!(event(invalid)["type"], "error");
    }
    event(json!({"type":"video","observation":{"time":12,"camera_id":"desk","eye_contact":0.95}}));
    let cut = event(json!({"type":"tick","time":12}));
    assert_eq!(cut["status"]["current_camera_id"], "wide");
    let instruction = &cut["outputs"][0]["instruction"];
    assert_eq!(instruction["target_camera_id"], "desk");
    let applied = event(
        json!({"type":"acknowledge","decision_id":instruction["decision_id"],"applied_at":12.1}),
    );
    assert_eq!(applied["status"]["current_camera_id"], "desk");
    assert_eq!(read(&mut watch)["seq"], 1);
    assert_eq!(read(&mut watch), cut);
    assert_eq!(read(&mut watch), applied);
    let records: Vec<Value> = std::fs::read_to_string(journal)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(records.len(), 4);
    assert_eq!(records[3], applied);
}

#[test]
fn worker_level_pause_restarts_after_backward_clock_jump() {
    check_meter_reset(&["worker"]);
}

#[test]
fn attached_host_level_pause_restarts_after_backward_clock_jump() {
    let tmp = tempfile::tempdir().unwrap();
    let mut server = Server(
        Command::new(env!("CARGO_BIN_EXE_auto-switcher"))
            .args(["serve", "--port", "0", "--journal"])
            .arg(tmp.path().join("events.jsonl"))
            .stdout(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let started = read(&mut BufReader::new(server.0.stdout.take().unwrap()));
    let address: std::net::SocketAddr = started["address"].as_str().unwrap().parse().unwrap();
    check_meter_reset(&["attach", "--port", &address.port().to_string()]);
}

fn check_meter_reset(args: &[&str]) {
    let mut worker = Server(
        Command::new(env!("CARGO_BIN_EXE_auto-switcher"))
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let mut stdin = worker.0.stdin.take().unwrap();
    let mut stdout = BufReader::new(worker.0.stdout.take().unwrap());
    let mut send = |value: Value| {
        writeln!(stdin, "{value}").unwrap();
        stdin.flush().unwrap();
        read(&mut stdout)
    };
    assert_eq!(
        send(json!({"strategy":"eyeContact","anchor_camera_id":"wide","emphasis_camera_id":"left"})),
        json!([])
    );
    let levels = |time: f64, rms: f64| json!({"type":"levels","time":time,"rms":rms,"peak":rms,"present":true});
    send(levels(10.0, 0.5));
    send(levels(10.5, 0.0));
    send(json!({"type":"tick","time":11.0}));
    // The host clock restarts; the director rebases its session.
    send(json!({"type":"tick","time":2.0}));
    send(levels(2.0, 0.0));
    let pause = send(levels(2.5, 0.0));
    let pause = pause[0]["cue"]["pause_duration"].as_f64().unwrap();
    assert!((pause - 0.5).abs() < 1e-9, "pause after clock jump was {pause}");
    send(levels(3.0, 0.5));
    let missing = send(json!({"type":"levels","time":3.5,"rms":0.9,"peak":1.0,"present":false}));
    assert_eq!(missing[0]["cue"]["speech_energy"], 0.0);
    assert_eq!(missing[0]["cue"]["emphasis"], 0.0);
    assert_eq!(missing[0]["cue"]["speech_stop"], true);
}
