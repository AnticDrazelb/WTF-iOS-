import SwiftData
import SwiftUI
import WTFCore

/// A day, for the Timeline to open: "Your Day".
struct DayRef: Hashable {
    let day: Date
}

extension Conversation {
    /// What "Your Day" reads of it: its notes, not its words.
    var dayNote: DayNote {
        let m = memory
        let hanging = threads.filter { $0.status == .hanging }.map { t in t.leftAt.map { "\(t.title): \($0)" } ?? t.title } + m.open
        return DayNote(start: start, title: title ?? "",
                       points: summary?.split(separator: "\n").map(String.init) ?? [],
                       decided: m.decided, todo: m.todo, hanging: hanging)
    }
}

/// What the day's recap is written from: the conversations that have been summarised.
private func written(_ conversations: [Conversation]) -> [DayNote] {
    conversations.filter { $0.title != nil }.map(\.dayNote)
}

private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

/// The top of each day in the Timeline: a few sentences on the whole of it, and how much got
/// settled, is still to do and was left hanging. Tap for all of it.
struct YourDayRow: View {
    let day: Date
    let conversations: [Conversation]
    @State private var recap: String?
    @State private var writing = false

    /// Days this recent are written up as soon as they're shown; older ones when they're opened.
    private var recent: Bool {
        let cal = Calendar.current
        return day >= cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))!
    }

    var body: some View {
        let notes = conversations.map(\.dayNote)
        let toWrite = written(conversations)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Your Day", systemImage: "sun.horizon").font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            Text(recap ?? DayReview.plain(notes, time: clock))
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(5)
            if writing {
                Text("Writing it up\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
            let counts = Self.counts(notes)
            if !counts.isEmpty {
                Text(counts).font(.caption.weight(.medium))
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .padding(.vertical, 4)
        .animation(.default, value: recap)
        .task(id: DayDigests.fingerprint(toWrite)) {
            recap = DayDigests.shared.last(for: day)
            guard recent else { return }
            writing = DayDigests.shared.needsWriting(day, notes: toWrite)
            if let fresh = await DayDigests.shared.recap(for: day, notes: toWrite) { recap = fresh }
            writing = false
        }
    }

    /// "2 decided · 3 to do · 1 left hanging".
    static func counts(_ notes: [DayNote]) -> String {
        let parts = [
            (DayReview.gather(notes, limit: 99) { $0.decided }.count, "decided"),
            (DayReview.gather(notes, limit: 99) { $0.todo }.count, "to do"),
            (DayReview.gather(notes, limit: 99) { $0.hanging }.count, "left hanging"),
        ]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " \u{00B7} ")
    }
}

/// "Your Day" in full: the recap, what got settled, what's still to do, what was left hanging,
/// and every conversation; each a tap from where it was said.
struct DayView: View {
    let day: Date
    @Query private var conversations: [Conversation]
    @State private var recap: String?
    @State private var writing = false

    init(day: Date) {
        self.day = day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        _conversations = Query(filter: #Predicate<Conversation> { $0.start >= day && $0.start < end }, sort: \Conversation.start)
    }

    var body: some View {
        let notes = conversations.map(\.dayNote)
        let toWrite = written(conversations)
        List {
            Section {
                Text(recap ?? DayReview.plain(notes, time: clock))
                if writing {
                    Text("Writing it up\u{2026}").font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(dayLabel(day))
            }
            items("Decided", icon: "checkmark.circle", DayReview.gather(notes, limit: 40) { $0.decided })
            items("To Do", icon: "circle", DayReview.gather(notes, limit: 40) { $0.todo })
            items("Left Hanging", icon: "ellipsis.bubble", DayReview.gather(notes, limit: 40) { $0.hanging })
            if !conversations.isEmpty {
                Section("Conversations") {
                    ForEach(conversations) { c in
                        NavigationLink(value: c) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(clock(c.start)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayTitle(c)).font(.headline)
                                    if let first = c.summary?.split(separator: "\n").first {
                                        Text(DayReview.tidy(String(first))).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Your Day")
        .animation(.default, value: recap)
        .task(id: DayDigests.fingerprint(toWrite)) {
            recap = DayDigests.shared.last(for: day)
            writing = DayDigests.shared.needsWriting(day, notes: toWrite)
            if let fresh = await DayDigests.shared.recap(for: day, notes: toWrite) { recap = fresh }
            writing = false
        }
    }

    @ViewBuilder
    private func items(_ title: String, icon: String, _ found: [(text: String, from: Int)]) -> some View {
        if !found.isEmpty {
            Section(title) {
                ForEach(Array(found.enumerated()), id: \.offset) { _, item in
                    let c = conversations[item.from]
                    NavigationLink(value: c) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text)
                                Text(displayTitle(c)).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: icon).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
