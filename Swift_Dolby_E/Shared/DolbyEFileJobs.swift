// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import SwiftData
import CoreData
import CryptoKit
import Darwin

@available(macOS 14, *)
@Model
final class DolbyEFileJob {
    var id: UUID
    var signature: String
    var inputPath: String
    var outputPath: String
    var partialPath: String
    var sourceIdentity: String
    var sourceBookmark: Data
    var outputBookmark: Data
    // Keep the old columns for lightweight migration, but do not repeatedly
    // bridge unchanged nonempty Data attributes through persistence snapshots.
    var sourceBookmarkBase64: String = ""
    var outputBookmarkBase64: String = ""
    var sourceFrames: Int64
    var status: String
    var phase: String
    var checkpointData: Data
    var checkpointHash: String
    var lastError: String
    var created: Date
    var updated: Date

    var sourceBookmarkBytes:Data {
        get{sourceBookmarkBase64.isEmpty ? DolbyEOwnedMetadata(sourceBookmark):(Data(base64Encoded:sourceBookmarkBase64) ?? Data())}
        set{sourceBookmarkBase64=newValue.base64EncodedString();sourceBookmark=Data()}
    }
    var outputBookmarkBytes:Data {
        get{outputBookmarkBase64.isEmpty ? DolbyEOwnedMetadata(outputBookmark):(Data(base64Encoded:outputBookmarkBase64) ?? Data())}
        set{outputBookmarkBase64=newValue.base64EncodedString();outputBookmark=Data()}
    }
    func migrateBookmarkStorage()->Bool {
        var changed=false
        if !sourceBookmark.isEmpty{sourceBookmarkBytes=DolbyEOwnedMetadata(sourceBookmark);changed=true}
        if !outputBookmark.isEmpty{outputBookmarkBytes=DolbyEOwnedMetadata(outputBookmark);changed=true}
        return changed
    }

    init(signature: String, input: URL, output: URL, sourceIdentity: String, sourceFrames: UInt64) {
        let id = UUID()
        self.id = id
        self.signature = signature
        self.inputPath = input.standardizedFileURL.path
        self.outputPath = output.standardizedFileURL.path
        self.partialPath = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(id.uuidString).partial").path
        self.sourceIdentity = sourceIdentity
        self.sourceBookmark = Data()
        self.outputBookmark = Data()
        self.sourceFrames = Int64(sourceFrames)
        self.status = "created"
        self.phase = "processing"
        self.checkpointData = Data()
        self.checkpointHash = ""
        self.lastError = ""
        self.created = Date()
        self.updated = Date()
    }
}

final class DolbyEFileJobRecord: Codable {
    var id: UUID
    var signature: String
    var inputPath: String
    var outputPath: String
    var partialPath: String
    var sourceIdentity: String
    var sourceBookmark: Data
    var outputBookmark: Data
    // Keep the old columns for lightweight migration, but do not repeatedly
    // bridge unchanged nonempty Data attributes through persistence snapshots.
    var sourceBookmarkBase64: String = ""
    var outputBookmarkBase64: String = ""
    var sourceFrames: Int64
    var status: String
    var phase: String
    var checkpointData: Data
    var checkpointHash: String
    var lastError: String
    var created: Date
    var updated: Date

    var sourceBookmarkBytes:Data {
        get{sourceBookmarkBase64.isEmpty ? DolbyEOwnedMetadata(sourceBookmark):(Data(base64Encoded:sourceBookmarkBase64) ?? Data())}
        set{sourceBookmarkBase64=newValue.base64EncodedString();sourceBookmark=Data()}
    }
    var outputBookmarkBytes:Data {
        get{outputBookmarkBase64.isEmpty ? DolbyEOwnedMetadata(outputBookmark):(Data(base64Encoded:outputBookmarkBase64) ?? Data())}
        set{outputBookmarkBase64=newValue.base64EncodedString();outputBookmark=Data()}
    }
    func migrateBookmarkStorage()->Bool {
        var changed=false
        if !sourceBookmark.isEmpty{sourceBookmarkBytes=DolbyEOwnedMetadata(sourceBookmark);changed=true}
        if !outputBookmark.isEmpty{outputBookmarkBytes=DolbyEOwnedMetadata(outputBookmark);changed=true}
        return changed
    }

    init(signature: String, input: URL, output: URL, sourceIdentity: String, sourceFrames: UInt64) {
        let id = UUID()
        self.id = id
        self.signature = signature
        self.inputPath = input.standardizedFileURL.path
        self.outputPath = output.standardizedFileURL.path
        self.partialPath = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(id.uuidString).partial").path
        self.sourceIdentity = sourceIdentity
        self.sourceBookmark = Data()
        self.outputBookmark = Data()
        self.sourceFrames = Int64(sourceFrames)
        self.status = "created"
        self.phase = "processing"
        self.checkpointData = Data()
        self.checkpointHash = ""
        self.lastError = ""
        self.created = Date()
        self.updated = Date()
    }
}

public struct DolbyEFileResult: Codable, Sendable {
    public let outputURL: URL
    public let jobID: String
    public let program: DolbyEProgram
    public let frameRate: DolbyEFrameRate
    public let inputFrames: UInt64
    public let outputFrames: UInt64
    public let videoFrames: UInt64
    public let resumed: Bool
    public var boundaryInfo: DolbyEStreamBoundaryInfo? = nil
    public var encodeVision: DolbyEEncodeVision = .e
    public var additionalOutputURLs: [URL] = []
    public var clippedSamples: UInt64 = 0
    public var loudness: [DolbyEProgrammeLoudnessReport]? = nil
}

/// Kept inside the processing actor that creates it. The job store contains only
/// source identity, progress and bounded codec checkpoints, never whole media.
final class DolbyEFileJobStore {
    private let persistence: any DolbyEJobPersistence
    private let legacy: DolbyECoreDataJobs?
    let directory: URL

    @available(macOS 14, *)
    var context: ModelContext { (persistence as! DolbyESwiftDataJobs).context }

    init(operation: String, directory override: URL? = nil, legacyPersistence: Bool = false) throws {
        let directory = try override ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SwiftDolbyE/Jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let legacyURL = directory.appendingPathComponent("\(operation).compat.store")
        if #available(macOS 14, *), !legacyPersistence {
            persistence = try DolbyESwiftDataJobs(operation: operation, directory: directory)
            legacy = FileManager.default.fileExists(atPath: legacyURL.path) ? try DolbyECoreDataJobs(url: legacyURL) : nil
        } else {
            persistence = try DolbyECoreDataJobs(url: legacyURL)
            legacy = nil
        }
    }

    func active(output: URL) throws -> DolbyEFileJobRecord? {
        var value = try persistence.active(path: output.standardizedFileURL.path)
        if value == nil, let legacy, let candidate = try legacy.active(path: output.standardizedFileURL.path) {
            // Import older-system checkpoints once when this job is next opened
            // on a SwiftData-capable OS. Never reinterpret an existing SwiftData store.
            if try !persistence.contains(id: candidate.id) {
                try persistence.persist(candidate)
                value = candidate
            }
            try legacy.retire(id: candidate.id)
        }
        if value?.migrateBookmarkStorage() == true, let value { try persistence.persist(value) }
        return value
    }

    func resumable(output: URL, signature: String) throws -> DolbyEFileJobRecord? {
        guard let job = try active(output: output) else { return nil }
        if job.signature == signature { return job }
        if job.checkpointData.isEmpty && !FileManager.default.fileExists(atPath: job.partialPath) {
            try update(job, status: "superseded")
            return nil
        }
        throw DolbyEError.invalidArgument("an unfinished output uses different source/settings; resume with its original options")
    }

    func insert(_ job: DolbyEFileJobRecord) throws {
        _=job.migrateBookmarkStorage()
        try persistence.persist(job)
    }

    func restore<T: Decodable>(_ type: T.Type, from job: DolbyEFileJobRecord) throws -> T? {
        let data=DolbyEOwnedMetadata(job.checkpointData)
        if data.isEmpty { return nil }
        guard Self.hash(data) == job.checkpointHash else {
            throw DolbyEError.malformed("processing checkpoint integrity failed for job \(job.id)")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ checkpoint: T, job: DolbyEFileJobRecord, complete: Bool, phase: String = "processing") throws {
        let data = try JSONEncoder().encode(checkpoint)
        guard data.count <= 4 * 1024 * 1024 else { throw DolbyEError.invalidArgument("codec checkpoint exceeds bounded state size") }
        job.checkpointData = DolbyEOwnedMetadata(data)
        job.checkpointHash = Self.hash(data)
        job.phase = complete ? "finalizing" : phase
        job.status = "running"
        job.updated = Date()
        try persistence.persist(job)
    }

    func update(_ job: DolbyEFileJobRecord, status: String, error: String = "") throws {
        job.status = status
        job.lastError = error
        job.updated = Date()
        try persistence.persist(job)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func signature(_ request: DolbyERequest, operation: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadata = (try? encoder.encode(request.ac3Metadata)).map(hash) ?? "default"
        var text = "codec-file-v18|\(operation)|\(request.inputURL.standardizedFileURL.path)|\(request.outputURL.standardizedFileURL.path)"
            + "|\(request.program.rawValue)|\(request.frameRate?.rawValue ?? "auto")|\(request.format.rawValue)|\(request.inputLayout.rawValue)|\(metadata)|\(request.decodeSelection.rawValue)|\(request.downmixMode.rawValue)"
            + "|\(request.encodeVision.rawValue)|\(request.dialogueSource.rawValue)|\(request.secondaryInputURL?.standardizedFileURL.path ?? "")"
        if let layout = request.decodeLayout { text += "|render=\(layout.rawValue)" }
        if let loudness=request.loudness {text += "|loudness-v22="+((try? encoder.encode(loudness)).map(hash) ?? "invalid")}
        if operation == "decode", request.decodeSelection != .all { text += "|speaker-render-v2" }
        return hash(Data(text.utf8))
    }

    static func identity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modification = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let first = try readBytes(handle, at: 0, count: Int(min(size, 65536)))
        let last = try readBytes(handle, at: size - min(size, 65536), count: Int(min(size, 65536)))
        return "\(size)|\(modification)|\(inode)|\(hash(first))|\(hash(last))"
    }
}


private protocol DolbyEJobPersistence: AnyObject {
    func active(path: String) throws -> DolbyEFileJobRecord?
    func contains(id: UUID) throws -> Bool
    func persist(_ job: DolbyEFileJobRecord) throws
}

/// Keeps the original entity and store schema on systems that support SwiftData.
@available(macOS 14, *)
private final class DolbyESwiftDataJobs: DolbyEJobPersistence {
    let context: ModelContext
    private let container: ModelContainer
    init(operation: String, directory: URL) throws {
        let configuration = ModelConfiguration("DolbyE-\(operation)",
            url: directory.appendingPathComponent("\(operation).store"), cloudKitDatabase: .none)
        container = try ModelContainer(for: DolbyEFileJob.self, configurations: configuration)
        context = ModelContext(container)
        context.autosaveEnabled = false
    }
    func active(path: String) throws -> DolbyEFileJobRecord? {
        var query = FetchDescriptor<DolbyEFileJob>(predicate: #Predicate {
            $0.outputPath == path && $0.status != "completed" && $0.status != "superseded"
        }, sortBy: [SortDescriptor(\DolbyEFileJob.updated, order: .reverse)])
        query.fetchLimit = 1
        guard let model = try context.fetch(query).first else { return nil }
        let record = DolbyEFileJobRecord(signature: model.signature, input: URL(fileURLWithPath: model.inputPath),
            output: URL(fileURLWithPath: model.outputPath), sourceIdentity: model.sourceIdentity, sourceFrames: 0)
        record.id = model.id
        record.signature = model.signature
        record.inputPath = model.inputPath
        record.outputPath = model.outputPath
        record.partialPath = model.partialPath
        record.sourceIdentity = model.sourceIdentity
        record.sourceBookmark = DolbyEOwnedMetadata(model.sourceBookmark)
        record.outputBookmark = DolbyEOwnedMetadata(model.outputBookmark)
        record.sourceBookmarkBase64 = model.sourceBookmarkBase64
        record.outputBookmarkBase64 = model.outputBookmarkBase64
        record.sourceFrames = model.sourceFrames
        record.status = model.status
        record.phase = model.phase
        record.checkpointData = DolbyEOwnedMetadata(model.checkpointData)
        record.checkpointHash = model.checkpointHash
        record.lastError = model.lastError
        record.created = model.created
        record.updated = model.updated
        return record
    }
    private func model(id: UUID) throws -> DolbyEFileJob? {
        var query = FetchDescriptor<DolbyEFileJob>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }
    func contains(id: UUID) throws -> Bool { try model(id: id) != nil }
    func persist(_ record: DolbyEFileJobRecord) throws {
        let value: DolbyEFileJob
        if let existing = try model(id: record.id) { value = existing }
        else {
            value = DolbyEFileJob(signature: record.signature, input: URL(fileURLWithPath: record.inputPath),
                output: URL(fileURLWithPath: record.outputPath), sourceIdentity: record.sourceIdentity, sourceFrames: 0)
            context.insert(value)
        }
        value.id = record.id
        value.signature = record.signature
        value.inputPath = record.inputPath
        value.outputPath = record.outputPath
        value.partialPath = record.partialPath
        value.sourceIdentity = record.sourceIdentity
        value.sourceBookmark = record.sourceBookmark
        value.outputBookmark = record.outputBookmark
        value.sourceBookmarkBase64 = record.sourceBookmarkBase64
        value.outputBookmarkBase64 = record.outputBookmarkBase64
        value.sourceFrames = record.sourceFrames
        value.status = record.status
        value.phase = record.phase
        value.checkpointData = record.checkpointData
        value.checkpointHash = record.checkpointHash
        value.lastError = record.lastError
        value.created = record.created
        value.updated = record.updated
        try context.save()
    }
}

/// macOS 12/13 store only bounded metadata/checkpoint records in a separate
/// SQLite schema. Managed objects never escape the owning context's queue.
private final class DolbyECoreDataJobs: DolbyEJobPersistence {
    private let context: NSManagedObjectContext
    init(url: URL) throws {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "DolbyEJobRecord"
        entity.managedObjectClassName = "NSManagedObject"
        entity.properties = [("id", NSAttributeType.UUIDAttributeType), ("outputPath", .stringAttributeType),
                             ("status", .stringAttributeType), ("updated", .dateAttributeType),
                             ("payload", .binaryDataAttributeType)].map { name, type in
            let attribute = NSAttributeDescription()
            attribute.name = name; attribute.attributeType = type; attribute.isOptional = false
            return attribute
        }
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
    }
    private static func fetch(_ context: NSManagedObjectContext, _ predicate: NSPredicate) throws -> NSManagedObject? {
        let query = NSFetchRequest<NSManagedObject>(entityName: "DolbyEJobRecord")
        query.predicate = predicate; query.fetchLimit = 1
        query.sortDescriptors = [NSSortDescriptor(key: "updated", ascending: false)]
        return try context.fetch(query).first
    }
    func active(path: String) throws -> DolbyEFileJobRecord? {
        let context = self.context
        return try context.performAndWait {
            guard let value = try Self.fetch(context, NSPredicate(format: "outputPath == %@ AND NOT (status IN %@)",
                path, ["completed", "superseded", "migrated"])), let data = value.value(forKey: "payload") as? Data else { return nil }
            guard data.count <= 8 * 1024 * 1024 else { throw DolbyEError.malformed("job record exceeds bounded metadata size") }
            let record = try JSONDecoder().decode(DolbyEFileJobRecord.self, from: data)
            guard record.id == value.value(forKey: "id") as? UUID, record.outputPath == path,
                  record.status == value.value(forKey: "status") as? String else { throw DolbyEError.malformed("job record identity mismatch") }
            return record
        }
    }
    func contains(id: UUID) throws -> Bool {
        let context = self.context
        return try context.performAndWait { try Self.fetch(context, NSPredicate(format: "id == %@", id as NSUUID)) != nil }
    }
    func persist(_ job: DolbyEFileJobRecord) throws {
        let data = try JSONEncoder().encode(job)
        guard data.count <= 8 * 1024 * 1024 else { throw DolbyEError.invalidArgument("job record exceeds bounded metadata size") }
        let context = self.context
        let id = job.id, path = job.outputPath, status = job.status, updated = job.updated
        try context.performAndWait {
            let value = try Self.fetch(context, NSPredicate(format: "id == %@", id as NSUUID))
                ?? NSEntityDescription.insertNewObject(forEntityName: "DolbyEJobRecord", into: context)
            value.setValue(id, forKey: "id"); value.setValue(path, forKey: "outputPath")
            value.setValue(status, forKey: "status"); value.setValue(updated, forKey: "updated")
            value.setValue(data, forKey: "payload")
            try context.save()
        }
    }
    func retire(id: UUID) throws {
        let context = self.context
        try context.performAndWait {
            if let value = try Self.fetch(context, NSPredicate(format: "id == %@", id as NSUUID)) {
                value.setValue("migrated", forKey: "status")
                try context.save()
            }
        }
    }
}

/// A process-wide filesystem lock prevents concurrent writers from resuming the
/// same partial output. Lock files are metadata and contain no source audio.
final class DolbyEOutputLock {
    private let descriptor: Int32

    init(output: URL, directory: URL) throws {
        let path = directory.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let name = DolbyEFileJobStore.hash(Data(output.standardizedFileURL.path.utf8)) + ".lock"
        let descriptor = Darwin.open(path.appendingPathComponent(name).path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var record = Darwin.flock()
        record.l_type = Int16(F_WRLCK)
        record.l_whence = Int16(SEEK_SET)
        // Descriptor-owned locks exclude writers even when both static frameworks
        // are loaded into one process. Process-owned F_SETLK would not do so.
        guard Darwin.fcntl(descriptor, F_OFD_SETLK, &record) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EAGAIN || code == EACCES {
                throw DolbyEError.invalidArgument("another process is writing this output")
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = descriptor
    }

    deinit {
        var record = Darwin.flock()
        record.l_type = Int16(F_UNLCK)
        record.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_OFD_SETLK, &record)
        Darwin.close(descriptor)
    }
}

final class DolbyESecurityAccess {
    let url: URL
    let bookmark: Data
    private var started: Bool

    init(url: URL, bookmark: Data = Data(), createBookmark: Bool = true) {
        var stale = false
        let resolved = bookmark.isEmpty ? nil : try? URL(resolvingBookmarkData: bookmark,
            options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        self.url = resolved ?? url
        self.started = self.url.startAccessingSecurityScopedResource()
        let stored = createBookmark ? ((try? self.url.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)) ?? bookmark) : bookmark
        self.bookmark=DolbyEOwnedMetadata(stored)
    }

    func stop() {
        if started { url.stopAccessingSecurityScopedResource(); started = false }
    }

    deinit { stop() }
}
