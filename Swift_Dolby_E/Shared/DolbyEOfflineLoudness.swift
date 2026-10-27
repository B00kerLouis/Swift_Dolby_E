// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public enum DolbyEOfflineLoudnessMode: String,Codable,Sendable {case measure,normalize}

/// Explicit programme processing, independent of listener gain and downstream
/// AC3DRC instructions. This workflow uses full-programme relative gating;
/// it does not claim automatic speech detection or DialogueIntelligence.
public struct DolbyEOfflineLoudnessConfiguration: Codable,Sendable,Equatable {
    public var mode: DolbyEOfflineLoudnessMode
    public var targetLUFS: Double
    public var maximumTruePeakDBTP: Double
    public var toleranceLU: Double
    public var ed2Layout: DolbyEPlaybackLayout
    public var payloadVersion: DolbyELoudnessPayloadVersion
    public init(mode:DolbyEOfflineLoudnessMode = .normalize,targetLUFS:Double = -23,
                maximumTruePeakDBTP:Double = -2.5,toleranceLU:Double = 0.2,
                ed2Layout:DolbyEPlaybackLayout = .fiveOne,payloadVersion:DolbyELoudnessPayloadVersion = .standard1) {
        self.mode=mode;self.targetLUFS=targetLUFS;self.maximumTruePeakDBTP=maximumTruePeakDBTP
        self.toleranceLU=toleranceLU;self.ed2Layout=ed2Layout;self.payloadVersion=payloadVersion
    }
    public func validate()throws {
        guard targetLUFS.isFinite,(-60 ... -1).contains(targetLUFS),maximumTruePeakDBTP.isFinite,(-24 ... -0.1).contains(maximumTruePeakDBTP),toleranceLU.isFinite,(0.05...1).contains(toleranceLU) else{throw DolbyEError.invalidArgument("offline loudness target/ceiling/tolerance")}
        guard ed2Layout != .stereo else{throw DolbyEError.invalidArgument("ED2normalization selects a discrete Main layout; Stereo is measured separately")}
    }
}

public struct DolbyEProgrammeLoudnessReport: Codable,Sendable {
    public let programme: String
    public let layout: String
    public let mode: DolbyEOfflineLoudnessMode
    public let targetLUFS: Double
    public let ceilingDBTP: Double
    public let fixedGainDB: Double
    public let before: DolbyELoudnessMeasurement
    public let after: DolbyELoudnessMeasurement
    public let targetAchieved: Bool
}

/// Fixed programme gains plus a smooth, linked protection envelope. ED2's
/// envelope is driven by its actual selected presentation, then applied once
/// to all16feeds. For a discrete linear render this preserves spatial ratios.
struct DolbyELoudnessProcessor: Codable,Sendable {
    let vision: DolbyEEncodeVision
    let program: DolbyEProgram
    let settings: DolbyEOfflineLoudnessConfiguration
    let gainsDB: [Double]
    private var renderer: DolbyED2PresentationRenderer
    private var peakLimiter: DolbyETruePeakLimiter
    init(vision:DolbyEEncodeVision,program:DolbyEProgram,settings:DolbyEOfflineLoudnessConfiguration,gainsDB:[Double])throws {
        try settings.validate()
        guard gainsDB.count==(vision == .ed2 ? 1:program.programChannelCounts.count),gainsDB.allSatisfy({$0.isFinite && (-80...60).contains($0)}) else{throw DolbyEError.invalidArgument("programme loudness gain count/range")}
        self.vision=vision;self.program=program;self.settings=settings;self.gainsDB=gainsDB
        renderer = .init(layout:settings.ed2Layout)
        let count=vision == .ed2 ? settings.ed2Layout.speakers.count:8
        let groups=vision == .ed2 ? [Array(0..<count)]:Self.groups(program)
        peakLimiter=try .init(groups:groups,channelCount:count)
    }
    static func groups(_ program:DolbyEProgram)->[[Int]] {
        var at=0
        return program.programChannelCounts.map {count in defer{at+=count};return Array(at..<(at+count))}
    }
    static func preparedScene(_ original:DolbyED2SceneMetadata)->DolbyED2SceneMetadata {
        var scene=original
        for object in scene.objects.indices {
            for block in scene.objects[object].states.indices {scene.objects[object].states[block].active=true;scene.objects[object].states[block].gain=1}
            scene.objects[object].alternatives=[.init(gain:1)]
        }
        scene.presentations=[.init(defaultDeviceMask:4,targets:[1,2,4].map {mask in
            .init(deviceMask:mask,objectMetadataIndices:Array(repeating:mask==4 ? 1:0,count:scene.objects.count),bedMetadataIndices:Array(repeating:0,count:scene.beds.count))
        })];return scene
    }
    mutating func ordinary(_ pcm:inout [Double],preview:inout [Double],collect:Bool=true)throws->[[Double]] {
        guard vision == .e,pcm.count%8==0,preview.count==512*8 else{throw DolbyEError.invalidArgument("ordinary loudness processing block")}
        let groups=Self.groups(program)
        if settings.mode == .normalize {
            for (i,group) in groups.enumerated(){let gain=pow(10,gainsDB[i]/20);for dataIndex in pcm.indices where group.contains(dataIndex%8){pcm[dataIndex]*=gain};for dataIndex in preview.indices where group.contains(dataIndex%8){preview[dataIndex]*=gain}}
            try protect(&pcm,preview:&preview)
        }
        guard collect else{return []}
        return groups.map {group in
            var output:[Double]=[];output.reserveCapacity(pcm.count/8*group.count)
            for at in stride(from:0,to:pcm.count,by:8){for channel in group{output.append(pcm[at+channel])}};return output
        }
    }
    mutating func immersive(_ pcm:inout [Double],scene:DolbyED2SceneMetadata,preview:inout [Double],previewScene:DolbyED2SceneMetadata,preparedObjectPCM:Bool=true,maximumParallelism:Int=1)throws->[Double] {
        guard vision == .ed2,pcm.count%16==0,preview.count==512*16 else{throw DolbyEError.invalidArgument("ED2loudness processing block")}
        if settings.mode == .normalize {let gain=pow(10,gainsDB[0]/20);for at in pcm.indices{pcm[at]*=gain};for at in preview.indices{preview[at]*=gain}}
        var rendered=try renderer.render(pcm,scene:preparedObjectPCM ? Self.preparedScene(scene):scene,maximumParallelism:maximumParallelism)
        if settings.mode == .normalize {
            var futureRenderer=renderer
            var future=try futureRenderer.render(preview,scene:preparedObjectPCM ? Self.preparedScene(previewScene):previewScene,maximumParallelism:maximumParallelism)
            let original=rendered,channels=settings.ed2Layout.speakers.count
            try protect(&rendered,preview:&future)
            for sample in 0..<(pcm.count/16) {
                let start=sample*channels
                var channel=0
                for index in 1..<channels where abs(original[start+index])>abs(original[start+channel]){channel=index}
                let gain=original[start+channel] == 0 ? 1:rendered[start+channel]/original[start+channel]
                guard gain.isFinite,gain>=0,gain<=1+1e-12 else{throw DolbyEError.malformed("linked presentation limiter gain")}
                for index in 0..<16{pcm[sample*16+index]*=min(1,gain)}
            }
        }
        return rendered
    }
    private mutating func protect(_ pcm:inout [Double],preview:inout [Double])throws {
        // Rescale the established limiter, preserving its default checkpoint
        // representation and making the selected output ceiling explicit.
        let scale=pow(10,(-2.5-settings.maximumTruePeakDBTP)/20)
        for i in pcm.indices{pcm[i]*=scale};for i in preview.indices{preview[i]*=scale}
        try peakLimiter.process(&pcm,preview:&preview)
        for i in pcm.indices{pcm[i]/=scale};for i in preview.indices{preview[i]/=scale}
    }
}
