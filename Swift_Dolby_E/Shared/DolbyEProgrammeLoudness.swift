// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public enum DolbyELoudnessPayloadVersion: Int,Codable,Sendable {case legacy0=0,standard1=1}
public enum DolbyELoudnessPractice: Int,Codable,Sendable {
    case unspecified=0,atsc=1,ebu=2,arib=3,freeTV=4,manual=14,consumer=15
}
public enum DolbyELoudnessCorrection: Int,Codable,Sendable {case fileBased=0,realTime=1}

/// Payload1programme loudness. Legacy0uses the observed basic-field profile;
/// standard1implements TS102366AnnexH including high-resolution and extended
/// fields. Absence is nil, never a fabricated0LUFS or a signed sentinel value.
public struct DolbyEProgrammeLoudness: Codable,Sendable,Equatable {
    public var version: DolbyELoudnessPayloadVersion
    public var dialogueChannels: Int?
    public var practice: DolbyELoudnessPractice = .unspecified
    public var dialogueGatedCorrection = false
    public var correction: DolbyELoudnessCorrection = .fileBased
    public var integratedLUFS: Double?
    public var speechGatedLUFS: Double?
    public var shortTermLUFS: Double?
    /// Peak since the preceding interval-peak payload; not a static programme max.
    public var intervalTruePeakDBTP: Double?
    public var downmixOffsetLU: Double?
    public var boundary: Boundary?
    public var correctionGatingMethod: Int = 0
    public var measurementGatingMethod: Int = 0
    public var maximumShortTermLUFS: Double?
    public var maximumTruePeakDBTP: Double?
    public var loudnessRangeLU: Double?
    public var loudnessRangePractice: Int = 0
    public var momentaryLUFS: Double?
    public var maximumMomentaryLUFS: Double?
    public struct Boundary: Codable,Sendable,Equatable {
        /// Number of codec syncframes, a power of2from2to512. No assumption
        /// that an ED2frame has the AC3frame's sample duration is introduced.
        public var frames: Int
        public var next: Bool
        public var sampleOffset: Int?
        public init(frames:Int,next:Bool,sampleOffset:Int?=nil){self.frames=frames;self.next=next;self.sampleOffset=sampleOffset}
    }
    public init(version:DolbyELoudnessPayloadVersion = .standard1){self.version=version}

    public func validate() throws {
        guard practice != .unspecified || (!dialogueGatedCorrection && correction == .fileBased),dialogueGatedCorrection || correctionGatingMethod==0,speechGatedLUFS != nil || measurementGatingMethod==0 else{throw DolbyEError.invalidArgument("loudness control field has no declaring presence condition")}
        guard dialogueChannels == nil || (0...7).contains(dialogueChannels!),[integratedLUFS,speechGatedLUFS,shortTermLUFS,intervalTruePeakDBTP,downmixOffsetLU,maximumShortTermLUFS,maximumTruePeakDBTP,loudnessRangeLU,momentaryLUFS,maximumMomentaryLUFS].compactMap({$0}).allSatisfy(\.isFinite),
              (0...3).contains(correctionGatingMethod),(0...3).contains(measurementGatingMethod),(0...1).contains(loudnessRangePractice),
              downmixOffsetLU == nil || (-7.5...7.5).contains(downmixOffsetLU!),loudnessRangeLU == nil || (0...102.3).contains(loudnessRangeLU!) else{throw DolbyEError.invalidArgument("programme loudness fields")}
        if let boundary {guard (2...512).contains(boundary.frames),boundary.frames.nonzeroBitCount==1,boundary.sampleOffset == nil || (0...2047).contains(boundary.sampleOffset!) else{throw DolbyEError.invalidArgument("programme loudness boundary")}}
        if version == .legacy0 {
            guard [maximumShortTermLUFS,maximumTruePeakDBTP,loudnessRangeLU,momentaryLUFS,maximumMomentaryLUFS].allSatisfy({$0==nil}),correctionGatingMethod==0,measurementGatingMethod==0,loudnessRangePractice==0 else {throw DolbyEError.unsupported("legacy0has no qualified extended loudness fields")}
        }
    }
    public func encoded() throws->Data {
        try validate();var bits=LoudnessBits()
        try bits.put(version.rawValue,2);try bits.flag(dialogueChannels != nil);if let dialogueChannels {try bits.put(dialogueChannels,3)}
        try bits.put(practice.rawValue,4)
        if practice != .unspecified {try bits.flag(dialogueGatedCorrection);try bits.put(correction.rawValue,1)}
        let values=[integratedLUFS,speechGatedLUFS,shortTermLUFS,intervalTruePeakDBTP]
        let widths=[7,7,8,8],offsets=[58.0,58,116,116]
        var coarse:[Double?]=[]
        for i in 0..<4 {
            let v=values[i],maximum=Double((1<<widths[i])-1)/2-offsets[i]
            let present=v.map{(-offsets[i]...maximum).contains($0)} ?? false
            if v != nil,!present,version == .legacy0 {throw DolbyEError.invalidArgument("legacy loudness value exceeds base range")}
            try bits.flag(present)
            if present,let v {let code=Int(((v+offsets[i])*2).rounded());try bits.put(code,widths[i]);coarse.append(Double(code)/2-offsets[i])}else{coarse.append(nil)}
        }
        try bits.flag(downmixOffsetLU != nil);if let value=downmixOffsetLU{try bits.put(Int(((value+7.5)*2).rounded()),5)}
        try bits.flag(boundary != nil)
        if let boundary {
            let power=boundary.frames.trailingZeroBitCount
            for _ in 1..<power {try bits.flag(false)};try bits.flag(true);try bits.flag(boundary.next)
            try bits.flag(boundary.sampleOffset != nil);if let offset=boundary.sampleOffset{try bits.put(offset,11)}
        }
        try bits.align()
        if version == .standard1 {
            for i in 0..<4 where coarse[i] != nil {
                let delta=Int(floor(values[i]!*10+0.5))-Int((coarse[i]!*10).rounded())
                try bits.flag(delta != 0)
                if delta != 0 {guard (-4...4).contains(delta) else{throw DolbyEError.invalidArgument("loudness fine precision")};try bits.put(delta<0 ? delta+4:delta+3,3)}
            }
            if dialogueGatedCorrection && practice != .unspecified {try bits.put(correctionGatingMethod,3)}
            for i in 0..<2 where coarse[i] == nil {try Self.extended(values[i],into:&bits)}
            if speechGatedLUFS != nil {try bits.put(measurementGatingMethod,3)}
            for i in 2..<4 where coarse[i] == nil {try Self.extended(values[i],into:&bits)}
            try Self.extended(maximumShortTermLUFS,into:&bits);try Self.extended(maximumTruePeakDBTP,into:&bits)
            try bits.flag(loudnessRangeLU != nil)
            if let range=loudnessRangeLU {try bits.put(Int((range*10).rounded()),10);try bits.put(loudnessRangePractice,3)}
            try Self.extended(momentaryLUFS,into:&bits);try Self.extended(maximumMomentaryLUFS,into:&bits)
            try bits.align()
        }
        return bits.data
    }
    private static func extended(_ value:Double?,into bits:inout LoudnessBits)throws {
        try bits.flag(value != nil)
        if let value {let code=Int(floor(value*10+0.5))+1024;guard (0...2047).contains(code) else{throw DolbyEError.invalidArgument("extended loudness value out of range")};try bits.put(code,11)}
    }
    public static func decode(_ data:Data)throws->Self {
        guard !data.isEmpty,data.count<=1024 else{throw DolbyEError.malformed("programme loudness payload size")}
        var bits=LoudnessBits(data:data)
        var version=try bits.take(2);if version==3{version+=try bits.take(4)}
        guard let kind=DolbyELoudnessPayloadVersion(rawValue:version) else{throw DolbyEError.unsupported("programme loudness version\(version)")}
        var value=Self(version:kind)
        if try bits.flag(){value.dialogueChannels=try bits.take(3)}
        guard let practice=DolbyELoudnessPractice(rawValue:try bits.take(4)) else{throw DolbyEError.malformed("reserved loudness practice")};value.practice=practice
        if practice != .unspecified {value.dialogueGatedCorrection=try bits.flag();value.correction=try bits.flag() ? .realTime:.fileBased}
        var fields:[Double?]=[],base:[Bool]=[]
        for (width,offset) in [(7,58.0),(7,58.0),(8,116.0),(8,116.0)] {
            let exists=try bits.flag();base.append(exists);fields.append(try exists ? Double(bits.take(width))/2-offset:nil)
        }
        if try bits.flag(){let code=try bits.take(5);value.downmixOffsetLU=code==31 ? 0:Double(code)/2-7.5}
        if try bits.flag() {
            var frames=1
            repeat {frames <<= 1;guard frames<=512 else{throw DolbyEError.malformed("loudness boundary unary length")}}while try !bits.flag()
            let next=try bits.flag(),offset=try bits.flag() ? bits.take(11):nil
            value.boundary = .init(frames:frames,next:next,sampleOffset:offset)
        }
        try bits.alignReading()
        if kind == .standard1 {
            for i in 0..<4 where base[i] {if try bits.flag(){let code=try bits.take(3);fields[i]! += Double(code<4 ? code-4:code-3)/10}}
            if value.dialogueGatedCorrection {value.correctionGatingMethod=try bits.take(3)}
            for i in 0..<2 where !base[i] {fields[i]=try Self.extended(from:&bits)}
            if fields[1] != nil{value.measurementGatingMethod=try bits.take(3)}
            for i in 2..<4 where !base[i]{fields[i]=try Self.extended(from:&bits)}
            value.maximumShortTermLUFS=try Self.extended(from:&bits);value.maximumTruePeakDBTP=try Self.extended(from:&bits)
            if try bits.flag(){value.loudnessRangeLU=Double(try bits.take(10))/10;value.loudnessRangePractice=try bits.take(3)}
            value.momentaryLUFS=try Self.extended(from:&bits);value.maximumMomentaryLUFS=try Self.extended(from:&bits)
            try bits.alignReading()
        }
        guard bits.position==data.count*8 else{throw DolbyEError.unsupported("unqualified trailing legacy/standard loudness syntax")}
        value.integratedLUFS=fields[0];value.speechGatedLUFS=fields[1];value.shortTermLUFS=fields[2];value.intervalTruePeakDBTP=fields[3]
        try value.validate();return value
    }
    private static func extended(from bits:inout LoudnessBits)throws->Double? {try bits.flag() ? Double(bits.take(11)-1024)/10:nil}
}

private struct LoudnessBits {
    var data=Data()
    var position=0
    mutating func put(_ value:Int,_ count:Int)throws {
        guard count>=0,count<=16,value>=0,value<(1<<count) else{throw DolbyEError.invalidArgument("loudness bit field range")}
        for index in (0..<count).reversed(){if position%8==0{data.append(0)};if value&(1<<index) != 0{data[position/8]|=1<<UInt8(7-position%8)};position+=1}
    }
    mutating func flag(_ value:Bool)throws{try put(value ? 1:0,1)}
    mutating func align()throws{while position%8 != 0 {try flag(false)}}
    mutating func take(_ count:Int)throws->Int {
        guard count>=0,count<=16,position+count<=data.count*8 else{throw DolbyEError.malformed("truncated loudness field at bit\(position)")}
        var value=0;for _ in 0..<count{value=value<<1|Int((data[position/8]>>UInt8(7-position%8))&1);position+=1};return value
    }
    mutating func flag()throws->Bool{try take(1) != 0}
    mutating func alignReading()throws{while position%8 != 0{guard try !flag() else{throw DolbyEError.malformed("nonzero loudness alignment")}}}
}

public struct DolbyED2LoudnessRecord: Sendable {
    public let codecSpecificID: Int?
    public let sampleOffset: Int?
    public let duration: Int?
    public let metadataGroupID: Int?
    public let frameAligned: Bool?
    public let processingAllowed: Int?
    public let value: DolbyEProgrammeLoudness
}

extension DolbyED2MetadataContainer {
    public func programmeLoudness() throws->[DolbyED2LoudnessRecord] {
        try payloads.filter{$0.id==1}.map{.init(codecSpecificID:$0.codecSpecificID,sampleOffset:$0.sampleOffset,duration:$0.duration,metadataGroupID:$0.groupID,frameAligned:$0.frameAligned,processingAllowed:$0.processingAllowed,value:try DolbyEProgrammeLoudness.decode($0.data))}
    }
}
