import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import MonitorToolsCore
import MonitorToolsMetal

struct QualificationFailure: Error { let reason: String }
func check(_ value: Bool, _ reason: String) throws { if !value { throw QualificationFailure(reason: reason) } }
struct Options {
    var root: URL
    var seconds = 5, width = 320, height = 180, feeds = 1, nominalFPS = 30
    var codecs = ["ProRes", "HEVC"], mode = "compare", pipeline = "synthetic", falseColor = "off"
    var sourceProfileID:String? {
        switch falseColor {
        case "logc3":return ARRIFalseColorProfile.logC3EI800.rawValue
        case "logc4":return ARRIFalseColorProfile.alexa35LogC4EI800.rawValue
        case "sony-slog3-sgamut3cine","sony-slog3-sgamut3":return falseColor
        default:return nil
        }
    }
    var sonySource:Bool {SonySLog3FalseColor.supports(sourceProfileID:sourceProfileID)}
    var falseColorProfileID:String? {sonySource ? SonySLog3FalseColor.profileID:sourceProfileID}
    var falseColorSpecification:String? {sourceProfileID == nil ? nil:(sonySource ? SonySLog3FalseColor.specificationVersion:ARRIFalseColorProfile.specificationVersion)}
    var frameRate: RecordingFrameRate { nominalFPS == 60 ? .fps5994 : .fps2997 }
    var duration: CMTime { CMTime(value:1001,timescale:Int32(nominalFPS * 1000)) }
    var count: Int { Int((Double(seconds) / duration.seconds).rounded(.up)) }
    var outputWidth: Int { min(1920,width) }
    var outputHeight: Int { max(1,Int(Double(height) * Double(outputWidth) / Double(width))) }
    init(_ args: [String]) throws {
        guard let path = args.first else { throw QualificationFailure(reason:"output root required") }
        root = URL(fileURLWithPath:path,isDirectory:true)
        var i = 1
        while i < args.count {
            guard i+1 < args.count else { throw QualificationFailure(reason:"missing value for \(args[i])") }
            let value = args[i+1]
            switch args[i] {
            case "--seconds": seconds = Int(value) ?? 0
            case "--width": width = Int(value) ?? 0
            case "--height": height = Int(value) ?? 0
            case "--feeds": feeds = Int(value) ?? 0
            case "--fps": nominalFPS = ["29.97","2997","30"].contains(value) ? 30 : (["59.94","5994","60"].contains(value) ? 60 : 0)
            case "--codec": codecs = value.lowercased() == "both" ? ["ProRes","HEVC"] : value.lowercased() == "prores" ? ["ProRes"] : value.lowercased() == "hevc" ? ["HEVC"] : []
            case "--mode": mode = value
            case "--pipeline": pipeline = value
            case "--false-color": falseColor = value
            default: throw QualificationFailure(reason:"unknown option \(args[i])")
            }
            i += 2
        }
        try check((1...7200).contains(seconds) && (16...3840).contains(width) && width % 2 == 0 && (16...2160).contains(height) && height % 2 == 0 && [1,2,4].contains(feeds) && [30,60].contains(nominalFPS) && !codecs.isEmpty && ["off","enabled","compare"].contains(mode) && ["synthetic","actual"].contains(pipeline),"invalid workload parameters")
        try check(["off","logc3","logc4","sony-slog3-sgamut3cine","sony-slog3-sgamut3"].contains(falseColor),"false color must be off, logc3, logc4, sony-slog3-sgamut3cine or sony-slog3-sgamut3")
        try check(pipeline != "actual" || (width==3840 && height==2160),"actual LUTProcessor pipeline requires3840x2160 input")
    }
    var workload: String { "\(feeds)Feed-\(width)x\(height)-\(nominalFPS == 60 ? "5994":"2997")-MovingV210-Paired\(outputWidth)x\(outputHeight)" }
}
final class GPUCounter: @unchecked Sendable {
    private let lock=NSLock();private var seconds=0.0,jobs=0
    private var callbackWall=Distribution(),callbackCPU=Distribution(),callbackOutliers:[[String:Double]]=[]
    func record(_ start:Double,_ end:Double){lock.lock();seconds += max(0,end-start);jobs += 1;lock.unlock()}
    func recordAndMeter(_ start:Double,_ end:Double) {
        let begin=ProcessInfo.processInfo.systemUptime,cpuStart=producerThreadCPU()
        record(start,end);AppGPUActivity.shared.record(start:start,end:end)
        let finished=ProcessInfo.processInfo.systemUptime,cpu=producerThreadCPU()-cpuStart
        lock.lock();defer{lock.unlock()};callbackWall.add(finished-begin);callbackCPU.add(cpu)
        if finished-begin>=0.010 && callbackOutliers.count<32 {callbackOutliers.append(["gpu_start":start,"gpu_end":end,"callback_begin":begin,"callback_end":finished,"wall_ms":(finished-begin)*1000,"thread_cpu_ms":cpu*1000])}
    }
    func reset(){lock.lock();seconds=0;jobs=0;callbackWall=Distribution();callbackCPU=Distribution();callbackOutliers=[];lock.unlock()}
    func callbackSnapshot()->[String:Any] {lock.lock();defer{lock.unlock()};return["count":callbackWall.count,"wall_p95_ms":callbackWall.percentile(0.95),"wall_p99_ms":callbackWall.percentile(0.99),"wall_max_ms":callbackWall.percentile(1),"thread_cpu_p95_ms":callbackCPU.percentile(0.95),"thread_cpu_p99_ms":callbackCPU.percentile(0.99),"outliers_first_32":callbackOutliers]}
    func snapshot()->(Double,Int){lock.lock();defer{lock.unlock()};return(seconds,jobs)}
}
struct PipelineSnapshot {
    var processed=0,failures=0,sequenceHash:UInt64=1469598103934665603
    var age=Distribution(),queueWait=Distribution(),processWall=Distribution(),processCPU=Distribution(),admissionWait=Distribution()
    var outliers:[[String:Double]]=[]
    var stages:[String:Distribution]=[:],commandOutliers:[[String:Double]]=[],terminalOutliers:[[String:Double]]=[]
    var commands=0
}
/// Production LUTProcessor on a per-feed serial queue with the production capture
/// admission bound. Recording submission stays on the independent producer route.
final class PipelineWorker: @unchecked Sendable {
    private let queue=DispatchQueue(label:"synthetic.production-pipeline",qos:.userInteractive),lock=NSLock()
    private let processor:LUTProcessor
    private let admission=PipelineAdmission(capacity:VideoContract.maxFramesInFlight)
    private var measured=PipelineSnapshot()
    private var collectingTiming=false,currentProcessStart=0.0,lastMeterReturn=0.0
    init(cube:CubeLUT) throws {
        processor=try LUTProcessor()
        try queue.sync{try processor.load(cube)}
        queue.sync{processor.commandTimingObserver={[weak self] in self?.recordCommand($0)}}
    }
    private func recordCommand(_ t:LUTProcessor.CommandTiming) {
        guard collectingTiming else{return}
        let values=["encode_to_commit":t.commitBegin-currentProcessStart,"commit":t.commitReturn-t.commitBegin,"gpu_queue":t.gpuStart-t.commitReturn,"gpu_execution":t.gpuEnd-t.gpuStart,"wait_resume":t.waitReturn-t.gpuEnd,"gpu_meter":t.meterReturn-t.waitReturn]
        lastMeterReturn=t.meterReturn
        lock.lock();defer{lock.unlock()};measured.commands += 1
        for (key,value) in values where value.isFinite && value>=0 && (key != "gpu_execution" || t.gpuStart>0) && (key != "wait_resume" || t.gpuEnd>0) {measured.stages[key,default:Distribution()].add(value)}
        if t.meterReturn-currentProcessStart>=0.010 && measured.commandOutliers.count<32 {measured.commandOutliers.append(["process_start":currentProcessStart,"commit_begin":t.commitBegin,"commit_return":t.commitReturn,"gpu_start":t.gpuStart,"gpu_end":t.gpuEnd,"wait_return":t.waitReturn,"meter_return":t.meterReturn])}
    }
    func beginMeasurement(){queue.sync{lock.lock();measured=PipelineSnapshot();lock.unlock();collectingTiming=true}}

    func warm(_ source:CVPixelBuffer,configuration:PipelineConfiguration) throws -> CVPixelBuffer {
        try queue.sync{try processor.process(source,configuration:configuration)}
    }
    func offer(_ frame:MonitorFrameBundle,configuration:PipelineConfiguration,sourceOnly:Bool,frameInterval:Double,completion:@escaping @Sendable(MonitorFrameBundle)->Void)->Bool {
        let decision=admission.acquire()
        guard decision.accepted else{return false}
        let enqueued=ProcessInfo.processInfo.systemUptime
        queue.async{[self] in
            defer{admission.release()}
            let closureStart=ProcessInfo.processInfo.systemUptime,closureCPU=producerThreadCPU()
            lock.lock();measured.admissionWait.add(decision.waitSeconds);lock.unlock()
            var processEnd=0.0,completionStart=0.0,completionEnd=0.0,completionCPU=0.0
            autoreleasepool {
                do {
                    if sourceOnly {
                        let earlyStart=ProcessInfo.processInfo.systemUptime,earlyCPUStart=producerThreadCPU()
                        completion(frame)
                        let earlyEnd=ProcessInfo.processInfo.systemUptime,earlyCPU=producerThreadCPU()-earlyCPUStart
                        lock.lock()
                        measured.stages["early_source_offer_wall",default:Distribution()].add(earlyEnd-earlyStart)
                        measured.stages["early_source_offer_thread_cpu",default:Distribution()].add(earlyCPU)
                        if earlyEnd-earlyStart>=0.010 && measured.terminalOutliers.count<32 {measured.terminalOutliers.append(["source_host_time":frame.stamp.hostTime,"early_source_offer_start":earlyStart,"early_source_offer_end":earlyEnd,"early_source_offer_cpu_ms":earlyCPU*1000])}
                        lock.unlock()
                    }
                    let processStart=ProcessInfo.processInfo.systemUptime,cpuStart=producerThreadCPU()
                    let queueAge=max(0,processStart-frame.stamp.hostTime)
                    currentProcessStart=processStart;lastMeterReturn=0
                    let output=try processor.process(frame.source,configuration:configuration)
                    processEnd=ProcessInfo.processInfo.systemUptime
                    let cpu=producerThreadCPU()-cpuStart
                    _ = queueAge
                    lock.lock();measured.queueWait.add(processStart-enqueued);measured.processWall.add(processEnd-processStart);measured.processCPU.add(cpu)
                    if lastMeterReturn>0 {measured.stages["post_meter_return",default:Distribution()].add(processEnd-lastMeterReturn)}
                    if processEnd-frame.stamp.hostTime>=0.010 && measured.outliers.count<32 {measured.outliers.append(["source_host_time":frame.stamp.hostTime,"worker_start":processStart,"worker_end":processEnd,"queue_ms":(processStart-enqueued)*1000,"process_wall_ms":(processEnd-processStart)*1000,"process_thread_cpu_ms":cpu*1000])}
                    measured.processed += 1;measured.sequenceHash=(measured.sequenceHash ^ frame.stamp.sequence) &* 1099511628211;measured.age.add(processEnd-frame.stamp.hostTime);lock.unlock()
                    completionStart=ProcessInfo.processInfo.systemUptime
                    let completionCPUStart=producerThreadCPU()
                    if !sourceOnly {completion(MonitorFrameBundle(stamp:frame.stamp,source:frame.source,output:output,sourceGeometry:frame.sourceGeometry,outputGeometry:MonitorGeometry(width:CVPixelBufferGetWidth(output),height:CVPixelBufferGetHeight(output)),correspondence:frame.correspondence,sourceSignal:frame.sourceSignal,outputSignal:frame.outputSignal))}
                    completionEnd=ProcessInfo.processInfo.systemUptime;completionCPU=producerThreadCPU()-completionCPUStart
                } catch {lock.lock();measured.failures += 1;lock.unlock()}
            }
            let terminal=ProcessInfo.processInfo.systemUptime,totalCPU=producerThreadCPU()-closureCPU
            lock.lock();defer{lock.unlock()}
            measured.stages["closure_wall",default:Distribution()].add(terminal-closureStart);measured.stages["closure_thread_cpu",default:Distribution()].add(totalCPU)
            if completionEnd>0 {measured.stages["completion_wall",default:Distribution()].add(completionEnd-completionStart);measured.stages["completion_thread_cpu",default:Distribution()].add(completionCPU);measured.stages["post_completion_cleanup",default:Distribution()].add(terminal-completionEnd)}
            if processEnd>0 && terminal-processEnd>=0.010 && measured.terminalOutliers.count<32 {measured.terminalOutliers.append(["source_host_time":frame.stamp.hostTime,"process_end":processEnd,"completion_start":completionStart,"completion_end":completionEnd,"terminal":terminal,"closure_cpu_ms":totalCPU*1000,"completion_cpu_ms":completionCPU*1000])}
        }
        return true
    }
    func drain(){queue.sync{processor.commandTimingObserver=nil;collectingTiming=false}}
    func snapshot()->PipelineSnapshot{lock.lock();defer{lock.unlock()};return measured}
    func admissionSnapshot()->PipelineAdmissionSnapshot{admission.snapshot()}
}
func fingerprint(_ image:CVPixelBuffer) -> UInt64 {
    CVPixelBufferLockBaseAddress(image,.readOnly);defer{CVPixelBufferUnlockBaseAddress(image,.readOnly)}
    let words=CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to:UInt32.self)
    let stride=CVPixelBufferGetBytesPerRow(image)/4, active=((CVPixelBufferGetWidth(image)+5)/6)*4
    var hash:UInt64=1469598103934665603
    for y in 0..<CVPixelBufferGetHeight(image) {for x in 0..<active {hash=(hash ^ UInt64(words[y*stride+x])) &* 1099511628211}}
    return hash
}
func luma(x:Int,y:Int,width:Int,height:Int,feed:Int,phase:Int) -> UInt32 {
    // Moving high-contrast edges over a repeatable ramp; no noise/camera-capacity claim.
    let edge=(width*(phase+1)/5 + feed*width/13)%width
    let detail=((x/12+y/16+phase)%2 == 0 ? 24:0)
    return UInt32(min(940,64+(x*600/max(1,width-1))+(x>edge ? 180:0)+(y>height/2 ? detail:0)))
}
struct Pattern {
    let source:CVPixelBuffer,output:CVPixelBuffer,hash:UInt64
}
func pattern(_ o:Options,feed:Int,phase:Int) throws -> Pattern {
    var source:CVPixelBuffer?,output:CVPixelBuffer?
    let attrs=[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary
    try check(CVPixelBufferCreate(nil,o.width,o.height,kCVPixelFormatType_422YpCbCr10,attrs,&source)==kCVReturnSuccess,"v210 allocation")
    try check(CVPixelBufferCreate(nil,o.pipeline == "actual" ? 1:o.outputWidth,o.pipeline == "actual" ? 1:o.outputHeight,kCVPixelFormatType_32BGRA,attrs,&output)==kCVReturnSuccess,"paired output allocation")
    let s=source!,p=output!
    CVBufferSetAttachment(s,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
    CVBufferSetAttachment(s,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
    CVBufferSetAttachment(s,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
    CVPixelBufferLockBaseAddress(s,[])
    let words=CVPixelBufferGetBaseAddress(s)!.assumingMemoryBound(to:UInt32.self),stride=CVPixelBufferGetBytesPerRow(s)/4
    memset(words,0,CVPixelBufferGetDataSize(s))
    let chroma:UInt32=UInt32(480+feed*16)
    for y in 0..<o.height {
        for x in Swift.stride(from:0,to:o.width,by:6) {
            func level(_ j:Int)->UInt32 {luma(x:min(o.width-1,x+j),y:y,width:o.width,height:o.height,feed:feed,phase:phase)}
            let v0=level(0),v1=level(1),v2=level(2),v3=level(3),v4=level(4),v5=level(5)
            let i=y*stride+x/6*4
            words[i]=chroma | (v0<<10) | (512<<20);words[i+1]=v1 | (chroma<<10) | (v2<<20)
            words[i+2]=512 | (v3<<10) | (chroma<<20);words[i+3]=v4 | (512<<10) | (v5<<20)
        }
    }
    CVPixelBufferUnlockBaseAddress(s,[])
    CVPixelBufferLockBaseAddress(p,[])
    let bytes=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(p)
    if o.pipeline == "synthetic" {for y in 0..<o.outputHeight {for x in 0..<o.outputWidth {
        let sx=min(o.width-1,Int((Double(x)+0.5)*Double(o.width)/Double(o.outputWidth)))
        let sy=min(o.height-1,Int((Double(y)+0.5)*Double(o.height)/Double(o.outputHeight)))
        // Explicit synthetic viewing transform, with source edges preserved geometrically.
        let value=UInt8(max(0,min(255,255-Int(luma(x:sx,y:sy,width:o.width,height:o.height,feed:feed,phase:phase)-64)*255/876)))
        let i=y*row+x*4;bytes[i]=value;bytes[i+1]=value;bytes[i+2]=value;bytes[i+3]=255
    }}}
    CVPixelBufferUnlockBaseAddress(p,[])
    return Pattern(source:s,output:p,hash:fingerprint(s))
}
struct DecodeResult {
    var frames=0,audioTracks=0,timecodeTracks=0,timescale:Int32=0
    var ptsHash:UInt64=1469598103934665603,durationHash:UInt64=1469598103934665603
    var maximumSourcePTSError=0.0,maximumAudioPTSError=0.0,maximumTimecodePTSError=0.0,maximumDecodedLumaError=0.0
    var decodedPixelSamples=0
    var audioFrames=0,timecodeFrames=0,audioReferenceMatches=true,timecodeReferenceMatches=true
    var audioHash:UInt64=1469598103934665603,timecodeHash:UInt64=1469598103934665603
}
func decode(_ url:URL,options:Options,feed:Int) async throws -> DecodeResult {
    let asset=AVURLAsset(url:url),tracks=try await asset.loadTracks(withMediaType:.video)
    try check(tracks.count==1,"missing video")
    var result=DecodeResult()
    let audioTracks=try await asset.loadTracks(withMediaType:.audio)
    let timecodeTracks=try await asset.loadTracks(withMediaType:.timecode)
    result.audioTracks=audioTracks.count;result.timecodeTracks=timecodeTracks.count
    result.timescale=try await tracks[0].load(.naturalTimeScale)
    let reader=try AVAssetReader(asset:asset)
    let output=AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    reader.add(output);try check(reader.startReading(),"reader failed")
    while let sample=output.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sample)>0 else{continue}
        let pts=CMSampleBufferGetPresentationTimeStamp(sample),duration=CMSampleBufferGetDuration(sample)
        result.maximumSourcePTSError=max(result.maximumSourcePTSError,abs(pts.seconds-Double(result.frames)*options.duration.seconds))
        for value in [UInt64(bitPattern:pts.value),UInt64(UInt32(bitPattern:pts.timescale))] {result.ptsHash=(result.ptsHash ^ value) &* 1099511628211}
        for value in [UInt64(bitPattern:duration.value),UInt64(UInt32(bitPattern:duration.timescale))] {result.durationHash=(result.durationHash ^ value) &* 1099511628211}
        if let image=CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(image,.readOnly)
            let bytes=CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(image)
            for yf in [1,3] {for xf in [1,3,5,7] {
                let x=options.width*xf/8,y=options.height*yf/4,i=y*row+x*4
                let measured=(0.0722*Double(bytes[i])+0.7152*Double(bytes[i+1])+0.2126*Double(bytes[i+2]))/255
                let expected=Double(luma(x:x,y:y,width:options.width,height:options.height,feed:feed,phase:result.frames%4)-64)/876
                result.maximumDecodedLumaError=max(result.maximumDecodedLumaError,abs(measured-expected));result.decodedPixelSamples += 1
            }}
            CVPixelBufferUnlockBaseAddress(image,.readOnly)
        }
        result.frames += 1
    }
    try check(reader.status == .completed,"video decode failed")
    for (kind,track) in [("audio",audioTracks.first),("timecode",timecodeTracks.first)] {
        guard let track else {continue}
        let auxiliary=try AVAssetReader(asset:asset),out=AVAssetReaderTrackOutput(track:track,outputSettings:nil)
        auxiliary.add(out);try check(auxiliary.startReading(),"auxiliary reader failed")
        while let sample=out.copyNextSampleBuffer() {
            // AVAssetReader emits empty trim/format/discontinuity markers around
            // native audio/timecode tracks; they are not media samples.
            guard CMSampleBufferGetNumSamples(sample)>0 else{continue}
            guard let block=CMSampleBufferGetDataBuffer(sample) else {throw QualificationFailure(reason:"missing auxiliary bytes")}
            var bytes=[UInt8](repeating:0,count:CMBlockBufferGetDataLength(block))
            let status=bytes.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
            try check(status==kCMBlockBufferNoErr,"auxiliary byte copy")
            if kind == "audio" {
                result.maximumAudioPTSError=max(result.maximumAudioPTSError,abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds-Double(result.audioFrames)/48000))
                result.audioFrames += CMSampleBufferGetNumSamples(sample)
                for (index,byte) in bytes.enumerated() {
                    result.audioHash=(result.audioHash ^ UInt64(byte)) &* 1099511628211
                    // Production recorder packs the24 significant high bits of PCM32.
                    if byte != (index%3 == 1 ? UInt8(feed+1):0) {result.audioReferenceMatches=false}
                }
            } else {
                result.maximumTimecodePTSError=max(result.maximumTimecodePTSError,abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds-Double(result.timecodeFrames)*options.duration.seconds))
                for byte in bytes {result.timecodeHash=(result.timecodeHash ^ UInt64(byte)) &* 1099511628211}
                for i in Swift.stride(from:0,to:bytes.count-3,by:4) {
                    let number=UInt32(bytes[i])<<24 | UInt32(bytes[i+1])<<16 | UInt32(bytes[i+2])<<8 | UInt32(bytes[i+3])
                    if number != UInt32(result.timecodeFrames) {result.timecodeReferenceMatches=false}
                    result.timecodeFrames += 1
                }
            }
        }
        try check(auxiliary.status == .completed,"auxiliary decode failed")
    }
    return result
}
func writeReceipt(_ receipt:[String:Any],root:URL) throws {
    let data=try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted])
    try data.write(to:root.appendingPathComponent("recording-receipt.json"),options:.atomic)
}
func run(_ o:Options) async throws {
    // Fixed before enabled runs: recording zero additional losses; named monitor minima
    // are intentionally useful at 4K. Failed workloads remain unqualified.
    let minimumPictureHz=20.0,minimumScopeHz=10.0,maximumPictureP95MS=100.0,maximumScopeP95MS=200.0
    var receipts:[[String:Any]]=[],allPassed=true
    var baseline:[String:[DecodeResult]]=[:],baselinePipeline:[String:[PipelineSnapshot]]=[:]
    let patterns=try (0..<o.feeds).map{feed in try (0..<4).map{try pattern(o,feed:feed,phase:$0)}}
    let fixtureBytes=patterns.flatMap{$0}.reduce(0){$0+CVPixelBufferGetDataSize($1.source)+CVPixelBufferGetDataSize($1.output)}
    let declaredSourceProfileID=o.sourceProfileID
    let signal=MonitorFrameSignal(range:.legal,matrix:.bt709,transfer:o.sonySource ? "slog3":(declaredSourceProfileID == nil ? "rec709":"declaredLog"),profileID:declaredSourceProfileID)
    let outputSignal=MonitorFrameSignal(range:o.pipeline == "actual" ? .legal:.full,matrix:.bt709,transfer:o.pipeline == "actual" ? "rec709":"sRGB")
    let pipelineConfig=PipelineConfiguration(applyLUT:true,downscale:true,convertTo420:true,reduceFrameRate:false,inputFast:o.nominalFPS==60)
    let identityCube=try CubeLUT(text:"LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
    let correspondence=MonitorCorrespondence(scaleX:Double(o.outputWidth)/Double(o.width),scaleY:Double(o.outputHeight)/Double(o.height),offsetX:0,offsetY:0)
    let modes=o.mode == "compare" ? [false,true]:[o.mode == "enabled"]
    var receipt:[String:Any]=["source_manifest_sha256":ProcessInfo.processInfo.environment["MONITOR_SOURCE_MANIFEST_SHA256"] ?? "uncaptured diagnostic","binary_sha256":ProcessInfo.processInfo.environment["MONITOR_BINARY_SHA256"] ?? "uncaptured diagnostic","status":"running","synthetic_only":true,"false_color_profile":o.falseColor,"declared_source_profile":declaredSourceProfileID ?? "none","false_color_style_profile_id":o.falseColorProfileID ?? "none","false_color_specification":o.falseColorSpecification ?? "none","false_color_reference_ei":800,"source_log_mapping":"native10Bit","source_code_range":"legal","source_ycbcr_matrix":"bt709","source_camera_ei":"unspecified; reference EI is not a camera setting","false_color_model":o.sonySource ? "per-channel Sony SLog3 decode; selected source-gamut linear luminance; LogC3 EI800 full-code reference bands":"literal published ARRI profile or false color off","false_color_qualification":"synthetic declared-profile composition stress; no physical camera calibration","zebra_requested":true,"zebra_effective_with_false_color":o.falseColor == "off","focus_enabled":true,"scopes_enabled":true,"workload":o.workload,"seconds_per_run":o.seconds,
        "monitor_path":"production MonitorToolsRenderer: one picture encode per offered frame into a 1920x1080 offscreen drawable stand-in; scopes in their own command buffer at 15Hz","monitor_target_width":1920,"monitor_target_height":1080,"monitor_scope_width":768,"monitor_scope_height":256,"pipeline":o.pipeline,"pipeline_queue_qos":"userInteractive (matches CaptureController.queue)","source_thread_qos":"userInteractive with verified Mach time constraint","actual_pipeline_admission_limit_per_feed":VideoContract.maxFramesInFlight,"output_basis":o.pipeline == "actual" ? "production LUTProcessor identity LUT + Lanczos4Kto1080 + NV12":"independently generated synthetic paired viewing output; not LUTProcessor","width":o.width,"height":o.height,"feeds":o.feeds,"fps":1/o.duration.seconds,"mode":o.mode,"codecs":o.codecs,
        "maximum_decoded_luma_error":0.03,"source_seed":"moving-v210-ramp-edge-v2","audio_seed":"per-feed-constant-PCM32-v1","immutable_phases_per_feed":4,"enabled_measurement_warmup":"one completed picture and scope encode per feed before paced recording window","fixture_bytes":fixtureBytes,
        "main_queue_heartbeat_hz":20,"maximum_main_queue_p95_ms":50,"maximum_main_queue_p99_ms":100,"minimum_main_queue_observed_hz":10,"producer_pacing":"host-clock no catchup; minimum98% of nominal","minimum_producer_hz":(1/o.duration.seconds)*0.98,"minimum_picture_hz":minimumPictureHz,"minimum_unique_scope_hz":minimumScopeHz,"maximum_picture_age_p95_ms":maximumPictureP95MS,"maximum_scope_age_p95_ms":maximumScopeP95MS,
        "camera_p95_regression_tolerance_ms":2,"camera_p99_regression_tolerance_ms":5,"physical_camera":"unqualified: no receiver","monitor_off_mode":"tools disabled: the plain picture pass still runs for every frame","compositor_throughput":"unqualified: offscreen targets, no display compositor",
        "os":ProcessInfo.processInfo.operatingSystemVersionString,"processor_count":ProcessInfo.processInfo.processorCount,
        "thermal_state_start":ProcessInfo.processInfo.thermalState.rawValue,"runs":receipts,"qualification":"pending execution"]
    try writeReceipt(receipt,root:o.root)
    for codecName in o.codecs {
        let codec=codecName == "ProRes" ? kCMVideoCodecType_AppleProRes422HQ:kCMVideoCodecType_HEVC
        for enabled in modes {
            if enabled && o.mode == "compare" && baseline[codecName] == nil {continue}
            let gpu=GPUCounter()
            let runtime=MonitorRuntime(gpuTiming:{gpu.recordAndMeter($0,$1)}),targets=(0..<o.feeds).map{MonitorTargetID("synthetic-\($0)")}
            var monitorList:[MonitorGPUWorkload]=[]
            let processors:[PipelineWorker]=try o.pipeline == "actual" ? (0..<o.feeds).map{_ in try PipelineWorker(cube:identityCube)}:[]
            var recorders:[SourceRecorderCore]=[],urls:[URL]=[],configuredPictureStages:[MonitorStage]=[],sourceOnlyRoutes:[Bool]=[],configuredFalseColorProfileIDs:[String]=[]
            defer {for recorder in recorders {try? recorder.stop()}}
            for feed in 0..<o.feeds {
                let url=o.root.appendingPathComponent("\(codecName)-\(enabled ? "enabled":"off")-feed\(feed).mov")
                urls.append(url)
                let config=try SourceRecordingConfiguration(feedID:SourceRecordingFeedID(targets[feed].rawValue),outputURL:url,width:o.width,height:o.height,videoCodec:codec,queueCapacity:24,frameRate:o.frameRate,timecodePolicy:.recordStart)
                let recorder=try SourceRecorderCore(configuration:config);try recorder.start();recorders.append(recorder)
                var tools=MonitorConfiguration();tools.toolsEnabled=enabled;tools.zebra.enabled=true;tools.focus.enabled=true;tools.scopes.enabled=true
                if let declaredSourceProfileID {tools.falseColor.mode = o.sonySource ? .sonySLog3 : .arri;tools.falseColor.profileID=o.falseColorProfileID;tools.falseColor.specificationVersion=o.falseColorSpecification;tools.sourceProfileID=declaredSourceProfileID;tools.sourceLogMapping = .native10Bit;tools.pictureStage = .source}
                tools.zebra.thresholdIRE=85+Double(feed);tools.focus.color=feed%2 == 0 ? .red:.yellow
                tools.pictureStage = declaredSourceProfileID == nil ? .processedOutput:.source;tools.scopeStage = feed%2 == 0 ? .source:.processedOutput
                let effectiveTools=tools.normalized()
                try check(effectiveTools.falseColor.mode == tools.falseColor.mode && effectiveTools.falseColor.profileID == tools.falseColor.profileID,"declared false-color configuration rejected during normalization")
                configuredFalseColorProfileIDs.append(effectiveTools.falseColor.profileID ?? "none")
                configuredPictureStages.append(tools.pictureStage)
                sourceOnlyRoutes.append(tools.pictureStage == .source && (!enabled || tools.scopeStage == .source))
                monitorList.append(try MonitorGPUWorkload(runtime:runtime,configuration:tools))
            }
            let counters=monitorList
            // Prime existing producer processing resources in both baseline/enabled modes.
            if o.pipeline == "actual" {for feed in 0..<o.feeds {_ = try processors[feed].warm(patterns[feed][0].source,configuration:pipelineConfig)}}
            // Shader initialization is outside the fixed qualification window. Functional
            // startup/failure behavior is covered by the smoke fixture; receipts say warm.
            // Every immutable phase once, so the measured window sees no first-use textures.
            for feed in 0..<o.feeds { for p in patterns[feed] {
                let warmOutput=o.pipeline == "actual" ? try processors[feed].warm(p.source,configuration:pipelineConfig):p.output
                let warm=MonitorFrameStamp(target:targets[feed],generation:1,sequence:0,sourcePTS:0,hostTime:ProcessInfo.processInfo.systemUptime,configurationRevision:1)
                counters[feed].offer(MonitorFrameBundle(stamp:warm,source:p.source,output:warmOutput,sourceGeometry:MonitorGeometry(width:o.width,height:o.height),outputGeometry:MonitorGeometry(width:o.outputWidth,height:o.outputHeight),correspondence:correspondence,sourceSignal:signal,outputSignal:outputSignal))
                try check(counters[feed].drain(timeout:30) && counters[feed].snapshot().failures == 0,"monitor warmup encode failed: \(counters[feed].snapshot().encodeErrors)")
            }}
            for counter in counters {counter.resetMeasurement()}
            let steadyStart=runtime.gpuStatistics
            for processor in processors {processor.beginMeasurement()}
            var admission=[Distribution](repeating:Distribution(),count:o.feeds),callback=[Distribution](repeating:Distribution(),count:o.feeds)
            var offerIntervals=[Distribution](repeating:Distribution(),count:o.feeds),offerLateness=[Distribution](repeating:Distribution(),count:o.feeds)
            var firstOffer=[Double?](repeating:nil,count:o.feeds),lastOffer=[Double?](repeating:nil,count:o.feeds)
            var admissionRejected=[Int](repeating:0,count:o.feeds),pipelineAdmitted=[Int](repeating:0,count:o.feeds)
            let initialProcessFootprint=footprint()
            let sampler=QualificationSampler {
                return ["footprint":Double(footprint()),"inflight":Double(counters.reduce(0){$0+$1.inFlight}),"queue":Double(recorders.map{$0.telemetry.queueSamples}.max() ?? 0),"gpuFraction":AppGPUActivity.shared.percent(now:ProcessInfo.processInfo.systemUptime)/100]
            }
            var producerWork=ProducerWorkMetrics()
            let heartbeat=MainQueueHeartbeat()
            defer{heartbeat.stop()}
            let started=ProcessInfo.processInfo.systemUptime,cpuStarted=clock()
            gpu.reset()
            let scheduler=try onPacedProducer(period:o.duration.seconds,feeds:o.feeds) {
            var nextDeadline=ProcessInfo.processInfo.systemUptime
            for index in 0..<o.count {
                let deadline=nextDeadline,wait=deadline-ProcessInfo.processInfo.systemUptime
                if wait>0 {waitForProducerDeadline(deadline)}
                // At most one producer event per actual picture period: never replay a
                // backlog of missed deadlines as an unpaced burst.
                nextDeadline=ProcessInfo.processInfo.systemUptime+o.duration.seconds
                let workStart=ProcessInfo.processInfo.systemUptime,cpuStart=producerThreadCPU()
                for offset in 0..<o.feeds {
                    let feed=(index+offset)%o.feeds,p=patterns[feed][index%4]
                    let begin=ProcessInfo.processInfo.systemUptime,pts=CMTimeMultiply(o.duration,multiplier:Int32(index))
                    if let previous=lastOffer[feed] {offerIntervals[feed].add(begin-previous)}
                    if firstOffer[feed] == nil {firstOffer[feed]=begin};lastOffer[feed]=begin
                    offerLateness[feed].add(max(0,begin-deadline))
                    if !recorders[feed].appendVideo(try VideoContract.sample(p.source,at:pts,duration:o.duration)){admissionRejected[feed] += 1}
                    let audioStart=Int64(index)*Int64(48000*1001)/Int64(o.nominalFPS*1000)
                    let nextStart=Int64(index+1)*Int64(48000*1001)/Int64(o.nominalFPS*1000)
                    let n=Int(nextStart-audioStart)
                    let pcm=[Int32](repeating:Int32(feed+1)<<16,count:n*2)
                    let pcmBytes=pcm.withUnsafeBytes{Data($0)}
                    let packet=try EmbeddedAudioPacket(sourcePCM32:pcmBytes,sampleFrameCount:n,presentationTime:CMTime(value:audioStart,timescale:48000))
                    if !recorders[feed].appendAudio(try EmbeddedAudioRecording.makeSampleBuffer(for:packet)){admissionRejected[feed] += 1}
                    admission[feed].add(ProcessInfo.processInfo.systemUptime-begin)
                    let stamp=MonitorFrameStamp(target:targets[feed],generation:1,sequence:UInt64(index+1),sourcePTS:pts.seconds,hostTime:begin,configurationRevision:1)
                    let bundle=MonitorFrameBundle(stamp:stamp,source:p.source,output:p.output,sourceGeometry:MonitorGeometry(width:o.width,height:o.height),outputGeometry:MonitorGeometry(width:o.outputWidth,height:o.outputHeight),correspondence:correspondence,sourceSignal:signal,outputSignal:outputSignal)
                    if o.pipeline == "actual" {
                        if processors[feed].offer(bundle,configuration:pipelineConfig,sourceOnly:sourceOnlyRoutes[feed],frameInterval:o.duration.seconds,completion:{counters[feed].offer($0)}){pipelineAdmitted[feed] += 1}
                    } else {counters[feed].offer(bundle)}
                    callback[feed].add(ProcessInfo.processInfo.systemUptime-begin)
                }
                producerWork.record(wallStart:workStart,cpuStart:cpuStart)
            }
            }
            let sampled=sampler.stop()
            let peakMemory=UInt64(sampled.maxima["footprint"] ?? Double(initialProcessFootprint)),peakInFlight=Int(sampled.maxima["inflight"] ?? 0),maxQueue=Int(sampled.maxima["queue"] ?? 0),combinedMetal=sampled.gpu
            for processor in processors {processor.drain()}
            let monitorsDrained=counters.allSatisfy{$0.drain(timeout:10)}
            let steadyEnd=runtime.gpuStatistics
            let finalizationStarted=ProcessInfo.processInfo.systemUptime
            for recorder in recorders {try recorder.stop()}
            let finalizationSeconds=ProcessInfo.processInfo.systemUptime-finalizationStarted
            heartbeat.stop()
            let elapsed=ProcessInfo.processInfo.systemUptime-started
            let recordingEndFootprint=footprint()
            let cpuSeconds=Double(clock()-cpuStarted)/Double(CLOCKS_PER_SEC),gpuMeasured=gpu.snapshot()
            var decoded:[DecodeResult]=[],runPassed=true
            for feed in 0..<o.feeds {
                let decodeStarted=ProcessInfo.processInfo.systemUptime
                let d=try await decode(urls[feed],options:o,feed:feed);decoded.append(d)
                let decodeSeconds=ProcessInfo.processInfo.systemUptime-decodeStarted
                let m=counters[feed].snapshot(),t=recorders[feed].telemetry,main=heartbeat.snapshot()
                let pipeline=o.pipeline == "actual" ? processors[feed].snapshot():PipelineSnapshot()
                let processingAdmission=o.pipeline == "actual" ? processors[feed].admissionSnapshot():PipelineAdmissionSnapshot(pending:0,maximumPending:0,capacityRejected:0)
                let sourceUnchanged=patterns[feed].allSatisfy{fingerprint($0.source)==$0.hash}
                let referencePTS=d.maximumSourcePTSError <= 1/Double(d.timescale)+0.000000001
                let expectedAudioFrames=Int(Int64(o.count)*Int64(48000*1001)/Int64(o.nominalFPS*1000))
                let producerSeconds=(lastOffer[feed]!-firstOffer[feed]!)+o.duration.seconds
                let producerHz=Double(o.count-1)/(lastOffer[feed]!-firstOffer[feed]!)
                let cadencePass=producerHz >= (1/o.duration.seconds)*0.98
                let mainResponsive=main.0.count >= UInt64(o.seconds*10) && main.0.percentile(0.95)<=50 && main.0.percentile(0.99)<=100
                let pipelineTimingMatches=(o.pipeline == "actual" ? baselinePipeline[codecName]:nil).map {old in
                    old[feed].sequenceHash==pipeline.sequenceHash && pipeline.age.percentile(0.95)<=old[feed].age.percentile(0.95)+2 && pipeline.age.percentile(0.99)<=old[feed].age.percentile(0.99)+5
                } ?? false
                let pipelinePass=o.pipeline != "actual" || (pipeline.processed==o.count && pipeline.failures==0 && pipelineAdmitted[feed]==o.count && (!enabled || o.mode != "compare" || pipelineTimingMatches))
                let mediaPass=pipelinePass && mainResponsive && cadencePass && d.decodedPixelSamples==o.count*8 && d.maximumDecodedLumaError <= 0.03 && d.maximumAudioPTSError <= 1.0/48000.0+0.000000001 && d.maximumTimecodePTSError <= 1/Double(d.timescale)+0.000000001 && d.audioFrames==expectedAudioFrames && d.timecodeFrames==o.count && d.audioReferenceMatches && d.timecodeReferenceMatches && d.frames == o.count && d.audioTracks==1 && d.timecodeTracks==1 && t.droppedVideo==0 && t.droppedAudio==0 && t.droppedEncodedVideo==0 && t.encoderErrors==0 && admissionRejected[feed]==0 && sourceUnchanged && referencePTS
                let paired=baseline[codecName].map{$0[feed].ptsHash==d.ptsHash && $0[feed].durationHash==d.durationHash && $0[feed].frames==d.frames && $0[feed].audioHash==d.audioHash && $0[feed].timecodeHash==d.timecodeHash} ?? false
                let pictureHz=Double(m.completedPictures)/producerSeconds,scopeHz=Double(m.completedScopes)/producerSeconds
                let declaredStage:MonitorStage=declaredSourceProfileID == nil ? .processedOutput:.source
                // Every offered frame is encoded and completes: the monitor never skips.
                let everyFrame=monitorsDrained && m.encoded==m.offered && m.completedPictures==m.offered && m.failures==0
                let expectedOffers=o.pipeline == "actual" ? pipelineAdmitted[feed]:o.count
                let monitorPass=configuredPictureStages[feed]==declaredStage && everyFrame && m.offered==expectedOffers && pictureHz>=minimumPictureHz && m.pictureAge.percentile(0.95)<=maximumPictureP95MS && (!enabled || (scopeHz>=minimumScopeHz && m.scopeAge.percentile(0.95)<=maximumScopeP95MS && m.toolUnavailable==0))
                let passed=mediaPass && monitorPass && (!enabled || o.mode != "compare" || paired)
                runPassed = runPassed && passed;allPassed=allPassed && passed
                receipts.append(["monitor_offer_route":sourceOnlyRoutes[feed] ? "source-before-LUT":"paired-output-after-LUT","activity_lifetime":"explicit matched end after awaited workload; prior receipt ownership unverified","process_id":ProcessInfo.processInfo.processIdentifier,"declared_picture_stage":declaredStage.rawValue,"configured_picture_stage":configuredPictureStages[feed].rawValue,"configured_false_color_profile_id":configuredFalseColorProfileIDs[feed],"configured_source_profile_id":declaredSourceProfileID ?? "none","producer_scheduler":scheduler.dictionary,"codec":codecName,"tools_enabled":enabled,"feed":feed,"status":passed ? "passed":"failed","elapsed_seconds":elapsed,"main_queue_responsive":mainResponsive,"main_queue_observed":main.0.count,"main_queue_pending_skips":main.1,"main_queue_p95_ms":main.0.percentile(0.95),"main_queue_p99_ms":main.0.percentile(0.99),"producer_seconds":producerSeconds,"producer_effective_hz":producerHz,"producer_cadence_pass":cadencePass,"producer_offer_interval_median_ms":offerIntervals[feed].percentile(0.5),"producer_offer_interval_p95_ms":offerIntervals[feed].percentile(0.95),"producer_offer_interval_p99_ms":offerIntervals[feed].percentile(0.99),"producer_offer_lateness_p95_ms":offerLateness[feed].percentile(0.95),"finalization_seconds":finalizationSeconds,"expected_frames":o.count,"decoded_frames":d.frames,
                    "decode_seconds":decodeSeconds,"decode_frames_per_second":Double(d.frames)/decodeSeconds,"decoded_luma_samples":d.decodedPixelSamples,"maximum_decoded_luma_error":d.maximumDecodedLumaError,"maximum_audio_pts_error_ms":d.maximumAudioPTSError*1000,"maximum_timecode_pts_error_ms":d.maximumTimecodePTSError*1000,"audio_decoded_frames":d.audioFrames,"audio_expected_frames":expectedAudioFrames,"audio_bytes_match_feed_reference":d.audioReferenceMatches,"timecode_decoded_frames":d.timecodeFrames,"timecode_values_match_source_reference":d.timecodeReferenceMatches,"audio_hash":String(d.audioHash),"timecode_hash":String(d.timecodeHash),"audio_tracks":d.audioTracks,"timecode_tracks":d.timecodeTracks,"container_timescale":d.timescale,"pts_hash":String(d.ptsHash),"duration_hash":String(d.durationHash),"maximum_source_pts_error_ms":d.maximumSourcePTSError*1000,
                    "exact_off_enabled_timing_match":paired,"source_active_words_unchanged":sourceUnchanged,"recording_admission_rejected":admissionRejected[feed],"recording_dropped_video":t.droppedVideo,"recording_dropped_audio":t.droppedAudio,"encoder_dropped_video":t.droppedEncodedVideo,"encoder_errors":t.encoderErrors,"last_error":t.lastError ?? "",
                    "admission_p95_ms":admission[feed].percentile(0.95),"admission_p99_ms":admission[feed].percentile(0.99),"callback_p95_ms":callback[feed].percentile(0.95),"callback_p99_ms":callback[feed].percentile(0.99),
                    "instrumented_combined_metal_p95_percent":combinedMetal.percentile(0.95)/10,"actual_pipeline_off_enabled_timing_match":pipelineTimingMatches,"actual_pipeline_processed":pipeline.processed,"actual_pipeline_failures":pipeline.failures,"actual_pipeline_admitted":pipelineAdmitted[feed],"actual_pipeline_admission_semantics":"blocking metadata-only lock, separate from histogram measurement; matches CaptureController","actual_pipeline_admission_capacity_rejected":processingAdmission.capacityRejected,"actual_pipeline_maximum_pending":processingAdmission.maximumPending,"actual_pipeline_pending_after_drain":processingAdmission.pending,"actual_pipeline_admission_wait_count":pipeline.admissionWait.count,"actual_pipeline_admission_wait_p95_ms":pipeline.admissionWait.percentile(0.95),"actual_pipeline_admission_wait_p99_ms":pipeline.admissionWait.percentile(0.99),"actual_pipeline_admission_wait_max_ms":pipeline.admissionWait.percentile(1),"actual_pipeline_age_p95_ms":pipeline.age.percentile(0.95),"actual_pipeline_age_p99_ms":pipeline.age.percentile(0.99),"actual_pipeline_queue_p95_ms":pipeline.queueWait.percentile(0.95),"actual_pipeline_queue_p99_ms":pipeline.queueWait.percentile(0.99),"actual_pipeline_process_wall_p95_ms":pipeline.processWall.percentile(0.95),"actual_pipeline_process_wall_p99_ms":pipeline.processWall.percentile(0.99),"actual_pipeline_process_thread_cpu_p95_ms":pipeline.processCPU.percentile(0.95),"actual_pipeline_timing_outliers_first_32":pipeline.outliers,"actual_pipeline_command_count":pipeline.commands,"actual_pipeline_stage_timings":pipeline.stages.mapValues{["count":Double($0.count),"p95_ms":$0.percentile(0.95),"p99_ms":$0.percentile(0.99)]},"actual_pipeline_command_outliers_first_32":pipeline.commandOutliers,"actual_pipeline_terminal_outliers_first_32":pipeline.terminalOutliers,"actual_pipeline_sequence_hash":String(pipeline.sequenceHash),
                    "monitor_offered":m.offered,"monitor_encoded":m.encoded,"monitor_completed_pictures":m.completedPictures,"monitor_skipped":m.offered-m.completedPictures,"monitor_every_frame":everyFrame,"monitor_scope_encodes":m.scopeEncodes,"monitor_completed_scopes":m.completedScopes,"monitor_failures":m.failures,"monitor_encode_errors":m.encodeErrors,"monitor_picture_hz":pictureHz,"monitor_scope_hz":scopeHz,
                    "monitor_picture_completion_age_p95_ms":m.pictureAge.percentile(0.95),"monitor_picture_completion_age_p99_ms":m.pictureAge.percentile(0.99),"monitor_scope_completion_age_p95_ms":m.scopeAge.percentile(0.95),"monitor_scope_completion_age_p99_ms":m.scopeAge.percentile(0.99),
                    "monitor_picture_gpu_p50_ms":m.pictureGPU.percentile(0.5),"monitor_picture_gpu_p95_ms":m.pictureGPU.percentile(0.95),"monitor_picture_gpu_p99_ms":m.pictureGPU.percentile(0.99),"monitor_scope_gpu_p50_ms":m.scopeGPU.percentile(0.5),"monitor_scope_gpu_p95_ms":m.scopeGPU.percentile(0.95),"monitor_cpu_encode_p95_ms":m.encodeWall.percentile(0.95),"monitor_cpu_encode_p99_ms":m.encodeWall.percentile(0.99),
                    "monitor_renderer_status_counts":m.statusCounts,"monitor_requested_tool_unavailable":m.toolUnavailable,
                    "monitor_gpu_statistics_scope":"runtime aggregate across all feeds; repeated per-feed rows must not be summed","monitor_wrapped_iosurface_textures_total":steadyEnd.wrappedTextures,"monitor_cached_iosurface_textures":steadyEnd.cachedTextures,"monitor_encode_contexts_total":steadyEnd.encodeContexts,"monitor_steady_state_new_textures":steadyEnd.wrappedTextures-steadyStart.wrappedTextures,"monitor_steady_state_new_contexts":steadyEnd.encodeContexts-steadyStart.encodeContexts,
                    "source_essential_work":producerWork.dictionary(feeds:o.feeds),"telemetry_samples":sampled.count,"telemetry_observed_hz":Double(sampled.count)/sampled.elapsed,"process_cpu_seconds":cpuSeconds,"process_cpu_percent":cpuSeconds/elapsed*100,"instrumented_monitor_gpu_command_seconds":gpuMeasured.0,"instrumented_monitor_gpu_command_count":gpuMeasured.1,"monitor_gpu_timing_callback":gpu.callbackSnapshot(),"gpu_metric":"summed command intervals, not total GPU utilization","process_footprint_before_recording":initialProcessFootprint,"process_footprint_at_recording_end":recordingEndFootprint,"sampled_peak_process_footprint":peakMemory,"sampled_peak_monitor_gpu_in_flight":peakInFlight,"sampled_max_recording_queue":maxQueue,"encoded_video_bytes":t.encodedVideoBytes,"path":urls[feed].path])
            }
            for counter in counters {counter.invalidate()}
            if !enabled && runPassed {baseline[codecName]=decoded;baselinePipeline[codecName]=processors.map{$0.snapshot()}}
            receipt["runs"]=receipts;receipt["status"]="running";try writeReceipt(receipt,root:o.root)
            print("PROGRESS codec=\(codecName) tools=\(enabled) feeds=\(o.feeds) media_and_monitor_pass=\(runPassed) elapsed=\(elapsed)");fflush(stdout)
        }
    }
    receipt["status"]=allPassed ? "passed":"failed"
    receipt["qualification"]=allPassed && o.mode == "compare" ? "executed named synthetic workload only":allPassed && o.mode == "off" ? "baseline sustainable for named synthetic workload; monitor unqualified":allPassed ? "enabled named synthetic reference passed; paired isolation unqualified":"unqualified: inspect failed runs"
    receipt["recording_isolation_qualification"]=allPassed && o.mode == "compare" ? "paired off/enabled timing and source reference passed":"unqualified: no paired off comparison in this invocation"
    receipt["sustained_30_minute"]=o.seconds>=1800 && allPassed
    receipt["sustained_30_minute_enabled"]=o.seconds>=1800 && o.mode != "off" && allPassed
    receipt["sustained_30_minute_paired_isolation"]=o.seconds>=1800 && o.mode == "compare" && allPassed
    receipt["thermal_state_end"]=ProcessInfo.processInfo.thermalState.rawValue
    try writeReceipt(receipt,root:o.root)
    print(String(data:try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted]),encoding:.utf8)!)
    try check(allPassed,"named workload failed; recording-receipt.json preserves all completed results")
}
Task.detached(priority:.userInitiated) {
    let qualificationActivity=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.latencyCritical],reason:"Paced synthetic video qualification")
    let exitCode:Int32
    do {let o=try Options(Array(CommandLine.arguments.dropFirst()));try FileManager.default.createDirectory(at:o.root,withIntermediateDirectories:true);try await run(o);exitCode=0}
    catch {
        if let path=CommandLine.arguments.dropFirst().first {
            let root=URL(fileURLWithPath:path,isDirectory:true),url=URL(fileURLWithPath:path).appendingPathComponent("recording-receipt.json")
            if let data=try? Data(contentsOf:url),var partial=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                partial["status"]="failed";partial["failure_reason"]=String(describing:error);try? writeReceipt(partial,root:root)
            }
        }
        fputs("MONITOR_RECORDING FAIL \(error)\n",stderr);exitCode=1
    }
    ProcessInfo.processInfo.endActivity(qualificationActivity)
    exit(exitCode)
}
dispatchMain()
