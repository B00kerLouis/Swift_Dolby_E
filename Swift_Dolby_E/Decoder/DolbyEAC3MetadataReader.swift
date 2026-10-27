// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

enum DolbyEAC3MetadataReader {
    static func read(_ bits: inout DolbyEBitReader, programs: Int) throws -> [DolbyEAC3ProgramInfo] {
        let id = try bits.read(bits: 4)
        if id == 0 { return [] }
        let length = Int(try bits.read(bits: 12))
        guard id == 1, length >= programs * 121 else { throw DolbyEError.malformed("AC-3 metadata segment identifier or size") }
        var result: [DolbyEAC3ProgramInfo] = []
        for _ in 0..<programs {
            let rate = UInt8(try bits.read(bits: 5)), service = UInt8(try bits.read(bits: 3)), mode = UInt8(try bits.read(bits: 3))
            let center = UInt8(try bits.read(bits: 2)), surround = UInt8(try bits.read(bits: 2)), dsur = UInt8(try bits.read(bits: 2))
            let lfe = try bits.read(bits: 1) != 0, dialogue = -Int(try bits.read(bits: 5))
            let languagePresent = try bits.read(bits: 1) != 0, language = UInt8(try bits.read(bits: 8))
            let production = try bits.read(bits: 1) != 0, mixing = Int(try bits.read(bits: 5)) + 80, room = UInt8(try bits.read(bits: 2))
            let copyright = try bits.read(bits: 1) != 0, original = try bits.read(bits: 1) != 0
            let extendedMixPresent = try bits.read(bits: 1) != 0, extendedMix = UInt16(try bits.read(bits: 14))
            let extendedPresent = try bits.read(bits: 1) != 0, extended = UInt16(try bits.read(bits: 14))
            let hp = try bits.read(bits: 1) != 0, bw = try bits.read(bits: 1) != 0, lpf = try bits.read(bits: 1) != 0
            let phase = try bits.read(bits: 1) != 0, attenuation = try bits.read(bits: 1) != 0, preemphasis = try bits.read(bits: 1) != 0
            let rfIsGain = try bits.read(bits: 1) != 0, rf = UInt8(try bits.read(bits: 8))
            let lineIsGain = try bits.read(bits: 1) != 0
            var line: [UInt8] = []
            for _ in 0..<4 { line.append(UInt8(try bits.read(bits: 8))) }
            result.append(DolbyEAC3ProgramInfo(bitRateCode: rate, serviceMode: service, audioCodingMode: mode,
                centerMixLevel: center, surroundMixLevel: surround, dolbySurroundMode: dsur, lfe: lfe, dialogueLevel: dialogue,
                languagePresent: languagePresent, languageCode: language, productionInformation: production, mixingLevel: mixing,
                roomType: room, copyright: copyright, originalBitstream: original, extendedMixPresent: extendedMixPresent,
                extendedMix: extendedMix, extendedBitstreamPresent: extendedPresent, extendedBitstream: extended,
                highPassFilter: hp, bandwidthLowPassFilter: bw, lfeLowPassFilter: lpf, surroundPhase90: phase,
                surroundAttenuation: attenuation, rfPreEmphasis: preemphasis, rfIsGainWord: rfIsGain, rfCode: rf,
                lineIsGainWord: lineIsGain, lineCodes: line))
        }
        // The section includes one additional reserved bit per program after
        // all 120-bit records, hence the declared 121*programCount length.
        for _ in 0..<programs { _ = try bits.read(bits: 1) }
        return result
    }
}
