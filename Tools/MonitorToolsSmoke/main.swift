import Foundation
import Darwin
import CoreVideo
import Metal
import MonitorToolsCore
import MonitorToolsMetal

// This executable only creates synthetic buffers. No capture/device APIs are imported.
// Paced N-feed run of the GPU monitor path: every offered frame must produce one
// completed picture encode, scopes run at the requested rate in their own command
// buffers, producer buffers stay untouched, and GPU objects stop growing after warmup.
struct Failure: Error { let reason: String }
func require(_ value: @autoclosure () -> Bool, _ reason: String) throws { if !value() { throw Failure(reason: reason) } }
func buffer(_ value:UInt8,width:Int=320,height:Int=180,format:OSType=kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
    var result:CVPixelBuffer?
    let attrs=[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary
    try require(CVPixelBufferCreate(nil,width,height,format,attrs,&result)==kCVReturnSuccess,"allocation")
    let image=result!
    CVBufferSetAttachment(image,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
    CVBufferSetAttachment(image,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
    CVBufferSetAttachment(image,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
    CVPixelBufferLockBaseAddress(image,[])
    if format==kCVPixelFormatType_422YpCbCr10 {
        let words=CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to:UInt32.self),stride=CVPixelBufferGetBytesPerRow(image)/4
        memset(words,0,CVPixelBufferGetDataSize(image))
        let cb=UInt32(512+Int(value)),cr:UInt32=512
        for row in 0..<height {for x in Swift.stride(from:0,to:width,by:6) {
            // A moving-free ramp with vertical edges so focus and zebra have work.
            let y=UInt32(64+(Int(value)*876/255+x/6%7*40+(x/96%2)*200)%876)
            let i=row*stride+x/6*4
            words[i]=cb | (y<<10) | (cr<<20);words[i+1]=y | (cb<<10) | (y<<20)
            words[i+2]=cr | (y<<10) | (cb<<20);words[i+3]=y | (cr<<10) | (y<<20)
        }}
    } else {memset(CVPixelBufferGetBaseAddress(image),Int32(value),CVPixelBufferGetDataSize(image))}
    CVPixelBufferUnlockBaseAddress(image,[])
    return image
}
let qualificationActivity=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.latencyCritical],reason:"Paced native video qualification")
DispatchQueue.global(qos:.userInitiated).async {
let exitCode:Int32
do {
    var seconds=10.0,feeds=2,width=320,height=180,format:OSType=kCVPixelFormatType_32BGRA,fps=30000.0/1001
    var index = 1
    while index < CommandLine.arguments.count {
        let arg = CommandLine.arguments[index]
        guard index + 1 < CommandLine.arguments.count else { throw Failure(reason: "missing argument") }
        if arg == "--seconds", let v = Double(CommandLine.arguments[index+1]), v >= 1, v <= 7200 { seconds = v }
        else if arg == "--feeds", let v = Int(CommandLine.arguments[index+1]), [1,2,4].contains(v) { feeds = v }
        else if arg == "--width",let v=Int(CommandLine.arguments[index+1]),(16...3840).contains(v),v%2==0 {width=v}
        else if arg == "--height",let v=Int(CommandLine.arguments[index+1]),(16...2160).contains(v),v%2==0 {height=v}
        else if arg == "--format",["v210","bgra"].contains(CommandLine.arguments[index+1]) {format=CommandLine.arguments[index+1] == "v210" ? kCVPixelFormatType_422YpCbCr10:kCVPixelFormatType_32BGRA}
        else if arg == "--fps",["29.97","59.94"].contains(CommandLine.arguments[index+1]) {fps=CommandLine.arguments[index+1] == "29.97" ? 30000.0/1001:60000.0/1001}
        else { throw Failure(reason: "usage: --seconds N --feeds 1|2|4 --width W --height H --format v210|bgra --fps29.97|59.94") }
        index += 2
    }
    let a = MonitorTargetID("synthetic-a")
    let stale = MonitorFrameStamp(target: a, generation: 1, sequence: 1, sourcePTS: 0, hostTime: 0, configurationRevision: 1)
    try require(!stale.matches(target: a, generation: 2, configurationRevision: 1), "stale generation accepted")
    var configs = (0..<feeds).map { _ in MonitorConfiguration() }
    configs[0].zebra.thresholdIRE = 80
    if feeds > 1 { try require(configs[1].zebra.thresholdIRE == 95, "feed configuration leaked") }
    // Package shader resource loading, and a shader failure reported instead of drawn.
    let gpuAvailable = MTLCreateSystemDefaultDevice() != nil
    let fixtureSource = try buffer(32), fixtureOutput = try buffer(240)
    let fixtureSignal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "sRGB")
    func fixtureBundle() -> MonitorFrameBundle {
        let stamp = MonitorFrameStamp(target: MonitorTargetID("runtime-fixture"), generation: 1, sequence: 1, sourcePTS: 0, hostTime: ProcessInfo.processInfo.systemUptime, configurationRevision: 1)
        return MonitorFrameBundle(stamp: stamp, source: fixtureSource, output: fixtureOutput, correspondence: .identity, sourceSignal: fixtureSignal, outputSignal: fixtureSignal)
    }
    var fixtureConfig = MonitorConfiguration(); fixtureConfig.toolsEnabled = true; fixtureConfig.zebra.enabled = true
    fixtureConfig.zebra.thresholdIRE = 50; fixtureConfig.scopes.enabled = true
    let invalid = MonitorRuntime(sharedDevice: { MTLCreateSystemDefaultDevice() }, shaderSource: "deliberately invalid shader")
    var invalidRendered = false
    do { _ = try invalid.renderSnapshot(fixtureBundle(), configuration: fixtureConfig); invalidRendered = true } catch {}
    try require(!invalidRendered, "invalid shader still produced a picture")
    try require(invalid.unavailableReason != nil, "invalid shader did not report the GPU unavailable")
    if gpuAvailable {
        let snapshot = try MonitorRuntime().renderSnapshot(fixtureBundle(), configuration: fixtureConfig.normalized())
        try require(snapshot.availability.isEmpty, "fixture tools unavailable: \(snapshot.availability)")
        try require(snapshot.scope != nil, "fixture scope missing")
        // Processed output 240 is 94 IRE: pixel (0,0) is on a zebra stripe, mixed toward white.
        let bytes = snapshot.pictureBytes
        try require(bytes[2] > 240 && bytes[1] > 240 && bytes[0] > 240, "fixture zebra not drawn")
        CVPixelBufferLockBaseAddress(fixtureOutput, .readOnly)
        let original = CVPixelBufferGetBaseAddress(fixtureOutput)!.load(as: UInt8.self)
        CVPixelBufferUnlockBaseAddress(fixtureOutput, .readOnly)
        try require(original == 240, "monitor wrote into the producer buffer")
    }
    try require(gpuAvailable, "Metal device unavailable")
    let runtime = MonitorRuntime()
    let sources = try (0..<feeds).map { try buffer(UInt8(20 + $0),width:width,height:height,format:format) }
    let outputs = try (0..<feeds).map { try buffer(UInt8(90 + $0),width:width,height:height,format:format) }
    let hashes = (sources + outputs).map(producerFingerprint)
    let legal = format == kCVPixelFormatType_422YpCbCr10
    let signal = MonitorFrameSignal(range: legal ? .legal : .full, matrix: .bt709, transfer: "ITU_R_709_2")
    // Every tool on; even feeds monitor the source, odd feeds the processed output.
    let workloads = try (0..<feeds).map { feed -> MonitorGPUWorkload in
        var config = MonitorConfiguration()
        config.toolsEnabled = true; config.zebra.enabled = true; config.focus.enabled = true
        config.scopes.enabled = true; config.scopes.refreshHz = 15
        config.pictureStage = feed % 2 == 0 ? .source : .processedOutput
        config.scopeStage = config.pictureStage
        return try MonitorGPUWorkload(runtime: runtime, configuration: config)
    }
    func bundle(feed: Int, tick: Int, now: Double) -> MonitorFrameBundle {
        let stamp = MonitorFrameStamp(target: MonitorTargetID("synthetic-\(feed)"), generation: 1, sequence: UInt64(tick + 1), sourcePTS: Double(tick) / fps, hostTime: now, configurationRevision: 1)
        return MonitorFrameBundle(stamp: stamp, source: sources[feed], output: outputs[feed], correspondence: .identity, sourceSignal: signal, outputSignal: signal)
    }
    // Shader compile and first-use resources happen outside the measured window.
    for feed in 0..<feeds { workloads[feed].offer(bundle(feed: feed, tick: -1, now: ProcessInfo.processInfo.systemUptime)) }
    try require(workloads.allSatisfy { $0.drain(timeout: 20) }, "warmup completion watchdog")
    for workload in workloads { workload.resetMeasurement() }
    let heartbeat=MainQueueHeartbeat()
    let started = ProcessInfo.processInfo.systemUptime
    let startFootprint=footprint()
    let sampler=QualificationSampler { ["footprint":Double(footprint())] }
    var producerWork=ProducerWorkMetrics()
    var tick = 0
    var steadyStart: MonitorGPUStatistics?
    var intervals=[Distribution](repeating:Distribution(),count:feeds),lastOffer=[Double?](repeating:nil,count:feeds)
    let scheduler=try onPacedProducer(period:1/fps,feeds:feeds) {
    var nextDeadline=ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - started < seconds {
        waitForProducerDeadline(nextDeadline)
        if ProcessInfo.processInfo.systemUptime-started >= seconds {break}
        nextDeadline=ProcessInfo.processInfo.systemUptime+1/fps
        // GPU object counts are taken one second in: after that nothing may grow.
        if steadyStart == nil && ProcessInfo.processInfo.systemUptime - started >= min(1, seconds / 4) { steadyStart = runtime.gpuStatistics }
        let workStart=ProcessInfo.processInfo.systemUptime,cpuStart=producerThreadCPU()
        for offset in 0..<feeds {
            let feed = (tick + offset) % feeds
            let now = ProcessInfo.processInfo.systemUptime
            if let old=lastOffer[feed] {intervals[feed].add(now-old)};lastOffer[feed]=now
            workloads[feed].offer(bundle(feed: feed, tick: tick, now: now))
        }
        producerWork.record(wallStart:workStart,cpuStart:cpuStart)
        tick += 1
    }
    }
    let sampled=sampler.stop()
    let peakFootprint=UInt64(sampled.maxima["footprint"] ?? Double(startFootprint))
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    try require(workloads.allSatisfy { $0.drain(timeout: 10) }, "GPU completion watchdog")
    heartbeat.stop();let main=heartbeat.snapshot()
    let steadyEnd = runtime.gpuStatistics
    let snapshots = workloads.map { $0.snapshot() }
    let unchanged = zip(sources + outputs, hashes).allSatisfy { producerFingerprint($0.0) == $0.1 }
    let producerHz=Double(tick)/elapsed
    let pictureHz = snapshots.map { Double($0.completedPictures) / elapsed }
    let scopeHz = snapshots.map { Double($0.completedScopes) / elapsed }
    var pictureGPU=Distribution(),scopeGPU=Distribution()
    for s in snapshots { for (i,n) in s.pictureGPU.bins.enumerated() where n > 0 { pictureGPU.bins[i] += n; pictureGPU.count += n }; for (i,n) in s.scopeGPU.bins.enumerated() where n > 0 { scopeGPU.bins[i] += n; scopeGPU.count += n } }
    let grownTextures = steadyEnd.wrappedTextures - (steadyStart?.wrappedTextures ?? steadyEnd.wrappedTextures)
    let grownContexts = steadyEnd.encodeContexts - (steadyStart?.encodeContexts ?? steadyEnd.encodeContexts)
    let requestedScopeHz = 15.0
    var failureReasons:[String]=[]
    if producerHz < fps*0.98 {failureReasons.append("producer pacing below98% target")}
    for (feed, s) in snapshots.enumerated() {
        if s.offered != tick {failureReasons.append("feed\(feed) offered \(s.offered) of \(tick) produced frames")}
        if s.encoded != s.offered || s.completedPictures != s.offered {failureReasons.append("feed\(feed) skipped pictures: offered \(s.offered) encoded \(s.encoded) completed \(s.completedPictures)")}
        if s.failures > 0 {failureReasons.append("feed\(feed) failures: \(s.encodeErrors)")}
        if s.toolUnavailable > 0 {failureReasons.append("feed\(feed) requested tools unavailable: \(s.statusCounts)")}
        if scopeHz[feed] < min(requestedScopeHz, fps) * 0.9 {failureReasons.append("feed\(feed) scope rate \(scopeHz[feed])Hz below90% of \(requestedScopeHz)Hz")}
        if s.pictureAge.percentile(0.99) > 200 {failureReasons.append("feed\(feed) picture completion p99 age exceeds200ms")}
    }
    if !unchanged {failureReasons.append("producer buffer bytes changed")}
    if grownTextures != 0 || grownContexts != 0 {failureReasons.append("steady-state GPU object growth: textures \(grownTextures) contexts \(grownContexts)")}
    if main.0.count<UInt64(seconds*10) || main.0.percentile(0.95)>50 || main.0.percentile(0.99)>100 {failureReasons.append("main queue responsiveness gate")}
    let receipt: [String: Any] = ["declared_picture_stages":"even feeds source, odd feeds processedOutput; every tool on (zebra, focus, RGB parade at 15Hz)","target":"1920x1080 offscreen drawable stand-in","process_id":ProcessInfo.processInfo.processIdentifier,"source_essential_work":producerWork.dictionary(feeds:feeds),"telemetry_samples":sampled.count,"telemetry_observed_hz":Double(sampled.count)/sampled.elapsed,"status":failureReasons.isEmpty ? "passed":"failed","failure_reasons":failureReasons,"width":width,"height":height,
        "pixel_format":format == kCVPixelFormatType_422YpCbCr10 ? "v210":"BGRA","process_footprint_start":startFootprint,"sampled_peak_process_footprint":peakFootprint,"process_footprint_end":footprint(),"main_queue_observed":main.0.count,"main_queue_p95_ms":main.0.percentile(0.95),"main_queue_p99_ms":main.0.percentile(0.99),"main_queue_pending_skips":main.1,"workload":"Monitor\(width)x\(height)-\(format == kCVPixelFormatType_422YpCbCr10 ? "v210":"BGRA")-\(feeds)Feed-\(fps)Hz","synthetic_only":true,
        "producer_scheduler":scheduler.dictionary,"seconds":elapsed,"producer_effective_hz":producerHz,"producer_frames":tick,"producer_offer_interval_p95_ms":intervals.map{$0.percentile(0.95)},"producer_offer_interval_p99_ms":intervals.map{$0.percentile(0.99)},"producer_pacing":"latencyCritical activity; host-clock no catchup; minimum98% nominal",
        "offered":snapshots.map(\.offered),"encoded":snapshots.map(\.encoded),"completed_pictures":snapshots.map(\.completedPictures),"skipped":snapshots.map{$0.offered-$0.completedPictures},"scope_encodes":snapshots.map(\.scopeEncodes),"completed_scopes":snapshots.map(\.completedScopes),"failures":snapshots.map(\.failures),
        "per_feed_picture_hz":pictureHz,"per_feed_scope_hz":scopeHz,"requested_scope_hz":requestedScopeHz,"picture_completion_age_p95_ms":snapshots.map{$0.pictureAge.percentile(0.95)},"picture_completion_age_p99_ms":snapshots.map{$0.pictureAge.percentile(0.99)},"scope_completion_age_p95_ms":snapshots.map{$0.scopeAge.percentile(0.95)},
        "picture_gpu_p50_ms":pictureGPU.percentile(0.5),"picture_gpu_p95_ms":pictureGPU.percentile(0.95),"picture_gpu_p99_ms":pictureGPU.percentile(0.99),"scope_gpu_p50_ms":scopeGPU.percentile(0.5),"scope_gpu_p95_ms":scopeGPU.percentile(0.95),"cpu_encode_p95_ms":snapshots.map{$0.encodeWall.percentile(0.95)},
        "renderer_status_counts":snapshots.map(\.statusCounts),"producer_buffers_unchanged":unchanged,
        "gpu_wrapped_textures_total":steadyEnd.wrappedTextures,"gpu_encode_contexts_total":steadyEnd.encodeContexts,"steady_state_new_textures":grownTextures,"steady_state_new_contexts":grownContexts,
        "gpu_available":gpuAvailable]
    print(String(data: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), encoding: .utf8)!);fflush(stdout)
    for workload in workloads { workload.invalidate() }
    try require(failureReasons.isEmpty,failureReasons.joined(separator:", "))
    exitCode=0
} catch { fputs("MONITOR_SYNTHETIC FAIL \(error)\n", stderr); exitCode=1 }
ProcessInfo.processInfo.endActivity(qualificationActivity)
exit(exitCode)
}
dispatchMain()
