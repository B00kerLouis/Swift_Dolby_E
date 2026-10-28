// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

struct DolbyEOfflineLoudnessPlan: Codable,Sendable {
    let settings: DolbyEOfflineLoudnessConfiguration
    let gainsDB: [Double]
    let reports: [DolbyEProgrammeLoudnessReport]
    var spectralShifts:[Int]? = nil
    func processor(request:DolbyERequest)throws->DolbyELoudnessProcessor {
        try .init(vision:request.encodeVision,program:request.program,settings:settings,gainsDB:gainsDB)
    }
    func programmePayload()->DolbyEProgrammeLoudness {
        var value=DolbyEProgrammeLoudness(version:settings.payloadVersion)
        // Measurement-only output must not assert that a loudness correction
        // was performed. The sidecar report still identifies its EBU method.
        value.practice=settings.mode == .normalize ? .ebu:.unspecified
        value.correction = .fileBased;value.integratedLUFS=reports.first?.after.integratedLUFS
        if settings.payloadVersion == .standard1 {
            value.maximumShortTermLUFS=reports.first?.after.maximumShortTermLUFS
            value.maximumTruePeakDBTP=reports.first?.after.truePeakDBTP
            value.loudnessRangeLU=reports.first?.after.loudnessRangeLU
            value.loudnessRangePractice=1
            value.maximumMomentaryLUFS=reports.first?.after.maximumMomentaryLUFS
        }
        return value
    }
    func ordinaryRequest(_ request:DolbyERequest)throws->DolbyERequest {
        var result=request
        var settings=request.ac3Metadata ?? request.program.programChannelCounts.indices.map{.defaults(program:request.program,index:$0)}
        guard settings.count==reports.count else{throw DolbyEError.invalidArgument("programme metadata/loudness cardinality")}
        for index in settings.indices {
            if let measured=reports[index].after.integratedLUFS {
                let rounded=Int(measured.rounded())
                guard (-31 ... -1).contains(rounded) else{throw DolbyEError.invalidArgument("measured programme loudness\(measured)cannot be represented by legacy dialnorm")}
                settings[index].dialogueLevel=rounded
            }
        }
        result.ac3Metadata=settings;return result
    }
}

private struct LoudnessPreparationCheckpoint: Codable {
    let sourcePosition: UInt64
    let videoFrames: UInt64
    let tail: Int
    let pass: Int
    let gainsDB: [Double]
    let original: [DolbyELoudnessMeasurement]?
    let ordinaryRouter: DolbyEEncodingRouter?
    let immersiveRouter: DolbyED2SceneRouter?
    let sourceLimiter: DolbyETruePeakLimiter
    let processor: DolbyELoudnessProcessor
    let analyzers: [DolbyELoudnessAnalyzer.Checkpoint]
    let plan: DolbyEOfflineLoudnessPlan?
    var spectralProfiler:DolbyESpectralProfiler? = nil
}

/// Recoverable source-owned passes. Energy spools stay beside the destination;
/// only bounded filters/router/renderer/checkpoints live in the job store. No
/// intermediate PCM master is generated. A prepared plan survives encoding
/// retries without repeating completed source analysis.
enum DolbyEOfflineLoudnessPreparation {
    static func run(_ request:DolbyERequest,sourceURL:URL,outputURL:URL,directory:URL,progress:DolbyEEncodingProgressReporter?=nil)throws->DolbyEOfflineLoudnessPlan? {
        guard let configuration=request.loudness else{return nil}
        try configuration.validate()
        let store=try DolbyEFileJobStore(operation:"loudness",directory:directory)
        let signature=DolbyEFileJobStore.signature(request,operation:"loudness")
        let existing=try store.resumable(output:request.outputURL,signature:signature)
        let saved=try existing.flatMap{try store.restore(LoudnessPreparationCheckpoint.self,from:$0)}
        let source=try DolbyEInputSource(url:sourceURL,program:request.encodeVision == .ed2 ? .eightMono:request.program)
        let identity=try source.identity(),rate=request.frameRate ?? source.embeddedFrameRate ?? .fps25
        guard existing == nil || existing?.sourceIdentity==identity else{throw DolbyEError.invalidArgument("loudness source/sidecar identity changed")}
        if let plan=saved?.plan{return plan}
        let job=existing ?? DolbyEFileJobRecord(signature:signature,input:request.inputURL,output:request.outputURL,sourceIdentity:identity,sourceFrames:source.info.frameCount)
        if existing==nil{try store.insert(job)}
        let isED2=request.encodeVision == .ed2
        let groups=isED2 ? [Array(0..<16)]:DolbyELoudnessProcessor.groups(request.program)
        let weights:[[Double]]=isED2 ? [DolbyELoudnessMeter.weights(speakers:configuration.ed2Layout.speakers)]:groups.enumerated().map {index,group in
            if request.program == .fiveOnePlusTwo{return index==0 ? [1,1,1,0,1.41,1.41]:[1,1]}
            if request.program == .eightMono{return [1]}
            return DolbyELoudnessMeter.weights(speakers:DolbyEPlaybackLayout.sevenOneScreen.speakers).prefix(group.count).map{$0}
        }
        var pass=saved?.pass ?? 0,gains=saved?.gainsDB ?? Array(repeating:0.0,count:weights.count)
        var original=saved?.original,frames=saved?.videoFrames ?? 0,tail=saved?.tail ?? 1
        var ordinary=try saved?.ordinaryRouter ?? (isED2 ? nil:DolbyEEncodingRouter(source:source,request:request))
        var immersive=saved?.immersiveRouter ?? (isED2 ? DolbyED2SceneRouter(dialogueSource:request.dialogueSource,inputLayout:request.inputLayout):nil)
        var sourceLimiter=try saved?.sourceLimiter ?? .init(groups:isED2 ? [Array(0..<16)]:(ordinary?.limitingGroups ?? []),channelCount:isED2 ? 16:8)
        var passSettings=configuration;if pass==0{passSettings.mode = .measure}
        var processor=try saved?.processor ?? .init(vision:request.encodeVision,program:request.program,settings:passSettings,gainsDB:gains)
        var spectralProfiler=saved?.spectralProfiler
        if saved==nil,configuration.mode == .measure {spectralProfiler=try .init(encodeVision:request.encodeVision,program:request.program,frameRate:rate)}
        func spool(_ index:Int)->URL {outputURL.deletingLastPathComponent().appendingPathComponent(".\(outputURL.lastPathComponent).\(job.id.uuidString).loudness-p\(pass)-\(index).energy")}
        func newAnalyzers()throws->[DolbyELoudnessAnalyzer] {
            try weights.indices.map {index in
                let url=spool(index)
                if FileManager.default.fileExists(atPath:url.path) {
                    let size=(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.uint64Value ?? 0
                    guard size<=64 else{throw DolbyEError.malformed("uncheckpointed loudness energy data")};try FileManager.default.removeItem(at:url)
                }
                return try .init(url:url,channelWeights:weights[index])
            }
        }
        var analyzers:[DolbyELoudnessAnalyzer]
        if let saved {
            guard saved.analyzers.count==weights.count else{throw DolbyEError.malformed("loudness analyzer checkpoint count")}
            analyzers=try saved.analyzers.enumerated().map{try .init(url:spool($0.offset),checkpoint:$0.element)}
            try source.seek(toFrame:saved.sourcePosition)
        }else{analyzers=try newAnalyzers()}
        func checkpoint(plan:DolbyEOfflineLoudnessPlan?=nil)throws {
            let state=try LoudnessPreparationCheckpoint(sourcePosition:source.position,videoFrames:frames,tail:tail,pass:pass,gainsDB:gains,original:original,ordinaryRouter:ordinary,immersiveRouter:immersive,sourceLimiter:sourceLimiter,processor:processor,analyzers:analyzers.map{try $0.checkpoint()},plan:plan,spectralProfiler:spectralProfiler)
            try store.save(state,job:job,complete:plan != nil,phase:"loudness-pass\(pass)")
            if plan != nil{try store.update(job,status:"prepared")}
        }
        do {
            if saved==nil{try checkpoint()}
            while true {
                let phase:DolbyEEncodingPhase = pass == 0 ? .measuringLoudness:.normalizingLoudness
                progress?.emit(phase,processed:source.position,total:source.info.frameCount,pass:pass+1)
                while source.position<source.info.frameCount || tail>0 {
                    try autoreleasepool {
                        try Task.checkCancellation()
                        let scale=UInt64(48000*rate.denominator),numerator=UInt64(rate.numerator)
                        guard frames<UInt64.max/scale-1 else{throw DolbyEError.invalidArgument("loudness frame clock overflow")}
                        let count=Int((frames+1)*scale/numerator-frames*scale/numerator)
                        if source.position>=source.info.frameCount{tail-=1}
                        if isED2 {
                            var routed=try source.readED2(maxFrames:count,router:&immersive!)
                            var future=try source.peekED2(maxFrames:DolbyETruePeakLimiter.previewFrames,router:immersive!)
                            try sourceLimiter.process(&routed.samples,preview:&future.samples)
                            let rendered=try processor.immersive(&routed.samples,scene:routed.metadata,preview:&future.samples,previewScene:future.metadata,maximumParallelism:request.maximumParallelism)
                            try analyzers[0].append(rendered,maximumParallelism:request.maximumParallelism)
                            try spectralProfiler?.append(routed.samples,maximumParallelism:request.maximumParallelism)
                        }else{
                            var routed=try source.readRouted(maxFrames:count,router:&ordinary!)
                            var future=try source.peekRouted(maxFrames:DolbyETruePeakLimiter.previewFrames,router:ordinary!)
                            if !sourceLimiter.groups.isEmpty{try sourceLimiter.process(&routed,preview:&future)}
                            let outputs=try processor.ordinary(&routed,preview:&future)
                            for i in analyzers.indices{try analyzers[i].append(outputs[i],maximumParallelism:request.maximumParallelism)}
                            try spectralProfiler?.append(routed,maximumParallelism:request.maximumParallelism)
                        }
                        frames+=1
                        progress?.emit(phase,processed:source.position,total:source.info.frameCount,pass:pass+1)
                        if frames%25==0{try checkpoint()}
                    }
                }
                guard try source.identity()==identity else{throw DolbyEError.invalidArgument("source changed during programme measurement")}
                let measured=try analyzers.map{try $0.measurement()}
                if original==nil{original=measured}
                let achieved=measured.indices.allSatisfy {index in
                    guard let level=measured[index].integratedLUFS else{return original![index].integratedLUFS==nil}
                    return abs(level-configuration.targetLUFS)<=configuration.toleranceLU && (measured[index].truePeakDBTP ?? -1000)<=configuration.maximumTruePeakDBTP+0.001
                }
                if configuration.mode == .measure || pass>0 && achieved {
                    let reports=measured.indices.map {index in
                        DolbyEProgrammeLoudnessReport(programme:isED2 ? "Main":request.program == .fiveOnePlusTwo ? (index==0 ? "Main":"Stereo"):"Programme\(index+1)",layout:isED2 ? configuration.ed2Layout.rawValue:request.program == .fiveOnePlusTwo ? (index==0 ? "5.1":"2.0"):request.program.rawValue,mode:configuration.mode,targetLUFS:configuration.targetLUFS,ceilingDBTP:configuration.maximumTruePeakDBTP,fixedGainDB:gains[index],before:original![index],after:measured[index],targetAchieved:measured[index].integratedLUFS.map{abs($0-configuration.targetLUFS)<=configuration.toleranceLU} ?? false)
                    }
                    var plan=DolbyEOfflineLoudnessPlan(settings:configuration,gainsDB:gains,reports:reports)
                    plan.spectralShifts=try spectralProfiler?.spectralShifts()
                    try checkpoint(plan:plan);return plan
                }
                guard pass<DolbyEEncodingProgressReporter.maximumNormalizationPasses-1 else{throw DolbyEError.invalidArgument("offline correction did not converge: measured\(measured.map{$0.integratedLUFS}), target\(configuration.targetLUFS)LUFS")}
                for i in gains.indices {if let level=measured[i].integratedLUFS{gains[i]+=configuration.targetLUFS-level}}
                pass+=1;frames=0;tail=1
                ordinary=try isED2 ? nil:DolbyEEncodingRouter(source:source,request:request)
                immersive=isED2 ? DolbyED2SceneRouter(dialogueSource:request.dialogueSource,inputLayout:request.inputLayout):nil
                sourceLimiter=try .init(groups:isED2 ? [Array(0..<16)]:(ordinary?.limitingGroups ?? []),channelCount:isED2 ? 16:8)
                processor=try .init(vision:request.encodeVision,program:request.program,settings:configuration,gainsDB:gains)
                spectralProfiler=try .init(encodeVision:request.encodeVision,program:request.program,frameRate:rate)
                try source.seek(toFrame:0);analyzers=try newAnalyzers();try checkpoint()
            }
        }catch{
            try? store.update(job,status:error is CancellationError ? "cancelled":"failed",error:error.localizedDescription);throw error
        }
    }
}
