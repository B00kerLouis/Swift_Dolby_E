// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// A real two-substream ED2 system encoder. Each substream encodes eight
/// independent full-band signals; the first carries bed/object/presentation
/// metadata identifying the meaning of those sixteen signals.
public struct DolbyED2PCMFrameEncoder: Codable, Sendable {
    public let frameRate: DolbyEFrameRate
    private var first: DolbyEPCMFrameEncoder
    private var second: DolbyEPCMFrameEncoder
    private var metadataClock: DolbyED2MetadataClock

    public init(frameRate: DolbyEFrameRate = .fps25, ac3Metadata: [DolbyEAC3Metadata]? = nil,
                spectralShifts: [Int] = Array(repeating: 0, count: 16)) throws {
        guard spectralShifts.count == 16 else { throw DolbyEError.invalidArgument("ED2 spectral normalization requires sixteen signals") }
        self.frameRate = frameRate
        self.metadataClock = DolbyED2MetadataClock(frameRate: frameRate)
        let settings = try Self.monoMetadata(ac3Metadata)
        first = try DolbyEPCMFrameEncoder(program: .eightMono, frameRate: frameRate, programs: Array(settings.prefix(8)), spectralShifts: Array(spectralShifts.prefix(8)))
        second = try DolbyEPCMFrameEncoder(program: .eightMono, frameRate: frameRate, programs: Array(settings.suffix(8)), spectralShifts: Array(spectralShifts.suffix(8)))
    }

    /// One shared setting, eight settings repeated on AES2, or sixteen settings
    /// in AES1/AES2 signal order. Other counts are rejected without discarding data.
    static func monoMetadata(_ source: [DolbyEAC3Metadata]?) throws -> [DolbyEProgramMetadata] {
        if let source, ![1, 8, 16].contains(source.count) { throw DolbyEError.invalidArgument("ED2 requires one shared, eight repeated-per-AES or sixteen independent-signal metadata settings") }
        return try (0..<16).map { index in
            var value = source.map { $0[index % $0.count] }
                ?? DolbyEAC3Metadata.defaults(program: .eightMono, index: index % 8)
            // Dolby E metadata describes each independent mono signal. The
            // complete immersive topology is described separately by MGI/OAMD.
            value.audioCodingMode = 1; value.lfe = false; value.dolbySurroundMode = 0
            value.surroundPhase90 = false; value.lfeLowPassFilter = false; value.preferredDownmix = 0
            return try DolbyEProgramMetadata(ac3: value)
        }
    }

    public func requiredInputFrames() throws -> Int {
        let a = try first.requiredInputFrames(), b = try second.requiredInputFrames()
        guard a == b else { throw DolbyEError.malformed("ED2 encoder substream clocks diverged") }
        return a
    }

    mutating func measureSpectralPeaks(_ pcm: [Double],maximumParallelism:Int=0) throws -> [Double] {
        guard pcm.count == (try requiredInputFrames()) * 16 else { throw DolbyEError.invalidArgument("headroom PCM frame size") }
        var one: [Double] = [], two: [Double] = []
        for at in stride(from: 0, to: pcm.count, by: 16) {
            one += pcm[at..<(at+8)]; two += pcm[(at+8)..<(at+16)]
        }
        let workers=try DolbyEParallelWork.limit(maximumParallelism),inputs=[one,two]
        let result=try DolbyEParallelWork.map([first,second],parallelism:min(2,workers)) {codec,index in
            var value=codec
            let peaks=try value.measureSpectralPeaks(inputs[index],maximumParallelism:workers==1 ? 1:max(1,workers/2))
            return(value,peaks)
        }
        first=result[0].0;second=result[1].0;return result[0].1+result[1].1
    }

    /// Returns four interleaved, left-aligned carrier channels (AES1 L/R,
    /// AES2 L/R). Metadata and its HMAC bind the actual newly encoded audio.
    public mutating func encode(_ pcm: [Double], scene: DolbyED2SceneMetadata,
                                preparedObjectPCM: Bool = false,maximumParallelism: Int = 0,
                                programmeLoudness: DolbyEProgrammeLoudness? = nil) throws -> [UInt32] {
        let count = try requiredInputFrames()
        guard pcm.count == count * 16, pcm.allSatisfy(\.isFinite) else { throw DolbyEError.invalidArgument("ED2 input must contain a complete sixteen-signal PCM frame") }
        try scene.validate()
        var clock = metadataClock
        var alignedScene = try clock.shift(scene: scene, frameCount: count)
        if preparedObjectPCM {
            // The source adapter has already applied authored gains, active
            // windows, zone routing and decorrelation to these aggregate PCM
            // channels. Their transport gain must stay at unity, including
            // silent intervals: silence is present in PCM, not a second gate.
            for object in alignedScene.objects.indices {
                for block in alignedScene.objects[object].states.indices {
                    alignedScene.objects[object].states[block].active = true
                    alignedScene.objects[object].states[block].gain = 1
                }
                // A gain-only immersive alternative inherits every dynamic
                // position update. It does not freeze a frame's first XYZ.
                alignedScene.objects[object].alternatives = [.init(gain: 1)]
            }
            alignedScene.presentations = [.init(defaultDeviceMask: 4, targets: [1, 2, 4].map { mask in
                .init(deviceMask: mask, objectMetadataIndices: Array(repeating: mask == 4 ? 1 : 0, count: alignedScene.objects.count),
                    bedMetadataIndices: Array(repeating: 0, count: alignedScene.beds.count))
            })]
        }
        // Carry complete object descriptions even through leading silence and
        // unused aggregation slots. An OAMD "not active" block omits both
        // position and gain, leaving a newly acquired stream without geometry.
        // Active-with-zero-gain is the equivalent mute representation and
        // explicitly conveys the real held position, size and snap fields.
        for object in alignedScene.objects.indices {
            for block in alignedScene.objects[object].states.indices where !alignedScene.objects[object].states[block].active {
                alignedScene.objects[object].states[block].active = true
                alignedScene.objects[object].states[block].gain = 0
            }
        }
        let metadataSizes = try (0..<2).map {
            try DolbyED2MetadataContainer.encodedWordCount(scene: alignedScene, duration: count, substreamIndex: $0,programmeLoudness:programmeLoudness)
        }
        // Keep a video-edit guard band before and after both synchronized
        // bursts. Audio allocation yields capacity to real dynamic metadata.
        let timing = DolbyECarrierTiming(frameRate: frameRate)
        let leadingWords = timing.referenceOffsetFrames * 2
        let trailingWords = (timing.guardBandFrames - timing.referenceOffsetFrames) * 2
        let nominal = try DolbyEFrameAllocation(program: .eightMono, rate: frameRate, evolution: true).payloadWords
        let budget = min(nominal, try timing.maximumPayloadWords(carrierFrames: count) - metadataSizes.max()!)
        guard budget >= 1024 else { throw DolbyEError.invalidArgument("ED2 metadata cannot fit the video-frame carrier capacity") }
        var x = [Double](), y = [Double]()
        x.reserveCapacity(count * 8); y.reserveCapacity(count * 8)
        for sample in stride(from: 0, to: pcm.count, by: 16) {
            x += pcm[sample..<(sample + 8)]; y += pcm[(sample + 8)..<(sample + 16)]
        }
        let workers = try DolbyEEncoderWork.limit(maximumParallelism)
        let inputs = [x,y]
        let cores = try DolbyEEncoderWork.map([first,second],parallelism:min(workers,2)) { original,index in
            var codec = original
            let words = try codec.encode(inputs[index],evolution:true,payloadWordCount:budget,
                maximumParallelism:workers == 1 ? 1 : max(1,workers/2))
            return (codec,words)
        }
        let ordinary = cores.map { $0.1 }
        var pairs: [[UInt32]] = []
        for index in 0..<2 {
            let start = leadingWords + 4
            let core = Array(ordinary[index][start..<(start + budget)])
            let metadata = try DolbyED2MetadataContainer.encode(scene: alignedScene, duration: count,
                substreamIndex: index, coreWords: core,programmeLoudness:programmeLoudness)
            guard metadata.count == metadataSizes[index] else { throw DolbyEError.malformed("ED2 metadata capacity changed during authentication") }
            let packet = try DolbyED2MetadataContainer.parse(words: metadata).verifying(coreWords: core)
            guard packet.authenticationVerified else { throw DolbyEError.malformed("ED2 encoded authentication verification failed") }
            let payload = core + metadata
            var pair = Array(repeating: UInt32(0), count: leadingWords)
            pair += [0x6f872000, 0x54e1f000, 0x003c0000, UInt32(payload.count * 20) << 12]
            pair += payload
            guard pair.count + trailingWords <= count * 2 else { throw DolbyEError.malformed("ED2 burst overflows its video-frame guard band") }
            pair += repeatElement(UInt32(0), count: count * 2 - pair.count)
            pairs.append(pair)
        }
        var result: [UInt32] = []; result.reserveCapacity(count * 4)
        for sample in 0..<count {
            result += [pairs[0][sample * 2], pairs[0][sample * 2 + 1], pairs[1][sample * 2], pairs[1][sample * 2 + 1]]
        }
        first = cores[0].0; second = cores[1].0; metadataClock = clock
        return result
    }
}
