use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Arc, Mutex, Once};
use std::thread;
use std::time::{Duration, SystemTime};

use chrono::Utc;
use flate2::{Decompress, FlushDecompress, Status};
use futures_util::{SinkExt, StreamExt};
use miniz_oxide::inflate::{decompress_to_vec, decompress_to_vec_zlib};
use serde::{Deserialize, Serialize};
use serde_json::de::Deserializer;
use serde_json::Value;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;
use tokio::time::{sleep, timeout};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::protocol::Message as WsMessage;
use tokio_tungstenite::connect_async;

static RUSTLS_PROVIDER_INIT: Once = Once::new();

fn ensure_rustls_crypto_provider() {
    RUSTLS_PROVIDER_INIT.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

#[cfg(debug_assertions)]
use log::{LevelFilter, Log, Metadata, Record};

#[cfg(debug_assertions)]
struct RustCoreLogger;

#[cfg(debug_assertions)]
impl Log for RustCoreLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        metadata.level() <= LevelFilter::Debug
    }

    fn log(&self, record: &Record) {
        if self.enabled(record.metadata()) {
            eprintln!("{}", record.args());
        }
    }

    fn flush(&self) {}
}

#[cfg(debug_assertions)]
static RUST_CORE_LOGGER: RustCoreLogger = RustCoreLogger;
#[cfg(debug_assertions)]
static LOG_INIT: Once = Once::new();

#[cfg(debug_assertions)]
fn ensure_rust_core_log() {
    LOG_INIT.call_once(|| {
        let _ = log::set_logger(&RUST_CORE_LOGGER).map(|()| log::set_max_level(LevelFilter::Debug));
    });
}

#[cfg(not(debug_assertions))]
#[inline]
fn ensure_rust_core_log() {}

// ===== Protocol layer (compatible with the current Swift MVP) =====

#[derive(Debug, Clone)]
enum DCSSClientCommand {
    Handshake { client_version: String },
    Input { command: String },
    Heartbeat,
}

#[derive(Debug, Clone)]
enum DCSSServerEvent {
    Hello { server_version: String },
    GameFrame { grid: Vec<String>, status_line: String },
    Message { text: String },
    HeartbeatAck,
    HeartbeatRequest,
    Error { code: i32, text: String },
    Unknown { type_name: String },
}

#[derive(Debug)]
enum ProtocolCodecError {
    InvalidUtf8,
    MalformedPayload(String),
}

#[derive(Debug, Serialize, Deserialize)]
struct WireEnvelope {
    type_: String,
    payload: HashMap<String, Value>,
}

impl WireEnvelope {
    fn new(type_name: &str, payload: HashMap<String, Value>) -> Self {
        Self {
            type_: type_name.to_string(),
            payload,
        }
    }
}

fn json_value_string(payload: &HashMap<String, Value>, key: &str) -> Option<String> {
    payload.get(key).and_then(|v| v.as_str().map(|s| s.to_string()))
}

fn json_value_int(payload: &HashMap<String, Value>, key: &str) -> Option<i32> {
    payload
        .get(key)
        .and_then(|v| v.as_i64())
        .map(|n| n as i32)
}

fn json_value_string_array(payload: &HashMap<String, Value>, key: &str) -> Option<Vec<String>> {
    payload.get(key).and_then(|v| v.as_array()).map(|arr| {
        arr.iter()
            .filter_map(|x| x.as_str().map(|s| s.to_string()))
            .collect::<Vec<_>>()
    })
}

fn parse_grid(payload: &HashMap<String, Value>) -> Vec<String> {
    if let Some(grid_raw) = json_value_string(payload, "grid") {
        // Swift splits on the literal "\n" substring (not an actual newline).
        return grid_raw
            .split("\\n")
            .map(|s| s.to_string())
            .collect();
    }

    if let Some(rows) = json_value_string_array(payload, "gridRows") {
        return rows;
    }

    vec![]
}

fn decode_server_event(data: &[u8]) -> Result<DCSSServerEvent, ProtocolCodecError> {
    let s = std::str::from_utf8(data).map_err(|_| ProtocolCodecError::InvalidUtf8)?;
    let value: Value = serde_json::from_str(s)
        .map_err(|e| ProtocolCodecError::MalformedPayload(format!("invalid json: {e}")))?;
    decode_server_value(value)
}

fn decode_server_events(data: &[u8]) -> Result<Vec<DCSSServerEvent>, ProtocolCodecError> {
    ensure_rust_core_log();
    let s = std::str::from_utf8(data).map_err(|_| ProtocolCodecError::InvalidUtf8)?;
    let mut events = Vec::new();
    let stream = Deserializer::from_str(s).into_iter::<Value>();
    for item in stream {
        let value = item
            .map_err(|e| ProtocolCodecError::MalformedPayload(format!("invalid json stream: {e}")))?;
        events.extend(decode_server_value_as_events(value)?);
    }
    if events.is_empty() {
        return Err(ProtocolCodecError::MalformedPayload(
            "json stream produced no events".to_string(),
        ));
    }
    Ok(events)
}

fn decode_server_value(value: Value) -> Result<DCSSServerEvent, ProtocolCodecError> {
    let obj = value.as_object().ok_or_else(|| {
        ProtocolCodecError::MalformedPayload("expected json object".to_string())
    })?;

    // Envelope mode: { "type": "...", "payload": {...} }
    let is_envelope = obj.get("type").and_then(|v| v.as_str()).is_some()
        && obj.get("payload").is_some();
    if is_envelope {
        let type_name = obj.get("type").and_then(|v| v.as_str()).unwrap_or("unknown");
        let payload_value = obj.get("payload").unwrap_or(&Value::Null);
        let payload_obj = payload_value.as_object().ok_or_else(|| {
            ProtocolCodecError::MalformedPayload("payload must be object".to_string())
        })?;
        let payload: HashMap<String, Value> = payload_obj.clone().into_iter().collect();
        return decode_by_type(type_name, &payload);
    }

    // Compatibility mode: flattened payloads.
    // Swift finds `type` or `msg`, then uses the whole object as payload.
    let type_name = obj
        .get("type")
        .and_then(|v| v.as_str())
        .or_else(|| obj.get("msg").and_then(|v| v.as_str()))
        .unwrap_or("unknown");
    let payload: HashMap<String, Value> = obj.clone().into_iter().collect();
    decode_by_type(type_name, &payload)
}

fn decode_server_value_as_events(value: Value) -> Result<Vec<DCSSServerEvent>, ProtocolCodecError> {
    if let Some(obj) = value.as_object() {
        if let Some(msgs) = obj.get("msgs").and_then(|v| v.as_array()) {
            let mut events = Vec::new();
            for item in msgs {
                if let Some(item_obj) = item.as_object() {
                    let payload: HashMap<String, Value> = item_obj.clone().into_iter().collect();
                    let msg_type = item_obj
                        .get("msg")
                        .and_then(|v| v.as_str())
                        .unwrap_or("unknown");
                    // DCSS web client uses { msgs: [{ msg: "...", ... }, ...] } envelope.
                    let ev = match msg_type {
                        "ping" => DCSSServerEvent::HeartbeatRequest,
                        "chat" | "message" => {
                            let text = payload
                                .get("text")
                                .and_then(|v| v.as_str())
                                .or_else(|| payload.get("message").and_then(|v| v.as_str()))
                                .unwrap_or("")
                                .to_string();
                            DCSSServerEvent::Message { text }
                        }
                        other => DCSSServerEvent::Unknown {
                            type_name: other.to_string(),
                        },
                    };
                    log::debug!("[RustCore] decoded msg type={msg_type}");
                    events.push(ev);
                }
            }
            if !events.is_empty() {
                return Ok(events);
            }
        }
    }
    if let Some(items) = value.as_array() {
        let mut events = Vec::new();
        for item in items {
            if let Some(item_obj) = item.as_object() {
                let payload: HashMap<String, Value> = item_obj.clone().into_iter().collect();
                let msg_type = item_obj
                    .get("msg")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown");
                let ev = match msg_type {
                    "ping" => DCSSServerEvent::HeartbeatRequest,
                    "chat" | "message" => {
                        let text = payload
                            .get("text")
                            .and_then(|v| v.as_str())
                            .or_else(|| payload.get("message").and_then(|v| v.as_str()))
                            .unwrap_or("")
                            .to_string();
                        DCSSServerEvent::Message { text }
                    }
                    other => DCSSServerEvent::Unknown {
                        type_name: other.to_string(),
                    },
                };
                log::debug!("[RustCore] decoded msg type={msg_type}");
                events.push(ev);
            }
        }
        if !events.is_empty() {
            return Ok(events);
        }
    }
    Ok(vec![decode_server_value(value)?])
}

fn decode_server_event_binary(data: &[u8]) -> Result<Vec<DCSSServerEvent>, ProtocolCodecError> {
    // 1) Try as plain UTF-8 JSON first.
    if let Ok(events) = decode_server_events(data) {
        if let Ok(text) = std::str::from_utf8(data) {
            log::debug!("[RustCore] binary payload decoded as plain utf8 len={}", data.len());
            log::debug!("[RustCore] inflated text preview={text}");
        }
        return Ok(events);
    }

    // 2) Try zlib-wrapped DEFLATE (common pako/default case).
    if let Ok(inflated) = decompress_to_vec_zlib(data) {
        if let Ok(events) = decode_server_events(&inflated) {
            log::debug!("[RustCore] binary payload decoded via zlib inflate len={}", inflated.len());
            if let Ok(text) = std::str::from_utf8(&inflated) {
                log::debug!("[RustCore] inflated text preview={text}");
            }
            return Ok(events);
        }
    }

    // 3) Try raw DEFLATE (pako inflateRaw case).
    if let Ok(inflated) = decompress_to_vec(data) {
        if let Ok(events) = decode_server_events(&inflated) {
            log::debug!("[RustCore] binary payload decoded via raw deflate len={}", inflated.len());
            if let Ok(text) = std::str::from_utf8(&inflated) {
                log::debug!("[RustCore] inflated text preview={text}");
            }
            return Ok(events);
        }
    }

    Err(ProtocolCodecError::MalformedPayload(
        "binary payload is not plain/inflated JSON".to_string(),
    ))
}

fn is_ignorable_decode_error(err: &ProtocolCodecError) -> bool {
    match err {
        ProtocolCodecError::InvalidUtf8 => true,
        ProtocolCodecError::MalformedPayload(msg) => {
            msg.contains("expected value")
                || msg.contains("EOF while parsing")
                || msg.contains("trailing characters")
                || msg.contains("json stream produced no events")
                || msg.contains("json stream produced no complete events yet")
        }
    }
}

struct StatefulBinaryInflater {
    raw: Decompress,
}

impl StatefulBinaryInflater {
    fn new() -> Self {
        // false => raw DEFLATE stream (no zlib/gzip header), matches permessage-deflate payloads.
        Self {
            raw: Decompress::new(false),
        }
    }

    fn decode_events(&mut self, data: &[u8]) -> Result<Vec<DCSSServerEvent>, ProtocolCodecError> {
        ensure_rust_core_log();
        // Per-frame inflate: each websocket binary message is expected to contain one full JSON payload.
        let mut input = Vec::with_capacity(data.len() + 4);
        input.extend_from_slice(data);
        // pako-compatible trailer for per-message Z_SYNC_FLUSH blocks.
        input.extend_from_slice(&[0x00, 0x00, 0xff, 0xff]);

        let mut inflated = Vec::new();
        let mut input_pos: usize = 0;

        loop {
            let out_start = inflated.len();
            inflated.resize(out_start + 8192, 0);

            let before_in = self.raw.total_in();
            let before_out = self.raw.total_out();

            let status = self.raw
                .decompress(
                    &input[input_pos..],
                    &mut inflated[out_start..],
                    FlushDecompress::Sync,
                )
                .map_err(|e| ProtocolCodecError::MalformedPayload(
                    format!("stateful raw inflate failed: {e}"),
                ))?;

            let consumed = (self.raw.total_in() - before_in) as usize;
            let produced = (self.raw.total_out() - before_out) as usize;
            input_pos += consumed;
            inflated.truncate(out_start + produced);

            if consumed == 0 && produced == 0 {
                break;
            }
        }

        log::debug!(
            "[RustCore] binary payload decoded via stateful deflate len={}",
            inflated.len()
        );
        if let Ok(text) = std::str::from_utf8(&inflated) {
            log::debug!("[RustCore] inflated text preview={text}");
        } else {
            log::debug!("[RustCore] inflated bytes are not valid UTF-8");
        }

        let mut events = Vec::new();
        for value in Deserializer::from_slice(&inflated).into_iter::<Value>() {
            let value = value.map_err(|e| ProtocolCodecError::MalformedPayload(format!("invalid json stream: {e}")))?;
            events.extend(decode_server_value_as_events(value)?);
        }
        Ok(events)
    }
}

fn decode_by_type(type_name: &str, payload: &HashMap<String, Value>) -> Result<DCSSServerEvent, ProtocolCodecError> {
    match type_name {
        "hello" | "welcome" => {
            let version = json_value_string(payload, "serverVersion")
                .or_else(|| json_value_string(payload, "version"))
                .unwrap_or_else(|| "unknown".to_string());
            Ok(DCSSServerEvent::Hello { server_version: version })
        }
        "frame" | "update" => {
            let grid = parse_grid(payload);
            let status_line = json_value_string(payload, "statusLine")
                .or_else(|| json_value_string(payload, "status"))
                .unwrap_or_else(|| "".to_string());
            Ok(DCSSServerEvent::GameFrame { grid, status_line })
        }
        "message" | "msg" => {
            let text = json_value_string(payload, "text")
                .or_else(|| json_value_string(payload, "message"))
                .ok_or_else(|| ProtocolCodecError::MalformedPayload("message requires text".to_string()))?;
            Ok(DCSSServerEvent::Message { text })
        }
        "heartbeat_ack" | "pong" => Ok(DCSSServerEvent::HeartbeatAck),
        "heartbeat" | "ping" => Ok(DCSSServerEvent::HeartbeatRequest),
        "error" => {
            let code = json_value_int(payload, "code").unwrap_or(-1);
            let text = json_value_string(payload, "text")
                .or_else(|| json_value_string(payload, "message"))
                .unwrap_or_else(|| "unknown".to_string());
            Ok(DCSSServerEvent::Error { code, text })
        }
        other => Ok(DCSSServerEvent::Unknown { type_name: other.to_string() }),
    }
}

fn encode_client_command(cmd: DCSSClientCommand) -> Result<Vec<u8>, ProtocolCodecError> {
    let envelope = match cmd {
        DCSSClientCommand::Handshake { client_version } => WireEnvelope::new(
            "handshake",
            HashMap::from([("clientVersion".to_string(), Value::String(client_version))]),
        ),
        DCSSClientCommand::Input { command } => WireEnvelope::new(
            "input",
            HashMap::from([("command".to_string(), Value::String(command))]),
        ),
        DCSSClientCommand::Heartbeat => WireEnvelope::new("heartbeat", HashMap::new()),
    };

    let json = serde_json::to_string(&envelope)
        .map_err(|e| ProtocolCodecError::MalformedPayload(format!("encode json: {e}")))?;
    Ok(json.into_bytes())
}

// WireEnvelope struct above serializes `type_` as `type_`, so implement a custom fix:
// We'll serialize manually to match Swift/Wire contract: { "type": "...", "payload": ... }.
//
// To keep the module small, we re-implement encode_client_command for actual wire format:
fn encode_client_command_wire(cmd: DCSSClientCommand) -> Vec<u8> {
    let type_name = match &cmd {
        DCSSClientCommand::Handshake { .. } => "handshake",
        DCSSClientCommand::Input { .. } => "input",
        DCSSClientCommand::Heartbeat => "heartbeat",
    };

    let payload: HashMap<String, Value> = match cmd {
        DCSSClientCommand::Handshake { client_version } => {
            HashMap::from([("clientVersion".to_string(), Value::String(client_version))])
        }
        DCSSClientCommand::Input { command } => {
            HashMap::from([("command".to_string(), Value::String(command))])
        }
        DCSSClientCommand::Heartbeat => HashMap::new(),
    };

    let envelope = serde_json::json!({
        "type": type_name,
        "payload": payload,
    });
    serde_json::to_string(&envelope)
        .expect("wire envelope to serialize")
        .into_bytes()
}

// ===== Session layer =====

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ConnectionStateRepr {
    Idle,
    Connecting,
    Connected,
    Reconnecting { attempt: u32 },
    Failed { reason: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct GameStateRepr {
    grid: Vec<String>,
    statusLine: String,
    lastMessage: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DiagnosticsRepr {
    lastEventType: Option<String>,
    reconnectAttempt: Option<u32>,
    lastError: Option<String>,
    lastConnectedAt: Option<String>, // RFC3339
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SnapshotRepr {
    connectionState: ConnectionStateRepr,
    gameState: GameStateRepr,
    diagnostics: DiagnosticsRepr,
}

#[derive(Debug, Clone)]
struct GameStateInternal {
    grid: Vec<String>,
    status_line: String,
    last_message: String,
}

#[derive(Debug, Clone)]
enum ConnectionStateInternal {
    Idle,
    Connecting,
    Connected,
    Reconnecting { attempt: u32 },
    Failed { reason: String },
}

#[derive(Debug, Clone)]
struct DiagnosticsInternal {
    last_event_type: Option<String>,
    reconnect_attempt: Option<u32>,
    last_error: Option<String>,
    last_connected_at: Option<SystemTime>,
}

#[derive(Debug, Clone)]
struct SessionStateInternal {
    connection_state: ConnectionStateInternal,
    game_state: GameStateInternal,
    diagnostics: DiagnosticsInternal,

    endpoint: Option<String>,
    client_version: String,
    is_in_background: bool,
}

#[derive(Debug)]
enum Command {
    ConnectNow,
    Disconnect,
    Input(String),
    Heartbeat,
    SetBackground(bool),
}

struct Session {
    state: Arc<Mutex<SessionStateInternal>>,
    cmd_tx: Mutex<Option<mpsc::Sender<Command>>>,
}

impl Session {
    fn new() -> Self {
        let state = SessionStateInternal {
            connection_state: ConnectionStateInternal::Idle,
            game_state: GameStateInternal {
                grid: vec![],
                status_line: "".to_string(),
                last_message: "".to_string(),
            },
            diagnostics: DiagnosticsInternal {
                last_event_type: None,
                reconnect_attempt: None,
                last_error: None,
                last_connected_at: None,
            },
            endpoint: None,
            client_version: "dcss-ios-0.1".to_string(),
            is_in_background: false,
        };

        Self {
            state: Arc::new(Mutex::new(state)),
            cmd_tx: Mutex::new(None),
        }
    }

    fn ensure_loop_started(&self) {
        let mut guard = self.cmd_tx.lock().unwrap();
        if guard.is_some() {
            return;
        }

        let (tx, rx) = mpsc::channel::<Command>(64);
        *guard = Some(tx);

        let state = self.state.clone();
        thread::spawn(move || {
            let rt = Runtime::new().expect("tokio runtime");
            rt.block_on(run_event_loop(state, rx));
        });
    }

    fn snapshot_json(&self) -> String {
        let state = self.state.lock().unwrap();

        let connection_state = match &state.connection_state {
            ConnectionStateInternal::Idle => ConnectionStateRepr::Idle,
            ConnectionStateInternal::Connecting => ConnectionStateRepr::Connecting,
            ConnectionStateInternal::Connected => ConnectionStateRepr::Connected,
            ConnectionStateInternal::Reconnecting { attempt } => {
                ConnectionStateRepr::Reconnecting { attempt: *attempt }
            }
            ConnectionStateInternal::Failed { reason } => {
                ConnectionStateRepr::Failed { reason: reason.clone() }
            }
        };

        let last_connected_at = state
            .diagnostics
            .last_connected_at
            .map(|_| Utc::now().to_rfc3339());
        // Note: we don't store actual timestamp conversion in this minimal impl.
        // It's enough for the UI debug fields.
        let diagnostics = DiagnosticsRepr {
            lastEventType: state.diagnostics.last_event_type.clone(),
            reconnectAttempt: state.diagnostics.reconnect_attempt,
            lastError: state.diagnostics.last_error.clone(),
            lastConnectedAt: last_connected_at,
        };

        let game_state = GameStateRepr {
            grid: state.game_state.grid.clone(),
            statusLine: state.game_state.status_line.clone(),
            lastMessage: state.game_state.last_message.clone(),
        };

        let snapshot = SnapshotRepr {
            connectionState: connection_state,
            gameState: game_state,
            diagnostics: diagnostics,
        };

        serde_json::to_string(&snapshot).unwrap_or_else(|_| "{}".to_string())
    }
}

async fn run_event_loop(
    state: Arc<Mutex<SessionStateInternal>>,
    mut cmd_rx: mpsc::Receiver<Command>,
) {
    ensure_rust_core_log();
    log::debug!("[RustCore] event loop started");
    loop {
        // Wait for a ConnectNow command or for outgoing commands while idle.
        match cmd_rx.recv().await {
            Some(Command::ConnectNow) => {
                log::debug!("[RustCore] ConnectNow received");
                // Attempt connect loop until disconnect/background.
                if state.lock().unwrap().is_in_background {
                    log::debug!("[RustCore] skip connect: app in background");
                    continue;
                }

                let endpoint = state.lock().unwrap().endpoint.clone();
                let client_version = state.lock().unwrap().client_version.clone();
                if endpoint.is_none() {
                    log::debug!("[RustCore] skip connect: endpoint missing");
                    continue;
                }
                let endpoint = endpoint.unwrap();
                log::debug!("[RustCore] connect target={endpoint}");

                let mut attempt: u32 = 0;
                let max_attempts: u32 = 5;
                let base_delay_secs: f64 = 1.0;

                loop {
                    attempt += 1;
                    if state.lock().unwrap().is_in_background {
                        break;
                    }

                    if attempt > 1 {
                        {
                            let mut s = state.lock().unwrap();
                            s.connection_state = ConnectionStateInternal::Reconnecting { attempt };
                            s.diagnostics.reconnect_attempt = Some(attempt);
                        }
                        let delay_secs = (2_f64.powi(attempt as i32) * base_delay_secs).min(20.0);
                        sleep(Duration::from_secs_f64(delay_secs)).await;
                    }

                    {
                        let mut s = state.lock().unwrap();
                        s.connection_state = ConnectionStateInternal::Connecting;
                        s.diagnostics.last_error = None;
                    }

                    log::debug!("[RustCore] connect attempt={attempt} start");
                    let ws_res = timeout(Duration::from_secs(20), connect_async(endpoint.clone())).await;
                    let ws_res = match ws_res {
                        Ok(res) => res,
                        Err(_) => {
                            let mut s = state.lock().unwrap();
                            s.diagnostics.last_error = Some("connect timeout".to_string());
                            log::debug!("[RustCore] connect attempt={attempt} timeout");
                            if attempt >= max_attempts {
                                s.connection_state = ConnectionStateInternal::Failed {
                                    reason: "connect timeout".to_string(),
                                };
                                break;
                            }
                            continue;
                        }
                    };
                    let (mut ws_stream, response) = match ws_res {
                        Ok(ok) => ok,
                        Err(e) => {
                            let mut s = state.lock().unwrap();
                            s.diagnostics.last_error = Some(e.to_string());
                            log::debug!("[RustCore] connect attempt={attempt} failed error={e}");
                            if attempt >= max_attempts {
                                s.connection_state = ConnectionStateInternal::Failed {
                                    reason: e.to_string(),
                                };
                                break;
                            }
                            continue;
                        }
                    };
                    log::debug!(
                        "[RustCore] handshake status={} extensions={:?} server={:?}",
                        response.status(),
                        response.headers().get("sec-websocket-extensions"),
                        response.headers().get("server"),
                    );

                    // Send handshake
                    let handshake = encode_client_command_wire(DCSSClientCommand::Handshake {
                        client_version: client_version.clone(),
                    });
                    if ws_stream.send(Message::Text(String::from_utf8_lossy(&handshake).to_string())).await.is_err() {
                        let mut s = state.lock().unwrap();
                        s.diagnostics.last_error = Some("send handshake failed".to_string());
                        if attempt >= max_attempts {
                            s.connection_state = ConnectionStateInternal::Failed {
                                reason: "send handshake failed".to_string(),
                            };
                            break;
                        }
                        continue;
                    }

                    {
                        let mut s = state.lock().unwrap();
                        s.connection_state = ConnectionStateInternal::Connected;
                        s.diagnostics.last_connected_at = Some(SystemTime::now());
                        s.diagnostics.reconnect_attempt = None;
                    }
                    log::debug!("[RustCore] connect attempt={attempt} success");
                    let mut binary_inflater = StatefulBinaryInflater::new();

                    // Connected loop
                    loop {
                        tokio::select! {
                            cmd = cmd_rx.recv() => {
                                match cmd {
                                    Some(Command::Input(command)) => {
                                        let payload = encode_client_command_wire(DCSSClientCommand::Input { command });
                                        if ws_stream.send(Message::Text(String::from_utf8_lossy(&payload).to_string())).await.is_err() {
                                            // Trigger reconnect
                                            break;
                                        }
                                    }
                                    Some(Command::Heartbeat) => {
                                        // Optional websocket ping
                                        let _ = ws_stream.send(Message::Ping(vec![])).await;
                                        let payload = encode_client_command_wire(DCSSClientCommand::Heartbeat);
                                        if ws_stream.send(Message::Text(String::from_utf8_lossy(&payload).to_string())).await.is_err() {
                                            break;
                                        }
                                    }
                                    Some(Command::SetBackground(true)) => {
                                        {
                                            let mut s = state.lock().unwrap();
                                            s.connection_state = ConnectionStateInternal::Idle;
                                            s.is_in_background = true;
                                        }
                                        let _ = ws_stream.close(None).await;
                                        break;
                                    }
                                    Some(Command::SetBackground(false)) => {
                                        let mut s = state.lock().unwrap();
                                        s.is_in_background = false;
                                    }
                                    Some(Command::Disconnect) => {
                                        {
                                            let mut s = state.lock().unwrap();
                                            s.connection_state = ConnectionStateInternal::Idle;
                                            s.diagnostics.reconnect_attempt = None;
                                        }
                                        let _ = ws_stream.close(None).await;
                                        break;
                                    }
                                    Some(Command::ConnectNow) => {
                                        // Already connected; ignore.
                                    }
                                    None => break,
                                }
                            }
                            msg = ws_stream.next() => {
                                let msg = match msg {
                                    Some(m) => m,
                                    None => {
                                        {
                                            let mut s = state.lock().unwrap();
                                            s.diagnostics.last_error = Some("socket stream ended (EOF)".to_string());
                                        }
                                        log::debug!("[RustCore] socket stream ended (EOF)");
                                        break;
                                    }
                                };
                                match msg {
                                    Ok(WsMessage::Text(txt)) => {
                                        log::debug!(
                                            "[RustCore] recv text len={} sample={}",
                                            txt.len(),
                                            txt.chars().take(180).collect::<String>()
                                        );
                                        let events = decode_server_events(txt.as_bytes());
                                        match events {
                                            Ok(decoded) => {
                                                for ev in decoded {
                                                    apply_event(&state, &mut ws_stream, ev).await;
                                                }
                                            }
                                            Err(e) => {
                                                let msg = format!("decode text failed: {:?}", e);
                                                if !is_ignorable_decode_error(&e) {
                                                    let mut s = state.lock().unwrap();
                                                    s.diagnostics.last_error = Some(msg.clone());
                                                }
                                                log::debug!("[RustCore] {msg}");
                                                // Ignore unknown text frames and keep connection alive.
                                                continue;
                                            }
                                        }
                                    }
                                    Ok(WsMessage::Binary(bin)) => {
                                        log::debug!("[RustCore] recv binary len={}", bin.len());
                                        let event = match binary_inflater.decode_events(&bin) {
                                            Ok(decoded) => Ok(decoded),
                                            Err(err) => {
                                                log::debug!("[RustCore] stateful inflater miss: {:?}", err);
                                                Err(err)
                                            }
                                        };
                                        match event {
                                            Ok(decoded) => {
                                                for ev in decoded {
                                                    apply_event(&state, &mut ws_stream, ev).await;
                                                }
                                            }
                                            Err(e) => {
                                                let hex_preview = bin
                                                    .iter()
                                                    .take(24)
                                                    .map(|b| format!("{:02x}", b))
                                                    .collect::<Vec<_>>()
                                                    .join(" ");
                                                let msg = format!("decode binary failed: {:?}", e);
                                                if !is_ignorable_decode_error(&e) {
                                                    let mut s = state.lock().unwrap();
                                                    s.diagnostics.last_error = Some(msg.clone());
                                                }
                                                log::debug!("[RustCore] {msg}; hex={hex_preview}");
                                                // Some servers send binary housekeeping frames. Do not reconnect on them.
                                                continue;
                                            }
                                        }
                                    }
                                    Ok(WsMessage::Ping(_)) => {}
                                    Ok(WsMessage::Pong(_)) => {}
                                    Ok(WsMessage::Close(frame)) => {
                                        let reason = frame
                                            .as_ref()
                                            .map(|f| format!("code={:?} reason={}", f.code, f.reason))
                                            .unwrap_or_else(|| "no close frame".to_string());
                                        {
                                            let mut s = state.lock().unwrap();
                                            s.diagnostics.last_error = Some(format!("socket closed: {reason}"));
                                        }
                                        log::debug!("[RustCore] socket closed: {reason}");
                                        break;
                                    }
                                    Err(e) => {
                                        {
                                            let mut s = state.lock().unwrap();
                                            s.diagnostics.last_error = Some(format!("socket error: {e}"));
                                        }
                                        log::debug!("[RustCore] websocket read error: {e}");
                                        break;
                                    }
                                    _ => {}
                                }
                            }
                        }

                        // Check if background should stop immediately.
                        if state.lock().unwrap().is_in_background {
                            break;
                        }
                    }

                    if state.lock().unwrap().is_in_background {
                        break;
                    }

                    // Reconnect on any socket exit (unless background/disconnect has moved to Idle).
                    if matches!(state.lock().unwrap().connection_state, ConnectionStateInternal::Idle) {
                        break;
                    }

                    if attempt >= max_attempts {
                        let mut s = state.lock().unwrap();
                        s.connection_state = ConnectionStateInternal::Failed { reason: "reconnect max attempts".to_string() };
                        log::debug!("[RustCore] reconnect max attempts reached");
                        break;
                    }
                }
            }
            Some(Command::Disconnect) => {
                let mut s = state.lock().unwrap();
                s.connection_state = ConnectionStateInternal::Idle;
            }
            Some(Command::Input(_)) | Some(Command::Heartbeat) => {
                // Ignore outgoing while disconnected.
            }
            Some(Command::SetBackground(bg)) => {
                let mut s = state.lock().unwrap();
                s.is_in_background = bg;
                if bg {
                    s.connection_state = ConnectionStateInternal::Idle;
                }
            }
            None => break,
        }
    }
}

async fn apply_event(
    state: &Arc<Mutex<SessionStateInternal>>,
    ws_stream: &mut tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    event: DCSSServerEvent,
) {
    let event_type_str = match &event {
        DCSSServerEvent::Hello { .. } => "hello",
        DCSSServerEvent::GameFrame { .. } => "frame",
        DCSSServerEvent::Message { .. } => "message",
        DCSSServerEvent::HeartbeatAck => "heartbeat_ack",
        DCSSServerEvent::HeartbeatRequest => "heartbeat",
        DCSSServerEvent::Error { .. } => "error",
        DCSSServerEvent::Unknown { type_name } => type_name.as_str(),
    }
    .to_string();

    {
        let mut s = state.lock().unwrap();
        s.diagnostics.last_event_type = Some(event_type_str);
    }

    match event {
        DCSSServerEvent::Hello { .. } => {}
        DCSSServerEvent::GameFrame { grid, status_line } => {
            let mut s = state.lock().unwrap();
            s.game_state.grid = grid;
            s.game_state.status_line = status_line;
        }
        DCSSServerEvent::Message { text } => {
            let mut s = state.lock().unwrap();
            s.game_state.last_message = text;
        }
        DCSSServerEvent::HeartbeatAck => {}
        DCSSServerEvent::HeartbeatRequest => {
            // Server asked us to send a heartbeat.
            let payload = encode_client_command_wire(DCSSClientCommand::Heartbeat);
            let _ = ws_stream.send(Message::Ping(vec![])).await;
            let _ = ws_stream
                .send(Message::Text(String::from_utf8_lossy(&payload).to_string()))
                .await;
        }
        DCSSServerEvent::Error { text, .. } => {
            let mut s = state.lock().unwrap();
            s.diagnostics.last_error = Some(text.clone());
            s.game_state.last_message = text;
        }
        DCSSServerEvent::Unknown { type_name } => {
            let mut s = state.lock().unwrap();
            s.game_state.last_message = format!("Unknown event: {type_name}");
        }
    }
}

// ===== C ABI =====

#[repr(C)]
pub struct DCSSSession {
    inner: Session,
}

fn cstr_to_string<'a>(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string()) }
}

#[no_mangle]
pub extern "C" fn dcss_session_create() -> *mut DCSSSession {
    ensure_rustls_crypto_provider();
    let session = DCSSSession {
        inner: Session::new(),
    };
    Box::into_raw(Box::new(session))
}

#[no_mangle]
pub extern "C" fn dcss_session_destroy(handle: *mut DCSSSession) {
    if handle.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub extern "C" fn dcss_session_connect(
    handle: *mut DCSSSession,
    url: *const c_char,
    client_version: *const c_char,
) {
    if handle.is_null() || url.is_null() {
        return;
    }

    let session = unsafe { &(*handle).inner };
    let url_s = cstr_to_string(url).unwrap_or_default();
    let client_s = cstr_to_string(client_version).unwrap_or_else(|| "dcss-ios-0.1".to_string());

    {
        let mut s = session.state.lock().unwrap();
        s.endpoint = Some(url_s);
        s.client_version = client_s;
        s.is_in_background = false;
        s.connection_state = ConnectionStateInternal::Connecting;
        s.diagnostics.last_error = None;
        s.diagnostics.reconnect_attempt = None;
    }

    session.ensure_loop_started();

    if let Some(tx) = session.cmd_tx.lock().unwrap().as_ref() {
        let _ = tx.try_send(Command::ConnectNow);
    }
}

#[no_mangle]
pub extern "C" fn dcss_session_disconnect(handle: *mut DCSSSession) {
    if handle.is_null() {
        return;
    }
    let session = unsafe { &(*handle).inner };
    {
        let mut s = session.state.lock().unwrap();
        s.connection_state = ConnectionStateInternal::Idle;
    }
    if let Some(tx) = session.cmd_tx.lock().unwrap().as_ref() {
        let _ = tx.try_send(Command::Disconnect);
    }
}

#[no_mangle]
pub extern "C" fn dcss_session_send_input(handle: *mut DCSSSession, command: *const c_char) {
    if handle.is_null() || command.is_null() {
        return;
    }
    let session = unsafe { &(*handle).inner };
    let cmd_s = cstr_to_string(command).unwrap_or_default();
    if let Some(tx) = session.cmd_tx.lock().unwrap().as_ref() {
        let _ = tx.try_send(Command::Input(cmd_s));
    }
}

#[no_mangle]
pub extern "C" fn dcss_session_send_heartbeat(handle: *mut DCSSSession) {
    if handle.is_null() {
        return;
    }
    let session = unsafe { &(*handle).inner };
    if let Some(tx) = session.cmd_tx.lock().unwrap().as_ref() {
        let _ = tx.try_send(Command::Heartbeat);
    }
}

#[no_mangle]
pub extern "C" fn dcss_session_app_did_enter_background(handle: *mut DCSSSession) {
    if handle.is_null() {
        return;
    }
    let session = unsafe { &(*handle).inner };
    {
        let mut s = session.state.lock().unwrap();
        s.is_in_background = true;
        s.connection_state = ConnectionStateInternal::Idle;
    }
    if let Some(tx) = session.cmd_tx.lock().unwrap().as_ref() {
        let _ = tx.try_send(Command::SetBackground(true));
    }
}

#[no_mangle]
pub extern "C" fn dcss_session_app_will_enter_foreground(handle: *mut DCSSSession) {
    if handle.is_null() {
        return;
    }
    let session = unsafe { &(*handle).inner };
    {
        let mut s = session.state.lock().unwrap();
        s.is_in_background = false;
    }
    session.ensure_loop_started();
    if let Some(tx) = session.cmd_tx.lock().unwrap().as_ref() {
        let _ = tx.try_send(Command::SetBackground(false));
        let _ = tx.try_send(Command::ConnectNow);
    }
}

#[no_mangle]
pub extern "C" fn dcss_session_get_snapshot_json(handle: *mut DCSSSession) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let session = unsafe { &(*handle).inner };
    let json = session.snapshot_json();
    CString::new(json).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn dcss_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(s));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> Vec<u8> {
        let path = match name {
            "hello" => "../Tests/DCSSCoreTests/Fixtures/hello.json",
            "frame" => "../Tests/DCSSCoreTests/Fixtures/frame.json",
            _ => panic!("unknown fixture"),
        };
        std::fs::read(path).expect("read fixture json")
    }

    #[test]
    fn decode_hello_fixture() {
        let data = fixture("hello");
        let event = decode_server_event(&data).expect("decode");
        match event {
            DCSSServerEvent::Hello { server_version } => assert_eq!(server_version, "0.32-webtiles"),
            _ => panic!("expected hello"),
        }
    }

    #[test]
    fn decode_frame_fixture() {
        let data = fixture("frame");
        let event = decode_server_event(&data).expect("decode");
        match event {
            DCSSServerEvent::GameFrame { grid, status_line } => {
                assert_eq!(grid, vec!["##########", "#..@.....#", "##########"]);
                assert_eq!(status_line, "HP 24/24 MP 3/3");
            }
            _ => panic!("expected frame"),
        }
    }

    #[test]
    fn decode_flattened_message_format() {
        let data = br#"{"msg":"msg","message":"You feel healthy."}"#;
        let event = decode_server_event(data).expect("decode");
        match event {
            DCSSServerEvent::Message { text } => assert_eq!(text, "You feel healthy."),
            _ => panic!("expected message"),
        }
    }

    #[test]
    fn encode_input_command() {
        let payload = encode_client_command_wire(DCSSClientCommand::Input { command: "o".to_string() });
        let v: Value = serde_json::from_slice(&payload).expect("json parse");
        assert_eq!(v["type"], "input");
        assert_eq!(v["payload"]["command"], "o");
    }

    fn hex_to_bytes(s: &str) -> Vec<u8> {
        s.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).expect("valid hex byte"))
            .collect()
    }

    #[test]
    fn decode_msgs_envelope_payload() {
        let payload = br#"{"msgs":[{"msg":"ping"},{"msg":"lobby_entry","username":"Broken26"}]}"#;
        let events = decode_server_events(payload).expect("decode msgs envelope");
        assert_eq!(events.len(), 2);
        match &events[0] {
            DCSSServerEvent::HeartbeatRequest => {}
            _ => panic!("expected heartbeat request"),
        }
        match &events[1] {
            DCSSServerEvent::Unknown { type_name } => assert_eq!(type_name, "lobby_entry"),
            _ => panic!("expected lobby_entry as unknown"),
        }
    }

    #[test]
    fn logged_binary_sequence_reproduces_current_parse_failure() {
        // Frames from device logs (stateful inflater path).
        let chunk1 = hex_to_bytes("c2 16 2c 83 ab 91 6c 6e 88 dc 48 36 41 ee 2f d0 ae 91 1c 5b 0b 00");
        let chunk2 = hex_to_bytes("1a 12 e9 c5 d2 14 2d bd 58 d0 36 bd 0c d6 ae 94 b1 81 81 39 4a 2a b1 a4");

        let mut inflater = StatefulBinaryInflater::new();

        let err1 = inflater.decode_events(&chunk1).expect_err("first chunk currently fails to parse");
        assert!(
            matches!(err1, ProtocolCodecError::MalformedPayload(ref m) if m.contains("expected value") || m.contains("no complete events yet")),
            "unexpected first error: {:?}",
            err1
        );

        let err2 = inflater.decode_events(&chunk2).expect_err("second chunk currently reproduces parse issue");
        assert!(
            matches!(err2, ProtocolCodecError::MalformedPayload(_)),
            "unexpected second error: {:?}",
            err2
        );
    }

    #[test]
    #[ignore = "network integration test; run explicitly"]
    fn live_websocket_receives_messages_from_cao() {
        ensure_rustls_crypto_provider();
        let rt = Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            use tokio::time::timeout;

            let (mut ws_stream, response) = timeout(
                Duration::from_secs(15),
                connect_async("wss://crawl.akrasiac.org:8443/socket"),
            )
            .await
            .expect("connect timeout")
            .expect("connect failed");

            assert_eq!(response.status().as_u16(), 101, "expected websocket upgrade");

            let mut inflator = StatefulBinaryInflater::new();
            for _ in 0..12 {
                let next_msg = timeout(Duration::from_secs(10), ws_stream.next())
                    .await
                    .expect("receive timeout");
                match next_msg {
                    Some(Ok(WsMessage::Text(t))) => {
                        log::debug!("[live-test] text frame len={}", t.len());
                        if let Ok(events) = decode_server_events(t.as_bytes()) {
                            for ev in events {
                                log::debug!("[live-test] decoded text event: {:?}", ev);
                            }
                        }
                        else {
                            panic!("decode text failed");
                        }
                    }
                    Some(Ok(WsMessage::Binary(b))) => {
                        log::debug!("[live-test] binary frame len={}", b.len());
                        if let Ok(events) = inflator.decode_events(&b) {
                            for ev in events {
                                log::debug!("[live-test] decoded binary event: {:?}", ev);
                            }
                        }
                        else {
                            panic!("decode binary failed");
                        }
                    }
                    Some(Ok(WsMessage::Ping(_))) | Some(Ok(WsMessage::Pong(_))) => {}
                    Some(Ok(WsMessage::Close(frame))) => {
                        panic!("socket closed before receiving enough frames: {:?}", frame);
                    }
                    Some(Err(e)) => panic!("socket receive error: {e}"),
                    None => panic!("socket ended before receiving enough frames"),
                    _ => {}
                }
            }
            let _ = ws_stream.close(None).await;
        });
    }
}

