// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

enum DolbyECodecBands {
    static let short = [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,3,3,3,4,4,4,5,5,6,6,7,8,9,10,11,12]
    static let medium = [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,3,3,3,3,4,4,5,5,6,7,7,8,9,10,11,12,13,15,16,18,20,22,25]

    static func sizes(kind: Int) -> [Int] {
        switch kind {
        case 38: return short
        case 44: return medium
        case 21: return Array(DolbyESpectralAllocation.longBandSizes.prefix(21))
        default: return DolbyESpectralAllocation.longBandSizes
        }
    }

    static func kinds(blockType: Int) -> [Int] {
        switch blockType {
        case 0, 4: return Array(repeating: 38, count: 8)
        case 1: return Array(repeating: 38, count: 6) + [44]
        case 5: return [44] + Array(repeating: 38, count: 6)
        case 3, 7: return [21]
        default: return [50]
        }
    }

    static func groups(kind: Int, bandwidth: Int) -> [Int] {
        switch kind {
        case 21: return [21]
        case 38: return [12, 26 - bandwidth]
        case 44: return [19, 25 - bandwidth]
        default: return [27, 23 - bandwidth]
        }
    }
}
