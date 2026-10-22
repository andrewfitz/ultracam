// MonitorKitScopes: waveform, vectorscope and histogram on the GPU.
//
//   let scopes = try ScopeEngine(device: device)        // once per device
//   let waveform = try scopes.makeAccumulator(settings: ScopeSettings(kind: .waveform))
//   let vectorscope = try scopes.makeAccumulator(settings: ScopeSettings(kind: .vectorscope))
//   let stage = try scopes.makeGroup([waveform, vectorscope])  // one pass for both
//   let renderer = scopes.makeRenderer()                // one per surface and scope
//
//   try stage.accumulate(frame, feed: feed, into: cb)   // at the host's scope rate
//   try renderer.render(waveform, target: drawable.texture, viewport: v, into: cb)  // every frame
//   let clipped = waveform.statisticsReader.statistics?.clippedHigh  // from any thread
