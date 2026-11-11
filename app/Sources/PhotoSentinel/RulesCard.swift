import PhotoCore
import SwiftUI

/// Every rule that decides what can leave the phone, in one place. Read only: the ages are
/// set in "What stays on your phone" above, and the rest cannot be switched off.
/// Each line is enforced by the removal engine (src/iphone_image/remove.py, docs/SAFETY.md).
struct RulesCard: View {
    private static let rules: [(String, String, String)] = [
        ("slider.horizontal.3", "Each type keeps what you set on My phone",
         "Camera, WhatsApp, screenshots and recordings each keep their own age, and photos and videos can differ."),
        ("calendar.badge.clock", "The last 30 days always stay",
         "Nothing taken in the last month leaves the phone, whatever an age, filter or your own rule says."),
        ("heart.fill", "Favourites always stay",
         "Tap the heart on anything you want kept on the phone for good."),
        ("rectangle.stack.fill", "WhatsApp items in your own albums stay",
         "Albums you made yourself keep WhatsApp media on the phone."),
        ("checkmark.icloud.fill", "Only what is checked in \(Backup.name) can go",
         "Each item's copy in \(Backup.name) is re-read and matched before it may leave the phone."),
        ("hand.tap.fill", "Nothing leaves the phone until you click Delete",
         "Removal starts only from a button you press, and then you click Delete when the dialog appears."),
        ("clock.badge.xmark", "Nothing runs on a schedule",
         "Backups copy to \(Backup.name) only when you start them, and a backup never removes anything from the phone."),
        ("trash.fill", "Removed items sit in Recently Deleted for 30 days",
         "On the iPhone you can recover them from Photos → Recently Deleted until then."),
    ]

    var body: some View {
        Card(title: "Rules Photo Sentinel follows", symbol: "lock.shield.fill", tint: Theme.good) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.rules, id: \.1) { symbol, title, detail in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol).foregroundStyle(Theme.good).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.callout.weight(.semibold))
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("These cannot be switched off in the app. The ages per type are set on My phone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
