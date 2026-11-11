import PhotoCore
import SwiftUI

/// The first page: where the phone's storage goes, a slider per source for how much of it
/// stays, and the phone with those choices, live as a slider moves. The sliders are a draft
/// until Save the plan; the clean-ups, Checkup and the Library use the saved plan.
/// Apply one source at a time, or the whole plan, every six months or so.
struct MyPhoneView: View {
    @ObservedObject var model: Model

    /// The button column beside a slider, the same width on every row so the sliders line up.
    private static let actionWidth: CGFloat = 150

    /// Biggest sources first is the Library's job; here the order is fixed, so a slider
    /// never jumps away from under the pointer as the numbers change.
    private static let order: [Channel] = [.camera, .whatsapp, .screenshot, .screenRecording, .otherApps, .unattributed]

    var body: some View {
        if let s = model.library {
            VStack(alignment: .leading, spacing: 14) {
                future(s)
                sliders(s)
                planCard
            }
        }
    }

    private var draft: KeepPlan { model.keepDraft }

    // MARK: Numbers

    private func leaving(_ kind: Recipe.Kind) -> AgeProfile.Part {
        model.profile?.leaving(kind, Age(draft.age(kind))) ?? AgeProfile.Part()
    }

    private func leaving(_ g: KeepGroup) -> AgeProfile.Part {
        g.kinds.map(leaving).reduce(AgeProfile.Part(), +)
    }

    private var leavingAll: AgeProfile.Part {
        KeepGroup.allCases.map(leaving).reduce(AgeProfile.Part(), +)
    }

    private func onPhone(_ s: LibrarySnapshot, _ c: Channel) -> Tally { s.channels.first { $0.channel == c }?.total ?? Tally() }

    private func onPhone(_ kind: Recipe.Kind) -> Tally { model.profile?.onPhone[kind] ?? Tally() }

    // MARK: Today and after

    private func future(_ s: LibrarySnapshot) -> some View {
        let going = leavingAll.frees
        let after = Tally(count: max(s.onPhone.count - going.count, 0), bytes: max(s.onPhone.bytes - going.bytes, 0))
        let channels = Self.order.filter { onPhone(s, $0).bytes > 0 }
        func left(_ c: Channel) -> Int64 {
            let g = KeepGroup.allCases.first { $0.channel == c }
            return max(onPhone(s, c).bytes - (g.map { leaving($0).frees.bytes } ?? 0), 0)
        }
        let part = leavingAll
        return Card(title: "Where your iPhone's storage goes", symbol: "internaldrive.fill", tint: Tab.phone.color,
                    trailing: model.loading ? AnyView(ProgressView().controlSize(.small)) : nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    tile("PHOTOS & VIDEOS ON YOUR IPHONE NOW", Fmt.bytes(s.onPhone.bytes), "\(Fmt.count(s.onPhone.count)) items", .primary)
                    Image(systemName: "arrow.right").font(.title2.weight(.bold)).foregroundStyle(.secondary).padding(.top, 26)
                    tile(model.planChanged ? "AFTER THESE SLIDERS (NOT SAVED)" : "AFTER YOUR PLAN", Fmt.bytes(after.bytes),
                         "\(Fmt.count(after.count)) items stay on the phone", Theme.good)
                    tile("MOVES TO \(Backup.name.uppercased())", Fmt.bytes(going.bytes),
                         going.count == 0 ? "nothing leaves the phone"
                         : "\(Fmt.count(going.count)) items · \(Fmt.bytes(part.removableNow.bytes)) already there"
                           + (part.notBackedUp.bytes > 0 ? ", \(Fmt.bytes(part.notBackedUp.bytes)) backed up first" : ""),
                         Tab.backup.color)
                }
                // Both bars on one scale: After is as much shorter as the phone gets emptier.
                GeometryReader { g in
                    let width = g.size.width - 56
                    let scale = s.onPhone.bytes == 0 ? 0 : width / CGFloat(s.onPhone.bytes)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("TODAY").sectionLabel().frame(width: 46, alignment: .leading)
                            StackBar(parts: channels.map { (Theme.color($0), Double(onPhone(s, $0).bytes)) }, height: 22)
                                .frame(width: max(width, 0))
                        }
                        HStack(spacing: 10) {
                            Text("AFTER").sectionLabel().frame(width: 46, alignment: .leading)
                            HStack(spacing: 0) {
                                StackBar(parts: channels.map { (Theme.color($0), Double(left($0))) }, height: 22)
                                    .frame(width: max(CGFloat(after.bytes) * scale, 0))
                                if going.bytes > 0 {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(Theme.good, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                        .overlay(Text("− \(Fmt.bytes(going.bytes))").font(.caption.weight(.bold)).foregroundStyle(Theme.good).lineLimit(1))
                                        .frame(width: max(CGFloat(going.bytes) * scale - 4, 0), height: 22)
                                        .padding(.leading, 4)
                                }
                            }
                            .animation(.easeOut(duration: 0.2), value: after.bytes)
                        }
                    }
                }
                .frame(height: 52)
                HStack(spacing: 14) {
                    ForEach(channels) { c in
                        let now = onPhone(s, c).bytes
                        legend(Theme.color(c), "\(c.title) " + (left(c) == now ? Fmt.bytes(now) : "\(Fmt.bytes(now)) → \(Fmt.bytes(left(c)))"))
                    }
                }
                .font(.caption)
            }
        }
    }

    private func tile(_ label: String, _ value: String, _ note: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).sectionLabel().lineLimit(1)
            Text(value).font(.system(size: 30, weight: .bold)).foregroundStyle(color).monospacedDigit()
            Text(note).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legend(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: 10)
            Text(text).monospacedDigit().fixedSize()
        }
    }

    // MARK: Sliders

    private func sliders(_ s: LibrarySnapshot) -> some View {
        Card(title: "How much stays on your phone", symbol: "slider.horizontal.3", tint: Tab.phone.color) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Slide left to keep less on the phone. Anything older goes to \(Backup.name), and stays there.")
                    .font(.callout).foregroundStyle(.secondary).padding(.bottom, 6)
                ForEach(Self.order.filter { onPhone(s, $0).count > 0 }) { c in
                    if let g = KeepGroup.allCases.first(where: { $0.channel == c }) {
                        groupRow(g, onPhone(s, c))
                    } else {
                        otherRow(c, onPhone(s, c))
                    }
                    Divider().padding(.vertical, 6)
                }
                Text("Favourites, WhatsApp items in your own albums and anything from the last 30 days always stay. So does anything not yet checked in \(Backup.name) until it has been backed up. The numbers are an estimate; removing shows the exact list first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func groupRow(_ g: KeepGroup, _ total: Tally) -> some View {
        let going = leaving(g)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SymbolTile(symbol: symbol(g.channel), color: Theme.color(g.channel), size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.channel.title).font(.callout.weight(.semibold))
                    Text("\(Fmt.bytes(total.bytes)) · \(Fmt.count(total.count)) items").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(width: 170, alignment: .leading)
                AgeSlider(value: draft.groupAge(g), tint: Theme.color(g.channel)) { v in model.keepDraft.setGroupAge(g, v) }
                applyButton(g, going)
                    .frame(width: Self.actionWidth, alignment: .trailing)
                frees(going, kinds: g.kinds)
            }
            if g.kinds.count > 1 {
                ForEach(g.kinds, id: \.self) { kind in kindRow(g, kind) }
            }
        }
    }

    /// Photos or videos inside a group: following it, or with an age of its own.
    private func kindRow(_ g: KeepGroup, _ kind: Recipe.Kind) -> some View {
        let total = onPhone(kind)
        let own = draft.isOverridden(kind)
        return HStack(spacing: 12) {
            Image(systemName: KeepGroup.part(kind) == "Videos" ? "video.fill" : "photo.fill")
                .foregroundStyle(Theme.color(g.channel)).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(KeepGroup.part(kind)).font(.callout)
                Text("\(Fmt.bytes(total.bytes)) · \(Fmt.count(total.count))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 152, alignment: .leading)
            if own {
                AgeSlider(value: draft.age(kind), tint: Theme.color(g.channel)) { v in model.keepDraft.setAge(kind, v) }
                RowButton(title: "Follow \(g.channel.title)", symbol: "arrow.uturn.backward", color: .secondary) { model.keepDraft.followGroup(kind) }
                    .frame(width: Self.actionWidth, alignment: .trailing)
                    .help("Use the \(g.channel.title) slider above for \(KeepGroup.part(kind).lowercased()) again.")
            } else {
                Text("Follows \(g.channel.title): \(AgeSlider.words(draft.age(kind)).lowercased())")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                RowButton(title: "Set its own", symbol: "slider.horizontal.below.rectangle", color: Theme.color(g.channel)) {
                    model.keepDraft.giveOwnAge(kind)
                }
                .frame(width: Self.actionWidth, alignment: .trailing)
                .help("Give \(g.channel.title) \(KeepGroup.part(kind).lowercased()) a different age, e.g. keep videos for 6 months and photos for 2 years.")
            }
            frees(leaving(kind), kinds: [kind])
        }
        .padding(.leading, 18)
    }

    private func otherRow(_ c: Channel, _ total: Tally) -> some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol(c), color: Theme.color(c), size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.callout.weight(.semibold))
                Text("\(Fmt.bytes(total.bytes)) · \(Fmt.count(total.count)) items").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 170, alignment: .leading)
            Text("Stays. To move some of it, make a rule by app, size, year or place.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            RowButton(title: "Make a rule", symbol: "plus.circle.fill", color: Tab.library.color) {
                model.draft = Filter(source: c.cliSource)
                model.openBuilder()
            }
        }
    }

    /// What this row takes off the phone, or why it takes nothing.
    private func frees(_ p: AgeProfile.Part, kinds: [Recipe.Kind]) -> some View {
        let keepsAll = kinds.allSatisfy { Age(draft.age($0)) == nil }
        let applied = kinds.compactMap(model.lastApplied).max()
        return VStack(alignment: .trailing, spacing: 1) {
            if p.frees.bytes > 0 {
                Text("frees \(Fmt.bytes(p.frees.bytes))").font(.callout.weight(.semibold)).foregroundStyle(Theme.good)
                Text("\(Fmt.count(p.frees.count)) items").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(keepsAll ? "Keeps everything" : "Already applied").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Text(applied.map { "on " + $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? " ")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .frame(width: 120, alignment: .trailing)
    }

    /// Just this source, now: its backup, then its removal list. Saves the plan first if the
    /// sliders have changed, so what runs is what the page shows.
    @ViewBuilder private func applyButton(_ g: KeepGroup, _ going: AgeProfile.Part) -> some View {
        if going.frees.count > 0 && model.plan.isEmpty {
            RowButton(title: model.planChanged ? "Save & apply…" : "Apply…", symbol: "iphone.and.arrow.forward",
                      color: Theme.color(g.channel), style: .fill) {
                if model.planChanged { model.savePlan() }
                model.apply(g.kinds)
            }
            .help("Only \(g.channel.title): backs up what \(Backup.name) doesn't have yet, then shows the exact list. Nothing is removed until you click Delete when the dialog appears.")
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func symbol(_ c: Channel) -> String {
        switch c {
        case .camera: "camera.fill"
        case .whatsapp: "bubble.left.and.bubble.right.fill"
        case .screenshot: "iphone"
        case .screenRecording: "record.circle"
        case .otherApps: "square.grid.2x2.fill"
        case .unattributed: "questionmark.square.dashed"
        }
    }

    // MARK: The plan

    private var planCard: some View {
        let going = leavingAll
        let day = Date.FormatStyle().day().month(.abbreviated).year()
        return Card(title: "Your plan", symbol: "checklist", tint: Tab.phone.color) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if model.planChanged {
                        Label("The sliders have changed since the plan was saved.", systemImage: "pencil.circle.fill").foregroundStyle(Theme.warn)
                    } else if model.planSavedAt > 0 {
                        Label("Saved \(Date(timeIntervalSince1970: model.planSavedAt).formatted(day)).", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                    } else {
                        Label("Your plan is the ages above. Move a slider, then save to change it.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                    }
                    if let next = model.nextReview {
                        Label(model.reviewDue ? "Time to apply it again." : "Next time to apply it: \(next.formatted(.dateTime.month(.wide).year())).",
                              systemImage: "calendar.badge.clock")
                            .foregroundStyle(model.reviewDue ? Theme.warn : .secondary)
                    }
                    Spacer()
                }
                .font(.callout.weight(.semibold))
                if !model.plan.isEmpty {
                    let todo = model.plan.first { !model.planDone.contains($0.id) }
                    HStack(spacing: 10) {
                        Image(systemName: "checklist").foregroundStyle(Tab.phone.color)
                        Text("Applying: \(model.planDone.count) of \(model.plan.count) done.").font(.callout)
                        Spacer()
                        if let todo, model.removing == nil {
                            RowButton(title: "Next: \(todo.title)…", symbol: "arrow.right.circle.fill", color: Tab.phone.color, style: .fill) { model.planNext() }
                        }
                        RowButton(title: "Stop", symbol: "xmark", color: .secondary) { model.stopPlan() }
                    }
                }
                HStack(spacing: 10) {
                    if model.planChanged {
                        RowButton(title: "Save the plan", symbol: "square.and.arrow.down.fill", color: Tab.phone.color, style: .fill) { model.savePlan() }
                            .help("Keeps these ages as your plan. Nothing is backed up or removed.")
                        RowButton(title: "Discard changes", symbol: "arrow.uturn.backward", color: .secondary) { model.discardPlan() }
                    }
                    if going.frees.count > 0 && model.plan.isEmpty {
                        RowButton(title: model.planChanged ? "Save & apply the plan…" : "Apply the plan…", symbol: "checklist",
                                  color: Tab.phone.color, style: model.planChanged ? .soft : .fill) {
                            if model.planChanged { model.savePlan() }
                            model.applyPlan(model.currentPlanSteps())
                        }
                        .help("Every source in turn: backs up what \(Backup.name) doesn't have yet, then shows each exact list. Nothing is removed until you click Delete when the dialog appears.")
                    }
                    Spacer()
                    RowButton(title: "See insights", symbol: "stethoscope", color: Tab.checkup.color) { model.tab = .checkup }
                    RowButton(title: "Explore the library", symbol: "chart.bar.xaxis", color: Tab.library.color) { model.tab = .library }
                }
                Text("Saving changes nothing on the phone. Apply one source with its own button, or the whole plan; each shows its list first, and nothing is removed until you click Delete when the dialog appears.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The rule builder as a floating window: from Make a rule, Add a rule, Edit, or a place's Filter.
struct RuleSheet: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FilterBuilder(model: model)
            HStack {
                Spacer()
                Button("Done") { model.builderOpen = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 960)
    }
}

/// A keep-on-phone age as a slider over the fixed stops, with "Keep everything" at the right.
struct AgeSlider: View {
    let value: String
    var tint: Color = Tab.phone.color
    let set: (String) -> Void

    private static let stops = Age.keepStops

    static func index(_ value: String) -> Int {
        guard let a = Age(value) else { return stops.count }
        return stops.firstIndex { $0.days >= a.days } ?? stops.count - 1
    }

    static func value(_ index: Int) -> String { index >= stops.count ? "off" : stops[index].description }

    static func words(_ value: String) -> String {
        guard let a = Age(value) else { return "Keep everything" }
        return "Keep last " + a.words
    }

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: Binding(get: { Double(Self.index(value)) },
                                  set: { set(Self.value(Int($0.rounded()))) }),
                   in: 0...Double(Self.stops.count), step: 1)
                .tint(tint)
                .frame(minWidth: 180)
            Text(Self.words(value)).font(.callout.weight(.semibold)).monospacedDigit()
                .frame(width: 150, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}
