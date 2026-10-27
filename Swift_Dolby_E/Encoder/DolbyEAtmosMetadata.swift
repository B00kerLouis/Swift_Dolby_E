// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum DolbyEAtmosMetadata {
    static func text(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let count = try file.seekToEnd()
        guard count <= 16 * 1024 * 1024 else { throw DolbyEError.malformed("Atmos metadata exceeds 16 MiB") }
        let data = try readBytes(file, at: 0, count: Int(count))
        guard let text = String(data: data, encoding: .utf8) else { throw DolbyEError.malformed("Atmos metadata is not UTF-8") }
        return text
    }
    static func scalar(_ line: String) -> (String, String)? {
        let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = stripped.hasPrefix("- ") ? String(stripped.dropFirst(2)) : stripped
        guard let separator = value.firstIndex(of: ":") else { return nil }
        let key = String(value[..<separator]).trimmingCharacters(in: .whitespaces)
        var text = String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) { text = String(text.dropFirst().dropLast()) }
        return (key, text)
    }
    static func descriptor(_ text: String) throws -> (audio: String, metadata: String, beds: [Int: DolbyEAtmosBed], objects: Set<Int>, channelOrder: [Int]) {
        var audio: String?, metadata: String?, pendingBed: DolbyEAtmosBed?
        var beds: [Int: DolbyEAtmosBed] = [:], objects: Set<Int> = []
        var order: [Int] = []
        var section = "", presentations = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = scalar(String(line)) else { continue }
            if key == "type" { presentations += 1; if presentations > 1 { break } }
            switch key {
            case "audio": audio = value
            case "metadata": metadata = value
            case "bedInstances": section = "bed"
            case "objects": section = "objects"; pendingBed = nil
            case "channel" where section == "bed":
                guard let bed = DolbyEAtmosBed(label: value) else { throw DolbyEError.unsupported("DAMF bed channel \(value)") }
                pendingBed = bed
            case "ID":
                guard let id = Int(value), (0..<256).contains(id) else { throw DolbyEError.malformed("invalid DAMF channel ID") }
                if section == "bed", let bed = pendingBed {
                    guard beds.updateValue(bed, forKey: id) == nil else { throw DolbyEError.malformed("duplicate DAMF bed ID") }
                    pendingBed = nil
                    order.append(id)
                } else if section == "objects" {
                    guard objects.insert(id).inserted else { throw DolbyEError.malformed("duplicate DAMF object ID") }
                    order.append(id)
                }
            default: break
            }
        }
        guard let audio, let metadata, !audio.isEmpty, !metadata.isEmpty, !beds.isEmpty || !objects.isEmpty,
              Set(beds.keys).isDisjoint(with: objects) else { throw DolbyEError.malformed("DAMF descriptor has no unambiguous audio, metadata and channel map") }
        return (audio, metadata, beds, objects, order)
    }
    static func damf(_ text: String, beds: [Int: DolbyEAtmosBed], objects: Set<Int>, channels: Int, channelOrder: [Int]? = nil) throws -> DolbyEAtmosScene {
        let mapping: [Int: Int]
        if let channelOrder {
            guard channelOrder.count == channels, Set(channelOrder).count == channels else { throw DolbyEError.malformed("DAMF descriptor order differs from CAF channel inventory") }
            mapping = Dictionary(uniqueKeysWithValues: channelOrder.enumerated().map { ($0.element, $0.offset) })
        } else { mapping = Dictionary(uniqueKeysWithValues: (0..<channels).map { ($0, $0) }) }
        var records: [Int: [[String: String]]] = [:]
        var id: Int?, record: [String: String] = [:], inherited = "0"
        func flush() {
            if let id { records[id, default: []].append(record) }
        }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = scalar(String(line)) else { continue }
            if key == "ID" {
                flush(); id = Int(value); record = ["samplePos": inherited]
            } else if key == "samplePos" {
                inherited = value
                if id != nil { record[key] = value }
            } else if id != nil { record[key] = value }
        }
        flush()
        var tracks: [DolbyEAtmosTrack] = []
        for channel in Set(beds.keys).union(objects).sorted() {
            var value = DolbyEAtmosValue(), level = 1.0, active = true, positioned = beds[channel] != nil
            var events: [DolbyEAtmosEvent] = []
            for record in records[channel] ?? [] {
                guard let sample = UInt64(record["samplePos"] ?? "0"), let ramp = UInt64(record["rampLength"] ?? "0") else {
                    throw DolbyEError.malformed("invalid DAMF event time")
                }
                if let position = record["pos"] {
                    let fields = position.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    guard fields.count == 3 else { throw DolbyEError.malformed("invalid DAMF object position") }
                    value.x = fields[0]; value.y = fields[1]; value.z = fields[2]; positioned = true
                }
                if let gain = record["gain"] {
                    guard let number = Double(gain), number.isFinite || number == -.infinity else { throw DolbyEError.malformed("invalid DAMF gain") }
                    level = pow(10, number / 20)
                }
                if let enabled = record["active"] {
                    guard ["true", "false", "1", "0"].contains(enabled.lowercased()) else { throw DolbyEError.malformed("invalid DAMF activation flag") }
                    active = enabled == "1" || enabled.lowercased() == "true"
                }
                if let size = record["size"] {
                    guard let number = Double(size), (0...1).contains(number) else { throw DolbyEError.malformed("invalid DAMF object size") }
                    value.spread = number
                }
                if let decorrelation = record["decorr"] {
                    guard let number = Double(decorrelation), (0...1).contains(number) else { throw DolbyEError.malformed("invalid DAMF decorrelation") }
                    value.decorrelation = number
                }
                if let snap = record["snap"] { value.snapTolerance = snap == "true" || snap == "1" ? 1 : nil }
                if let zones = record["zones"], zones != "all" { throw DolbyEError.unsupported("DAMF selected object zones: \(zones)") }
                guard positioned || !active else { throw DolbyEError.malformed("active DAMF object \(channel) has no position") }
                value.gain = active ? level : 0
                let event = DolbyEAtmosEvent(sample: sample, ramp: ramp, value: value)
                if events.last?.sample == sample { events[events.count - 1] = event }
                else {
                    guard events.last == nil || events.last!.sample < sample else { throw DolbyEError.malformed("DAMF events are out of order") }
                    events.append(event)
                }
            }
            guard beds[channel] != nil || !events.isEmpty else { throw DolbyEError.malformed("DAMF object \(channel) has no timeline") }
            guard let physical = mapping[channel] else { throw DolbyEError.malformed("DAMF element \(channel) has no CAF channel assignment") }
            tracks.append(DolbyEAtmosTrack(channel: physical, bed: beds[channel], start: 0, end: .max, gain: 1, events: events))
        }
        let scene = DolbyEAtmosScene(channels: channels, tracks: tracks, ignoredChannels: [])
        try scene.validate(); return scene
    }

    static func adm(_ data: Data, chna: Data?, channels: Int) throws -> DolbyEAtmosScene {
        try adm(parser: XMLParser(data: data), chna: chna, channels: channels)
    }
    static func adm(stream: InputStream, chna: Data?, channels: Int) throws -> DolbyEAtmosScene {
        try adm(parser: XMLParser(stream: stream), chna: chna, channels: channels)
    }
    private static func adm(parser: XMLParser, chna: Data?, channels: Int) throws -> DolbyEAtmosScene {
        let document = DolbyEADMDocument()
        parser.shouldResolveExternalEntities = false; parser.delegate = document
        let parsed = parser.parse()
        if let failure = document.failure { throw failure }
        guard parsed, !document.invalid else { throw DolbyEError.malformed("ADM XML: \(parser.parserError?.localizedDescription ?? "invalid or excessive XML structure")") }
        let nodes = document.nodes
        var indexed: [String: DolbyEADMNode] = [:]
        for node in nodes {
            for (key, value) in node.attributes where key.hasSuffix("ID") || key == "UID" {
                if indexed[value] != nil { throw DolbyEError.malformed("duplicate ADM identifier \(value)") }
                indexed[value] = node
            }
        }
        var assignments: [(Int, String, String)] = []
        if let chna {
            guard chna.count >= 4, try chna.integer(at: 0, bytes: 2) == UInt64(channels) else { throw DolbyEError.malformed("ADM chna channel count") }
            let count = Int(try chna.integer(at: 2, bytes: 2))
            guard count <= (chna.count - 4) / 40 else { throw DolbyEError.malformed("truncated ADM chna") }
            func ascii(_ range: Range<Int>) -> String { String(decoding: chna[range].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces) }
            for index in 0..<count {
                let offset = 4 + index * 40
                let track = Int(try chna.integer(at: offset, bytes: 2)) - 1
                if track < 0 { continue } // Standard unused chna entry.
                guard track < channels else { throw DolbyEError.malformed("ADM chna track exceeds PCM channel count") }
                assignments.append((track, ascii((offset + 2)..<(offset + 14)), ascii((offset + 14)..<(offset + 28))))
            }
        } else {
            for node in nodes where node.name == "audioTrackUID" {
                guard let index = Int(node.attributes["trackIndex"] ?? ""), let uid = node.attributes["UID"], (1...channels).contains(index) else {
                    throw DolbyEError.malformed("ADM without chna needs explicit audioTrackUID trackIndex assignments")
                }
                assignments.append((index - 1, uid, ""))
            }
        }
        guard !assignments.isEmpty else { throw DolbyEError.malformed("ADM has no PCM channel assignments") }
        func resolve(_ id: String, path: Set<String> = []) throws -> DolbyEADMNode? {
            guard !path.contains(id), path.count < 16 else { throw DolbyEError.malformed("cyclic ADM format references") }
            guard let node = indexed[id] else {
                if id.hasPrefix("AT_"), id.count > 6 { return indexed["AC_" + id.dropFirst(3).dropLast(3)] }
                return nil
            }
            if node.name == "audioChannelFormat" { return node }
            for child in node.children where ["audioChannelFormatIDRef", "audioTrackFormatIDRef", "audioStreamFormatIDRef"].contains(child.name) {
                if let format = try resolve(child.text, path: path.union([id])) { return format }
            }
            return nil
        }
        struct Usage { let uid: String; let start: UInt64; let end: UInt64; let gain: Double }
        var usages: [Usage] = []
        func visit(_ node: DolbyEADMNode, start: UInt64 = 0, end: UInt64 = .max, gain: Double = 1, path: Set<String> = []) throws {
            let id = node.attributes["audioObjectID"] ?? node.attributes["audioContentID"] ?? node.attributes["audioProgrammeID"] ?? ""
            guard !path.contains(id), path.count < 32 else { throw DolbyEError.malformed("cyclic ADM programme graph") }
            let localStart = try time(node.attributes["start"])
            guard start <= UInt64.max - localStart else { throw DolbyEError.malformed("ADM object start overflow") }
            let origin = start + localStart
            let duration = try node.attributes["duration"].map { try time($0) }
            guard duration == nil || origin <= UInt64.max - duration! else { throw DolbyEError.malformed("ADM object duration overflow") }
            let limit = min(end, duration.map { origin + $0 } ?? end)
            var level = gain
            if let node = node.children.first(where: { $0.name == "gain" }) { level *= try gainValue(node) }
            if node.children.contains(where: { $0.name == "mute" && $0.text == "1" }) { level = 0 }
            for child in node.children {
                if child.name == "audioTrackUIDRef", child.text != "ATU_00000000" { usages.append(Usage(uid: child.text, start: origin, end: limit, gain: level)) }
                else if ["audioContentIDRef", "audioObjectIDRef"].contains(child.name) {
                    guard let referenced = indexed[child.text] else { throw DolbyEError.malformed("missing ADM reference \(child.text)") }
                    try visit(referenced, start: origin, end: limit, gain: level, path: path.union([id]))
                }
            }
        }
        if let programme = nodes.first(where: { $0.name == "audioProgramme" }) { try visit(programme) }
        if usages.isEmpty { usages = assignments.map { Usage(uid: $0.1, start: 0, end: .max, gain: 1) } }
        let selected = Set(usages.map(\.uid))
        var tracks: [DolbyEAtmosTrack] = [], ignored = Set<Int>(), seen = Set<String>()
        for (channel, uid, reference) in assignments {
            guard seen.insert("\(channel)|\(uid)").inserted else { continue }
            if !selected.contains(uid) { ignored.insert(channel); continue }
            guard let format = try resolve(uid) ?? resolve(reference) else { throw DolbyEError.malformed("unresolved ADM channel format for \(uid)") }
            let isObject = format.attributes["typeLabel"] == "0003" || format.attributes["typeDefinition"]?.lowercased() == "objects"
            let speaker = format.speakerLabel
            let bed = isObject ? nil : DolbyEAtmosBed(label: speaker ?? format.attributes["audioChannelFormatName"] ?? "")
            guard isObject || bed != nil else { throw DolbyEError.unsupported("ADM direct speaker \(speaker ?? format.attributes["audioChannelFormatName"] ?? "unknown")") }
            let events = format.blocks
            for usage in usages where usage.uid == uid {
                tracks.append(DolbyEAtmosTrack(channel: channel, bed: bed, start: usage.start, end: usage.end, gain: usage.gain, events: events))
            }
        }
        let scene = DolbyEAtmosScene(channels: channels, tracks: tracks, ignoredChannels: ignored)
        try scene.validate(); return scene
    }

    fileprivate static func admBlock(_ block: DolbyEADMNode, isObject: Bool, initial: Bool) throws -> DolbyEAtmosEvent {
        var value = DolbyEAtmosValue()
        let positions = block.children.filter { $0.name == "position" && $0.attributes["bound"] == nil }
        var coordinates: [String: Double] = [:]
        for coordinate in positions {
            guard let axis = coordinate.attributes["coordinate"], let number = Double(coordinate.text), number.isFinite else { throw DolbyEError.malformed("invalid ADM position") }
            coordinates[axis.lowercased()] = number
        }
        let cartesian = block.children.first(where: { $0.name == "cartesian" })?.text == "1" || coordinates["x"] != nil
        if isObject {
            guard !positions.isEmpty else { throw DolbyEError.malformed("ADM object block has no position") }
            if cartesian { value.x = coordinates["x"] ?? 0; value.y = coordinates["y"] ?? 0; value.z = coordinates["z"] ?? 0 }
            else {
                let azimuth = (coordinates["azimuth"] ?? 0) * .pi / 180, elevation = (coordinates["elevation"] ?? 0) * .pi / 180
                let distance = coordinates["distance"] ?? 1
                value.x = -sin(azimuth) * cos(elevation) * distance; value.y = cos(azimuth) * cos(elevation) * distance; value.z = sin(elevation) * distance
            }
        }
        if let gain = block.children.first(where: { $0.name == "gain" }) { value.gain = try gainValue(gain) }
        let extents = try ["width", "height", "depth"].map { key -> Double in
            guard let node = block.children.first(where: { $0.name == key }) else { return 0 }
            guard let number = Double(node.text), number.isFinite, number >= 0 else { throw DolbyEError.malformed("invalid ADM \(key)") }
            return number
        }
        value.spread = min(1, max(extents[0] / (cartesian ? 1 : 360), extents[1] / (cartesian ? 1 : 180), extents[2]))
        if let diffuse = block.children.first(where: { $0.name == "diffuse" }) {
            guard let number = Double(diffuse.text), (0...1).contains(number) else { throw DolbyEError.malformed("invalid ADM diffuse amount") }
            value.decorrelation = number
        }
        if let lock = block.children.first(where: { $0.name == "channelLock" }), lock.text == "1" {
            value.snapTolerance = lock.attributes["maxDistance"].flatMap(Double.init).map { min(1, max(0, $0 / 2)) } ?? 1
        }
        if let exclusion = block.children.first(where: { $0.name == "zoneExclusion" }) {
            let anchors: [[Double]] = [[-1, 1, 0], [0, 1, 0], [1, 1, 0], [-1, 0, 0], [1, 0, 0], [-1, -1, 0], [1, -1, 0], [0, 1, 1], [0, -1, 1]]
            var zones = [Double](repeating: 1, count: 9)
            for zone in exclusion.children where zone.name == "zone" {
                guard ["minX", "maxX", "minY", "maxY", "minZ", "maxZ"].contains(where: { zone.attributes[$0] != nil }) else {
                    throw DolbyEError.unsupported("ADM zone exclusion requires Cartesian bounds")
                }
                for (index, point) in anchors.enumerated() {
                    var inside = true
                    for (axis, name) in ["X", "Y", "Z"].enumerated() {
                        let low = zone.attributes["min" + name].flatMap(Double.init) ?? -1
                        let high = zone.attributes["max" + name].flatMap(Double.init) ?? 1
                        guard low.isFinite, high.isFinite, low <= high else { throw DolbyEError.malformed("invalid ADM zone bounds") }
                        inside = inside && point[axis] >= low && point[axis] <= high
                    }
                    if inside { zones[index] = 0 }
                }
            }
            value.zones = zones
        }
        if let divergence = block.children.first(where: { $0.name == "objectDivergence" }), Double(divergence.text) != 0 {
            throw DolbyEError.unsupported("ADM object divergence")
        }
        let start = try time(block.attributes["rtime"])
        let jump = block.children.first(where: { $0.name == "jumpPosition" })
        let ramp = try jump?.text == "1" ? time(jump?.attributes["interpolationLength"]) : time(block.attributes["duration"])
        return DolbyEAtmosEvent(sample: start, ramp: initial ? 0 : ramp, value: value)
    }

    private static func time(_ text: String?) throws -> UInt64 {
        guard let text else { return 0 }
        let fields = text.split(separator: ":")
        var seconds: Double
        if fields.count == 3, let hours = Double(fields[0]), let minutes = Double(fields[1]), let tail = Double(fields[2]) { seconds = hours * 3600 + minutes * 60 + tail }
        else if let number = Double(text) { seconds = number }
        else { throw DolbyEError.malformed("invalid ADM time \(text)") }
        seconds *= 48000
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) else { throw DolbyEError.malformed("ADM time exceeds sample clock") }
        return UInt64(seconds.rounded(.toNearestOrEven))
    }
    private static func gainValue(_ node: DolbyEADMNode) throws -> Double {
        guard let number = Double(node.text), number.isFinite || number == -.infinity else { throw DolbyEError.malformed("invalid ADM gain") }
        let value = node.attributes["gainUnit"] == "dB" ? pow(10, number / 20) : number
        guard value.isFinite, value >= 0 else { throw DolbyEError.malformed("invalid ADM linear gain") }
        return value
    }
}

fileprivate final class DolbyEADMNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [DolbyEADMNode] = []
    var blocks: [DolbyEAtmosEvent] = []
    var speakerLabel: String?
    init(_ name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
}

private final class DolbyEADMDocument: NSObject, XMLParserDelegate {
    var nodes: [DolbyEADMNode] = []
    var stack: [DolbyEADMNode] = []
    var invalid = false
    var failure: (any Error)?
    private var retainedBlocks = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard stack.count < 64, nodes.count < 200000 else { invalid = true; parser.abortParsing(); return }
        let node = DolbyEADMNode(name.split(separator: ":").last.map(String.init) ?? name, attributes: attributes)
        stack.last?.children.append(node); stack.append(node)
        if ["audioProgramme", "audioContent", "audioObject", "audioChannelFormat", "audioTrackUID", "audioTrackFormat", "audioStreamFormat", "audioPackFormat"].contains(node.name) { nodes.append(node) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let node = stack.last else { return }
        node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if node.name == "audioBlockFormat", stack.count >= 2 {
            let format = stack[stack.count - 2]
            do {
                if let speaker = node.children.first(where: { $0.name == "speakerLabel" })?.text { format.speakerLabel = speaker }
                let object = format.attributes["typeLabel"] == "0003" || format.attributes["typeDefinition"]?.lowercased() == "objects"
                let event = try DolbyEAtmosMetadata.admBlock(node, isObject: object, initial: format.blocks.isEmpty)
                if let last = format.blocks.last, last.sample == event.sample { format.blocks[format.blocks.count - 1] = event }
                else if let last = format.blocks.last, last.value == event.value,
                        last.ramp <= event.sample - min(event.sample, last.sample) { }
                else {
                    guard retainedBlocks < 262144, format.blocks.last == nil || format.blocks.last!.sample < event.sample else { throw DolbyEError.malformed("excessive or out-of-order ADM events") }
                    format.blocks.append(event); retainedBlocks += 1
                }
            } catch { failure = error; parser.abortParsing() }
            if format.children.last === node { format.children.removeLast() }
        }
        stack.removeLast()
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
}
