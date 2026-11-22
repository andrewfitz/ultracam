pub mod audio;
pub mod director;
pub mod ffi;
pub mod llm;
pub mod model;
pub mod offline;
pub mod timeline;

pub use director::{Director, DirectorState};
pub use model::{
    AudioCue, CueKind, CutInstruction, CutReason, OfflineAnalysis, RecordingArtifact,
    SessionSource, SessionTimebase, SessionTimeline, StreamEvent, SwitcherConfig, SwitcherOutput,
    TranscriptCue, VideoObservation,
};
pub use timeline::TimelineRecorder;
