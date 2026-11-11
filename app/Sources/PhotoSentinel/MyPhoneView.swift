import PhotoCore
import SwiftUI

/// The first page: where the phone's storage goes, a slider per source for how much of it
/// stays, and what the phone looks like with those choices, live as a slider moves.
/// The ages are the same ones every clean-up, Checkup and the Library use.
struct MyPhoneView: View {
    @ObservedObject var model: Model
    @State private var refreshing: Task<Void, Never>?

    /// Biggest sources first is the Library's job; here the order is fixed, so a slider
    /// never jumps away from under the pointer as the numbers change.
    /// The button column beside a slider, the same width on every row so the sliders line up.
    private static let actionWidth: CGFloat = 150

    private static let order: [Channel] = [.camera, .whatsapp, .screenshot, .screenRecording, .otherApps, .unattributed]

    var body: some View {
        if let s = model.library {
            VStack(alignment: .leading, spacing: 14) {
                future(s)
                sliders(s)
                next
            }
            // The rest of the app (Checkup, Library) catches up once the slider is let go.
            .onChange(of: model.ages) {
                refreshing?.cancel()
                refreshing = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    if !Task.isCancelled { model.refresh() }
                }
            }
        }
    }

    // MARK: Numbers

    private func leaving(_ kind: Recipe.Kind) -> AgeProfile.Part {
        model.profile?.leaving(kind, Age(model.age(kind))) ?? AgeProfile.Part()
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
        let going = leavingAll
        let after = max(s.onPhone.bytes - going.frees.bytes, 0)
        let channels = Self.order.filter { onPhone(s, $0).bytes > 0 }
        func left(_ c: Channel) -> Int64 {
            let g = KeepGroup.allCases.first { $0.channel == c }
            return max(onPhone(s, c).bytes - (g.map { leaving($0).frees.bytes } ?? 0), 0)
        }
        return Card(title: "Where your iPhone's storage goes", symbol: "internaldrive.fill", tint: Tab.phone.color,
                    trailing: model.loading ? AnyView(ProgressView().controlSize(.small)) : nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Fmt.bytes(s.onPhone.bytes)).font(.system(size: 30, weight: .bold)).monospacedDigit()
                    Image(systemName: "arrow.right").font(.title3.weight(.bold)).foregroundStyle(.secondary)
                    Text(Fmt.bytes(after)).font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.good).monospacedDigit()
                    VStack(alignment: .leading, spacing: 0) {
                        Text("on your iPhone with the choices below").font(.callout)
                        Text(going.frees.count == 0 ? "Everything stays as it is."
                             : "Frees \(Fmt.bytes(going.frees.bytes)): \(Fmt.count(going.frees.count)) items go to \(Backup.name).")
                            .font(.callout.weight(.semibold)).foregroundStyle(going.frees.count == 0 ? Color.secondary : Theme.good)
                    }
                    .monospacedDigit()
                }
                bar("TODAY", channels.map { (Theme.color($0), Double(onPhone(s, $0).bytes)) })
                bar("AFTER", channels.map { (Theme.color($0), Double(left($0))) } + [(Theme.good.opacity(0.22), Double(going.frees.bytes))])
                HStack(spacing: 14) {
                    ForEach(channels) { c in
                        let now = onPhone(s, c).bytes
                        legend(Theme.color(c), "\(c.title) " + (left(c) == now ? Fmt.bytes(now) : "\(Fmt.bytes(now)) → \(Fmt.bytes(left(c)))"))
                    }
                    if going.frees.bytes > 0 { legend(Theme.good.opacity(0.22), "Freed \(Fmt.bytes(going.frees.bytes))") }
                }
                .font(.caption)
                if going.frees.count > 0 {
                    HStack(spacing: 14) {
                        Label("\(Fmt.bytes(going.removableNow.bytes)) is already in \(Backup.name) and can go now", systemImage: "checkmark.icloud.fill")
                            .foregroundStyle(Theme.good)
                        if going.notBackedUp.bytes > 0 {
                            Label("\(Fmt.bytes(going.notBackedUp.bytes)) is backed up first", systemImage: "icloud.and.arrow.up.fill")
                                .foregroundStyle(Theme.warn)
                        }
                    }
                    .font(.caption.weight(.semibold)).monospacedDigit()
                }
            }
        }
    }

    private func bar(_ label: String, _ parts: [(Color, Double)]) -> some View {
        HStack(spacing: 10) {
            Text(label).sectionLabel().frame(width: 46, alignment: .leading)
            StackBar(parts: parts, height: 22)
                .animation(.easeOut(duration: 0.2), value: parts.map(\.1))
        }
    }

    private func legend(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: 10)
            Text(text).monospacedDigit()
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
                AgeSlider(value: model.groupAge(g), tint: Theme.color(g.channel)) { model.setGroupAge(g, $0) }
                Color.clear.frame(width: Self.actionWidth, height: 1)
                frees(going)
            }
            if g.kinds.count > 1 {
                ForEach(g.kinds, id: \.self) { kind in kindRow(g, kind) }
            }
        }
    }

    /// Photos or videos inside a group: following it, or with an age of its own.
    private func kindRow(_ g: KeepGroup, _ kind: Recipe.Kind) -> some View {
        let total = onPhone(kind)
        let own = model.isOverridden(kind)
        return HStack(spacing: 12) {
            Image(systemName: KeepGroup.part(kind) == "Videos" ? "video.fill" : "photo.fill")
                .foregroundStyle(Theme.color(g.channel)).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(KeepGroup.part(kind)).font(.callout)
                Text("\(Fmt.bytes(total.bytes)) · \(Fmt.count(total.count))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 152, alignment: .leading)
            if own {
                AgeSlider(value: model.age(kind), tint: Theme.color(g.channel)) { model.setAge(kind, $0) }
                RowButton(title: "Follow \(g.channel.title)", symbol: "arrow.uturn.backward", color: .secondary) { model.followGroup(kind) }
                    .frame(width: Self.actionWidth, alignment: .trailing)
                    .help("Use the \(g.channel.title) slider above for \(KeepGroup.part(kind).lowercased()) again.")
            } else {
                Text("Follows \(g.channel.title): \(AgeSlider.words(model.age(kind)).lowercased())")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                RowButton(title: "Set its own", symbol: "slider.horizontal.below.rectangle", color: Theme.color(g.channel)) {
                    model.giveOwnAge(kind)
                }
                .frame(width: Self.actionWidth, alignment: .trailing)
                .help("Give \(g.channel.title) \(KeepGroup.part(kind).lowercased()) a different age, e.g. keep videos for 6 months and photos for 2 years.")
            }
            frees(leaving(kind))
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
                model.draft = Filter()
                model.openBuilder()
            }
        }
    }

    private func frees(_ p: AgeProfile.Part) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(p.frees.bytes > 0 ? "frees \(Fmt.bytes(p.frees.bytes))" : "frees nothing")
                .font(.callout.weight(.semibold)).foregroundStyle(p.frees.bytes > 0 ? Theme.good : .secondary)
            Text(p.frees.count > 0 ? "\(Fmt.count(p.frees.count)) items" : " ").font(.caption).foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .frame(width: 110, alignment: .trailing)
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

    // MARK: Next

    private var next: some View {
        let going = leavingAll
        return Card(title: "Next", symbol: "arrow.right.circle.fill", tint: Tab.phone.color) {
            VStack(alignment: .leading, spacing: 10) {
                if !model.plan.isEmpty {
                    let todo = model.plan.first { !model.planDone.contains($0.id) }
                    HStack(spacing: 10) {
                        Image(systemName: "checklist").foregroundStyle(Tab.phone.color)
                        Text("Applying your plan: \(model.planDone.count) of \(model.plan.count) types done.").font(.callout)
                        Spacer()
                        if let todo, model.removing == nil {
                            RowButton(title: "Next: \(todo.title)…", symbol: "arrow.right.circle.fill", color: Tab.phone.color, style: .fill) { model.planNext() }
                        }
                        RowButton(title: "Stop", symbol: "xmark", color: .secondary) { model.stopPlan() }
                    }
                }
                HStack(spacing: 10) {
                    if going.frees.count > 0 && model.plan.isEmpty {
                        RowButton(title: "Apply my plan…", symbol: "checklist", color: Tab.phone.color, style: .fill) {
                            model.applyPlan(model.currentPlanSteps())
                        }
                        .help("Backs up what \(Backup.name) doesn't have yet, then takes you through each type: the exact list, then you click Delete when the dialog appears.")
                    }
                    RowButton(title: "See insights", symbol: "stethoscope", color: Tab.checkup.color) { model.tab = .checkup }
                    RowButton(title: "Explore the library", symbol: "chart.bar.xaxis", color: Tab.library.color) { model.tab = .library }
                    Spacer()
                }
                Text("Nothing leaves the phone from this page. Apply my plan shows each list first, and nothing is removed until you click Delete when the dialog appears.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
