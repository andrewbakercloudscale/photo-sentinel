import PhotoCore
import SwiftUI

/// Removing a clean-up from the phone, in the order the owner asked for:
/// prove Google Drive has it, plan it, type the phrase, remove, then show the proof.
///
/// Every step is a CLI task (TaskStore), so the sheet only reads their results. Closing it,
/// or the app, never stops a step; reopening shows where it got to.
struct RemovalSheet: View {
    @ObservedObject var model: Model
    /// The clean-up as the owner set it up; `recipe` is it narrowed to this time's scope.
    let base: Recipe
    /// ImageRenderer draws nothing inside a ScrollView, so `--snapshot` turns it off.
    var scrolls = true
    @State private var typed = ""
    @State private var proof: Proof?
    @State private var routes: [Route]?

    /// An audit counts for six hours: long enough to plan and remove after it, short
    /// enough that a Drive change since is unlikely. The removal re-checks Drive anyway.
    private static let auditLife: TimeInterval = 6 * 3600
    /// This time only: an age other than the setting, or just the oldest part.
    @State private var scope = Scope()
    @State private var scoped: (recipe: Recipe, stats: RecipeStats)?
    private var recipe: Recipe { scope.isDefault ? base : scoped?.recipe ?? base }
    private var stats: RecipeStats? {
        scope.isDefault ? model.library?.recipes.first { $0.id == base.id } : scoped?.stats
    }
    private var audit: TaskStatus? { model.latest(.audit) }
    private var lastRemoval: TaskStatus? { model.latest(.remove, recipe: recipe) }
    /// A removal that had already finished when the sheet opened. The sheet starts from a
    /// fresh Remove step then, with that one shown only as "Last time".
    @State private var spent: String?
    private var usedUp: Bool { spent != nil && lastRemoval?.task.id == spent }
    private var removal: TaskStatus? { usedUp ? nil : lastRemoval }

    private var auditReport: AuditReport? { audit?.decode(AuditReport.self) }
    private var auditFresh: Bool {
        guard let a = audit, !a.running else { return false }
        return Date().timeIntervalSince(a.task.startedAt) < Self.auditLife
    }
    private var driveConfirmed: Bool { auditFresh && auditReport?.clean == true }
    /// The removal re-reads every item's hash from Google Drive itself, so the whole-Drive check is extra assurance, not a gate. Only a check that found Drive
    /// missing something, or one still running, holds the removal back.
    private var driveBlocks: Bool { (audit?.running ?? false) || auditReport?.clean == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SymbolTile(symbol: recipe.symbol, color: Tab.cleanUp.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.title).font(.title2.weight(.bold))
                    Text(base.detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                CapsuleButton(title: "Close", symbol: "xmark", color: Theme.bad) { model.removing = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            if scrolls { ScrollView { steps } } else { steps }
        }
        // A range, not a size: the sheet then has a resize edge.
        .frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity, minHeight: 520, idealHeight: 760, maxHeight: .infinity)
        .background(Color(light: "#f5f5f7", dark: "#1c1c1f"))
        .onChange(of: removal?.running) { loadProof() }
        .task(id: scope) { await rescope() }
        .onChange(of: recipe) { routes = loadRoutes() }
        .onChange(of: model.storage?.destinations) { routes = loadRoutes() }
        .onAppear {
            if let r = lastRemoval, !r.running, r.errorMessage == nil { spent = r.task.id }
            loadProof(); routes = loadRoutes()
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            WhereTheyGo(model: model, routes: routes ?? loadRoutes())
            ScopeCard(base: base, scope: $scope, scoped: scope.isDefault ? nil : scoped?.recipe, stats: stats,
                      locked: removal?.running == true)
            backupStep
            driveStep
            removeStep
            proofStep
        }
        .padding(18)
    }

    private func rescope() async {
        guard !scope.isDefault else { scoped = nil; return }
        let (path, base, scope) = (model.ledgerPath, base, scope)
        let result = await Task.detached { () -> (Recipe, RecipeStats)? in
            let db = try? SQLiteReader(path: path)
            guard let db, let r = try? Ledger.scoped(db, base, scope), let st = try? Ledger.stats(db, r) else { return nil }
            return (r, st)
        }.value
        if let result { scoped = (result.0, result.1) }
    }

    // MARK: 1. Back up whatever is not in Drive yet

    @ViewBuilder private var backupStep: some View {
        let missing = stats?.notBackedUp ?? Tally()
        Step(number: 1, title: "Back up", done: missing.count == 0) {
            if missing.count == 0 {
                Text("Everything this clean-up selects is already in \(Backup.name).").font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Fmt.count(missing.count)) items (\(Fmt.bytes(missing.bytes))) are only on the phone. They are never removed until \(Backup.name) has them. You can still remove the rest now.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if recipe.backups.isEmpty {
                        Text("Back these up with the Camera videos and Screen recordings clean-ups.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        let queued = model.queue.filter { q in recipe.backups.contains { $0.source == q.source && $0.type == q.type } }
                        let running = model.jobs.contains { j in
                            if case .running = j.state { return recipe.backups.contains { $0.source == j.source } }
                            return false
                        }
                        HStack {
                            if running {
                                Pill(text: "Backing up now", symbol: "icloud.and.arrow.up.fill", color: Theme.good)
                                CapsuleButton(title: "Open Activity", symbol: "waveform.path.ecg", color: Tab.activity.color, style: .ghost) {
                                    model.removing = nil
                                    model.tab = .activity
                                }
                            } else if !queued.isEmpty {
                                if let ahead = model.runningBackup {
                                    Pill(text: "Waiting for the \(ahead.title) backup to end", symbol: "clock.fill", color: Theme.warn)
                                    CapsuleButton(title: "Back these up first", symbol: "arrow.up.to.line", color: Tab.backup.color) { model.backUpFirst(recipe) }
                                        .help("Stops the \(ahead.title) backup, backs these up, then carries on with \(ahead.title) from where it was. Nothing is lost: what is already in \(Backup.name) stays there.")
                                } else {
                                    Pill(text: "Queued · starting", symbol: "clock.fill", color: Theme.warn)
                                }
                            } else {
                                CapsuleButton(title: "Back up to \(Backup.name)", symbol: "icloud.and.arrow.up.fill", color: Tab.backup.color) { model.backUp(recipe) }
                            }
                        }
                        if running, let step = model.jobs.first(where: { j in j.state == .running && recipe.backups.contains { $0.source == j.source } })?.step {
                            Text(step.prefix(1).uppercased() + step.dropFirst() + ".").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 2. Confirm Google Drive holds everything it is said to hold

    @ViewBuilder private var driveStep: some View {
        Step(number: 2, title: "Check all of \(Backup.name) (optional)", done: driveConfirmed) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Re-reads the SHA-256 of every file in \(Backup.name) and compares it with the hash taken when it was copied off the phone. Takes about 7 minutes. You can skip it: the removal re-checks each item it removes in \(Backup.name) anyway.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let a = audit, a.running {
                    Running(text: "Asking \(Backup.name) for every file's hash (about 7 minutes)…", since: a.task.startedAt)
                } else if let r = auditReport, auditFresh {
                    AuditSummary(report: r, at: audit!.task.startedAt)
                    if !r.clean { Text("Removal stays locked until this is clean.").font(.callout.weight(.semibold)).foregroundStyle(Theme.bad) }
                } else if let msg = audit?.errorMessage, auditFresh {
                    Text("The check could not finish: \(msg)").font(.callout).foregroundStyle(Theme.bad)
                } else if let a = audit {
                    // Without this the step shows only a button, and nothing says why 3 and 4 are locked.
                    Text("Last checked \(a.task.startedAt.formatted(date: .abbreviated, time: .shortened))\(auditReport?.clean == true ? ", and everything matched" : "").")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !(audit?.running ?? false) && !driveConfirmed || (auditReport != nil && !auditFresh) {
                    CapsuleButton(title: audit == nil ? "Check \(Backup.name)" : "Check again", symbol: "checkmark.shield.fill", color: Theme.good, style: .soft) { model.runAudit() }
                }
            }
        }
    }

    // MARK: 3. Remove: one run plans afresh, re-checks Google Drive, then removes

    @ViewBuilder private var removeStep: some View {
        let done = removal.map { !$0.running && $0.errorMessage == nil } ?? false
        let estimate = stats?.removableNow.count ?? 0
        Step(number: 3, title: "Remove from iPhone", done: done, locked: driveBlocks && removal == nil) {
            VStack(alignment: .leading, spacing: 10) {
                if let r = removal, r.running {
                    Text("Removing \(recipe.title.lowercased()) that are safe in \(Backup.name), and nothing else.")
                        .font(.body.weight(.semibold))
                    Running(text: (r.progressText ?? "Getting ready") + "…", since: r.task.startedAt)
                    Text("It checks each one is still on the phone and re-checks its copy in \(Backup.name). Everything else is only read, never changed. Then macOS asks to allow deleting them, with the exact count: click Delete in that box.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if done, let r = removal?.decode(RemovalPlan.self) {
                    Text("Removed \(Fmt.count(r.removed ?? 0)) items, \(Fmt.bytes(r.bytesRemoved ?? 0)).")
                        .font(.body.weight(.semibold)).foregroundStyle(Theme.good)
                    Text("They are in Recently Deleted on the phone for 30 days. Space comes back when that empties.")
                        .font(.callout).foregroundStyle(.secondary)
                    if r.blocked > 0 { PlanSummary(plan: r, kept: true) }
                } else if driveBlocks {
                    Text((audit?.running ?? false) ? "Unlocks when the \(Backup.name) check in step 2 finishes." : "Locked: the \(Backup.name) check in step 2 found problems. Fix them and check again.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    if usedUp, let last = lastRemoval?.decode(RemovalPlan.self) {
                        Text("Last time: removed \(Fmt.count(last.removed ?? 0)) items, \(Fmt.bytes(last.bytesRemoved ?? 0)), on \(lastRemoval!.task.startedAt.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.callout).foregroundStyle(Theme.good)
                    }
                    let missing = stats?.notBackedUp.count ?? 0
                    if estimate == 0 && missing > 0 {
                        // Running it now would only check them all to say this.
                        Callout(text: "Nothing can come off yet: none of the \(Fmt.count(missing)) are in \(Backup.name). Back them up in step 1 above. Remove opens here when that finishes.")
                    } else {
                        if let msg = removal?.errorMessage, !usedUp {
                            Callout(text: msg.contains("nothing is safe to remove")
                                    ? "Nothing was removed: none of them are safely in \(Backup.name) yet. Back them up in step 1 above."
                                    : "The last try stopped: \(msg)")
                        }
                        removeForm(estimate: estimate)
                    }
                }
            }
        }
    }

    @ViewBuilder private func removeForm(estimate: Int) -> some View {
        Text("Removes \(estimate > 0 ? "about \(Fmt.count(estimate)) " : "")\(recipe.title.lowercased()) whose copy in \(Backup.name) is checked again first. Anything not safely there stays on the phone. Removed items go to Recently Deleted for 30 days, on this iPhone and every device on the same iCloud account.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        Text("Type Confirm to start:").font(.callout)
        HStack {
            TextField("Confirm", text: $typed).textFieldStyle(.roundedBorder)
                .onSubmit { start() }
            CapsuleButton(title: "Remove", symbol: "trash.fill", color: confirmed ? Theme.bad : .secondary) { start() }
                .disabled(!confirmed)
        }
        Text("Takes about 2 minutes. Then macOS shows the exact count and asks to allow deleting them: click Delete in that box.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private var confirmed: Bool { typed.trimmingCharacters(in: .whitespaces).lowercased() == "confirm" }

    private func start() {
        guard confirmed else { return }
        model.remove(recipe, phrase: RemovalPlan.currentPhrase)
        typed = ""
    }

    // MARK: 5. Proof

    @ViewBuilder private var proofStep: some View {
        if let p = proof, p.total > 0 {
            Step(number: 4, title: "Proof they are in \(Backup.name)", done: p.allConfirmed) {
                ProofTable(proof: p)
            }
        }
    }

    private func loadRoutes() -> [Route] {
        guard let st = model.storage else { return [] }
        return (try? Ledger.routes(SQLiteReader(path: model.ledgerPath), recipe, storage: st)) ?? []
    }

    private func loadProof() {
        guard let r = removal, !r.running else { proof = nil; return }
        proof = try? Ledger.proof(SQLiteReader(path: model.ledgerPath), since: Ledger.stamp(r.task.startedAt))
    }
}

// MARK: Pieces

/// Every confirmation says where things go: which account, which folders, and how much of
/// it is there already. Both can be changed from here.
struct WhereTheyGo: View {
    @ObservedObject var model: Model
    let routes: [Route]
    @State private var opening: String?
    @State private var linkError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill.badge.icloud").foregroundStyle(Tab.backup.color)
                Text("Where they go").font(.headline)
                Text(model.storage?.accountTitle ?? Backup.name).foregroundStyle(.secondary)
                Spacer()
                CapsuleButton(title: "Change folders", symbol: "folder.badge.gearshape", color: Tab.backup.color, style: .soft) {
                    model.removing = nil
                    model.tab = .backup
                }
                CapsuleButton(title: "Change account", symbol: "person.crop.circle.badge.questionmark", color: Tab.backup.color, style: .ghost) {
                    model.removing = nil
                    model.tab = .settings
                }
            }
            if routes.isEmpty {
                Text("Nothing on the phone matches this clean-up.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(routes) { r in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(Tab.backup.color)
                    Text(r.folder).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Self.detail(r)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    // Only a folder something is already in exists in Google Drive to be opened.
                    if r.inDrive.count > 0, !r.folder.hasPrefix("elsewhere in ") {
                        CapsuleButton(title: opening == r.folder ? "Opening…" : "View in GDrive", symbol: "arrow.up.forward.square",
                                      color: Tab.backup.color, style: .ghost) { open(r.folder) }
                            .disabled(opening != nil)
                            .help("Opens this folder in Google Drive in your browser.")
                    }
                }
            }
            if let linkError {
                Text(linkError).font(.caption).foregroundStyle(Theme.bad)
            }
            Text("Removed items go to Recently Deleted on the phone for 30 days. Nothing is deleted from \(Backup.name).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tab.backup.color.opacity(0.5), lineWidth: 1.5))
    }

    private func open(_ folder: String) {
        let engine = model.engine
        opening = folder
        linkError = nil
        Task {
            switch await Task.detached(operation: { Result { try engine.folderLink(folder) } }).value {
            case .success(let url): NSWorkspace.shared.open(url)
            case .failure(let e): linkError = "Could not open it: \((e as? JobError)?.text ?? "\(e)")"
            }
            opening = nil
        }
    }

    static func detail(_ r: Route) -> String {
        var parts: [String] = []
        if r.inDrive.count > 0 { parts.append("\(Fmt.count(r.inDrive.count)) there (\(Fmt.bytes(r.inDrive.bytes)))") }
        if r.toBackUp.count > 0 { parts.append("\(Fmt.count(r.toBackUp.count)) to back up (\(Fmt.bytes(r.toBackUp.bytes)))") }
        return parts.joined(separator: " · ")
    }
}

struct Step<Content: View>: View {
    let number: Int
    let title: String
    var done = false
    var locked = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Theme.good : (locked ? Color.secondary.opacity(0.3) : Tab.cleanUp.color))
                // A done step keeps its number, so "step 3" still points at it; green says done.
                Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(locked ? .secondary : .primary)
                content.opacity(locked ? 0.55 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(done ? Theme.good.opacity(0.5) : Theme.cardStroke, lineWidth: 1.5))
    }
}

struct Running: View {
    let text: String
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout.weight(.medium))
                Spacer()
                Text(Duration.seconds(ctx.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

struct AuditSummary: View {
    let report: AuditReport
    let at: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: report.clean ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(report.clean ? Theme.good : Theme.bad)
                Text(report.clean
                     ? "\(Fmt.count(report.matched ?? 0)) of \(Fmt.count(report.claimedVerified ?? 0)) backed-up items are in \(Backup.name) with matching hashes."
                     : "\(Backup.name) does not hold everything the ledger says it does.")
                    .font(.callout.weight(.semibold))
            }
            Text("Checked \(at.formatted(date: .omitted, time: .shortened)) · \(Fmt.count(report.remoteFiles ?? 0)) files in \(Backup.name)")
                .font(.caption).foregroundStyle(.secondary)
            ForEach((report.missing ?? []).prefix(5), id: \.id) { Text("Missing from \(Backup.name): \($0.path)").font(.caption).foregroundStyle(Theme.bad) }
            ForEach((report.hashMismatch ?? []).prefix(5), id: \.id) { Text("Hash differs: \($0.path)").font(.caption).foregroundStyle(Theme.bad) }
            ForEach(report.conflicts.prefix(5), id: \.self) { Text("\($0.kind): \($0.detail)").font(.caption).foregroundStyle(Theme.bad) }
        }
    }
}

struct PlanSummary: View {
    let plan: RemovalPlan
    /// After a removal: only what stayed, since the headline already says what went.
    var kept = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !kept { HStack(spacing: 6) {
                Image(systemName: plan.eligible > 0 ? "checkmark.shield.fill" : "info.circle.fill")
                    .foregroundStyle(plan.eligible > 0 ? Theme.good : Color.secondary)
                Text(plan.eligible > 0
                     ? "\(Fmt.count(plan.eligible)) items, \(Fmt.bytes(plan.eligibleBytes)), can go. Each one's \(Backup.name) copy was re-read just now and matched."
                     : "Nothing can go yet. Everything this clean-up found stays on the phone, for the reasons below.")
                    .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            } }
            if plan.blocked > 0 {
                Text("\(Fmt.count(plan.blocked)) stay on the phone:").font(.callout)
                ForEach(plan.blockedReasons.sorted { $0.value > $1.value }, id: \.key) { reason, n in
                    HStack {
                        Text("· \(Self.plain(reason))")
                        Spacer()
                        Text(Fmt.count(n)).monospacedDigit()
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// remove.py's block reasons in the owner's words.
    static func plain(_ r: String) -> String {
        switch r {
        case "flagged as a suspected proxy": "Might be a low-res stand-in for the real photo"
        case "Google Drive's copy is not the size of the original": "\(Backup.name)'s copy is smaller than the original, so it may be a low-res stand-in"
        case "no hash recorded, so the remote copy cannot be compared": "No fingerprint taken, so \(Backup.name)'s copy can't be checked"
        case "not verified in the cloud": "Not in \(Backup.name) yet"
        case "not at the remote right now": "Missing from \(Backup.name) right now"
        case "the remote copy does not match the recorded hash": "\(Backup.name)'s copy doesn't match"
        case "favourited": "Favourite"
        default: r.prefix(1).uppercased() + r.dropFirst()
        }
    }
}

struct ProofTable: View {
    let proof: Proof

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: proof.allConfirmed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(proof.allConfirmed ? Theme.good : Theme.warn)
                Text("\(Fmt.count(proof.confirmed)) of \(Fmt.count(proof.total)) removed items had their \(Backup.name) hash re-read and matched in the same run. \(Fmt.count(proof.stillVerified)) are still verified in \(Backup.name) now.")
                    .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if !proof.rows.isEmpty {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        GridRow {
                            Text("File"); Text("In \(Backup.name) at"); Text("SHA-256"); Text("")
                        }
                        .font(.caption.weight(.bold))
                        ForEach(proof.rows) { r in
                            GridRow {
                                Text(r.filename).lineLimit(1)
                                Text(r.drivePath).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                                Text(r.sha256.prefix(12) + "…").monospaced().foregroundStyle(.secondary)
                                Image(systemName: r.driveHashConfirmed && r.stillVerified ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(r.driveHashConfirmed && r.stillVerified ? Theme.good : Theme.warn)
                            }
                            .font(.caption)
                            .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 220)
                if proof.rows.count < proof.total { Text("Showing the latest \(Fmt.count(proof.rows.count)).").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// This time only: an age other than the setting, or just the oldest part ("the oldest
/// 5 GB"). Backup, plan and removal all follow it; the setting itself stays as it is.
struct ScopeCard: View {
    let base: Recipe
    @Binding var scope: Scope
    /// The clean-up narrowed to the scope, once counted.
    let scoped: Recipe?
    let stats: RecipeStats?
    var locked = false
    @State private var gb = ""

    private static let gbBytes: Int64 = 1_073_741_824
    static let ages = ["2y", "3y", "5y"].compactMap { Age($0) }
    static let amounts: [(Scope.Amount, String)] =
        [(.all, "All of it")] + [1, 2, 5, 10, 20, 50].map { (.bytes(Int64($0) * gbBytes), "The oldest \($0) GB") }
        + [25, 50, 75].map { (.percent($0), "The oldest \($0)%") }

    private var setting: Age? { base.age ?? base.filter.olderThan.flatMap { Age($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(Tab.cleanUp.color)
                Text("This time").font(.headline)
                Spacer()
                if !scope.isDefault {
                    Button("Back to my setting") { scope = Scope(); gb = "" }.buttonStyle(.link)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker("Taken more than", selection: $scope.age) {
                    Text("\(setting?.words ?? "any age") ago (my setting)").tag(Age?.none)
                    ForEach(Self.ages.filter { $0 != setting }, id: \.self) { Text("\($0.words) ago").tag(Optional($0)) }
                }
                .fixedSize()
                Picker("How much", selection: $scope.amount) {
                    ForEach(Self.amounts, id: \.0) { Text($0.1).tag($0.0) }
                    if case .bytes(let b) = scope.amount, !Self.amounts.contains(where: { $0.0 == scope.amount }) {
                        Text("The oldest \(Fmt.bytes(b))").tag(scope.amount)
                    }
                }
                .fixedSize()
                HStack(spacing: 4) {
                    Text("Or type an amount: the oldest").foregroundStyle(.secondary)
                    TextField("5", text: $gb).frame(width: 50).multilineTextAlignment(.trailing)
                        .onSubmit(applyGB)
                    Text("GB").foregroundStyle(.secondary)
                    Button("Use", action: applyGB).disabled(Double(gb.replacingOccurrences(of: ",", with: ".")) == nil)
                }
                .fixedSize()
            }
            .font(.callout)
            Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(locked)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tab.cleanUp.color.opacity(0.5), lineWidth: 1.5))
    }

    private func applyGB() {
        guard let v = Double(gb.replacingOccurrences(of: ",", with: ".")), v > 0 else { return }
        scope.amount = .bytes(Int64(v * Double(Self.gbBytes)))
    }

    private var summary: String {
        guard let stats else { return "Counting…" }
        let covers = "Covers \(Fmt.count(stats.selected.count)) items (\(Fmt.bytes(stats.selected.bytes)))"
        if scope.isDefault { return covers + ", as your setting says. Change it here for this time only." }
        let before = scoped?.age.map { $0.cutoff() } ?? scoped?.filter.olderThan.flatMap { Age($0)?.cutoff() }
        let taken = before.flatMap { Fmt.dateOnly($0) }.map { ", taken before \($0)" } ?? ""
        return covers + taken + ". This time only: your setting stays \(setting?.words ?? "any age")."
    }
}
