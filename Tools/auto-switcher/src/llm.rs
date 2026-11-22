use crate::model::{AudioCue, MediaTime, TranscriptCue, VideoObservation};
use anyhow::{Context, Result};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Weak};
use std::thread;
use std::time::Duration;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DecisionContext {
    pub request_id: Uuid,
    pub media_time: MediaTime,
    pub current_camera_id: String,
    pub anchor_camera_id: String,
    pub emphasis_camera_id: String,
    pub audio: Vec<AudioCue>,
    pub transcript: Vec<TranscriptCue>,
    pub video: Vec<VideoObservation>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LlmProposal {
    pub target_camera_id: Option<String>,
    pub confidence: f32,
    pub reason: String,
    #[serde(default)]
    pub hold: bool,
}

pub trait LlmDecisionProvider: Send {
    fn decide(&mut self, context: &DecisionContext) -> Result<LlmProposal>;
}

#[derive(Debug, Clone)]
pub struct OllamaProvider {
    pub endpoint: String,
    pub model: String,
    pub timeout: Duration,
}

impl Default for OllamaProvider {
    fn default() -> Self {
        Self {
            endpoint: "http://127.0.0.1:11434/api/generate".to_string(),
            model: "llama3.2:latest".to_string(),
            timeout: Duration::from_secs(20),
        }
    }
}

#[derive(Debug, Serialize)]
struct OllamaRequest<'a> {
    model: &'a str,
    prompt: String,
    stream: bool,
    format: &'static str,
}

#[derive(Debug, Deserialize)]
struct OllamaResponse {
    response: String,
}

impl LlmDecisionProvider for OllamaProvider {
    fn decide(&mut self, context: &DecisionContext) -> Result<LlmProposal> {
        let prompt = format!(
            "You are a conservative video director. Return JSON only with keys target_camera_id, confidence, reason, hold. Choose only the anchor or emphasis camera. Prefer hold when evidence is weak. Context:\n{}",
            serde_json::to_string(context)?
        );
        let client = Client::builder().timeout(self.timeout).build()?;
        let response: OllamaResponse = client
            .post(&self.endpoint)
            .json(&OllamaRequest {
                model: &self.model,
                prompt,
                stream: false,
                format: "json",
            })
            .send()
            .context("Ollama request failed")?
            .error_for_status()
            .context("Ollama returned an error status")?
            .json()
            .context("invalid Ollama response envelope")?;
        let proposal: LlmProposal = serde_json::from_str(&response.response)
            .context("Ollama response was not valid decision JSON")?;
        Ok(proposal)
    }
}

struct Request {
    session: Weak<()>,
    id: Uuid,
    context: DecisionContext,
}

struct ResultMessage {
    id: Uuid,
    result: Result<LlmProposal, String>,
}

/// Non-blocking delayed advisor. The realtime loop never waits for Ollama;
/// requests execute on a bounded worker channel and are only eligible after
/// the configured media delay. Late responses are discarded by the caller.
pub struct DelayedLlmAdvisor {
    session: Arc<()>,
    request_tx: SyncSender<Request>,
    result_rx: Receiver<ResultMessage>,
    pending: HashMap<Uuid, (MediaTime, MediaTime)>,
    completed: HashMap<Uuid, Result<LlmProposal, String>>,
}

impl DelayedLlmAdvisor {
    pub fn new(provider: Box<dyn LlmDecisionProvider>) -> Self {
        let (request_tx, request_rx) = mpsc::sync_channel::<Request>(8);
        let (result_tx, result_rx) = mpsc::channel::<ResultMessage>();
        thread::Builder::new()
            .name("auto-switcher-ollama".to_string())
            .spawn(move || {
                let mut provider = provider;
                while let Ok(request) = request_rx.recv() {
                    if request.session.upgrade().is_none() {
                        continue;
                    }
                    let id = request.id;
                    let result = provider
                        .decide(&request.context)
                        .map_err(|error| error.to_string());
                    if result_tx.send(ResultMessage { id, result }).is_err() {
                        break;
                    }
                }
            })
            .expect("failed to start Ollama advisor worker");
        Self {
            session: Arc::new(()),
            request_tx,
            result_rx,
            pending: HashMap::new(),
            completed: HashMap::new(),
        }
    }

    /// Retire queued requests and forget their IDs so in-flight replies are discarded by poll.
    pub fn reset(&mut self) {
        self.session = Arc::new(());
        self.pending.clear();
        self.completed.clear();
    }

    pub fn submit(
        &mut self,
        mut context: DecisionContext,
        available_at: MediaTime,
        expires_at: MediaTime,
    ) -> Option<Uuid> {
        const MAX_PENDING_REQUESTS: usize = 64;
        if self.pending.len() >= MAX_PENDING_REQUESTS
            || !available_at.is_finite()
            || !expires_at.is_finite()
            || available_at < 0.0
            || expires_at < available_at
        {
            return None;
        }
        let id = Uuid::new_v4();
        context.request_id = id;
        let request = Request {
            session: Arc::downgrade(&self.session),
            id,
            context,
        };
        if self.request_tx.try_send(request).is_err() {
            return None;
        }
        self.pending.insert(id, (available_at, expires_at));
        Some(id)
    }

    pub fn poll(&mut self, now: MediaTime) -> Vec<(Uuid, Result<LlmProposal, String>)> {
        if !now.is_finite() || now < 0.0 {
            return Vec::new();
        }
        let mut output = Vec::new();
        while let Ok(message) = self.result_rx.try_recv() {
            if !self.pending.contains_key(&message.id) {
                continue;
            }
            self.completed.insert(message.id, message.result);
        }
        let expired: Vec<Uuid> = self
            .pending
            .iter()
            .filter_map(|(id, (_, expires_at))| (now > *expires_at).then_some(*id))
            .collect();
        for id in expired {
            self.pending.remove(&id);
            self.completed.remove(&id);
        }
        let ready: Vec<Uuid> = self
            .pending
            .iter()
            .filter_map(|(id, (available_at, _))| {
                (now >= *available_at && self.completed.contains_key(id)).then_some(*id)
            })
            .collect();
        for id in ready {
            self.pending.remove(&id);
            if let Some(result) = self.completed.remove(&id) {
                output.push((id, result));
            }
        }
        output
    }
}
