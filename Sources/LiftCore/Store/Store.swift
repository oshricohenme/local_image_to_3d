import Foundation
import GRDB

/// The SQLite database (`<workdir>/lift.sqlite`). Records are in Records.swift; queries live with their callers.
public final class Store: Sendable {
    public let db: DatabaseQueue

    public init(path: String) throws {
        db = try DatabaseQueue(path: path)
        try Self.migrator.migrate(db)
    }

    /// For tests.
    public init() throws {
        db = try DatabaseQueue()
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "job") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("priority", .text).notNull()
                t.column("position", .double).notNull()
                t.column("source", .text).notNull()
                t.column("state", .text).notNull().indexed()
                t.column("waitReason", .text)
                t.column("forceStart", .boolean).notNull()
                t.column("currentStep", .integer).notNull()
                t.column("error", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
            }
            try db.create(table: "step") { t in
                t.column("jobId", .text).notNull().references("job", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.primaryKey(["jobId", "idx"])
                t.column("recipe", .text).notNull()
                t.column("task", .text).notNull()
                t.column("inputs", .text).notNull()
                t.column("settings", .text).notNull()
                t.column("state", .text).notNull()
                t.column("waitReason", .text)
                t.column("stage", .text)
                t.column("fraction", .double)
                t.column("outputs", .text).notNull()
                t.column("error", .text)
                t.column("workerId", .text)
                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
            }
            try db.create(table: "event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("jobId", .text).notNull().indexed().references("job", onDelete: .cascade)
                t.column("stepIdx", .integer)
                t.column("at", .datetime).notNull()
                t.column("kind", .text).notNull()
                t.column("detail", .text).notNull()
            }
            try db.create(table: "worker") { t in
                t.primaryKey("id", .text)
                t.column("recipe", .text).notNull()
                t.column("pid", .integer).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("loadSeconds", .double)
                t.column("endedAt", .datetime)
                t.column("endReason", .text)
            }
            try db.create(table: "memorySample") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recipe", .text).notNull()
                t.column("task", .text).notNull()
                t.column("keyValues", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("bytes", .integer).notNull()
                t.column("at", .datetime).notNull()
            }
            try db.create(table: "weightHash") { t in
                t.primaryKey("path", .text)
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("sha256", .text).notNull()
            }
            try db.create(table: "weightCheck") { t in
                t.primaryKey("recipe", .text)
                t.column("at", .datetime).notNull()
                t.column("snapshots", .text).notNull()
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "job") { t in t.add(column: "memoryAccepted", .boolean).notNull().defaults(to: false) }
        }
        return m
    }
}

