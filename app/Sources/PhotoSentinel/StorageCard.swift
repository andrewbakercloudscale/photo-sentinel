import AppKit
import PhotoCore
import SwiftUI

/// Settings: which account backups go to, which folders in it, and the archive folder on
/// this Mac. Accounts are rclone remotes. An S3 bucket is added here; anything else is
/// `rclone config`, opened in Terminal.
struct StorageCard: View {
    @ObservedObject var model: Model
    @State private var account = ""
    @State private var archive = ""
    @State private var message: (ok: Bool, text: String)?
    @State private var saving = false
    @State private var showOwnClient = false
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var signingIn = false
    @State var showS3 = false
    @State private var s3 = S3Form()
    @State private var addingS3 = false

    var body: some View {
        Card(title: "Where backups go", symbol: "externaldrive.fill.badge.icloud", tint: Tab.backup.color) {
            if let s = model.storage {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow {
                            Text("Account")
                            HStack(spacing: 8) {
                                Picker("", selection: $account) {
                                    ForEach(s.accounts) { a in
                                        Text(a.canVerify ? "\(a.name) · \(a.title)" : "\(a.name) · \(a.title) (cannot be checked yet)")
                                            .tag(a.name)
                                            .selectionDisabled(!a.canVerify)
                                    }
                                }
                                .labelsHidden().fixedSize()
                                CapsuleButton(title: "Add S3 bucket…", symbol: "plus.circle.fill", color: Tab.backup.color, style: .ghost) {
                                    showS3 = true
                                }
                                .help("Add an Amazon S3 bucket, or an S3 compatible one such as Backblaze B2 or Cloudflare R2, with its access keys.")
                                CapsuleButton(title: "Other…", symbol: "terminal", color: .primary, style: .ghost) {
                                    Self.openRcloneConfig()
                                }
                                .help("Opens Terminal with rclone's own setup, for any other account. Come back and pick the new account here.")
                            }
                        }
                        GridRow(alignment: .top) {
                            Text("Folders")
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(["photos", "videos", "screenshots", "whatsapp"], id: \.self) { k in
                                    HStack(spacing: 6) {
                                        Text(k == "whatsapp" ? "WhatsApp" : k.capitalized).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                        Text((s.destinations[k] ?? "").isEmpty ? "with the photos" : s.destinations[k]!)
                                            .font(.callout.monospaced()).textSelection(.enabled)
                                    }
                                }
                                Button("Change folders and their layout in Backup → How backups are stored") { model.tab = .backup }
                                    .buttonStyle(.link)
                            }
                        }
                        GridRow {
                            Text("Archive on this Mac")
                            HStack(spacing: 8) {
                                TextField("", text: $archive).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                                Button("Choose…") { choose() }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NSString(string: s.archive).expandingTildeInPath)
                                }
                            }
                        }
                    }
                    .font(.callout)
                    if showS3 { s3Form() }
                    if s.sharedClientId == true { clientIdHint(s) }
                    if changed(s) { pending(s) }
                    if let m = message {
                        Text(m.text).font(.callout).foregroundStyle(m.ok ? Theme.good : Theme.bad).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Every backup is checked by hash before anything leaves the phone. Google Drive and a folder on this Mac are checked by SHA-256, S3 by MD5. OneDrive and Dropbox report hashes of their own, so they are listed but cannot be picked yet. Items backed up before Photo Sentinel kept MD5 have none, so an S3 account never removes those from the phone.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .onAppear { reset(s) }
                .onChange(of: s.remote) { reset(s) }
                .onChange(of: s.archive) { reset(s) }
                .onAppear { openSignIn() }
                .onChange(of: model.ownSignIn) { openSignIn() }
            } else {
                Text("Reading the backup settings…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// rclone's built-in Google project is shared by every rclone user, so Google Drive throttles
    /// it. The owner makes their own client in Google Cloud (links below), pastes it here, and
    /// `config own-client` signs in with it in the browser. The account only changes if that
    /// reaches the same Google Drive.
    /// Checkup's Sign in to Google lands here with the steps open.
    private func openSignIn() {
        guard model.ownSignIn else { return }
        showOwnClient = true
        model.ownSignIn = false
    }

    @ViewBuilder private func clientIdHint(_ s: StorageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Uploads to Google Drive are slow. Photo Sentinel uploads with a tool called rclone, which signs in to Google as rclone, and Google limits how fast all of rclone's users together can upload. Set up your own sign-in and Google gives you a limit of your own. It's free, takes about 10 minutes, and you only do it once.",
                  systemImage: "tortoise.fill")
                .foregroundStyle(Theme.warn)
            if showOwnClient {
                ownClientSteps(s)
            } else {
                CapsuleButton(title: "Use my own Google sign-in", symbol: "person.badge.key.fill", color: Tab.backup.color) {
                    showOwnClient = true
                }
            }
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    private static let ownClientSteps: [(title: String, how: String, url: String)] = [
        ("Make a Google Cloud project", "Any name, then Create. Sign in to Google Cloud with any Google account.", "https://console.cloud.google.com/projectcreate"),
        ("Turn on the Google Drive API", "Check the new project is picked at the top, then Enable.", "https://console.cloud.google.com/apis/library/drive.googleapis.com"),
        ("Set up its sign-in screen", "Get started: any app name, your email, Audience External, your email again, then Create.", "https://console.cloud.google.com/auth/branding"),
        ("Publish it", "Publish app, then Confirm. Skip this and Google signs you out every 7 days, which stops backups.", "https://console.cloud.google.com/auth/audience"),
        ("Make a client", "Application type Desktop app, any name, Create. Keep that window open: it shows the Client ID and Client secret.", "https://console.cloud.google.com/auth/clients/create"),
    ]

    @ViewBuilder private func ownClientSteps(_ s: StorageReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(Array(Self.ownClientSteps.enumerated()), id: \.offset) { i, step in
                    GridRow(alignment: .firstTextBaseline) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).fontWeight(.medium)
                            Text(step.how).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        CapsuleButton(title: "Open", symbol: "arrow.up.right.square", color: Tab.backup.color, style: .soft) {
                            NSWorkspace.shared.open(URL(string: step.url)!)
                        }
                    }
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("6.").monospacedDigit().foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Paste them here and sign in").fontWeight(.medium)
                        TextField("Client ID", text: $clientId).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                        SecureField("Client secret", text: $clientSecret).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                        Text("Your browser opens: sign in as the Google account your backups are in. Google says it hasn't verified the app: it is your own, so click Continue. The account changes only if that sign-in reaches the same Google Drive.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            HStack(spacing: 8) {
                CapsuleButton(title: signingIn ? "Waiting for the browser…" : "Sign in to Google", symbol: "person.badge.key.fill", color: Tab.backup.color) {
                    Task { await signIn() }
                }
                .disabled(signingIn || model.backupBusy || clientId.trimmingCharacters(in: .whitespaces).isEmpty || clientSecret.isEmpty)
                .help(model.backupBusy ? "Wait for the running backup to finish: signing in again cuts off its uploads." : "")
                if signingIn { ProgressView().controlSize(.small) }
                CapsuleButton(title: "Cancel", color: .primary, style: .ghost) {
                    showOwnClient = false
                    clientSecret = ""
                }
                .disabled(signingIn)
            }
            if model.backupBusy { Text("Signing in waits until the running backup finishes: it would cut off its uploads.").foregroundStyle(.secondary) }
            Button("rclone's guide to this") { NSWorkspace.shared.open(URL(string: "https://rclone.org/drive/#making-your-own-client-id")!) }
                .buttonStyle(.link)
        }
    }

    private func signIn() async {
        signingIn = true
        message = nil
        let engine = model.engine
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await Task.detached { Result { try engine.ownClient(id: id, secret: secret) } }.value
        signingIn = false
        switch result {
        case .success:
            clientSecret = ""
            showOwnClient = false
            message = (true, "Done. Uploads to Google Drive now use your own sign-in. Nothing already backed up changes.")
            model.refresh()
        case .failure(let e):
            message = (false, (e as? JobError)?.text ?? "\(e)")
        }
    }

    @ViewBuilder private func s3Form() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add an S3 bucket").fontWeight(.medium)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow { Text("Bucket"); TextField("my-bucket, or my-bucket/iphone", text: $s3.bucket).textFieldStyle(.roundedBorder) }
                GridRow { Text("Access key ID"); TextField("AKIA…", text: $s3.keyId).textFieldStyle(.roundedBorder).font(.callout.monospaced()) }
                GridRow { Text("Secret access key"); SecureField("", text: $s3.secret).textFieldStyle(.roundedBorder).font(.callout.monospaced()) }
                GridRow { Text("Region"); TextField("us-east-1", text: $s3.region).textFieldStyle(.roundedBorder) }
                GridRow { Text("Endpoint"); TextField("Leave empty for Amazon S3", text: $s3.endpoint).textFieldStyle(.roundedBorder) }
                GridRow { Text("Call it"); TextField("s3", text: $s3.name).textFieldStyle(.roundedBorder) }
            }
            Text("Photo Sentinel writes a small test file to the bucket, checks S3 reports its fingerprint (MD5), and deletes it. The account is added only if that works. The keys are kept in rclone's settings on this Mac, like your Google Drive sign-in. Adding it does not move backups: pick it under Account and Save.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                CapsuleButton(title: addingS3 ? "Checking the bucket…" : "Add bucket", symbol: "checkmark", color: Tab.backup.color) {
                    Task { await addS3() }
                }
                .disabled(addingS3 || !s3.ready)
                if addingS3 { ProgressView().controlSize(.small) }
                CapsuleButton(title: "Cancel", color: .primary, style: .ghost) {
                    showS3 = false
                    s3 = S3Form()
                }
                .disabled(addingS3)
            }
        }
        .font(.callout)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func addS3() async {
        addingS3 = true
        message = nil
        let engine = model.engine
        let f = s3
        let result = await Task.detached {
            Result { try engine.addS3(name: f.name, bucket: f.bucket, keyId: f.keyId, secret: f.secret, region: f.region, endpoint: f.endpoint) }
        }.value
        addingS3 = false
        switch result {
        case .success(let remote):
            showS3 = false
            s3 = S3Form()
            message = (true, "Added \(remote). To send new backups there, pick it under Account and Save.")
            if let r = await Task.detached(operation: { try? engine.storage() }).value {
                model.storage = r
                account = remote
            }
        case .failure(let e):
            s3.secret = ""
            message = (false, "Not added: \((e as? JobError)?.text ?? "\(e)")")
        }
    }

    private func changed(_ s: StorageReport) -> Bool {
        account != s.remote || NSString(string: archive).expandingTildeInPath != s.archive
    }

    @ViewBuilder private func pending(_ s: StorageReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if account != s.remote {
                Label("New backups go to \(account). The \(Fmt.count(s.backedUp.count)) items (\(Fmt.bytes(s.backedUp.bytes))) already backed up stay in \(s.accountTitle) and are not copied over. Removal checks the account in use, so those items stay on the phone until they are in \(account) too.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warn)
            }
            if NSString(string: archive).expandingTildeInPath != s.archive {
                Label("New copies go to \(archive). Files already in \(s.archive) stay there.", systemImage: "folder.fill")
            }
            HStack(spacing: 8) {
                CapsuleButton(title: saving ? "Saving…" : "Save", symbol: "checkmark", color: Tab.backup.color) {
                    Task { await save(s) }
                }
                .disabled(saving || model.backupBusy)
                .help(model.backupBusy ? "Wait for the running backup to finish: it uses these settings." : "")
                CapsuleButton(title: "Cancel", color: .primary, style: .ghost) { reset(s) }
                if model.backupBusy { Text("Saving waits until the running backup finishes.").foregroundStyle(.secondary) }
            }
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    private func reset(_ s: StorageReport) {
        account = s.remote
        archive = s.archive
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSString(string: archive).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { archive = url.path }
    }

    private func save(_ s: StorageReport) async {
        saving = true
        let engine = model.engine
        let remote = account != s.remote ? account : nil
        let folder = NSString(string: archive).expandingTildeInPath
        let arch = folder != s.archive ? folder : nil
        let result = await Task.detached { Result { try engine.storage(remote: remote, archive: arch, apply: true) } }.value
        saving = false
        switch result {
        case .success(let r):
            model.storage = r
            message = (true, "Saved. New backups use it.")
            model.refresh()
        case .failure(let e):
            message = (false, "Not saved: \((e as? JobError)?.text ?? "\(e)")")
        }
    }

    static func openRcloneConfig() {
        let script = "tell application \"Terminal\" to activate\ntell application \"Terminal\" to do script \"rclone config\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

/// What the Add S3 bucket form holds. Ready once the bucket and both keys are filled in.
struct S3Form: Equatable {
    var bucket = ""
    var keyId = ""
    var secret = ""
    var region = "us-east-1"
    var endpoint = ""
    var name = "s3"
    var ready: Bool {
        ![bucket, keyId, secret, name].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Settings: when backups pause. The job checks before every step and stops a transfer
/// the moment the Mac joins a metered connection, unless the switch here is off.
struct WhenBackupsRunCard: View {
    @ObservedObject var model: Model
    @State private var metered: Bool?
    @State private var pause: Bool?
    @State private var error: String?

    var body: some View {
        Card(title: "When backups run", symbol: "wifi", tint: Tab.backup.color) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "personalhotspot").foregroundStyle(pause == false ? Theme.warn : Theme.good)
                    Toggle("Pause on a phone hotspot", isOn: Binding(get: { pause ?? true }, set: { save($0) }))
                        .toggleStyle(.switch).font(.body.weight(.medium))
                        .disabled(pause == nil)
                    Spacer()
                    if let metered {
                        Text(metered ? (pause == false ? "Now: on a hotspot, backups carry on" : "Now: on a hotspot, backups are paused") : "Now: on normal Wi-Fi")
                            .font(.callout).foregroundStyle(metered ? Theme.warn : .secondary)
                    }
                }
                Text(pause == false
                     ? "Off: backups copy and upload on your iPhone's Personal Hotspot too, which uses its data. A running backup follows the switch within a minute."
                     : "Nothing copies or uploads on your iPhone's Personal Hotspot or any connection macOS marks as metered. Switching to one mid-upload stops the upload at once; it carries on by itself back on normal Wi-Fi. Checks and plans are small and still run.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.callout).foregroundStyle(Theme.bad) }
            }
        }
        .task {
            metered = await Self.isMetered()
            let engine = model.engine
            switch await Task.detached(operation: { Result { try engine.pauseOnHotspot() } }).value {
            case .success(let on): pause = on
            case .failure(let e): error = "Could not read the setting: \((e as? JobError)?.text ?? "\(e)")"
            }
        }
    }

    private func save(_ on: Bool) {
        let engine = model.engine
        pause = on
        Task {
            switch await Task.detached(operation: { Result { try engine.pauseOnHotspot(on) } }).value {
            case .success(let saved): pause = saved; error = nil
            case .failure(let e): pause = !on; error = "Not saved: \((e as? JobError)?.text ?? "\(e)")"
            }
        }
    }

    /// cycle.sh's rule: an iPhone hotspot hands out 172.20.10.0/28, or macOS flags the link IsExpensive.
    static func isMetered() async -> Bool {
        await Task.detached {
            let route = shell("/sbin/route", ["-n", "get", "default"])
            let gateway = route.split(separator: "\n").first { $0.contains("gateway:") }?.split(separator: " ").last.map(String.init) ?? ""
            if gateway.hasPrefix("172.20.10.") { return true }
            guard let ifc = route.split(separator: "\n").first(where: { $0.contains("interface:") })?.split(separator: " ").last else { return false }
            return shell("/usr/sbin/ipconfig", ["getsummary", String(ifc)]).contains("IsExpensive : TRUE")
        }.value
    }

    nonisolated private static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
