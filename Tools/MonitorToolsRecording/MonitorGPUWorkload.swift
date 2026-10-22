import CoreVideo
import Foundation
@preconcurrency import Metal
import MonitorToolsCore
import MonitorToolsMetal

/// One feed's monitor surface work, run offscreen with the production renderer:
/// every offered frame gets one picture encode into a 1080p target (never
/// refused or thinned), and scopes get their own command buffer at the
/// configured rate. Producer IOSurfaces are read in place; nothing is copied.
final class MonitorGPUWorkload: MonitorEncodeCompletion, @unchecked Sendable {
    struct Snapshot {
        var offered=0,encoded=0,completedPictures=0,scopeEncodes=0,completedScopes=0,failures=0
        var encodeErrors:[String]=[]
        var pictureGPU=Distribution(),scopeGPU=Distribution(),pictureAge=Distribution(),scopeAge=Distribution(),encodeWall=Distribution()
        var statusCounts:[String:Int]=[:]
        var toolUnavailable=0
    }
    private struct Pending {let host:Double;let scope:Bool;let measured:Bool}
    let runtime:MonitorRuntime
    let configuration:MonitorConfiguration
    private let renderer:MonitorToolsRenderer
    private let lock=NSLock(),encodeLock=NSLock()
    private var measured=Snapshot()
    private var pending:[Int:Pending]=[:]
    private var nextKind=1
    private var nextScopeTime = -Double.infinity
    private var measuring=true
    private let targets:[MTLTexture],scopeTargets:[MTLTexture]
    private let residency:MTLResidencySet
    private var targetIndex=0

    init(runtime:MonitorRuntime,configuration:MonitorConfiguration,width:Int=1920,height:Int=1080) throws {
        self.runtime=runtime;self.configuration=configuration.normalized()
        renderer=MonitorToolsRenderer(runtime:runtime)
        guard let device=runtime.device else {throw WorkloadFailure(reason:runtime.unavailableReason ?? "Monitor GPU unavailable")}
        func texture(_ w:Int,_ h:Int) throws -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false)
            d.usage=[.shaderRead,.shaderWrite];d.storageMode = .private
            guard let t=device.makeTexture(descriptor:d) else {throw WorkloadFailure(reason:"target allocation failed")}
            return t
        }
        // Three targets stand in for a layer's drawables.
        targets=try (0..<3).map{_ in try texture(width,height)}
        scopeTargets=try (0..<3).map{_ in try texture(MonitorToolsRenderer.scopeWidth,MonitorToolsRenderer.scopeHeight)}
        residency=try device.makeResidencySet(descriptor:MTLResidencySetDescriptor())
        for t in targets+scopeTargets {residency.addAllocation(t)}
        residency.commit()
        runtime.attachDrawables(residency)
    }
    deinit {runtime.detachDrawables(residency)}

    /// Starts a fresh measurement window; warmup work still in flight is not counted.
    func resetMeasurement() {
        lock.lock();measured=Snapshot();pending=pending.mapValues{Pending(host:$0.host,scope:$0.scope,measured:false)};lock.unlock()
    }
    func snapshot()->Snapshot {lock.lock();defer{lock.unlock()};return measured}
    /// GPU work committed but not yet completed.
    var inFlight:Int {lock.lock();defer{lock.unlock()};return pending.count}

    func offer(_ bundle:MonitorFrameBundle) {
        let begin=ProcessInfo.processInfo.systemUptime
        lock.lock();measured.offered += 1;lock.unlock()
        encodeLock.lock();defer{encodeLock.unlock()}
        let state=MonitorRenderState(configuration:configuration)
        do {
            let frame=try runtime.gpuFrame(bundle)
            let target=targets[targetIndex%targets.count],scopeTarget=scopeTargets[targetIndex%scopeTargets.count]
            targetIndex &+= 1
            let context=try runtime.beginEncoding()
            do {
                try renderer.encode(frame:frame,state:state,target:target,viewport:MonitorViewport(width:target.width,height:target.height),into:context)
            } catch {runtime.abandon(context);throw error}
            let kind=register(host:bundle.stamp.hostTime,scope:false)
            runtime.commit(context,completion:self,kind:kind)
            let status=renderer.status
            lock.lock()
            measured.encoded += 1
            for s in status where measured.statusCounts.count<16 || measured.statusCounts[s] != nil {measured.statusCounts[s,default:0] += 1}
            if configuration.toolsEnabled && status.contains(where:{$0.hasPrefix("False color unavailable:") || $0.hasPrefix("Focus unavailable:") || $0.hasPrefix("Monitor tools unavailable:")}) {measured.toolUnavailable += 1}
            lock.unlock()
            // Scopes at the user's rate, on the frame clock, in their own command buffer.
            let host=bundle.stamp.hostTime,interval=1/Double(max(1,min(60,configuration.scopes.refreshHz)))
            if renderer.wantsScopes(state) && host >= nextScopeTime-0.002 {
                nextScopeTime = nextScopeTime+interval > host ? nextScopeTime+interval : host+interval
                let scopeContext=try runtime.beginEncoding()
                do {try renderer.encodeScopes(frame:frame,state:state,target:scopeTarget,into:scopeContext)}
                catch {runtime.abandon(scopeContext);throw error}
                let scopeKind=register(host:host,scope:true)
                runtime.commit(scopeContext,completion:self,kind:scopeKind)
                lock.lock();measured.scopeEncodes += 1;lock.unlock()
            }
        } catch {
            lock.lock();measured.failures += 1;if measured.encodeErrors.count<16 {measured.encodeErrors.append(String(describing:error))};lock.unlock()
        }
        lock.lock();measured.encodeWall.add(ProcessInfo.processInfo.systemUptime-begin);lock.unlock()
    }

    private func register(host:Double,scope:Bool)->Int {
        lock.lock();defer{lock.unlock()}
        nextKind &+= 1
        pending[nextKind]=Pending(host:host,scope:scope,measured:true)
        return nextKind
    }

    func encodeCompleted(kind:Int,gpuStart:Double,gpuEnd:Double,failed:Bool) {
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock();defer{lock.unlock()}
        guard let entry=pending.removeValue(forKey:kind),entry.measured else {return}
        if failed {measured.failures += 1;if measured.encodeErrors.count<16 {measured.encodeErrors.append("GPU work failed")};return}
        let gpu=max(0,gpuEnd-gpuStart)
        if entry.scope {
            measured.completedScopes += 1;measured.scopeGPU.add(gpu);measured.scopeAge.add(now-entry.host)
        } else {
            measured.completedPictures += 1;measured.pictureGPU.add(gpu);measured.pictureAge.add(now-entry.host)
        }
    }

    /// Waits for every committed encode to complete.
    func drain(timeout:Double) -> Bool {
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while inFlight>0 && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.002)}
        return inFlight == 0
    }
    func invalidate(){renderer.invalidate()}
}
struct WorkloadFailure:Error {let reason:String}

/// FNV-1a over every byte of every plane, so a monitor write into a producer buffer is caught.
func producerFingerprint(_ image:CVPixelBuffer)->UInt64 {
    CVPixelBufferLockBaseAddress(image,.readOnly);defer{CVPixelBufferUnlockBaseAddress(image,.readOnly)}
    var hash:UInt64=1469598103934665603
    let planes=max(1,CVPixelBufferGetPlaneCount(image))
    for plane in 0..<planes {
        let planar=CVPixelBufferGetPlaneCount(image)>0
        guard let base=planar ? CVPixelBufferGetBaseAddressOfPlane(image,plane):CVPixelBufferGetBaseAddress(image) else {continue}
        let rows=planar ? CVPixelBufferGetHeightOfPlane(image,plane):CVPixelBufferGetHeight(image)
        let stride=planar ? CVPixelBufferGetBytesPerRowOfPlane(image,plane):CVPixelBufferGetBytesPerRow(image)
        let words=base.assumingMemoryBound(to:UInt64.self)
        for i in 0..<(rows*stride/8) {hash=(hash ^ words[i]) &* 1099511628211}
    }
    return hash
}
