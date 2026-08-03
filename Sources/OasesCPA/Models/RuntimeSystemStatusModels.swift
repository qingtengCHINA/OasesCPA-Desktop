import Foundation

struct RuntimeSystemStatus: Decodable, Sendable {
    let service: String
    let dbPath: String?
    let events: Int64?
    let deadLetters: Int64?
    let collector: RuntimeCollectorStatus?
    let dataMigration: RuntimeDataMigrationStatus?
}

struct RuntimeCollectorStatus: Decodable, Sendable {
    let collector: String?
    let upstream: String?
    let mode: String?
    let transport: String?
    let queue: String?
    let lastConsumedAt: Int64?
    let lastInsertedAt: Int64?
    let totalInserted: Int64?
    let totalSkipped: Int64?
    let deadLetters: Int64?
    let lastError: String?
}

struct RuntimeDataMigrationStatus: Decodable, Sendable {
    let name: String?
    let status: String?
    let lastEventId: Int64?
    let targetEventId: Int64?
    let processedRows: Int64?
    let changedRows: Int64?
    let startedAtMs: Int64?
    let updatedAtMs: Int64?
    let finishedAtMs: Int64?
}
