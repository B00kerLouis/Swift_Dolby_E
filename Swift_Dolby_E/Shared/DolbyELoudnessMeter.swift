// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import Accelerate
import CryptoKit

/// A completed400ms gating block on the100ms grid. Energies are linear,
/// channel-weighted K-filter powers; they are never averaged in decibels.
public struct DolbyELoudnessWindow: Sendable {
    public let endingSample: UInt64
    public let gatingEnergy: Double
    public let shortTermEnergy: Double?
}

public struct DolbyELoudnessMeasurement: Codable, Sendable, Equatable {
    public let sampleFrames: UInt64
    public let integratedLUFS: Double?
    public let maximumMomentaryLUFS: Double?
    public let maximumShortTermLUFS: Double?
    public let loudnessRangeLU: Double?
    public let truePeakDBTP: Double?
    public let gatingBlocks: UInt64
    public let includedGatingBlocks: UInt64
}

/// BS.1770-5/EBU streaming window analysis at48kHz. Bounded state contains two
/// biquads/channel,11raw samples/channel and30energy steps. Integrated gating
/// is finalized separately from externally stored energy records, rather than
/// keeping arbitrarily many blocks in RAM or rounding the relative-gate bins.
public struct DolbyELoudnessMeter: Codable, Sendable {
    public let channelWeights: [Double]
    public private(set) var samplePosition: UInt64 = 0
    public private(set) var maximumMomentaryLUFS: Double?
    public private(set) var maximumShortTermLUFS: Double?
    private var channels: [Channel]
    private var phase = 0
    private var powers: [Double] = []

    public init(channelWeights: [Double]) throws {
        guard (1...16).contains(channelWeights.count),channelWeights.allSatisfy({$0.isFinite && $0 >= 0 && $0 <= 2}),channelWeights.contains(where:{$0>0}) else {
            throw DolbyEError.invalidArgument("loudness requires1...16declared speaker weights")
        }
        self.channelWeights=channelWeights;channels=channelWeights.map {_ in Channel()}
    }

    /// Speaker angles determine Annex3weights. Rear speakers outside±120° and
    /// all height speakers use1; LFE contributes0, including a second LFE.
    public static func weights(speakers: [DolbyESpeaker]) -> [Double] {
        speakers.map { speaker in
            if speaker == .lfe {return 0}
            let point=speaker.position
            let elevation=atan2(point.z,hypot(point.x,point.y))*180/Double.pi
            let azimuth=abs(atan2(point.x,point.y)*180/Double.pi)
            return abs(elevation)<30 && azimuth>=60 && azimuth<=120 ? 1.41:1
        }
    }
    public static func loudness(energy: Double) -> Double? {
        energy>0 && energy.isFinite ? -0.691+10*log10(energy):nil
    }
    public var truePeakDBTP: Double? {
        let peak=channels.map {max($0.peak,Self.truePeak($0.rawHistory+Array(repeating:0,count:11),frames:11))}.max() ?? 0
        return peak>0 ? 20*log10(peak):nil
    }

    /// Reader handles do not cross workers. Each worker owns one immutable
    /// input view and its independent filter state; the ordered barrier commits
    /// every channel and window atomically, including a failure after DSP.
    public mutating func append(_ samples: [Double],maximumParallelism: Int = 0) throws -> [DolbyELoudnessWindow] {
        try validateState()
        let count=channelWeights.count
        guard samples.count%count==0,(1...8192).contains(samples.count/count),channels.count==count,(0..<4800).contains(phase),powers.count<=30 else {throw DolbyEError.invalidArgument("bounded loudness PCM/checkpoint shape")}
        let frames=samples.count/count,priorPhase=phase,start=samplePosition
        let end=start.addingReportingOverflow(UInt64(frames));guard !end.overflow else{throw DolbyEError.invalidArgument("loudness sample clock overflow")}
        let results=try DolbyEParallelWork.map(channels,parallelism:maximumParallelism) { original,index in
            var channel=original,position=priorPhase,steps:[Double]=[],raw:[Double]=[]
            raw.reserveCapacity(frames)
            for sample in 0..<frames {
                let value=samples[sample*count+index]
                guard value.isFinite,abs(value)<=1e6 else{throw DolbyEError.invalidArgument("nonfinite or excessive loudness PCM")}
                raw.append(value)
                let filtered=channel.highPass.process(channel.shelf.process(value))
                channel.sum+=filtered*filtered;position+=1
                if position==4800 {steps.append(channel.sum/4800);channel.sum=0;position=0}
            }
            let input=channel.rawHistory+raw
            channel.peak=max(channel.peak,Self.truePeak(input,frames:frames),raw.map(abs).max() ?? 0)
            channel.rawHistory=Array(input.suffix(11))
            guard channel.sum.isFinite,steps.allSatisfy({$0.isFinite && $0>=0}),channel.valid else{throw DolbyEError.malformed("loudness filter overflow/checkpoint")}
            return (channel,steps)
        }
        var history=powers,windows:[DolbyELoudnessWindow]=[],maximumM=maximumMomentaryLUFS,maximumS=maximumShortTermLUFS
        let completed=(priorPhase+frames)/4800
        for index in 0..<completed {
            var energy=0.0
            for channel in 0..<count {energy+=results[channel].1[index]*channelWeights[channel]}
            history.append(energy);if history.count>30{history.removeFirst()}
            if history.count>=4 {
                let momentary=history.suffix(4).reduce(0,+)/4
                let short=history.count==30 ? history.reduce(0,+)/30:nil
                if let value=Self.loudness(energy:momentary){maximumM=max(maximumM ?? value,value)}
                if let short,let value=Self.loudness(energy:short){maximumS=max(maximumS ?? value,value)}
                let ending=start+UInt64(4800-priorPhase+index*4800)
                windows.append(.init(endingSample:ending,gatingEnergy:momentary,shortTermEnergy:short))
            }
        }
        channels=results.map(\.0);powers=history;phase=(priorPhase+frames)%4800;samplePosition=end.partialValue
        maximumMomentaryLUFS=maximumM;maximumShortTermLUFS=maximumS
        return windows
    }
    func validateState()throws {
        guard (1...16).contains(channelWeights.count),channels.count==channelWeights.count,channelWeights.allSatisfy({$0.isFinite && (0...2).contains($0)}),channelWeights.contains(where:{$0>0}),channels.allSatisfy(\.valid),phase==Int(samplePosition%4800),powers.count==Int(min(30,samplePosition/4800)),powers.allSatisfy({$0.isFinite && $0>=0}),[maximumMomentaryLUFS,maximumShortTermLUFS].compactMap({$0}).allSatisfy(\.isFinite) else{throw DolbyEError.malformed("loudness meter checkpoint state")}
    }
    private struct Biquad: Codable,Sendable {
        let b0: Double,b1: Double,b2: Double,a1: Double,a2: Double
        var x1=0.0,x2=0.0,y1=0.0,y2=0.0
        mutating func process(_ x: Double)->Double {
            let y=b0*x+b1*x1+b2*x2-a1*y1-a2*y2
            x2=x1;x1=x;y2=y1;y1=y;return y
        }
        var valid: Bool {[b0,b1,b2,a1,a2,x1,x2,y1,y2].allSatisfy(\.isFinite)}
    }
    private struct Channel: Codable,Sendable {
        var shelf=Biquad(b0:1.53512485958697,b1:-2.69169618940638,b2:1.19839281085285,a1:-1.69065929318241,a2:0.73248077421585)
        var highPass=Biquad(b0:1,b1:-2,b2:1,a1:-1.99004745483398,a2:0.99007225036621)
        var sum=0.0,peak=0.0
        var rawHistory=Array(repeating:0.0,count:11)
        var valid: Bool {shelf.valid && highPass.valid && sum.isFinite && sum>=0 && peak.isFinite && rawHistory.count==11 && rawHistory.allSatisfy(\.isFinite)}
    }
    private static func truePeak(_ input: [Double],frames: Int)->Double {
        guard frames>0,input.count==frames+11 else{return 0}
        var filtered=Array(repeating:0.0,count:frames),peak=0.0
        for taps in DolbyETruePeakLimiter.taps {
            vDSP_convD(input,1,taps,1,&filtered,1,vDSP_Length(frames),12)
            var value=0.0;vDSP_maxmgvD(filtered,1,&value,vDSP_Length(frames));peak=max(peak,value)
        }
        return peak
    }
}

/// Owns the energy-record file and is deliberately not Sendable. Only16bytes
/// per completed100ms step are retained externally, never source PCM. Exact
/// relative gating and LRA order statistics use bounded sequential scans.
public final class DolbyELoudnessAnalyzer {
    public struct Checkpoint: Codable,Sendable {
        public let meter: DolbyELoudnessMeter
        public let recordCount: UInt64
        let id: UUID
        let digest: String
    }
    public let url: URL
    private let file: FileHandle
    private let id: UUID
    private var meter: DolbyELoudnessMeter
    private var records: UInt64=0
    private var hash=SHA256()
    private static let headerSize=64
    private static func header(_ id: UUID)->Data {var d=Data("libdolbye-loudness-v1\n\(id.uuidString)\n".utf8);d.append(contentsOf:repeatElement(0,count:headerSize-d.count));return d}
    public init(url: URL,channelWeights: [Double]) throws {
        guard !FileManager.default.fileExists(atPath:url.path) else{throw DolbyEError.invalidArgument("loudness energy file already exists")}
        self.url=url;id=UUID();meter=try .init(channelWeights:channelWeights)
        guard FileManager.default.createFile(atPath:url.path,contents:nil) else{throw CocoaError(.fileWriteUnknown)}
        file=try FileHandle(forUpdating:url);let header=Self.header(id);try file.write(contentsOf:header);hash.update(data:header)
    }
    public init(url: URL,checkpoint: Checkpoint) throws {
        self.url=url;id=checkpoint.id;meter=checkpoint.meter;records=checkpoint.recordCount
        file=try FileHandle(forUpdating:url)
        try meter.validateState()
        guard records==(meter.samplePosition>=19200 ? meter.samplePosition/4800-3:0) else{throw DolbyEError.malformed("loudness record/sample clocks disagree")}
        guard records<=UInt64.max/16-4 else{throw DolbyEError.malformed("loudness energy record count")}
        let bytes=UInt64(Self.headerSize)+records*16
        guard try file.seekToEnd()>=bytes else{throw DolbyEError.malformed("truncated loudness checkpoint data")}
        try file.seek(toOffset:0);var remaining=bytes
        while remaining>0 {
            let data=try file.read(upToCount:Int(min(remaining,65536))) ?? Data()
            guard !data.isEmpty else{throw DolbyEError.malformed("truncated loudness energy hash")};hash.update(data:data);remaining-=UInt64(data.count)
        }
        guard Self.digest(hash)==checkpoint.digest else{throw DolbyEError.malformed("loudness energy checkpoint integrity")}
        try file.seek(toOffset:0);guard try file.read(upToCount:Self.headerSize)==Self.header(id) else{throw DolbyEError.malformed("loudness energy file identity")}
        try file.truncate(atOffset:bytes);try file.seek(toOffset:bytes)
    }
    deinit {try? file.close()}
    public func append(_ pcm: [Double],maximumParallelism: Int=0) throws {
        var next=meter;let windows=try next.append(pcm,maximumParallelism:maximumParallelism)
        var data=Data(capacity:windows.count*16)
        for window in windows {for value in [window.gatingEnergy,window.shortTermEnergy ?? 0] {var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits){data.append(contentsOf:$0)}}}
        do {try file.write(contentsOf:data)}catch{try? file.truncate(atOffset:UInt64(Self.headerSize)+records*16);try? file.seek(toOffset:UInt64(Self.headerSize)+records*16);throw error}
        meter=next;records+=UInt64(windows.count);hash.update(data:data)
    }
    public func checkpoint() throws->Checkpoint {try file.synchronize();return .init(meter:meter,recordCount:records,id:id,digest:Self.digest(hash))}
    private static func digest(_ hash: SHA256)->String {hash.finalize().map{String(format:"%02x",$0)}.joined()}
    private func scan(_ body:(Double,Double)throws->Void) throws {
        try file.synchronize();let reader=try FileHandle(forReadingFrom:url);defer{try? reader.close()};try reader.seek(toOffset:UInt64(Self.headerSize))
        var remaining=records
        while remaining>0 {
            try Task.checkCancellation()
            let count=Int(min(remaining,4096)),data=try reader.read(upToCount:count*16) ?? Data()
            guard data.count==count*16 else{throw DolbyEError.malformed("loudness energy record EOF")}
            try data.withUnsafeBytes { bytes in
                for at in stride(from:0,to:data.count,by:16) {
                    let first=Double(bitPattern:UInt64(littleEndian:bytes.loadUnaligned(fromByteOffset:at,as:UInt64.self)))
                    let second=Double(bitPattern:UInt64(littleEndian:bytes.loadUnaligned(fromByteOffset:at+8,as:UInt64.self)))
                    guard first.isFinite,second.isFinite,first>=0,second>=0 else{throw DolbyEError.malformed("invalid loudness energy record")}
                    try body(first,second)
                }
            }
            remaining-=UInt64(count)
        }
    }
    public func measurement() throws->DolbyELoudnessMeasurement {
        let absolute=pow(10,(-70+0.691)/10)
        var sum=0.0,shortSum=0.0,count:UInt64=0,shortCount:UInt64=0
        try scan {energy,short in if energy>absolute{sum+=energy;count+=1};if short>absolute{shortSum+=short;shortCount+=1}}
        let threshold=count>0 ? max(absolute,sum/Double(count)/10):absolute
        let shortThreshold=shortCount>0 ? max(absolute,shortSum/Double(shortCount)/100):absolute
        var included:UInt64=0,includedShort:UInt64=0;sum=0
        try scan {energy,short in if energy>threshold{sum+=energy;included+=1};if short>shortThreshold{includedShort+=1}}
        var range:Double?
        if includedShort>0 {
            let positions=[0.10,0.95].map{max(0,min(Double(includedShort-1),Double(includedShort)*$0-0.5))}
            let ranks=positions.flatMap{[UInt64(floor($0)),UInt64(ceil($0))]}
            let values=try orderStatistics(ranks,threshold:shortThreshold)
            let levels=values.map{DolbyELoudnessMeter.loudness(energy:$0)!}
            range=(levels[2]+(levels[3]-levels[2])*(positions[1]-floor(positions[1])))-(levels[0]+(levels[1]-levels[0])*(positions[0]-floor(positions[0])))
        }
        return .init(sampleFrames:meter.samplePosition,integratedLUFS:included>0 ? DolbyELoudnessMeter.loudness(energy:sum/Double(included)):nil,maximumMomentaryLUFS:meter.maximumMomentaryLUFS,maximumShortTermLUFS:meter.maximumShortTermLUFS,loudnessRangeLU:range,truePeakDBTP:meter.truePeakDBTP,gatingBlocks:records,includedGatingBlocks:included)
    }
    /// Positive finiteDouble bit patterns have numeric sort order. Eight radix
    /// scans select the four interpolation endpoints exactly in bounded memory.
    private func orderStatistics(_ ranks:[UInt64],threshold:Double)throws->[Double] {
        var prefix=Array(repeating:UInt64(0),count:ranks.count),remaining=ranks
        for byte in 0..<8 {
            let shift=(7-byte)*8,mask:UInt64=byte==0 ? 0 : UInt64.max << (64-byte*8)
            var counts=Array(repeating:Array(repeating:UInt64(0),count:256),count:ranks.count)
            try scan {_,energy in
                if energy>threshold {let bits=energy.bitPattern;for i in ranks.indices where bits&mask==prefix[i] {counts[i][Int((bits>>shift)&255)]+=1}}
            }
            for i in ranks.indices {
                var selected=0
                while selected<256 && remaining[i]>=counts[i][selected] {remaining[i]-=counts[i][selected];selected+=1}
                guard selected<256 else{throw DolbyEError.malformed("loudness percentile rank")}
                prefix[i]|=UInt64(selected)<<shift
            }
        }
        return prefix.map{Double(bitPattern:$0)}
    }
}
