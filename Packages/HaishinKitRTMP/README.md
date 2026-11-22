# HaishinKit RTMP runtime

Ultracam builds the macOS core and RTMP runtime from [HaishinKit.swift 2.3.1](https://github.com/HaishinKit/HaishinKit.swift/tree/047929455583f65ea5b9ee18b8bb9e39161dd290). The upstream directories `HaishinKit/Sources` and `RTMPHaishinKit/Sources` supply the Swift files under `Sources/HaishinKit` and `Sources/RTMPHaishinKit`. Both targets belong to the same Swift package so the RTMP channel can access the core package interfaces.

Ultracam extends the RTMP publisher with Enhanced RTMP AV1 signaling, destination codec capability checks, and a shared audio and video epoch for externally encoded pictures. The epoch delays pictures by the audio encoder's priming interval, which FLV receivers present before the first PCM sample. Preserve these publishing changes when refreshing the upstream sources. The package tests verify packet bytes and the repository’s streaming receiver smoke tests decode the published media.
