// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import CoreAudio
import AudioToolbox

public struct DolbyEAudioDevice: Identifiable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let speakers: [DolbyESpeaker]
    public let physicalChannels: Int
    public let sampleRate: Double
    public let channelIndices: [Int]
    public var outputChannels: Int { max(0, min(16, physicalChannels)) }
    public var usable: Bool { outputChannels > 0 }
    public var hasSpeakerLabels: Bool { !speakers.isEmpty && speakers.count == channelIndices.count }
    public func assigning(speakers: [DolbyESpeaker], channelIndices: [Int]? = nil) throws -> DolbyEAudioDevice {
        let indices = channelIndices ?? Array(speakers.indices)
        guard !speakers.isEmpty, speakers.count <= 16, Set(speakers).count == speakers.count,
              indices.count == speakers.count, Set(indices).count == indices.count,
              indices.allSatisfy({ (0..<outputChannels).contains($0) }) else {
            throw DolbyEError.invalidArgument("playback uses distinct physical outputs within channels 1–16 only")
        }
        return DolbyEAudioDevice(id: id, name: name, speakers: speakers, physicalChannels: physicalChannels, sampleRate: sampleRate, channelIndices: indices)
    }
}

public enum DolbyEAudioDevices {
    public static func outputs() throws -> [DolbyEAudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size <= 65536 else { throw DolbyEError.unsupported("CoreAudio output device discovery") }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw DolbyEError.unsupported("CoreAudio device list changed") }
        return ids.compactMap { inspect($0) }
    }
    public static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }
    private static func inspect(_ id: AudioDeviceID) -> DolbyEAudioDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size,
              size <= 65536 else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0, channels <= 256 else { return nil }
        address.mSelector = kAudioObjectPropertyName; address.mScope = kAudioObjectPropertyScopeGlobal
        size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        let nameStorage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UnsafeRawPointer?>.alignment)
        defer { nameStorage.deallocate() }
        nameStorage.initializeMemory(as: UnsafeRawPointer?.self, repeating: nil, count: 1)
        let nameStatus = AudioObjectGetPropertyData(id, &address, 0, nil, &size, nameStorage)
        let title: String
        if nameStatus == noErr, let pointer = nameStorage.load(as: UnsafeRawPointer?.self) {
            title = Unmanaged<CFString>.fromOpaque(pointer).takeRetainedValue() as String
        } else { title = "Audio device \(id)" }
        var speakers: [DolbyESpeaker] = [], indices: [Int] = []
        address.mSelector = kAudioDevicePropertyPreferredChannelLayout; address.mScope = kAudioDevicePropertyScopeOutput
        size = 0
        if AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size >= 12, size <= 65536 {
            let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { data.deallocate() }
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, data) == noErr {
                var layout = data.assumingMemoryBound(to: AudioChannelLayout.self)
                var expanded: UnsafeMutableRawPointer?
                defer { expanded?.deallocate() }
                if layout.pointee.mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions {
                    var tag = layout.pointee.mChannelLayoutTag, bitmap = layout.pointee.mChannelBitmap
                    let isBitmap = tag == kAudioChannelLayoutTag_UseChannelBitmap
                    let property = isBitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
                    var length: UInt32 = 0
                    let result = isBitmap
                        ? AudioFormatGetPropertyInfo(property, 4, &bitmap, &length)
                        : AudioFormatGetPropertyInfo(property, 4, &tag, &length)
                    if result == noErr, length >= 12, length <= 65536 {
                        let value = UnsafeMutableRawPointer.allocate(byteCount: Int(length), alignment: MemoryLayout<AudioChannelLayout>.alignment)
                        expanded = value
                        let result = isBitmap ? AudioFormatGetProperty(property, 4, &bitmap, &length, value)
                            : AudioFormatGetProperty(property, 4, &tag, &length, value)
                        if result == noErr { layout = value.assumingMemoryBound(to: AudioChannelLayout.self); size = length }
                    }
                }
                let count = Int(layout.pointee.mNumberChannelDescriptions)
                if layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions,
                   count == channels, 12 + count * MemoryLayout<AudioChannelDescription>.size <= Int(size) {
                    let descriptions = UnsafeRawPointer(layout).advanced(by: 12).assumingMemoryBound(to: AudioChannelDescription.self)
                    for index in 0..<min(count, 16) {
                        if let speaker = speaker(descriptions[index].mChannelLabel), !speakers.contains(speaker) {
                            speakers.append(speaker); indices.append(index)
                        }
                    }
                    if speakers.count != min(channels, 16) { speakers = []; indices = [] }
                }
            }
        }
        // Speaker metadata is used only for explicit downmix monitoring.
        // Discrete direct playback depends solely on the available output count.
        if speakers.isEmpty, channels == 2 {
            address.mSelector = kAudioDevicePropertyPreferredChannelsForStereo
            var pair: [UInt32] = [0, 0]; size = 8
            let result = pair.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
            if result == noErr, Set(pair) == Set([UInt32(1), UInt32(2)]) {
                speakers = [.left, .right]; indices = pair.map { Int($0) - 1 }
            }
        }
        address.mSelector = kAudioDevicePropertyNominalSampleRate; address.mScope = kAudioObjectPropertyScopeGlobal
        var sampleRate = 0.0; size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &sampleRate) == noErr,
              sampleRate.isFinite, (8000...384000).contains(sampleRate) else { return nil }
        return DolbyEAudioDevice(id: id, name: title, speakers: speakers, physicalChannels: channels, sampleRate: sampleRate, channelIndices: indices)
    }
    private static func speaker(_ label: AudioChannelLabel) -> DolbyESpeaker? {
        switch label {
        case kAudioChannelLabel_Left, kAudioChannelLabel_HeadphonesLeft, kAudioChannelLabel_BinauralLeft: .left
        case kAudioChannelLabel_Right, kAudioChannelLabel_HeadphonesRight, kAudioChannelLabel_BinauralRight: .right
        case kAudioChannelLabel_Center: .center
        case kAudioChannelLabel_LFEScreen: .lfe
        case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_LeftSideSurround: .leftSide
        case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RightSideSurround: .rightSide
        case kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_LeftBackSurround: .leftBack
        case kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_RightBackSurround: .rightBack
        case kAudioChannelLabel_LeftCenter: .leftExtra
        case kAudioChannelLabel_RightCenter: .rightExtra
        case kAudioChannelLabel_LeftWide: .wideLeft
        case kAudioChannelLabel_RightWide: .wideRight
        case kAudioChannelLabel_LeftTopFront: .topFrontLeft
        case kAudioChannelLabel_RightTopFront: .topFrontRight
        case kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_LeftTopRear: .topBackLeft
        case kAudioChannelLabel_TopBackRight, kAudioChannelLabel_RightTopRear: .topBackRight
        case kAudioChannelLabel_LeftTopMiddle: .topMiddleLeft
        case kAudioChannelLabel_RightTopMiddle: .topMiddleRight
        default: nil
        }
    }
}
