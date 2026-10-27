// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

// Registered MXF property identifiers, ST 377-1 / ST 382. These are data
// identifiers, not an implementation imported from a third-party library.
enum DolbyEMXFPropertyLabels {
    static let values: [UInt16: Data] = [
        0x0201: DolbyEMXFKLV.ul("060e2b34010101020407010000000000"), // DataDefinition
        0x0202: DolbyEMXFKLV.ul("060e2b34010101020702020101030000"), // Duration
        0x1001: DolbyEMXFKLV.ul("060e2b34010101020601010406090000"), // StructuralComponents
        0x1101: DolbyEMXFKLV.ul("060e2b34010101020601010301000000"), // SourcePackageID
        0x1102: DolbyEMXFKLV.ul("060e2b34010101020601010302000000"), // SourceTrackID
        0x1201: DolbyEMXFKLV.ul("060e2b34010101020702010301040000"), // StartPosition
        0x1901: DolbyEMXFKLV.ul("060e2b34010101020601010405010000"), // Packages
        0x1902: DolbyEMXFKLV.ul("060e2b34010101020601010405020000"), // EssenceContainerData
        0x2701: DolbyEMXFKLV.ul("060e2b34010101020601010601000000"), // LinkedPackageUID
        0x3001: DolbyEMXFKLV.ul("060e2b34010101010406010100000000"), // SampleRate
        0x3002: DolbyEMXFKLV.ul("060e2b34010101010406010200000000"), // ContainerDuration
        0x3004: DolbyEMXFKLV.ul("060e2b34010101020601010401020000"), // EssenceContainer
        0x3006: DolbyEMXFKLV.ul("060e2b34010101050601010305000000"), // LinkedTrackID
        0x3b02: DolbyEMXFKLV.ul("060e2b34010101020702011002040000"), // LastModifiedDate
        0x3b03: DolbyEMXFKLV.ul("060e2b34010101020601010402010000"), // ContentStorage
        0x3b05: DolbyEMXFKLV.ul("060e2b34010101020301020105000000"), // Version
        0x3b06: DolbyEMXFKLV.ul("060e2b34010101020601010406040000"), // Identifications
        0x3b07: DolbyEMXFKLV.ul("060e2b34010101020301020104000000"), // ObjectModelVersion
        0x3b08: DolbyEMXFKLV.ul("060e2b34010101040601010401080000"), // PrimaryPackage
        0x3b09: DolbyEMXFKLV.ul("060e2b34010101050102020300000000"), // OperationalPattern
        0x3b0a: DolbyEMXFKLV.ul("060e2b34010101050102021002010000"), // EssenceContainers
        0x3b0b: DolbyEMXFKLV.ul("060e2b34010101050102021002020000"), // DMSchemes
        0x3c01: DolbyEMXFKLV.ul("060e2b34010101020520070102010000"), // CompanyName
        0x3c02: DolbyEMXFKLV.ul("060e2b34010101020520070103010000"), // ProductName
        0x3c04: DolbyEMXFKLV.ul("060e2b34010101020520070105010000"), // VersionString
        0x3c05: DolbyEMXFKLV.ul("060e2b34010101020520070107000000"), // ProductUID
        0x3c06: DolbyEMXFKLV.ul("060e2b34010101020702011002030000"), // ModificationDate
        0x3c09: DolbyEMXFKLV.ul("060e2b34010101020520070101000000"), // ThisGenerationUID
        0x3c0a: DolbyEMXFKLV.ul("060e2b34010101010101150200000000"), // InstanceUID
        0x3d01: DolbyEMXFKLV.ul("060e2b34010101040402030304000000"), // QuantizationBits
        0x3d02: DolbyEMXFKLV.ul("060e2b34010101040402030104000000"), // Locked
        0x3d03: DolbyEMXFKLV.ul("060e2b34010101050402030101010000"), // AudioSamplingRate
        0x3d06: DolbyEMXFKLV.ul("060e2b34010101020402040200000000"), // SoundEssenceCompression
        0x3d07: DolbyEMXFKLV.ul("060e2b34010101050402010104000000"), // ChannelCount
        0x3d09: DolbyEMXFKLV.ul("060e2b34010101050402030305000000"), // AvgBps
        0x3d0a: DolbyEMXFKLV.ul("060e2b34010101050402030201000000"), // BlockAlign
        0x3f01: DolbyEMXFKLV.ul("060e2b340101010406010104060b0000"), // MultipleDescriptor :: SubDescriptorUIDs
        0x3f06: DolbyEMXFKLV.ul("060e2b34010101040103040500000000"), // IndexSID
        0x3f07: DolbyEMXFKLV.ul("060e2b34010101040103040400000000"), // EssenceStreamID
        0x4401: DolbyEMXFKLV.ul("060e2b34010101010101151000000000"), // PackageUID
        0x4402: DolbyEMXFKLV.ul("060e2b34010101010103030201000000"), // Name
        0x4403: DolbyEMXFKLV.ul("060e2b34010101020601010406050000"), // Tracks
        0x4404: DolbyEMXFKLV.ul("060e2b34010101020702011002050000"), // PackageModifiedDate
        0x4405: DolbyEMXFKLV.ul("060e2b34010101020702011001030000"), // PackageCreationDate
        0x4701: DolbyEMXFKLV.ul("060e2b34010101020601010402030000"), // Descriptor
        0x4801: DolbyEMXFKLV.ul("060e2b34010101020107010100000000"), // TrackID
        0x4803: DolbyEMXFKLV.ul("060e2b34010101020601010402040000"), // Sequence
        0x4804: DolbyEMXFKLV.ul("060e2b34010101020104010300000000"), // TrackNumber
        0x4b01: DolbyEMXFKLV.ul("060e2b34010101020530040500000000"), // EditRate
        0x4b02: DolbyEMXFKLV.ul("060e2b34010101020702010301030000"), // Origin
    ]
}
