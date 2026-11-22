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
