import Foundation

/// One row on the Checkup tab: something worth doing, and the one action that does it.
public struct Finding: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case safety, space, job, info }
    public enum Action: Hashable, Sendable {
        case resume(String)      // a job id
        case recipe(String)      // a recipe id: opens Clean up
        case openTab(String)
        case emptyBin
        case macStorage          // macOS Settings > General > Storage
        case ownSignIn           // Settings > Where backups go, with the sign-in steps open
        case backUpLivePhotos    // live-photos --apply
        case none
    }

    public let id: String
    public let kind: Kind
    public let symbol: String
    public let title: String
    public let detail: String
    public let actionTitle: String
    public let action: Action
    /// Bytes this would free, for ordering.
    public let bytes: Int64
}

public enum Detector {
    /// Safety first, then stopped jobs, then space by size. Pure: tested without a ledger.
    /// The Mac's own disk, not the phone's: backups pass through it on the way to Google Drive.
    /// Tidied Mac copies go to the Bin, so emptying it is usually what gives the space back.
    static func lowMacSpace(_ c: Check, jobs: [Job], binBytes: Int64?) -> Finding {
        let free = c.detail.components(separatedBy: " free").first ?? c.detail
        var detail = "Backups copy each item to this Mac on its way to \(Backup.name), in batches that shrink to fit, and always leave some space free. There is no room for even a small batch now."
        let running = jobs.filter { $0.state == .running }.map(\.title)
        if !running.isEmpty {
            detail += " The running \(running.joined(separator: " and ")) backup tidies its Mac copies when it ends."
        }
        let binWorthIt = binBytes.map { $0 >= 100_000_000 } ?? true
        if let b = binBytes, binWorthIt {
            detail += " The Bin holds \(Fmt.bytes(b)): tidied copies go there, already safe in \(Backup.name), and the space only comes back when it is emptied."
        } else if binBytes == nil {
            detail += " Tidied copies go to the Bin, already safe in \(Backup.name); the space only comes back when it is emptied."
        } else {
            detail += " The Bin is already empty, so see what else is using this Mac's disk."
        }
        return Finding(id: "doctor.\(c.name)", kind: .safety, symbol: "internaldrive.fill",
                       title: "This Mac is low on space: \(free) free",
                       detail: detail,
                       actionTitle: binWorthIt ? "Empty Bin" + (binBytes.map { " (\(Fmt.bytes($0)))" } ?? "") + "…" : "See what uses space",
                       action: binWorthIt ? .emptyBin : .macStorage, bytes: .max)
    }

    /// `sharedSignIn`: Google Drive signs in through rclone's shared Google project, whose
    /// quota slows uploads for everyone using it.
    public static func findings(library s: LibrarySnapshot, jobs: [Job], doctor: DoctorReport?, binBytes: Int64? = nil,
                                sharedSignIn: Bool = false, livePhotosRunning: Bool = false) -> [Finding] {
        var out: [Finding] = []

        let live = s.liveMotionMissing
        if live.count > 0 {
            out.append(Finding(id: "live.motion", kind: .space, symbol: "livephoto",
                               title: "\(Fmt.count(live.count)) Live Photos can't come off the phone yet",
                               detail: "\(Backup.name) has the photo (\(Fmt.bytes(live.bytes))) but not the few seconds of video that make it move, so they stay on the phone. Back up the moving part and they can be cleaned up like any other photo. Nothing is removed." + (livePhotosRunning ? " Backing up now." : ""),
                               actionTitle: livePhotosRunning ? "Watch progress" : "Back up Live Photos",
                               action: livePhotosRunning ? .openTab("Activity") : .backUpLivePhotos, bytes: live.bytes))
        }

        if sharedSignIn {
            out.append(Finding(id: "google.signin", kind: .job, symbol: "person.badge.key.fill",
                               title: "Sign in to Google yourself so uploads stop being slowed down",
                               detail: "Photo Sentinel signs in to Google through rclone, a tool shared by many people, and Google limits how fast all of them together can upload. Your own sign-in gets you your own limit. It's free, takes about 10 minutes, and you only do it once. Backups keep running meanwhile.",
                               actionTitle: "Sign in to Google", action: .ownSignIn, bytes: .max - 4))
        }

        for c in doctor?.results ?? [] where c.failed {
            if c.name == "disk headroom" {
                out.append(lowMacSpace(c, jobs: jobs, binBytes: binBytes))
                continue
            }
            out.append(Finding(id: "doctor.\(c.name)", kind: .safety, symbol: "exclamationmark.triangle.fill",
                               title: "\(c.name.prefix(1).uppercased())\(c.name.dropFirst()): \(c.detail)",
                               detail: c.remedy.isEmpty ? "Run doctor for details." : c.remedy,
                               actionTitle: "Open Settings", action: .openTab("Settings"), bytes: .max))
        }

        let camera = s.channels.filter { $0.channel == .camera }
        let taken = camera.first?.notBackedUpAge
        let phoneOnly = camera
            .reduce(Tally()) { Tally(count: $0.count + $1.total.count - $1.verified.count, bytes: $0.bytes + $1.total.bytes - $1.verified.bytes) }
        if phoneOnly.count > 0 {
            let running = jobs.contains { $0.source == "camera" && $0.state == .running }
            out.append(Finding(id: "camera.unprotected", kind: .safety, symbol: "exclamationmark.shield.fill",
                               title: "\(Fmt.count(phoneOnly.count)) camera photos and videos are only on your phone",
                               detail: "\(Fmt.bytes(phoneOnly.bytes)) with no copy in \(Backup.name)" + (taken.map { ", \($0)." } ?? ".") + (running ? " Backing up now." : ""),
                               actionTitle: running ? "Watch progress" : "Back up", action: .openTab("Activity"), bytes: phoneOnly.bytes))
        }

        for j in jobs {
            switch j.state {
            case .stopped(let why):
                out.append(Finding(id: "job.\(j.id)", kind: .job, symbol: "pause.circle.fill",
                                   title: "\(j.title) backup stopped", detail: why,
                                   actionTitle: "Resume", action: .resume(j.id), bytes: .max - 1))
            case .paused(let why):
                out.append(Finding(id: "job.\(j.id)", kind: .job, symbol: "pause.circle.fill",
                                   title: "\(j.title) backup is paused", detail: why,
                                   actionTitle: "Show", action: .openTab("Activity"), bytes: .max - 2))
            default: break
            }
        }

        let removals = s.unfinishedOperations.filter(\.needsPerson)
        if !removals.isEmpty {
            out.append(Finding(id: "journal.remove", kind: .job, symbol: "hand.raised.fill",
                               title: "\(removals.count) removal\(removals.count == 1 ? "" : "s") never confirmed",
                               detail: "The app stopped before Photos said what it deleted. The latest scan of the phone settles it: what is gone is recorded as removed, the rest can be planned again.",
                               actionTitle: "Finish it", action: .openTab("Activity"), bytes: .max - 3))
        }

        for r in s.recipes where r.recipe.kind != .largeVideos {
            if r.removableNow.count > 0 {
                out.append(Finding(id: "ready.\(r.id)", kind: .space, symbol: r.recipe.symbol,
                                   title: "About \(Fmt.count(r.removableNow.count)) \(noun(r.recipe)) are safe in \(Backup.name)",
                                   detail: "\(Fmt.bytes(r.removableNow.bytes)) you can take off the phone now.",
                                   actionTitle: "Remove from iPhone", action: .recipe(r.id), bytes: r.removableNow.bytes))
            } else if r.notBackedUp.count > 0 {
                out.append(Finding(id: "todo.\(r.id)", kind: .space, symbol: r.recipe.symbol,
                                   title: "\(Fmt.count(r.selected.count)) \(noun(r.recipe))",
                                   detail: "\(Fmt.bytes(r.selected.bytes)). Each gets a copy in \(Backup.name) first; you see them before anything goes.",
                                   actionTitle: "Clean up", action: .recipe(r.id), bytes: r.selected.bytes))
            }
        }

        return out.sorted { a, b in
            a.kind == b.kind ? a.bytes > b.bytes : rank(a.kind) < rank(b.kind)
        }
    }

    static func rank(_ k: Finding.Kind) -> Int {
        switch k { case .safety: 0; case .job: 1; case .space: 2; case .info: 3 }
    }

    static func noun(_ r: Recipe) -> String {
        let age = r.age.map { " older than \($0.words)" } ?? ""
        switch r.kind {
        case .oldVideos: return "camera videos" + age
        case .cameraPhotos: return "camera photos" + age
        case .whatsapp: return "WhatsApp items" + age
        case .screenshots: return "screenshots" + age
        case .screenRecordings: return "screen recordings" + age
        case .largeVideos: return "large videos"
        case .custom: return "items in \u{201C}\(r.title)\u{201D}"
        }
    }
}
