# Multicam production suite specification

**Design draft 0.2 · November 23, 2026 · For product and engineering review**

This document specifies the intended product. The existing Auto Switcher prototype is a source of reusable code and test fixtures. Its transports, process boundaries, and file formats have not been adopted as the final design. In this draft, **must** identifies a requirement and **proposed** identifies a design choice awaiting review. Example messages, filenames, and commands describe the proposed interfaces.

**Naming is deferred.** Cam (UltraCam), Switch (Auto Switcher), Transcribe (Transcriberrr) and Cut (MPCut) are working role labels. The current project names below identify the integration points. Choose the suite name, shared visual identity and final app icons after the core workflows are built. Protocol roles, schema identifiers, session files and capability negotiation must work across a display-name change.

## 1. Product outcome

An operator chooses a switching style and turns on Auto in UltraCam. The apps discover one another, exchange the necessary media, and show what they are doing. UltraCam records the original angles and applies the switcher’s decisions to Program. After the shoot, the editor can open exactly what aired in MPCut, generate a different edit from the originals, or adjust individual cuts. An editor starting with existing multicam files can enter the same workflow directly from MPCut.

Three requirements govern the design:

1. **One owner for each decision.** Auto Switcher owns all automatic shot selection, including a simple timer. UltraCam owns the truth about which frame reached Program. MPCut owns the editor’s project and export.
2. **Independent products.** Each app must be useful by itself and offer GUI and headless CLI entry points. Integration uses published capabilities and formats. For example, a timer needs no transcript service, and MPCut can open a completed edit without any service running.
3. **A portable editorial result.** A session must survive process restarts, moving media to another disk, and transfer to another machine. An edit must remain usable without the model that generated it.

The first integration covers the four first-party apps on one Mac plus portable file exchange. Other live routing hosts, remote service discovery, and device-specific control plug-ins are later work.

## 2. Starting point and required changes

| App | Existing capability to reuse | Required change |
|---|---|---|
| UltraCam | Camera identities, capture clocks, source recording, Program routing, frame-boundary application and recording sidecars | Replace the private director worker and linked interval policy with one service client. Add automatic registration, JPEG sampling, native audio publication, negotiated input delivery, and delayed multicam playout. |
| Auto Switcher | Rust director, heuristics, rules, timers, local face-landmark model, session journals, CLI and menu-bar prototype | Make the Rust service authoritative for all modes. Add session management, input negotiation, deadline-aware scheduling, native providers, durable revisions and editorial interchange. |
| Transcriberrr | GUI, CLI, batch transcription, native realtime tracks, frame timing, drafts, finals, retractions and reconnect support | Allow an authorized second process to subscribe to the producer’s recognition session. Connect live and batch outputs to the production time map. |
| MPCut | Native multicam projects, rational offsets, picture switches, fixed/follow/muted audio, aligned JPEG export and CLI | Add switch-session import/export, media identity matching, offline orchestration, alternate revisions and explicit round-trip conflict handling. |

MPCut already supports comparing camera JPEGs at the same group time. Transcriberrr already accepts mono PCM16 at 24 kHz and gives native tracks a common frame clock. Reuse these paths and preserve each app’s native project format. Development checkout references, relative to the directory containing the UltraCam and Auto Switcher repositories, are `misc/mpcut/README.md`, `misc/mpcut/Sources/MPCutCore/MulticamProject.swift` and `misc/transcriberrr/README.md`.

## 3. App responsibilities and service lifetime

| Owner | Publishes | Consumes | Standalone use |
|---|---|---|---|
| UltraCam | Route inventory, source health, production clock, sampled JPEGs, selected audio, applied cuts, recording manifests | Input plans, profile controls, cut requests, service status | Capture, manual Program routing and recording |
| Auto Switcher | Profile catalog, input plans, cut requests, explanations, status, session packages and edit revisions | Evidence, operator commands, actual application times | Headless or GUI direction using registered inputs, files or compatible providers |
| Transcriberrr | Timed speech, track and speaker attribution when available, revisions, model readiness | Live audio tracks or file jobs | Realtime ASR server and file transcription |
| MPCut | Aligned source coverage, requested stills, audio selection, editorial revisions and exports | Source recordings, transcripts, switching sessions | Multicam editing, analysis, still extraction and export |

**Proposed service model.** One per-user Auto Switcher service accepts multiple named sessions. Its GUI, the shared menu and its CLI control the same service. A live session has one authoritative Program host. An offline job has an independent session or revision and cannot claim a live host’s output. Transcriberrr likewise exposes its service to its GUI, CLI, audio publishers, and transcript subscribers.

Starting Auto must discover or launch the switcher exactly once, including simultaneous GUI and CLI starts. Discovery returns a service instance ID, endpoint, supported versions and readiness. A local rendezvous record and singleton lock are proposed; the sandboxed UltraCam build must prove discovery, launch and per-user authorization on a clean Mac before choosing the final macOS registration mechanism. A stale record is identified by a failed instance handshake. Opening or closing a control window must not interrupt active sessions. Releasing one client must not terminate another client’s ASR job. Headless session ownership and explicit stop commands must work with no window open.

UltraCam selects Auto, Hold, a profile, role bindings, audio source, processing mode, and profile-declared operator settings. Auto Switcher validates settings, returns the effective configuration and revision, and owns their behavior. The advanced profile editor and provider configuration belong in Auto Switcher. An operator can open the matching switcher or transcription session directly from UltraCam.

### Repository and release layout

**Proposed layout for review.** Keep four product repositories with independent releases. Put the versioned switching contracts, example profiles, exchange fixtures and conformance runner in Switch. Each app pins a published contract release and advertises its supported protocol versions at runtime. This lets a separately installed Cut import a session written by an older Cam/Switch combination. Ship the small shared menu helper as a separately versioned component from the Switch repository. Each GUI installer must be able to supply or reuse it, including on a Mac with only Cut installed. Integration builds test the four released apps together. Repository consolidation and product renaming are separate decisions from the service extraction.

## 4. Processing modes and evidence deadlines

| Mode | Evidence available for a target cut at media time T | Output commitment |
|---|---|---|
| Immediate live | Evidence already received when the scheduler must decide. Timers, health, levels, pauses, motion and fast face-direction estimates are primary inputs. Recent partial or final text may contribute. | Apply at the first eligible Program frame within the request window. Slow inference never blocks capture, audio delivery or Program. |
| Delayed live | Capture runs ahead of Program by configured delay D. For a cut at T, the director can use observations from later media times that actually arrived before T’s playout deadline. | The viewer receives delayed picture and matching delayed audio. A pending decision may change until the host’s commit deadline. Original recordings and capture preview stay on source time. |
| Offline edit | The job can inspect the complete selected range, use final text, compare all angles and revisit earlier provisional cuts. | Write an editable revision. Rendering a movie is a separate MPCut operation. |

**Proposed initial settings.** Start experiments at 4 JPEG samples per second per eligible camera, 640 pixels on the long edge, and a 10-second delayed-live preset. These are qualification inputs, not measured system-wide guarantees. Profiles may operate without images or request other rates. Negotiate what the host can actually deliver. A history window of ten seconds of *past* evidence is also valid in immediate mode and adds no intentional Program delay.

**Example.** A person starts speaking at 01:20 and a transcript identifies the answer at 01:22. Immediate mode can react at or after receipt. If capture is at 01:22 and delayed Program is at 01:12, the switcher still has time to place the cut at 01:20. In an offline pass, it can put the cut on the first suitable source frame and keep the reaction shot that follows. In every case the decision must carry the timestamps of the evidence it actually used.

**Delay ownership.** UltraCam buffers timestamped, retrievable picture for every eligible angle and the selected soundtrack. Its admission check estimates memory, disk bandwidth, decode capacity, camera count, frame rates and retention margin. A bounded compressed or disk-backed buffer is a design candidate. If an angle cannot cover the intended playhead, it is ineligible there. Advertise earliest available, latest available and committed-through times. During warm-up, show remaining fill time and require the operator’s selected startup behavior before taking delayed Program live. On changing delay or recovering from underrun, expose the discontinuity and maintain A/V sync. Never silently jump a live audience ten seconds or label an unsupported delay active.

**Optional parallel output.** Immediate Program plus a context-aware alternate edit can share source recordings and transcript work. The alternate is a distinct revision with its own evidence cutoff and never issues a command to live Program. This workflow does not require multi-angle delayed playout.

## 5. Native live workflow

1. UltraCam opens or resumes a production, registers route IDs, stream capabilities, actual on-air route, clock generation and available recording assets.
2. Auto Switcher resolves the selected profile’s editorial roles to routes. Return missing or ambiguous bindings for operator selection. Persist explicit bindings by ID, including after cameras reorder.
3. Auto Switcher returns an input plan with required and optional signals, sample rate and sizes, model readiness requirements, acceptable age, and requested delay. UltraCam acknowledges negotiated values or explains the shortfall.
4. UltraCam samples its own capture frames into JPEGs. If the plan needs text, UltraCam finds or launches Transcriberrr, opens an audio track and passes a scoped subscription reference to Auto Switcher. UltraCam sends the audio once to Transcriberrr. Auto Switcher consumes events directly from that session.
5. For low-latency speech or prosody evidence, UltraCam also supplies the requested timestamped meter samples or an explicitly negotiated analysis audio stream. Thresholding, interpretation and shot selection run in Auto Switcher.
6. Auto Switcher issues an expiring proposal. UltraCam verifies the bound source, coverage, generation and deadline, schedules it at a real output boundary and reports the result. A scheduled request alone cannot advance the switcher’s confirmed Program state.
7. On stop, UltraCam closes recording segments and publishes final media references. Auto Switcher finalizes the journal and the as-aired revision. Failed or interrupted finalization remains recoverable and is visible to the operator.

## 6. Wire contract

**Proposed transport.** Use a local authenticated WebSocket control connection with UTF-8 JSON envelopes. Use separately flow-controlled binary channels for JPEG data. Continue to use Transcriberrr’s native WebSocket audio encoding, track registration and resume semantics. An independent client may publish normalized evidence without transferring media. File interchange requires no network connection.

**Negotiation and identity.** A handshake includes peer role, instance ID, protocol major/minor and capabilities. Reject incompatible majors; negotiate optional features explicitly. Pin the selected versions for the connection. Assign stable production, route, asset, track and segment IDs. Use fresh connection and instance IDs on restart. A route represents a logical editorial choice; an asset identifies a recording segment. Multiple files or reconnects may belong to one route.

| Message family | Publisher → consumer | Required semantics |
|---|---|---|
| `hello`, `capabilities`, `service.status` | Each peer → connected peer | Version selection, actor identity, instance, readiness, supported signals and resource limits |
| `session.open/resume/close`, `host.claim/release` | Host or job runner ↔ switcher | Session identity, mode, exclusive live routing lease, last accepted sequence, current generation |
| `routes.update`, `clock.map/reset`, `source.health` | Host → switcher | Stable route bindings, coverage, clock mapping and effective media time |
| `profile.apply`, `input.plan/accepted` | Controller ↔ switcher ↔ producers | Expected config revision, effective config, required/optional inputs, negotiated rates and degradation |
| `frame.sample`, `audio.levels`, `analysis.observation` | Producer → switcher | Sample ID, route or track, generation, media time, availability time, payload descriptor and producing method |
| `transcript.subscribe`, transcript revisions | Switcher ↔ Transcriberrr | Scoped read access, track and item IDs, revision, source frame range, text, final/retracted state, optional speaker and confidence |
| `cut.request/cancel/applied/rejected`, `route.manual` | Director ↔ host | Decision ID, generation, target, intended time, expiry, reason, outcome and actual frame identity |
| `state.snapshot/update`, `job.progress/error` | Services → observers | Monotonic journal sequence, component state, input age, lag, backlog, recoverable error code and capability impact |

A minimal proposed cut request:

```json
{
  "version": "1.0",
  "type": "cut.request",
  "session_id": "prod-42",
  "generation": 3,
  "sequence": 187,
  "decision_id": "decision-17",
  "profile_revision": 4,
  "target_route_id": "desk",
  "intended_ticks": 2880000,
  "expires_ticks": 3120000,
  "reason": "desk_activity",
  "evidence_ids": ["frame-92", "levels-55"]
}
```

The matching host outcome:

```json
{
  "version": "1.0",
  "type": "cut.applied",
  "session_id": "prod-42",
  "generation": 3,
  "decision_id": "decision-17",
  "target_route_id": "desk",
  "program_ticks": 2888008,
  "asset_id": "desk-take-2",
  "source_pts": {"value": 100100, "timescale": 30000}
}
```

**Ordering and retry.** Each publisher identifies its input events. The switcher assigns the canonical journal sequence on acceptance. A retry with the same ID and payload returns the previous result; the same ID with a different payload is a conflict. Only the routing lease holder can confirm Program. On reconnect, exchange the actual route, generation, pending IDs and last contiguous sequence. Recover history from the journal or start with a new snapshot after a declared gap. Historical proposals must never trigger a second cut. Manual changes cancel conflicting pending automation. A cancellation racing an applied frame resolves to what the host actually displayed.

**Queues and deadlines.** Keep one replaceable unsent analysis frame per route in live mode. Bound decoded dimensions, payload bytes, concurrent inference, transcript replay and observer queues. Carry JPEG metadata and payload under the same sample ID; discard incomplete samples. Prioritize route and clock messages over media delivery. Missing JPEGs affect visual evidence age independently of camera health. Offline jobs use bounded batches and backpressure so requested frames can be completed instead of silently dropped.

### Observers and generic outputs

A session owner can enable event broadcasting to authorized subscribers. A subscriber receives the initial snapshot, then sequenced updates for the session and topics it selected. Observing a session grants no routing authority. Route IDs are opaque to Switch. The host binds an ID to a camera, scene or other action. Native Cam uses the acknowledged host path.

For a host controlled through global shortcuts, the operator can bind each route ID to a macOS keycode and modifiers and explicitly arm that output. The adapter posts a shortcut once per committed command ID, reports permission or dispatch failure, and never posts shortcuts during history replay or an offline edit. Journal a successful post as `shortcut.dispatched`. Without a host acknowledgement the actual route and frame remain unconfirmed. Timestamp export in GUI and CLI must distinguish intended time, dispatch time and confirmed Program time, including manual cuts. Proposed CSV columns are session ID, decision ID, route, outcome, intended ticks, dispatch time with clock domain, and applied ticks. Missing times are empty. The first release focuses on the four native apps. OBS and device-specific adapters are later integrations.

## 7. Clocks, media sampling and transcript semantics

Use a production timeline at **240,000 ticks/second**, with integer ticks in interchange. Preserve native source PTS and timescale alongside production time. Each recording segment has an explicit source-to-production mapping, bounded validity range and generation. Use rational arithmetic until a frame must be selected. For ordinary unit-rate material, group time equals source time plus the declared offset. Variable frame rate, discontinuities, restarted cameras and drift require actual indexed frame PTS and, where needed, additional mapping segments. Never derive all frame boundaries from nominal fps.

For example, 24,000 mono audio frames at 24 kHz represent one second or 240,000 production ticks. A track that starts at production tick 480,000 maps audio frame 24,000 to tick 720,000 within that mapping segment. A new audio origin must have a new mapping. For wall-clock latency diagnostics, record monotonic arrival times separately from media time.

A JPEG descriptor carries route ID, sample ID, requested and actual capture times, source PTS, dimensions, orientation and media type. UltraCam chooses a captured frame and encodes asynchronously outside Program delivery. MPCut performs the equivalent operation against its index and reports the *actual* frame selected, including when two angles have different frame rates. An unavailable angle returns a coverage gap.

A transcript event preserves track/item identity, revision order, audio-frame range, text, optional speaker attribution, and when it became available. Keep a higher revision, honor retractions and deduplicate replay. Missing confidence or unidentified speakers must remain unknown. A correction arriving after Program commitment can improve an alternate edit; the as-aired result stays factual.

## 8. Profiles and providers

Profiles are versioned JSON documents. Publish JSON Schemas and valid/invalid examples for profiles, control envelopes, sample descriptors, transcript bindings, session manifests and edit revisions. Allow namespaced extensions and explicitly mark required capabilities. Unknown required features fail validation before activation. Profiles are data and must not execute shell commands.

| Profile field group | Required behavior |
|---|---|
| Identity and roles | Stable profile ID/version, named editorial roles, required/optional bindings and supported timing modes |
| Inputs | Signal type, producer capability, preferred sample rate, freshness, acceptable revisions, and required or optional status |
| Decisions | Timer or rule conditions, priority and tie resolution, shot minimum/maximum, dwell, cooldown, hysteresis and health behavior |
| Model policy | Task and output schema, eligible providers, deadlines, score handling, fallback and explicit cloud permission |
| Operator controls | Typed labels, ranges, defaults, units and whether a change applies immediately or at a new decision boundary |
| Provenance | Effective profile hash, provider/model version, effective parameters and reason/evidence references for every proposed cut |

Ship model-free Timer and Motion profiles, a talking-head profile, a camera-facing profile, and a multi-angle workbench example. Treat face direction as an estimate with confidence; hold through uncertainty, multiple plausible faces and brief head turns. Providers may publish additional typed signals such as pitch, energy, speaker activity or model-estimated tone. A signal definition must identify units, time range and provenance. A profile must declare how to behave when that signal is absent.

Switch must ship a usable local image-capable model with its release and expose its readiness from the GUI and CLI. Model-free profiles must start with inference disabled. The built-in provider and optional local or cloud providers use the same versioned observation or decision interface, reporting supported inputs, deadlines, model identity and structured outputs. Switch validates candidate decisions against route bindings, hold, timing and health policy before requesting a cut. An optional cloud provider receives only the explicitly authorized inputs. Provider deadlines differ by mode. Immediate switching drops stale results; delayed switching may use them until the relevant playout deadline; offline processing can retry or checkpoint them. Store outputs used for a decision so replay can reproduce the recorded choice even if a model changes.

## 9. Portable switching session and MPCut round trip

**Proposed artifact:** a directory package with a versioned manifest, append-only journal and immutable edit revisions. It can reference external originals and optionally include sampled stills or transcripts. The package must remain readable with no running service.

```text
Interview.switchsession/
  manifest.json
  journal/events.jsonl
  revisions/as-aired.json
  revisions/offline-001.json
  revisions/editor-001.json
  evidence/                 # optional cached samples and transcripts
```

| Record | Minimum content |
|---|---|
| Manifest | Format version, session ID, scale, mode, roles, routes, recording assets, media locators, fingerprints, source coverage, mapping segments, initial route, audio policy, revisions and completion state |
| Journal | Ordered evidence references, config changes, generations, manual actions, proposals, cancellations, expiries and actual host outcomes |
| Edit revision | Stable revision ID, parent revision, authoring app, creation method, ordered non-overlapping picture spans, cut IDs, angle/asset references, audio selections and provenance |
| Evidence inventory | Sample or transcript IDs, producer/model version, source ranges, relative locators, content hashes and retention policy |

Use half-open picture spans `[start, end)`. Within a declared continuous program range there must be one active picture per tick or an explicit gap. A boundary belongs to the incoming shot. Preserve fixed soundtrack, follow-camera and muted policies independently of picture selections. Distinguish missing coverage from an intentional editorial gap. Moving a cut keeps its identity; adding a new cut creates a new identity. Record removed IDs relative to the parent revision so a later merge can detect conflicts.

**As aired** is constructed from the initial Program state, actual applications and manual changes. A rejected or expired proposal remains in the journal. If a crash leaves an outcome unknown, mark the affected range unconfirmed until reconciled. **Offline pass** and **editor revision** are separate descendants. Reanalysis cannot overwrite a human revision. Save manifests and revisions atomically, checkpoint long jobs, validate referenced assets, and recover the contiguous valid prefix after an interrupted journal append.

**Live → MPCut.** Resolve originals by stable asset identity, with relative paths and fingerprints for relinking. Map production spans to MPCut group time, preserve source offsets, and instantiate the native multicam angles, switches, soundtrack policy and selected assembly range. Keep exchange IDs in project metadata or a versioned companion mapping saved with the project. Present missing assets and conflicting offsets for resolution. Opening a session must never require a rendered Program recording.

**MPCut → offline director.** MPCut owns alignment and selected ranges. Export a source manifest, aligned angle samples with actual frame timestamps, and selected soundtrack or audio-track references. Transcriberrr produces a timed transcript. Auto Switcher runs the selected profile and returns a proposed revision. MPCut validates angle coverage, imports it alongside the current edit and lets the user preview, accept, modify or discard it.

**MPCut → session → MPCut.** Export editorial changes as a child revision, including revised boundaries, removed switches, retained source offsets and audio choices. If the session head changed since import, preserve both revisions and ask which to open or merge. Unsupported native edits must generate an explicit interchange report; do not silently flatten a speed change, assembly reorder or audio edit into a different multicam cut. Exact lossless round-trip coverage for the first release is synchronized multicam picture cuts, supported soundtrack policies and declared group ranges. Broader timeline operations need separately specified mappings.

## 10. Operator surfaces and headless workflows

The GUI and CLI of each app must invoke the same domain operations and validation. An offline batch must run with no GUI session interaction, support cancellation and resumption, stream machine-readable progress, write diagnostics separately, and return a meaningful terminal exit status. Hardware capture, model installation or macOS permissions may require initial setup; report the missing prerequisite before starting a job.

| App | GUI workflow | Proposed CLI operation |
|---|---|---|
| UltraCam | Select feeds, profile, timing mode, audio and recording destination; start/hold/stop live session | Start capture with a saved production config; enumerate devices, inspect status, hold/resume, stop and finalize |
| Auto Switcher | Sessions, profile editor, bindings, evidence freshness, decision history and export | Serve, validate a profile, inspect/watch a session, run/resume offline analysis and export a revision |
| Transcriberrr | Select model, run service, show publishing tracks and subscribing consumers; transcribe files | Existing serve/batch operations plus scoped subscription management and session status |
| MPCut | Open an as-aired session, relink, generate alternate edit, compare and export changes | Inspect/import session, export aligned samples/audio, orchestrate analysis, import or export a revision and render through the normal export engine |

### One macOS menu-bar item

In a graphical login session, the first suite GUI that requests menu integration starts or attaches to a per-user menu helper. Concurrent launches must converge on one status item. The helper presents one monochrome macOS template icon for the whole suite, with four stable submenus. A headless command starts only the services its workflow needs. The helper can quit, restart or be upgraded while capture, recognition and offline jobs continue. On reconnect it rebuilds its view from service snapshots.

| Submenu | At a glance | Actions |
|---|---|---|
| Cam | Capture state, actual Program route, recording and delay | Open Cam, open the active production, take or release Hold |
| Switch | Service readiness, active profile and routing host | Open Switch, start or connect to the service, inspect decisions, edit the profile |
| Transcribe | Audio publisher, incoming level, model readiness and transcript lag | Open Transcribe, inspect the active track, start a standalone transcription |
| Cut | Open project or headless job, current stage, progress and revision | Open Cut, import the live session, inspect or resume an offline job |

Show installation, GUI and service state separately. A closed window can coexist with a running service. Show missing apps as “Not installed” and idle installed apps as “Ready to open.” Each submenu exposes actions supported by that installation and authorized for that session. Quitting the menu helper and stopping a production are distinct actions.

The active production view lists **Cam → Switch** (registration and JPEGs), **Cam → Transcribe** (audio), **Transcribe → Switch** (transcript), and **Switch → Cam** (cut requests and host acknowledgements). For an offline job show Cut as the evidence producer, the selected transcription job and the returned revision. Each link reports its endpoints, session ID, negotiated capability, last input or acknowledgement, and reason when waiting, degraded or disconnected. Mark optional links unused when the profile did not request them. Each app exposes its own snapshot to its headless CLI. The menu joins snapshots by session ID so an unrelated healthy ASR job cannot make a broken production appear connected.

**Cross-app status.** Expose the same snapshot to GUI and CLI. Show service identity, connection state, negotiated capability, last valid media time, input age, backlog and consequence for directing. UltraCam should distinguish “audio arriving, waiting for speech” from “no audio received.” Auto Switcher should distinguish “model warming” from “source unavailable.” Transcriberrr should identify the producing audio track and subscribers. MPCut should show completed stages, stale inputs, relink requirements and the revision being reviewed.

For delayed Program, display actual buffer fill, capture time, playout time and remaining decision headroom. For immediate Program, report measured application latency and stale evidence. For offline, report media range completed by stage and whether prior work will be reused. Each manual cut, Hold or profile change should show its effective media time.

## 11. Failure, privacy and resource policy

| Condition | Required behavior |
|---|---|
| Switcher unavailable or restarted | UltraCam holds the actual current route, keeps manual control and recording available, reconnects with bounded backoff and reseeds from Program before resuming automation. |
| Transcription unavailable, late or retracted | Publish speech status; apply the profile’s declared fallback or hold. Continue independent camera and audio work. |
| JPEG stream stale or model overloaded | Drop superseded live samples, mark visual evidence stale, and reduce negotiated sampling when supported. Do not label a camera offline solely from analysis lag. |
| Route lost or two decisions race | Host rejects an unavailable target, applies at most one decision per boundary, and reports any actual manual override. Recovery follows the effective health/hold policy. |
| Delayed buffer too small or a deadline missed | Publish reduced route coverage and missed deadline; retain a playable synchronized route or enter the specified fallback. Past Program frames are immutable. |
| Offline input changes during a job | Invalidate dependent results by source/alignment/config/model fingerprint; reuse valid stages. Never attach stale evidence to a revised sync map. |
| Disk full or recording interrupted | Surface loss of durable history separately from capture health. Preserve completed assets and revisions; explicitly mark any unrecorded interval. |
| Incompatible peer or denied capability | Explain the version/capability mismatch and available modes before activation. Other independent workflows continue. |

Default to local processing and loopback service access. Authenticate local peers and scope publish, subscribe, route-control and file access separately. An ASR read subscription cannot publish audio or take over a producer’s resume credential. Store credentials in the OS credential store, redact logs, and exclude credentials from portable packages. Persist transcripts and JPEGs only under the session’s selected retention settings. Show the provider and data types before enabling cloud transfer. Propagate cancellation to jobs started solely for that session.

## 12. Delivery sequence and release gates

| Increment | Demonstration required before moving on |
|---|---|
| 1. Contract and round-trip fixture | Two angles with different offsets, a gap, a manual switch and one continuous microphone. Import into MPCut, move one boundary, export and reopen. Angle selection and audio match at every frame; the original revision still opens. |
| 2. Single shared service | Start Auto from UltraCam with no services running, then repeat with an existing service. Exactly one switcher owns the session. A timer cut is acknowledged at the Program boundary. Remove the private director and embedded interval algorithm after parity checks. |
| 3. Native live evidence | Two cameras deliver JPEGs without reopening devices. One audio stream is recognized once while the switcher receives revisions directly. Verify clock resets, a late final, health loss and manual override. Demonstrate each app’s independent headless workflow. |
| 4. Offline generation | Run an aligned multicam project via GUI and CLI. Interrupt after still extraction, resume, import the same result and relink moved files. A changed offset invalidates the appropriate cached evidence. Human revisions survive a second analysis. |
| 5. Delayed Program | At representative camera counts, formats and rates, demonstrate ten seconds of aligned picture and audio, a context-informed retroactive choice before commitment, and graceful underrun. Test both audience-delayed Program and the immediate-plus-alternate workflow if approved. |
| 6. Suite menu and standalone operation | Launch all four GUIs concurrently and verify one template icon with four submenus. Close and restart the helper during a live recording and an offline job. Disable transcription and verify that only dependent links degrade. On a clean login run the four CLI workflows without starting a GUI or creating a menu icon. Test each product installed alone. |
| 7. Release qualification | Repeat on a clean Mac with signed apps, sandbox boundaries, denied permissions, model warm-up, process crashes and offline operation. Validate compatibility, migration, package recovery and bounded resource use. |

Publish conformance fixtures for protocol negotiation, idempotent retries, wrong generation, expired cut, manual/application race, transcript retraction, mixed frame rates, delayed-camera gaps and edit-package round trips. Measure **capture → sample**, **sample → evidence**, **speech → draft/final**, **evidence → decision**, and **decision → actual Program frame** independently. Report p50/p95/p99, drops, CPU/GPU load, peak memory, buffer storage and A/V drift under sustained load. Set numeric live release budgets using those measurements; a fast inference benchmark alone does not qualify the complete system.

## 13. Decisions for review before implementation

1. **Output modes.** Approve immediate Program, delayed Program and offline edits as the core modes. Decide whether immediate Program plus a parallel alternate edit belongs in the first release.
2. **Delay behavior.** Confirm the ten-second starting preset, acceptable storage/resource cost, and what the audience sees during initial fill or an unrecoverable underrun.
3. **Session authority.** Approve one per-user service, multiple isolated sessions and one authoritative live Program host per session.
4. **Interchange boundary.** Approve a portable versioned session package, immutable as-aired history, and child editorial revisions alongside MPCut’s native project. Decide which assembly edits beyond cuts and soundtrack choices need first-release round-trip fidelity.
5. **Evidence defaults.** Decide whether raw JPEG samples, transcript text or only decisions and evidence references are saved by default, and whether cloud processing is ever allowed without per-production selection.
6. **Qualification targets.** Select the first supported hardware/camera matrix, acceptable immediate latency, acceptable delayed A/V drift, and default fallback when a profile loses required evidence.

7. **Packaging.** Review the four-repository layout, shared helper distribution and upgrade ownership against standalone installs. Validate mixed-version operation before fixing the installer strategy.

Approval of this draft establishes the architecture. The next design deliverable would be machine-readable schemas, worked wire traces and a golden four-app round-trip fixture for review before production integration.
