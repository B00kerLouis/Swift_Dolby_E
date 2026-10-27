// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import CryptoKit

/// Room coordinates use the ADM convention: +Y is front and +Z is above.
/// The legacy OAMD bitstream reverses Y; that conversion belongs at its boundary.
public struct DolbyED2Position: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double = 0, y: Double = 1, z: Double = 0) {
        self.x = x; self.y = y; self.z = z
    }
    func validate() throws {
        guard [x, y, z].allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw DolbyEError.invalidArgument("ED2 position is outside the normalized room")
        }
    }
}

public enum DolbyED2Speaker: String, Codable, Sendable, CaseIterable {
    case left = "L", right = "R", center = "C", lfe = "LFE"
    case leftSurround = "Ls", rightSurround = "Rs"
    case leftRear = "Lrs", rightRear = "Rrs"
    case leftHeightFront = "Ltf", rightHeightFront = "Rtf"
    case leftTopMiddle = "Ltm", rightTopMiddle = "Rtm"
    case leftHeightRear = "Ltr", rightHeightRear = "Rtr"
    case leftWide = "Lw", rightWide = "Rw", lfe2 = "LFE2"

    public static var fiveOneTwo: [Self] {
        [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .leftTopMiddle, .rightTopMiddle]
    }
    public static var fiveOne: [Self] { Array(fiveOneTwo.prefix(6)) }
}

public struct DolbyED2SourceMapping: Codable, Sendable, Equatable {
    public var substreamIndex: Int
    public var channelIndex: Int
    public init(substreamIndex: Int, channelIndex: Int) {
        self.substreamIndex = substreamIndex; self.channelIndex = channelIndex
    }
    func validate() throws {
        guard (0..<2).contains(substreamIndex), (0..<8).contains(channelIndex) else {
            throw DolbyEError.invalidArgument("ED2 source mapping exceeds two eight-channel substreams")
        }
    }
}

public struct DolbyED2ObjectState: Codable, Sendable, Equatable {
    public var sampleOffset: Int
    public var rampDuration: Int
    public var position: DolbyED2Position
    public var gain: Double
    public var active: Bool
    public var size: Double
    public var snap: Bool
    public init(sampleOffset: Int = 0, rampDuration: Int = 0, position: DolbyED2Position,
                gain: Double = 1, active: Bool = true, size: Double = 0, snap: Bool = false) {
        self.sampleOffset = sampleOffset; self.rampDuration = rampDuration; self.position = position
        self.gain = gain; self.active = active; self.size = size; self.snap = snap
    }
}

public struct DolbyED2ObjectAlternative: Codable, Sendable, Equatable {
    public var position: DolbyED2Position?
    public var gain: Double?
    public var headphoneRenderMode: Int?
    public var headphoneMetadataState: Bool?
    public var headphoneHeadTrackingState: Bool?
    public init(position: DolbyED2Position? = nil, gain: Double? = nil, headphoneRenderMode: Int? = nil,
                headphoneMetadataState: Bool? = nil, headphoneHeadTrackingState: Bool? = nil) {
        self.position = position; self.gain = gain; self.headphoneRenderMode = headphoneRenderMode
        self.headphoneMetadataState = headphoneMetadataState; self.headphoneHeadTrackingState = headphoneHeadTrackingState
    }
}

public struct DolbyED2ObjectMetadata: Codable, Sendable, Equatable {
    public var source: DolbyED2SourceMapping
    /// MGI sound category 1 identifies dialogue; 0 is a generic object.
    public var isDialogue: Bool
    public var states: [DolbyED2ObjectState]
    public var alternatives: [DolbyED2ObjectAlternative]
    public init(source: DolbyED2SourceMapping, isDialogue: Bool = false, states: [DolbyED2ObjectState],
                alternatives: [DolbyED2ObjectAlternative] = []) {
        self.source = source; self.isDialogue = isDialogue; self.states = states; self.alternatives = alternatives
    }
    public init(position: DolbyED2Position, substreamIndex: Int = 1, channelIndex: Int,
                gain: Double = 1, active: Bool = true, isDialogue: Bool = false) {
        self.init(source: DolbyED2SourceMapping(substreamIndex: substreamIndex, channelIndex: channelIndex),
            isDialogue: isDialogue, states: [.init(position: position, gain: gain, active: active)])
    }
    public var position: DolbyED2Position { states.first?.position ?? DolbyED2Position() }
    public var gain: Double { states.first?.gain ?? 0 }
}

public struct DolbyED2BedMetadata: Codable, Sendable, Equatable {
    public var channels: [DolbyED2Speaker]
    public var source: DolbyED2SourceMapping
    public var gains: [Double]
    public var alternativeGains: [Double?]
    public init(channels: [DolbyED2Speaker] = DolbyED2Speaker.fiveOneTwo,
                source: DolbyED2SourceMapping = .init(substreamIndex: 0, channelIndex: 0),
                gains: [Double]? = nil, alternativeGains: [Double?] = []) {
        self.channels = channels; self.source = source
        self.gains = gains ?? Array(repeating: 1, count: channels.count)
        self.alternativeGains = alternativeGains
    }
}

public struct DolbyED2PresentationTarget: Codable, Sendable, Equatable {
    /// Bit mask: 1 Stereo, 2 Surround, 4 Immersive.
    public var deviceMask: Int
    /// -1 disables an element; 0 chooses its base OAMD, positive values choose MGI alternates.
    public var objectMetadataIndices: [Int]
    public var bedMetadataIndices: [Int]
    public init(deviceMask: Int, objectMetadataIndices: [Int], bedMetadataIndices: [Int]) {
        self.deviceMask = deviceMask; self.objectMetadataIndices = objectMetadataIndices
        self.bedMetadataIndices = bedMetadataIndices
    }
}

public struct DolbyED2PresentationMetadata: Codable, Sendable, Equatable {
    public var defaultDeviceMask: Int
    public var targets: [DolbyED2PresentationTarget]
    public init(defaultDeviceMask: Int = 4, targets: [DolbyED2PresentationTarget]) {
        self.defaultDeviceMask = defaultDeviceMask; self.targets = targets
    }
}

public struct DolbyED2SceneMetadata: Codable, Sendable, Equatable {
    public var programID: UInt16
    public var beds: [DolbyED2BedMetadata]
    public var objects: [DolbyED2ObjectMetadata]
    public var presentations: [DolbyED2PresentationMetadata]
    public init(programID: UInt16 = 1, beds: [DolbyED2BedMetadata] = [.init()],
                objects: [DolbyED2ObjectMetadata], presentations: [DolbyED2PresentationMetadata]? = nil) {
        self.programID = programID; self.beds = beds; self.objects = objects
        self.presentations = presentations ?? [.init(targets: [1, 2, 4].map {
            .init(deviceMask: $0, objectMetadataIndices: Array(repeating: 0, count: objects.count),
                bedMetadataIndices: Array(repeating: 0, count: beds.count))
        })]
    }
    public func validate() throws {
        let channels = beds.reduce(0) { $0 + $1.channels.count } + objects.count
        guard channels > 0, channels <= 16, !presentations.isEmpty, presentations.count <= 16 else {
            throw DolbyEError.invalidArgument("ED2 scene exceeds the sixteen-element transport or presentation limit")
        }
        for bed in beds {
            try bed.source.validate()
            guard !bed.channels.isEmpty, Set(bed.channels).count == bed.channels.count,
                  bed.gains.count == bed.channels.count, bed.gains.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  bed.source.channelIndex + bed.channels.count <= 8 else {
                throw DolbyEError.invalidArgument("ED2 bed must fit its declared substream")
            }
        }
        for object in objects {
            try object.source.validate()
            guard !object.states.isEmpty, object.states.count <= 8 else { throw DolbyEError.invalidArgument("ED2 object update count") }
            for (index, state) in object.states.enumerated() {
                try state.position.validate()
                guard (0...2047).contains(state.sampleOffset), (0...2048).contains(state.rampDuration),
                      state.gain.isFinite, state.gain >= 0, (0...1).contains(state.size),
                      index == 0 || object.states[index - 1].sampleOffset < state.sampleOffset else {
                    throw DolbyEError.invalidArgument("ED2 object state fields")
                }
            }
            guard object.alternatives.count <= 16 else { throw DolbyEError.invalidArgument("ED2 object alternative count") }
            for alternate in object.alternatives {
                try alternate.position?.validate()
                guard alternate.gain == nil || (alternate.gain!.isFinite && alternate.gain! >= 0),
                      alternate.headphoneRenderMode == nil || (0...3).contains(alternate.headphoneRenderMode!) else {
                    throw DolbyEError.invalidArgument("ED2 alternative metadata")
                }
            }
        }
        for presentation in presentations {
            guard (0...7).contains(presentation.defaultDeviceMask), !presentation.targets.isEmpty,
                  presentation.targets.count <= 8 else { throw DolbyEError.invalidArgument("ED2 presentation target count") }
            for target in presentation.targets {
                guard (1...7).contains(target.deviceMask), target.objectMetadataIndices.count == objects.count,
                      target.bedMetadataIndices.count == beds.count,
                      target.objectMetadataIndices.allSatisfy({ $0 >= -1 }), target.bedMetadataIndices.allSatisfy({ $0 >= -1 }) else {
                    throw DolbyEError.invalidArgument("ED2 presentation element selection")
                }
                guard target.objectMetadataIndices.enumerated().allSatisfy({ $0.element <= objects[$0.offset].alternatives.count }),
                      target.bedMetadataIndices.enumerated().allSatisfy({ $0.element <= beds[$0.offset].alternativeGains.count }) else {
                    throw DolbyEError.invalidArgument("ED2 presentation references unavailable alternative metadata")
                }
            }
        }
    }

    /// Resolves MGI alternatives before rendering. Positive indices select an
    /// alternate as an override of the base state, not as another audio source.
    public func resolved(presentation: Int = 0, deviceMask: Int = 4) throws -> Self {
        guard presentations.indices.contains(presentation), (1...7).contains(deviceMask),
              let target = presentations[presentation].targets.first(where: { $0.deviceMask & deviceMask != 0 }) else {
            throw DolbyEError.invalidArgument("ED2 presentation does not provide the requested rendering target")
        }
        try validate()
        var result = self
        for index in objects.indices {
            let selection = target.objectMetadataIndices[index]
            for block in result.objects[index].states.indices {
                if selection == -1 { result.objects[index].states[block].active = false; result.objects[index].states[block].gain = 0 }
                else if selection > 0 {
                    let alternate = objects[index].alternatives[selection - 1]
                    if let point = alternate.position { result.objects[index].states[block].position = point }
                    if let gain = alternate.gain { result.objects[index].states[block].gain = gain }
                }
            }
        }
        for index in beds.indices {
            let selection = target.bedMetadataIndices[index]
            if selection == -1 { result.beds[index].gains = Array(repeating: 0, count: beds[index].channels.count) }
            else if selection > 0, let gain = beds[index].alternativeGains[selection - 1] {
                result.beds[index].gains = Array(repeating: gain, count: beds[index].channels.count)
            }
        }
        return result
    }
}

/// Legacy Evolution/EMDF metadata, including the original bytes needed for
/// independent signature verification. CRC validity and authentication validity
/// are deliberately separate: the former never establishes the latter.
public struct DolbyED2MetadataContainer: Sendable {
    public struct Payload: Sendable, Equatable {
        public let id: Int
        public let data: Data
        public let sampleOffset: Int?
        public let duration: Int?
        public let codecSpecificID: Int?
        public let discardUnknown: Bool
        public let groupID: Int?
        public let frameAligned: Bool?
        public let createDuplicate: Bool?
        public let removeDuplicate: Bool?
        public let priority: Int?
        public let processingAllowed: Int?
    }
    public let keyID: Int
    public let payloads: [Payload]
    public let rawPacket: Data
    public let emdfBytes: Data
    public let canonicalEMDF: Data
    public let primaryProtection: Data
    public let secondaryProtection: Data
    public let primaryBitOffset: Int
    /// Bytes after the CRC-protected wrapper, preserved exactly as transported.
    /// They are outside EMDF authentication. The final byte can be partial;
    /// trailingBitCount distinguishes it from complete advertised bytes.
    public let trailingData: Data
    public let trailingBitCount: Int
    public let crcVerified: Bool
    public let authenticationVerified: Bool

    public static func parse(words: [UInt32], validBitCount: Int? = nil) throws -> Self {
        guard !words.isEmpty, words.count <= 4095, words.allSatisfy({ $0 & 0xfff == 0 }) else {
            throw DolbyEError.malformed("unaligned or oversized ED2 metadata words")
        }
        guard validBitCount == nil || (validBitCount! > 0 && validBitCount! <= words.count * 20) else {
            throw DolbyEError.malformed("ED2 advertised metadata length exceeds carrier words")
        }
        var writer = ED2BitWriter()
        for word in words { try writer.append(Int(word >> 12), bits: 20) }
        return try parse(bytes: writer.data, validBitCount: validBitCount ?? words.count * 20)
    }

    public static func parse(bytes: Data, validBitCount: Int? = nil) throws -> Self {
        guard bytes.count >= 10, bytes.count <= 16384 else { throw DolbyEError.malformed("ED2 metadata packet size") }
        let bitCount = validBitCount ?? bytes.count * 8
        guard bitCount > 0, bitCount <= bytes.count * 8 else { throw DolbyEError.malformed("ED2 advertised metadata bit count") }
        let encoded = Array(bytes)
        var raw = encoded
        guard raw[0] == 0x58, raw[1] == 0x38, raw[2] & 0xe0 == 0 else {
            throw DolbyEError.malformed("ED2 Evolution marker or reserved bits")
        }
        let escaped = raw[2] & 0x10 != 0, code = Int(raw[2] & 15) << 8 | Int(raw[3])
        if escaped { raw = unescaped(raw, code: code) }
        guard raw[4] == 0xbb else { throw DolbyEError.unsupported("ED2 guard-band element ID \(raw[4])") }
        let length = Int(raw[5]) << 8 | Int(raw[6])
        guard length > 0, length <= raw.count - 9, (9 + length) * 8 <= bitCount else { throw DolbyEError.malformed("ED2 EMDF length exceeds packet") }
        let end = 9 + length
        guard crc16(Array(raw[4..<end])) == 0 else { throw DolbyEError.malformed("ED2 metadata CRC") }
        let data = Data(raw[7..<(7 + length)])
        var bits = ED2BitReader(data: data)
        var version = try bits.take(2)
        if version == 3 { version += try bits.variable(2) }
        guard version == 0 else { throw DolbyEError.unsupported("EMDF version \(version)") }
        var key = try bits.take(3)
        if key == 7 { key += try bits.variable(3) }
        var payloads: [Payload] = []
        while true {
            var id = try bits.take(5)
            if id == 31 { id += try bits.variable(5) }
            if id == 0 { break }
            guard payloads.count < 32 else { throw DolbyEError.malformed("excessive EMDF payload count") }
            let sampleOffset = try bits.flag() ? bits.variable(11) : nil
            let duration = try bits.flag() ? bits.variable(11) : nil
            let group = try bits.flag() ? bits.variable(2) : nil
            let codec = try bits.flag() ? bits.take(8) : nil
            let discard = try bits.flag()
            var frameAligned:Bool?,createDuplicate:Bool?,removeDuplicate:Bool?,priority:Int?,processingAllowed:Int?
            if !discard {
                var aligned = false
                if sampleOffset == nil {
                    aligned = try bits.flag()
                    frameAligned=aligned
                    if aligned {createDuplicate=try bits.flag();removeDuplicate=try bits.flag()}
                }
                if sampleOffset != nil || aligned {priority=try bits.take(5);processingAllowed=try bits.take(2)}
            }
            let count = try bits.variable(8)
            let payload = try bits.octets(count)
            payloads.append(Payload(id: id, data: payload, sampleOffset: sampleOffset,
                duration: duration, codecSpecificID: codec, discardUnknown: discard,groupID:group,frameAligned:frameAligned,createDuplicate:createDuplicate,removeDuplicate:removeDuplicate,priority:priority,processingAllowed:processingAllowed))
        }
        let lengths = [0, 1, 4, 16]
        let primarySize = lengths[try bits.take(2)], secondarySize = lengths[try bits.take(2)]
        guard primarySize > 0 else { throw DolbyEError.malformed("EMDF requires primary protection") }
        let protectionAt = bits.position
        let primary = try bits.octets(primarySize), secondary = try bits.octets(secondarySize)
        try bits.zeroPadding()
        var canonical = Array(data)
        for bit in protectionAt..<(protectionAt + (primarySize + secondarySize) * 8) {
            canonical[bit / 8] &= ~UInt8(1 << (7 - bit % 8))
        }
        return Self(keyID: key, payloads: payloads, rawPacket: Data(encoded.prefix(end)), emdfBytes: data,
            canonicalEMDF: Data(canonical), primaryProtection: primary, secondaryProtection: secondary,
            primaryBitOffset: protectionAt, trailingData: Data(encoded[end..<((bitCount + 7) / 8)]),
            trailingBitCount: bitCount - end * 8, crcVerified: true, authenticationVerified: false)
    }

    /// Only a verifier that has the correct key and codec/history inputs can
    /// upgrade this result. Unsupported authentication must remain explicit.
    public func verifying(_ verifier: (Self) throws -> Bool) throws -> Self {
        guard try verifier(self) else { throw DolbyEError.malformed("ED2 EMDF authentication mismatch") }
        return Self(keyID: keyID, payloads: payloads, rawPacket: rawPacket, emdfBytes: emdfBytes,
            canonicalEMDF: canonicalEMDF, primaryProtection: primaryProtection, secondaryProtection: secondaryProtection,
            primaryBitOffset: primaryBitOffset, trailingData: trailingData, trailingBitCount: trailingBitCount,
            crcVerified: crcVerified, authenticationVerified: true)
    }

    /// The reference ED2 profile signs the complete Dolby E core in left-aligned
    /// UInt32 little-endian form, then the canonical unescaped EMDF container.
    /// Secondary protection authenticates the complete primary digest, not its
    /// four transmitted octets. No cross-frame signing state is used by this profile.
    public func verifying(coreWords: [UInt32]) throws -> Self {
        guard keyID == 1, primaryProtection.count == 4, secondaryProtection.count == 4 else {
            throw DolbyEError.unsupported("ED2 authentication key or protection profile")
        }
        return try verifying { value in
            let signed = try Self.protection(coreWords: coreWords, emdf: value.canonicalEMDF)
            return value.primaryProtection == signed.primary && value.secondaryProtection == signed.secondary
        }
    }

    public static func encodeLegacy(scene: DolbyED2SceneMetadata?, coreWords: [UInt32]) throws -> [UInt32] {
        try encodeLegacy(scene: scene, keyID: 1) { canonical in
            try protection(coreWords: coreWords, emdf: canonical)
        }
    }

    /// Generates the two-substream profile. Each substream has its own signed
    /// audio core. Topology and object updates belong to substream zero; the
    /// second substream carries its own duration/loudness metadata and signature.
    /// A zero loudness payload explicitly leaves measurements/correction absent.
    public static func encode(scene: DolbyED2SceneMetadata, duration: Int, substreamIndex: Int,
                              coreWords: [UInt32],programmeLoudness: DolbyEProgrammeLoudness? = nil) throws -> [UInt32] {
        guard (0..<2).contains(substreamIndex), (1...2047).contains(duration) else {
            throw DolbyEError.invalidArgument("ED2 substream index or frame duration")
        }
        try scene.validate()
        return try encodePacket(scene: substreamIndex == 0 ? scene : nil, duration: duration, keyID: 1,programmeLoudness:programmeLoudness) { canonical in
            try protection(coreWords: coreWords, emdf: canonical)
        }
    }

    /// Computes the exact transport reservation without fabricating signatures.
    /// Authentication and nibble escaping preserve the canonical packet length.
    public static func encodedWordCount(scene: DolbyED2SceneMetadata, duration: Int,
                                        substreamIndex: Int,programmeLoudness: DolbyEProgrammeLoudness? = nil) throws -> Int {
        guard (0..<2).contains(substreamIndex), (1...2047).contains(duration) else {
            throw DolbyEError.invalidArgument("ED2 substream index or frame duration")
        }
        try scene.validate()
        let canonical = try canonicalPacket(scene: substreamIndex == 0 ? scene : nil, duration: duration, keyID: 1,programmeLoudness:programmeLoudness)
        return ((canonical.data.count + 9) * 8 + 19) / 20
    }

    private static func protection(coreWords: [UInt32], emdf: Data) throws -> (primary: Data, secondary: Data) {
        guard !coreWords.isEmpty, coreWords.count <= 4095, coreWords.allSatisfy({ $0 & 0xfff == 0 }) else {
            throw DolbyEError.invalidArgument("ED2 authentication requires aligned Dolby E core words")
        }
        let key = SymmetricKey(data: Data([UInt8](arrayLiteral:
            0x1e, 0xe9, 0x68, 0x14, 0x33, 0x26, 0x1e, 0x2e, 0xc0, 0x73, 0xde, 0xd6, 0x55, 0xcc, 0x0c, 0x4f,
            0x00, 0x61, 0xa4, 0xd6, 0x0e, 0x07, 0x01, 0x37, 0x86, 0x93, 0x48, 0x2c, 0x72, 0xf1, 0xe4, 0x08)))
        var input = Data(capacity: coreWords.count * 4 + emdf.count)
        for word in coreWords {
            input.append(UInt8(truncatingIfNeeded: word)); input.append(UInt8(truncatingIfNeeded: word >> 8))
            input.append(UInt8(truncatingIfNeeded: word >> 16)); input.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        input.append(emdf)
        let primary = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
        let secondary = Data(HMAC<SHA256>.authenticationCode(for: primary, using: key))
        return (Data(primary.prefix(4)), Data(secondary.prefix(4)))
    }

    public func scene() throws -> DolbyED2SceneMetadata? {
        let objects = payloads.filter { $0.id == 11 }, graphs = payloads.filter { $0.id == 13 }
        guard !objects.isEmpty || !graphs.isEmpty else { return nil }
        guard objects.count == 1, graphs.count == 1 else { throw DolbyEError.unsupported("ED2 requires one complete OAMD/MGI scene per frame") }
        let oamd = try ED2ObjectAudio.parse(objects[0].data)
        return try ED2MixGraph.parse(graphs[0].data, audio: oamd)
    }

    /// Rebuilds a packet only after a caller supplies actual protection values.
    /// The signer receives canonical EMDF bytes with both protection fields zero.
    private static func encodeLegacy(scene: DolbyED2SceneMetadata?, keyID: Int = 1,
        signer: (Data) throws -> (primary: Data, secondary: Data)) throws -> [UInt32] {
        try encodePacket(scene: scene, duration: nil, keyID: keyID, signer: signer)
    }

    private static func canonicalPacket(scene: DolbyED2SceneMetadata?, duration: Int?, keyID: Int,programmeLoudness: DolbyEProgrammeLoudness? = nil) throws -> (data: Data, at: Int) {
        guard (0..<7).contains(keyID) else { throw DolbyEError.invalidArgument("legacy ED2 key ID") }
        var payloads: [(Int, Data)] = []
        if let scene {
            try scene.validate()
            payloads = [(11, try ED2ObjectAudio.encode(scene)), (13, try ED2MixGraph.encode(scene))]
        }
        var bits = ED2BitWriter()
        try bits.append(0, bits: 2); try bits.append(keyID, bits: 3)
        if let duration {
            for codecID in [1, 254] {
                let body: Data
                if let programmeLoudness {
                    // The reference distinguishes the programme record from
                    // the separate compatibility record. Do not assign a
                    // rendered Main measurement to unrelated mono signals.
                    body = try (codecID == 1 ? programmeLoudness:DolbyEProgrammeLoudness(version:programmeLoudness.version)).encoded()
                }else{body=Data([0,0])}
                try bits.append(1, bits: 5)
                try bits.append(1, bits: 1); try bits.variable(0, width: 11)
                try bits.append(1, bits: 1); try bits.variable(duration, width: 11)
                try bits.append(0, bits: 1); try bits.append(1, bits: 1); try bits.append(codecID, bits: 8)
                try bits.append(0, bits: 1); try bits.append(0, bits: 5); try bits.append(1, bits: 2)
                try bits.variable(body.count, width: 8); try bits.octets(body)
            }
        }
        for (id, data) in payloads {
            try bits.append(id, bits: 5)
            try bits.append(0, bits: 3) // sample offset, duration and group ID are absent
            try bits.append(1, bits: 1); try bits.append(1, bits: 8) // ED2-specific payload
            try bits.append(0, bits: 1); try bits.append(0, bits: 1) // mandatory, not frame-aligned
            try bits.variable(data.count, width: 8); try bits.octets(data)
        }
        try bits.append(0, bits: 5)
        try bits.append(2, bits: 2); try bits.append(2, bits: 2)
        let at = bits.position
        try bits.append(0, bits: 32); try bits.append(0, bits: 32); try bits.align()
        return (bits.data, at)
    }

    private static func encodePacket(scene: DolbyED2SceneMetadata?, duration: Int?, keyID: Int,programmeLoudness: DolbyEProgrammeLoudness? = nil,
        signer: (Data) throws -> (primary: Data, secondary: Data)) throws -> [UInt32] {
        let canonical = try canonicalPacket(scene: scene, duration: duration, keyID: keyID,programmeLoudness:programmeLoudness)
        var emdf = Array(canonical.data)
        let at = canonical.at
        let protection = try signer(Data(emdf))
        guard protection.primary.count == 4, protection.secondary.count == 4 else {
            throw DolbyEError.invalidArgument("legacy ED2 signer must return two 32-bit protection values")
        }
        for (offset, byte) in (protection.primary + protection.secondary).enumerated() {
            for bit in 0..<8 where byte & (1 << (7 - bit)) != 0 {
                let index = at + offset * 8 + bit
                emdf[index / 8] |= 1 << (7 - index % 8)
            }
        }
        guard emdf.count <= 4096 else { throw DolbyEError.invalidArgument("ED2 metadata exceeds bounded frame capacity") }
        var body = [UInt8(0xbb), UInt8(emdf.count >> 8), UInt8(emdf.count & 255)] + emdf
        let crc = crc16(body)
        body += [UInt8(crc >> 8), UInt8(crc & 255)]
        var packet: [UInt8]?
        for code in stride(from: 0xffe, through: 1, by: -1) where code != 0x078 {
            let candidate = escaped(body, code: code)
            let wrapped = [UInt8(0x58), 0x38, 0x10 | UInt8(code >> 8), UInt8(code & 255)] + candidate
            if Array(unescaped(wrapped, code: code).dropFirst(4)) == body { packet = wrapped; break }
        }
        guard let packet else { throw DolbyEError.malformed("no reversible ED2 escape code available") }
        var output = ED2BitReader(data: Data(packet))
        var words: [UInt32] = []
        while output.remaining > 0 {
            let count = min(20, output.remaining)
            words.append(UInt32(try output.take(count)) << (32 - count))
        }
        return words
    }

    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var value: UInt16 = 0
        for byte in bytes {
            value ^= UInt16(byte) << 8
            for _ in 0..<8 { value = value & 0x8000 != 0 ? (value &<< 1) ^ 0x8005 : value &<< 1 }
        }
        return value
    }
    private static func unescaped(_ source: [UInt8], code: Int) -> [UInt8] {
        var result = source
        guard result.count > 5 else { return result }
        for index in 4..<(result.count - 1) {
            if Int(result[index]) << 4 | Int(result[index + 1] >> 4) == code {
                result[index] = 7; result[index + 1] = result[index + 1] & 15 | 0x80
            }
            if Int(result[index] & 15) << 8 | Int(result[index + 1]) == code {
                result[index] &= 0xf0; result[index + 1] = 0x78
            }
        }
        return result
    }
    private static func escaped(_ source: [UInt8], code: Int) -> [UInt8] {
        var nibbles = source.flatMap { [$0 >> 4, $0 & 15] }
        guard nibbles.count >= 3 else { return source }
        for index in 0..<(nibbles.count - 2) {
            if nibbles[index] == 0, nibbles[index + 1] == 7, nibbles[index + 2] == 8 {
                nibbles[index] = UInt8(code >> 8); nibbles[index + 1] = UInt8((code >> 4) & 15)
                nibbles[index + 2] = UInt8(code & 15)
            }
        }
        return stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] }
    }
}

private struct ED2BitReader {
    let data: [UInt8]
    var position = 0
    var end: Int
    var remaining: Int { end - position }
    init(data: Data) { self.data = Array(data); self.end = data.count * 8 }
    mutating func take(_ count: Int) throws -> Int {
        guard (0...32).contains(count), count <= remaining else { throw DolbyEError.malformed("truncated ED2 field at bit \(position)") }
        var result = 0
        for _ in 0..<count { result = result << 1 | Int((data[position / 8] >> (7 - position % 8)) & 1); position += 1 }
        return result
    }
    mutating func flag() throws -> Bool { try take(1) != 0 }
    mutating func variable(_ width: Int) throws -> Int {
        guard (1...11).contains(width) else { throw DolbyEError.malformed("invalid ED2 variable integer width") }
        var result = 0
        for _ in 0..<5 {
            let value = try take(width)
            guard result <= (Int.max - value) else { throw DolbyEError.malformed("ED2 variable integer overflow") }
            result += value
            if try !flag() { return result }
            guard result < (1 << (30 - width)) else { throw DolbyEError.malformed("oversized ED2 variable integer") }
            result = (result + 1) << width
        }
        throw DolbyEError.malformed("unterminated ED2 variable integer")
    }
    mutating func octets(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining / 8 else { throw DolbyEError.malformed("ED2 payload length exceeds packet") }
        return Data(try (0..<count).map { _ in UInt8(try take(8)) })
    }
    mutating func bounded(_ count: Int) throws -> Self {
        guard count >= 0, count <= remaining else { throw DolbyEError.malformed("ED2 sub-element length exceeds payload") }
        var result = self; result.end = position + count; position += count; return result
    }
    mutating func align(relativeTo start: Int = 0) throws {
        let count = (8 - (position - start) % 8) % 8
        guard try take(count) == 0 else { throw DolbyEError.malformed("nonzero ED2 byte alignment") }
    }
    mutating func skip(_ count: Int) throws { _ = try bounded(count) }
    mutating func zeroPadding() throws {
        guard remaining < 8 else { throw DolbyEError.malformed("unconsumed ED2 payload bytes") }
        guard try take(remaining) == 0 else { throw DolbyEError.malformed("nonzero ED2 trailing padding") }
    }
}

private struct ED2BitWriter {
    private var bytes: [UInt8] = []
    private(set) var position = 0
    var data: Data { Data(bytes) }
    mutating func append(_ value: Int, bits: Int) throws {
        guard (0...32).contains(bits), value >= 0, bits == 32 || value < (1 << bits), position <= 131072 - bits else {
            throw DolbyEError.invalidArgument("ED2 bit field exceeds width or packet bound")
        }
        for offset in 0..<bits {
            if position % 8 == 0 { bytes.append(0) }
            if (value >> (bits - 1 - offset)) & 1 != 0 { bytes[position / 8] |= 1 << (7 - position % 8) }
            position += 1
        }
    }
    mutating func variable(_ value: Int, width: Int) throws {
        guard value >= 0, value <= 1 << 30 else { throw DolbyEError.invalidArgument("ED2 variable integer range") }
        var groups: [Int] = [], remaining = value
        let mask = (1 << width) - 1
        repeat {
            groups.append(remaining & mask)
            remaining = (remaining >> width) - 1
        } while remaining >= 0
        for index in groups.indices.reversed() {
            try append(groups[index], bits: width); try append(index == 0 ? 0 : 1, bits: 1)
        }
    }
    mutating func octets(_ value: Data) throws { for byte in value { try append(Int(byte), bits: 8) } }
    mutating func align() throws { try append(0, bits: (8 - position % 8) % 8) }
}

struct ED2ObjectAudio {
    var beds: [[DolbyED2Speaker]]
    var states: [[DolbyED2ObjectState]]
    var dynamicCount: Int

    static let groups: [[DolbyED2Speaker]] = [
        [.left, .right], [.center], [.lfe], [.leftSurround, .rightSurround], [.leftRear, .rightRear],
        [.leftHeightFront, .rightHeightFront], [.leftTopMiddle, .rightTopMiddle],
        [.leftHeightRear, .rightHeightRear], [.leftWide, .rightWide], [.lfe2]
    ]
    static let ramps = [32, 64, 128, 256, 320, 480, 1000, 1001, 1024, 1600, 1601, 1602, 1920, 2000, 2002, 2048]

    static func parse(_ data: Data) throws -> Self {
        var bits = ED2BitReader(data: data)
        var version = try bits.take(2)
        if version == 3 { version += try bits.take(3) }
        guard version == 0 else { throw DolbyEError.unsupported("ED2 OAMD version \(version)") }
        var total = try bits.take(5)
        if total == 31 { total += try bits.take(7) }
        total += 1
        guard total <= 16 else { throw DolbyEError.unsupported("ED2 OAMD exceeds sixteen elements") }
        var beds: [[DolbyED2Speaker]] = [], dynamic = 0
        if try bits.flag() {
            if try bits.flag() { beds = [[.lfe]] }
            dynamic = total - beds.count
        } else {
            let mask = try bits.take(4)
            if mask & 1 != 0 {
                _ = try bits.flag() // Explicit MGI mappings resolve channel distribution.
                let count = try bits.flag() ? bits.take(3) + 2 : 1
                guard count <= 4 else { throw DolbyEError.unsupported("ED2 OAMD bed count") }
                for _ in 0..<count {
                    if try bits.flag() { beds.append([.lfe]) }
                    else if try bits.flag() {
                        let channelMask = try bits.take(10)
                        beds.append(groups.enumerated().flatMap { channelMask & (1 << $0.offset) != 0 ? $0.element : [] })
                    } else {
                        let channelMask = try bits.take(17)
                        beds.append(DolbyED2Speaker.allCases.enumerated().compactMap { channelMask & (1 << $0.offset) != 0 ? $0.element : nil })
                    }
                    guard !beds.last!.isEmpty else { throw DolbyEError.malformed("empty ED2 OAMD bed") }
                }
            }
            guard mask & 2 == 0 else { throw DolbyEError.unsupported("ED2 intermediate spatial format") }
            if mask & 4 != 0 {
                dynamic = try bits.take(5)
                if dynamic == 31 { dynamic += try bits.take(7) }
                dynamic += 1
            }
            if mask & 8 != 0 {
                let reserved = try bits.take(4)
                try bits.skip((reserved + 1) * 8)
            }
        }
        let bedChannels = beds.reduce(0) { $0 + $1.count }
        guard bedChannels + dynamic == total else { throw DolbyEError.malformed("ED2 OAMD bed/object count disagreement") }
        let alternate = try bits.flag()
        var elements = try bits.take(4)
        if elements == 15 { elements += try bits.take(5) }
        guard elements > 0, elements <= 32 else { throw DolbyEError.malformed("ED2 OA element count") }
        var result: [[DolbyED2ObjectState]]?
        for _ in 0..<elements {
            let id = try bits.take(4), count = try bits.variable(4) + 1
            var element = try bits.bounded(count * 8)
            if alternate { _ = try element.take(4) }
            let discard = try element.flag()
            if id == 1 {
                guard result == nil else { throw DolbyEError.unsupported("multiple ED2 object elements") }
                result = try parseElement(&element, count: total, bedChannels: bedChannels)
                try element.zeroPadding()
            } else if !discard { throw DolbyEError.unsupported("required ED2 OA element \(id)") }
        }
        try bits.zeroPadding()
        guard let result else { throw DolbyEError.malformed("ED2 OAMD has no object element") }
        return Self(beds: beds, states: result, dynamicCount: dynamic)
    }

    private static func parseElement(_ bits: inout ED2BitReader, count: Int, bedChannels: Int) throws -> [[DolbyED2ObjectState]] {
        let offsetCode = try bits.take(2)
        let offset: Int
        switch offsetCode {
        case 0: offset = 0
        case 1: offset = try [8, 16, 18, 24][bits.take(2)]
        case 2: offset = try bits.take(5)
        default: throw DolbyEError.malformed("reserved OAMD sample offset")
        }
        let blocks = try bits.take(3) + 1
        var timing: [(Int, Int)] = []
        for _ in 0..<blocks {
            let sample = try bits.take(6) * 32 + offset, code = try bits.take(2)
            let duration: Int
            if code == 3 { duration = try bits.flag() ? ramps[bits.take(4)] : bits.take(11) }
            else { duration = [0, 512, 1536][code] }
            guard timing.last == nil || timing.last!.0 < sample else { throw DolbyEError.malformed("OAMD update times are not increasing") }
            timing.append((sample, duration))
        }
        if try !bits.flag() { _ = try bits.take(5) }
        var output: [[DolbyED2ObjectState]] = []
        for object in 0..<count {
            var states: [DolbyED2ObjectState] = []
            for block in 0..<blocks {
                let inactive = try bits.flag()
                var state = states.last ?? DolbyED2ObjectState(position: .init(x: 0, y: 0, z: 0))
                state.sampleOffset = timing[block].0; state.rampDuration = timing[block].1
                state.active = !inactive
                let basic = try inactive ? 0 : (block == 0 ? 1 : bits.take(2))
                // 0 resets the fields, 2 reuses the previous block, and 3
                // reuses then selectively overrides it. Mask bit 0 is gain;
                // bit 1 is priority. Full-field packets alone cannot test this.
                if basic == 0 { state.gain = 0 }
                if basic & 1 != 0 {
                    let fields = try basic & 2 == 0 ? 3 : bits.take(2)
                    if fields & 1 != 0 {
                        switch try bits.take(2) {
                        case 0: state.gain = 1
                        case 1: state.gain = 0
                        case 2:
                            let code = try bits.take(6)
                            state.gain = pow(10, Double((code < 15 ? 15 : 14) - code) / 20)
                        default: state.gain = output.last?[block].gain ?? 1
                        }
                    }
                    if fields & 2 != 0, try !bits.flag() { _ = try bits.take(5) }
                }
                if inactive { state.gain = 0 }
                let render = try inactive || object < bedChannels ? 0 : (block == 0 ? 1 : bits.take(2))
                if render == 0 { state.position = .init(x: 0, y: 0, z: 0); state.size = 0; state.snap = false }
                if render & 1 != 0 {
                    let fields = try render & 2 == 0 ? 15 : bits.take(4)
                    if fields & 1 != 0 {
                        if block > 0, try bits.flag() {
                            // Signed three-bit deltas operate on the previous
                            // wire coordinates, before Q15 conversion/clamping.
                            let x = 31 + Int((state.position.x * 31).rounded())
                            let y = 31 - Int((state.position.y * 31).rounded())
                            let z = Int((state.position.z * 15).rounded())
                            func delta(_ code: Int) -> Int { code < 4 ? code : code - 8 }
                            let dx = try delta(bits.take(3)), dy = try delta(bits.take(3)), dz = try delta(bits.take(3))
                            state.position = .init(x: Double(max(0, min(62, x + dx))) / 31 - 1,
                                y: 1 - Double(max(0, min(62, y + dy))) / 31,
                                z: Double(max(-15, min(15, z + dz))) / 15)
                        } else { state.position = try readPosition(&bits) }
                        if try bits.flag(), try !bits.flag() { _ = try bits.take(4) }
                    }
                    if fields & 2 != 0 { _ = try bits.take(4) }
                    if fields & 4 != 0 {
                        switch try bits.take(2) {
                        case 0: state.size = 0
                        case 1: state.size = Double(try bits.take(5)) / 31
                        case 2:
                            let dimensions = try [bits.take(5), bits.take(5), bits.take(5)]
                            guard Set(dimensions).count <= 1 else { throw DolbyEError.unsupported("anisotropic ED2 object size") }
                            state.size = Double(dimensions[0]) / 31
                        default: state.size = 0 // reserved mode falls back to point extent
                        }
                    }
                    if fields & 8 != 0 {
                        if try bits.flag() { _ = try bits.take(5) }
                    }
                    // Snap belongs to the render update, even when the zone
                    // field is absent from a selective field mask.
                    state.snap = try bits.flag()
                }
                if try bits.flag() { try bits.skip((bits.take(4) + 1) * 8) }
                states.append(state)
            }
            output.append(states)
        }
        return output
    }

    static func encode(_ scene: DolbyED2SceneMetadata) throws -> Data {
        let bedCount = scene.beds.reduce(0) { $0 + $1.channels.count }, total = bedCount + scene.objects.count
        let timing = scene.objects.first?.states ?? [.init(position: .init())]
        let grid = timing.map { [$0.sampleOffset, $0.rampDuration] }
        guard scene.objects.allSatisfy({ $0.states.map { [$0.sampleOffset, $0.rampDuration] } == grid }) else {
            throw DolbyEError.invalidArgument("ED2 object updates must use a common frame grid")
        }
        let residual = timing[0].sampleOffset % 32
        guard timing.allSatisfy({ $0.sampleOffset % 32 == residual }) else { throw DolbyEError.invalidArgument("ED2 update grid must have one residual sample offset") }
        var element = ED2BitWriter()
        try element.append(0, bits: 1)
        if residual == 0 { try element.append(0, bits: 2) }
        else { try element.append(2, bits: 2); try element.append(residual, bits: 5) }
        try element.append(timing.count - 1, bits: 3)
        for update in timing {
            try element.append(update.sampleOffset / 32, bits: 6)
            if update.rampDuration == 0 { try element.append(0, bits: 2) }
            else if update.rampDuration == 512 { try element.append(1, bits: 2) }
            else if update.rampDuration == 1536 { try element.append(2, bits: 2) }
            else {
                try element.append(3, bits: 2)
                if let index = ramps.firstIndex(of: update.rampDuration) {
                    try element.append(1, bits: 1); try element.append(index, bits: 4)
                } else { try element.append(0, bits: 1); try element.append(update.rampDuration, bits: 11) }
            }
        }
        try element.append(1, bits: 1)
        let bedGains = scene.beds.flatMap(\.gains)
        for object in 0..<total {
            for block in timing.indices {
                let state = object < bedCount ? DolbyED2ObjectState(position: .init(), gain: bedGains[object])
                    : scene.objects[object - bedCount].states[block]
                try element.append(state.active ? 0 : 1, bits: 1)
                if state.active {
                    if block > 0 { try element.append(1, bits: 2) }
                    try writeGain(state.gain, to: &element)
                    try element.append(1, bits: 1)
                    if object >= bedCount {
                        if block > 0 { try element.append(1, bits: 2); try element.append(0, bits: 1) }
                        try writePosition(state.position, to: &element)
                        try element.append(0, bits: 1) // no distance constraint
                        try element.append(0, bits: 3); try element.append(1, bits: 1)
                        if state.size == 0 { try element.append(0, bits: 2) }
                        else { try element.append(1, bits: 2); try element.append(Int((state.size * 31).rounded()), bits: 5) }
                        try element.append(0, bits: 1); try element.append(state.snap ? 1 : 0, bits: 1)
                    }
                }
                try element.append(0, bits: 1)
            }
        }
        try element.align()
        var payload = ED2BitWriter()
        try payload.append(0, bits: 2); try payload.append(total - 1, bits: 5)
        if scene.beds.isEmpty {
            try payload.append(1, bits: 1); try payload.append(0, bits: 1)
        } else {
            try payload.append(0, bits: 1)
            try payload.append(1 | (scene.objects.isEmpty ? 0 : 4), bits: 4)
            try payload.append(1, bits: 1)
            try payload.append(scene.beds.count > 1 ? 1 : 0, bits: 1)
            if scene.beds.count > 1 { try payload.append(scene.beds.count - 2, bits: 3) }
            for bed in scene.beds {
                if bed.channels == [.lfe] { try payload.append(1, bits: 1) }
                else {
                    try payload.append(0, bits: 1)
                    let set = Set(bed.channels)
                    var mask = 0, represented: [DolbyED2Speaker] = []
                    for (index, group) in groups.enumerated() where Set(group).isSubset(of: set) {
                        mask |= 1 << index; represented += group
                    }
                    if represented == bed.channels {
                        try payload.append(1, bits: 1); try payload.append(mask, bits: 10)
                    } else {
                        guard DolbyED2Speaker.allCases.filter({ set.contains($0) }) == bed.channels else { throw DolbyEError.invalidArgument("ED2 bed channel order is not representable") }
                        try payload.append(0, bits: 1)
                        let mask = DolbyED2Speaker.allCases.enumerated().reduce(0) { $0 | (set.contains($1.element) ? 1 << $1.offset : 0) }
                        try payload.append(mask, bits: 17)
                    }
                }
            }
            if !scene.objects.isEmpty { try payload.append(scene.objects.count - 1, bits: 5) }
        }
        try payload.append(0, bits: 1); try payload.append(1, bits: 4); try payload.append(1, bits: 4)
        try payload.variable(element.data.count - 1, width: 4); try payload.octets(element.data); try payload.align()
        return payload.data
    }

    fileprivate static func readPosition(_ bits: inout ED2BitReader) throws -> DolbyED2Position {
        let x = try bits.take(6), y = try bits.take(6), positive = try bits.flag(), z = try bits.take(4)
        return .init(x: Double(min(x, 62)) / 31 - 1, y: 1 - Double(min(y, 62)) / 31,
            z: Double(z) / 15 * (positive ? 1 : -1))
    }
    fileprivate static func writePosition(_ point: DolbyED2Position, to writer: inout ED2BitWriter) throws {
        try point.validate()
        try writer.append(31 + Int((point.x * 31).rounded()), bits: 6)
        try writer.append(31 - Int((point.y * 31).rounded()), bits: 6)
        try writer.append(point.z >= 0 ? 1 : 0, bits: 1)
        try writer.append(Int((abs(point.z) * 15).rounded()), bits: 4)
    }
    private static func writeGain(_ gain: Double, to writer: inout ED2BitWriter) throws {
        if gain == 0 { try writer.append(1, bits: 2) }
        else if gain == 1 { try writer.append(0, bits: 2) }
        else {
            let db = Int((20 * log10(gain)).rounded())
            guard (-49...15).contains(db) else { throw DolbyEError.invalidArgument("ED2 object gain exceeds legacy OAMD range") }
            if db == 0 { try writer.append(0, bits: 2) }
            else { try writer.append(2, bits: 2); try writer.append(db > 0 ? 15 - db : 14 - db, bits: 6) }
        }
    }
}

private enum ED2MixGraph {
    static func parse(_ data: Data, audio: ED2ObjectAudio) throws -> DolbyED2SceneMetadata {
        var bits = ED2BitReader(data: data)
        var version = try bits.take(2)
        if version == 3 { version += try bits.variable(2) }
        guard version == 5 else { throw DolbyEError.unsupported("ED2 mix graph version \(version)") }
        let programIDPresent = try bits.flag(), mapped = try bits.flag()
        let extensionPresent = try bits.flag(), descriptionPresent = try bits.flag()
        if programIDPresent { _ = try bits.take(3); _ = try bits.take(16) }
        try bits.align()
        let programID = UInt16(try bits.take(16)), presentationCount = try bits.take(4) + 1
        let objectCount = try bits.take(7), bedCount = try bits.take(4)
        guard objectCount == audio.dynamicCount, bedCount == audio.beds.count, objectCount + bedCount <= 16 else {
            throw DolbyEError.malformed("ED2 OAMD/MGI element counts disagree")
        }
        var objectAlternatives: [[DolbyED2ObjectAlternative]] = [], categories: [Bool] = []
        for _ in 0..<objectCount {
            let count = try bits.variable(2), category = try bits.take(2)
            guard count <= 16, category <= 1 else { throw DolbyEError.unsupported("ED2 object alternatives or sound category") }
            categories.append(category == 1)
            var alternatives: [DolbyED2ObjectAlternative] = []
            for _ in 0..<count {
                let mask = try bits.variable(3), length = try bits.variable(3)
                guard mask <= 7 else { throw DolbyEError.unsupported("ED2 alternate object fields") }
                var body = try bits.bounded(length * 8)
                var value = DolbyED2ObjectAlternative()
                if mask & 1 != 0 {
                    let code = try body.take(6)
                    value.gain = code == 63 ? 0 : pow(10, Double(15 - code) / 20)
                }
                if mask & 2 != 0 { value.position = try ED2ObjectAudio.readPosition(&body) }
                if mask & 4 != 0 {
                    value.headphoneMetadataState = try body.flag()
                    value.headphoneRenderMode = try body.take(2)
                    value.headphoneHeadTrackingState = try body.flag()
                }
                try body.zeroPadding()
                alternatives.append(value)
            }
            objectAlternatives.append(alternatives)
        }
        var bedAlternatives: [[Double?]] = []
        for _ in 0..<bedCount {
            let count = try bits.variable(2)
            guard count <= 16 else { throw DolbyEError.unsupported("ED2 bed alternative count") }
            var alternatives: [Double?] = []
            for _ in 0..<count {
                let mask = try bits.variable(2), length = try bits.variable(2)
                guard mask <= 1 else { throw DolbyEError.unsupported("ED2 alternate bed fields") }
                var body = try bits.bounded(length * 8)
                let gain = try mask & 1 != 0 ? pow(10, Double(15 - body.take(6)) / 20) : nil
                try body.zeroPadding(); alternatives.append(gain)
            }
            bedAlternatives.append(alternatives)
        }
        var presentations: [DolbyED2PresentationMetadata] = []
        for _ in 0..<presentationCount {
            let count = try bits.variable(2) + 1, preferred = try bits.variable(2)
            guard count <= 8, (0...7).contains(preferred) else { throw DolbyEError.malformed("ED2 target configuration at bit \(bits.position): count \(count), mask \(preferred)") }
            var targets: [DolbyED2PresentationTarget] = []
            for _ in 0..<count {
                let mask = try bits.variable(3)
                var objects: [Int] = [], beds: [Int] = []
                for index in 0..<objectCount {
                    objects.append(try bits.flag() ? bits.take(width(objectAlternatives[index].count + 1)) : -1)
                }
                for index in 0..<bedCount {
                    beds.append(try bits.flag() ? bits.take(width(bedAlternatives[index].count + 1)) : -1)
                }
                targets.append(.init(deviceMask: mask, objectMetadataIndices: objects, bedMetadataIndices: beds))
            }
            if try bits.flag() { try bits.skip(bits.variable(4)) }
            presentations.append(.init(defaultDeviceMask: preferred, targets: targets))
        }
        guard mapped else { throw DolbyEError.unsupported("ED2 mix graph without explicit substream mappings") }
        var mappings: [DolbyED2SourceMapping] = []
        for _ in 0..<(objectCount + bedCount) {
            let stream = try bits.take(4), standard = try bits.flag()
            var channel = try bits.take(standard ? 3 : 5)
            if !standard && channel == 31 { channel += try bits.variable(3) }
            let value = DolbyED2SourceMapping(substreamIndex: stream, channelIndex: channel)
            try value.validate(); mappings.append(value)
        }
        try bits.align()
        if extensionPresent, try bits.flag() { try bits.skip(bits.variable(4)) }
        // Description packets are text split over several frames. Their raw bytes
        // remain in the authenticated payload; they do not alter audio routing.
        if descriptionPresent { try bits.skip(bits.remaining) }
        else { try bits.zeroPadding() }
        var objects: [DolbyED2ObjectMetadata] = [], beds: [DolbyED2BedMetadata] = []
        let channels = audio.beds.reduce(0) { $0 + $1.count }
        for index in 0..<objectCount {
            objects.append(.init(source: mappings[index], isDialogue: categories[index],
                states: audio.states[channels + index], alternatives: objectAlternatives[index]))
        }
        var channel = 0
        for index in 0..<bedCount {
            let gains = audio.states[channel..<(channel + audio.beds[index].count)].map { $0.first!.gain }
            beds.append(.init(channels: audio.beds[index], source: mappings[objectCount + index],
                gains: gains, alternativeGains: bedAlternatives[index]))
            channel += audio.beds[index].count
        }
        let result = DolbyED2SceneMetadata(programID: programID, beds: beds, objects: objects, presentations: presentations)
        try result.validate(); return result
    }

    static func encode(_ scene: DolbyED2SceneMetadata) throws -> Data {
        var bits = ED2BitWriter()
        try bits.append(3, bits: 2); try bits.variable(2, width: 2)
        try bits.append(0, bits: 1); try bits.append(1, bits: 1); try bits.append(0, bits: 2)
        try bits.align(); try bits.append(Int(scene.programID), bits: 16)
        try bits.append(scene.presentations.count - 1, bits: 4)
        try bits.append(scene.objects.count, bits: 7); try bits.append(scene.beds.count, bits: 4)
        for object in scene.objects {
            try bits.variable(object.alternatives.count, width: 2)
            try bits.append(object.isDialogue ? 1 : 0, bits: 2)
            for alternative in object.alternatives {
                var body = ED2BitWriter(), mask = 0
                if let gain = alternative.gain {
                    mask |= 1
                    let code: Int
                    if gain == 0 { code = 63 }
                    else {
                        let db = Int((20 * log10(gain)).rounded())
                        guard (-47...15).contains(db) else { throw DolbyEError.invalidArgument("ED2 alternate gain range") }
                        code = 15 - db
                    }
                    try body.append(code, bits: 6)
                }
                if let position = alternative.position { mask |= 2; try ED2ObjectAudio.writePosition(position, to: &body) }
                if let mode = alternative.headphoneRenderMode {
                    mask |= 4; try body.append(alternative.headphoneMetadataState == true ? 1 : 0, bits: 1)
                    try body.append(mode, bits: 2); try body.append(alternative.headphoneHeadTrackingState == true ? 1 : 0, bits: 1)
                }
                try body.align(); try bits.variable(mask, width: 3); try bits.variable(body.data.count, width: 3)
                try bits.octets(body.data)
            }
        }
        for bed in scene.beds {
            try bits.variable(bed.alternativeGains.count, width: 2)
            for gain in bed.alternativeGains {
                if let gain {
                    guard gain > 0 else { throw DolbyEError.invalidArgument("ED2 alternate bed gain must be positive") }
                    let code = 15 - Int((20 * log10(gain)).rounded())
                    guard (0...63).contains(code) else { throw DolbyEError.invalidArgument("ED2 alternate bed gain range") }
                    try bits.variable(1, width: 2); try bits.variable(1, width: 2)
                    try bits.append(code, bits: 6); try bits.append(0, bits: 2)
                } else { try bits.variable(0, width: 2); try bits.variable(0, width: 2) }
            }
        }
        for presentation in scene.presentations {
            try bits.variable(presentation.targets.count - 1, width: 2)
            try bits.variable(presentation.defaultDeviceMask, width: 2)
            for target in presentation.targets {
                try bits.variable(target.deviceMask, width: 3)
                for (index, value) in target.objectMetadataIndices.enumerated() {
                    try bits.append(value >= 0 ? 1 : 0, bits: 1)
                    if value >= 0 { try bits.append(value, bits: width(scene.objects[index].alternatives.count + 1)) }
                }
                for (index, value) in target.bedMetadataIndices.enumerated() {
                    try bits.append(value >= 0 ? 1 : 0, bits: 1)
                    if value >= 0 { try bits.append(value, bits: width(scene.beds[index].alternativeGains.count + 1)) }
                }
            }
            try bits.append(0, bits: 1)
        }
        for mapping in scene.objects.map(\.source) + scene.beds.map(\.source) {
            try bits.append(mapping.substreamIndex, bits: 4); try bits.append(1, bits: 1)
            try bits.append(mapping.channelIndex, bits: 3)
        }
        try bits.align(); return bits.data
    }

    private static func width(_ value: Int) -> Int { Int.bitWidth - value.leadingZeroBitCount }
}
