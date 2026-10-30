import Foundation

/// A one-off narrowing of a clean-up, chosen in its sheet: an age other than the
/// owner's setting, and/or only the oldest part of it ("the oldest 5 GB"). The setting
/// itself is untouched. Every amount becomes an age, so backup, plan and removal all
/// run on the one `--older-than` they already understand.
public struct Scope: Hashable, Sendable {
    public enum Amount: Hashable, Sendable {
        case all
        case bytes(Int64)
        case percent(Int)
    }

    /// Nil keeps the clean-up's own age.
    public var age: Age?
    public var amount: Amount = .all

    public init(age: Age? = nil, amount: Amount = .all) {
        self.age = age
        self.amount = amount
    }

    public var isDefault: Bool { age == nil && amount == .all }
}

extension Recipe {
    /// The same clean-up with another age; nil means any age.
    public func withAge(_ a: Age?) -> Recipe {
        guard kind == .custom else {
            var r = self
            r.age = a
            return r
        }
        var f = filter
        f.olderThan = a?.description
        return Recipe(custom: f)
    }
}

extension Ledger {
    /// The clean-up narrowed to `scope`. An amount picks the oldest items on the phone,
    /// in the order they were taken, until it is reached, and becomes the age of the
    /// last one it needs: whole days, so it can take a few more from that same day.
    public static func scoped(_ db: SQLiteReader, _ recipe: Recipe, _ scope: Scope, now: Date = Date()) throws -> Recipe {
        let r = scope.age.map { recipe.withAge($0) } ?? recipe
        guard scope.amount != .all else { return r }
        let (w, args) = r.whereClause(now: now)
        let rows = try db.rows("""
            SELECT a.created_at_device, COALESCE(a.size_bytes, 0) FROM assets a
            WHERE a.present_on_phone = 1 AND \(w) AND a.created_at_device IS NOT NULL
            ORDER BY a.created_at_device, a.id
            """, args)
        let total = rows.reduce(Int64(0)) { $0 + Int64($1.int(1)) }
        let target: Int64
        switch scope.amount {
        case .all: target = total
        case .bytes(let b): target = b
        case .percent(let p): target = total * Int64(p) / 100
        }
        guard target < total else { return r }
        var sum: Int64 = 0
        for row in rows {
            sum += Int64(row.int(1))
            guard sum >= target else { continue }
            guard let taken = Fmt.date(row.str(0)) else { break }
            let days = Int(now.timeIntervalSince(taken) / 86_400)
            return r.withAge(Age(max(days, 0), "d"))
        }
        return r
    }
}
