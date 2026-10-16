import EventKit
import EventKitUI
import SwiftData
import SwiftUI
import UIKit

/// Three lists, the way you'd keep them: Calendar, To-dos and Shopping. What WTF heard sits at
/// the top of each, waiting for a yes ("Add") or a "Not Now"; below it, what's on the list.
struct ListsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ActionItem.created, order: .reverse) private var items: [ActionItem]
    @State private var drafts: [String: String] = [:]
    @State private var ticking: Set<UUID> = []
    @State private var calendarItem: ActionItem?
    /// The list being added to: kept after Return, so the next item can be typed straight away.
    @FocusState private var adding: String?
    /// Ticked items too, at the bottom of each list, so one ticked by mistake can be put back.
    @AppStorage("listsShowCompleted") private var showCompleted = false

    private struct ListGroup: Identifiable {
        var id: String, title: String, icon: String, empty: String, canAdd: Bool
    }

    private let groups = [
        ListGroup(id: "EVENT", title: "Calendar", icon: "calendar", empty: "Appointments and plans you mention appear here.", canAdd: false),
        ListGroup(id: "TODO", title: "To-dos", icon: "checklist", empty: "Things you say you'll do appear here.", canAdd: true),
        ListGroup(id: "BUY", title: "Shopping", icon: "cart", empty: "Things you need to buy appear here.", canAdd: true),
    ]

    private func suggested(_ type: String) -> [ActionItem] { items.filter { $0.status == "suggested" && $0.type == type } }
    private func listed(_ type: String) -> [ActionItem] {
        items.filter { $0.status == "accepted" && $0.type == type }.sorted { a, b in
            (a.start ?? .distantFuture, b.created) < (b.start ?? .distantFuture, a.created)
        }
    }
    private func completed(_ type: String) -> [ActionItem] { items.filter { $0.status == "done" && $0.type == type } }

    var body: some View {
        NavigationStack {
            List {
                Text("What WTF hears you mention waits here. Nothing goes on a list until you add it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
                ForEach(groups) { group in section(group) }
            }
            .animation(.snappy, value: items.map(\.status))
            .navigationTitle("Lists")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ListeningButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show Completed", systemImage: "checkmark.circle", isOn: $showCompleted)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .sheet(item: $calendarItem) { item in
                EventEditor(item: item) { saved in
                    if saved { item.status = "accepted"; save() }
                    calendarItem = nil
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private func section(_ group: ListGroup) -> some View {
        let waiting = suggested(group.id)
        let kept = listed(group.id)
        Section {
            ForEach(waiting) { s in
                SuggestionRow(item: s, onAccept: { accept(s) }, onDismiss: { finish(s, as: "dismissed") })
                    // As the kept items below: swipe it away, or swipe the other way to add it.
                    .swipeActions(edge: .trailing) {
                        Button("Dismiss", systemImage: "xmark", role: .destructive) { finish(s, as: "dismissed") }
                    }
                    .swipeActions(edge: .leading) {
                        Button(s.type == "EVENT" ? "Add to Calendar" : "Add", systemImage: "plus") { accept(s) }
                            .tint(.gray)
                    }
            }
            ForEach(kept) { item in
                CheckRow(item: item, ticking: ticking.contains(item.id)) { tick(item) }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.title }
                        if item.type == "EVENT" {
                            Button("Add to Calendar", systemImage: "calendar.badge.plus") { calendarItem = item }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { finish(item, as: "dismissed") }
                    }
            }
            .onDelete { offsets in
                for i in offsets { finish(kept[i], as: "dismissed", saving: false) } // kept as dismissed, so it isn't suggested again
                save()
            }
            if showCompleted {
                let done = completed(group.id)
                ForEach(done) { item in
                    CheckRow(item: item, ticking: false, done: true) { item.status = "accepted"; item.doneAt = nil; save() }
                }
                .onDelete { offsets in
                    for i in offsets { finish(done[i], as: "dismissed", saving: false) }
                    save()
                }
            }
            if group.canAdd {
                HStack(spacing: 14) {
                    Image(systemName: "plus.circle").font(.title2).foregroundStyle(.tertiary)
                    TextField(group.id == "BUY" ? "Add to shopping" : "Add to-do", text: Binding(
                        get: { drafts[group.id] ?? "" }, set: { drafts[group.id] = $0 }))
                        .focused($adding, equals: group.id)
                        .submitLabel(.next)
                        .onSubmit {
                            let typed = !(drafts[group.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                            add(group.id)
                            // Return ends editing first; then back to the field, as in Reminders.
                            // Return on an empty field puts the keyboard away.
                            if typed { Task { adding = group.id } }
                        }
                }
            } else if waiting.isEmpty && kept.isEmpty && !(showCompleted && !completed(group.id).isEmpty) {
                Text(group.empty).font(.subheadline).foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: group.icon).font(.headline).foregroundStyle(.secondary)
                Text(group.title).font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                Spacer()
                if !kept.isEmpty {
                    ShareLink(item: group.title + ":\n" + kept.map { "\u{2022} \($0.title)" + (detail($0).map { " (\($0))" } ?? "") }.joined(separator: "\n")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func accept(_ item: ActionItem) {
        if item.type == "EVENT" { calendarItem = item } else { item.status = "accepted"; save() }
    }

    /// Ticked items stay a moment, so a second tap can undo it.
    private func tick(_ item: ActionItem) {
        if ticking.contains(item.id) { ticking.remove(item.id); return }
        ticking.insert(item.id)
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard ticking.contains(item.id) else { return }
            ticking.remove(item.id)
            finish(item, as: "done")
        }
    }

    /// Ticked off or turned down: from now it's kept only as long as Keep Transcripts says.
    private func finish(_ item: ActionItem, as status: String, saving: Bool = true) {
        item.status = status
        item.doneAt = Date()
        if saving { save() }
    }

    private func add(_ type: String) {
        let t = (drafts[type] ?? "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        context.insert(ActionItem(type: type, title: t, status: "accepted"))
        drafts[type] = ""
        save()
    }

    private func save() { try? context.save() }
}

func detail(_ item: ActionItem) -> String? {
    guard item.type == "EVENT" else { return nil }
    var parts: [String] = []
    if let start = item.start {
        parts.append(item.allDay ? start.formatted(.dateTime.weekday(.wide).day().month(.wide))
                                 : start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
    }
    if let place = item.place { parts.append(place) }
    return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
}

struct SuggestionRow: View {
    let item: ActionItem
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkle").font(.footnote).foregroundStyle(.tertiary)
                .frame(width: 29, height: 29)
                .accessibilityLabel("Heard")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                if let d = detail(item) { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                if let note = item.note { NoteBadge(note: note) }
                if let quote = item.quote {
                    VStack(alignment: .leading, spacing: 2) {
                        if let at = item.heardAt { Text("From your conversation \(heardWhen(at))").font(.caption).foregroundStyle(.secondary) }
                        Text("\u{201C}\(quote)\u{201D}").font(.footnote).italic().foregroundStyle(.secondary).lineLimit(3)
                    }
                    .padding(.top, 2)
                }
                // Side by side, or one above the other when large text wouldn't fit them.
                ViewThatFits(in: .horizontal) {
                    HStack { addButton; dismissButton }
                    VStack(alignment: .leading, spacing: 8) { addButton; dismissButton }
                }
                .buttonBorderShape(.capsule)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private var addButton: some View {
        Button(item.type == "EVENT" ? "Add to Calendar" : "Add", action: onAccept).buttonStyle(.bordered)
    }

    private var dismissButton: some View {
        Button("Dismiss", action: onDismiss).buttonStyle(.borderless).foregroundStyle(.secondary)
    }
}

/// A Reminders row: the ring fills with a dot when ticked. A completed one (Show Completed)
/// stays filled, and a tap puts it back on the list.
struct CheckRow: View {
    let item: ActionItem
    let ticking: Bool
    var done = false
    let onTick: () -> Void

    private var filled: Bool { ticking || done }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onTick) {
                Image(systemName: filled ? "largecircle.fill.circle" : "circle")
                    .font(.title2)
                    .foregroundStyle(filled ? Color.primary : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Mark \(item.title) as not done" : "Mark \(item.title) as done")
            .accessibilityValue(filled ? "Done" : "")
            .sensoryFeedback(.success, trigger: ticking) { _, now in now }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).foregroundStyle(filled ? .secondary : .primary)
                if let d = detail(item) { Text(d).font(.footnote).foregroundStyle(.secondary) }
                if let note = item.note, item.type == "EVENT" { NoteBadge(note: note) }
            }
        }
    }
}

/// "Not booked yet", "Date not certain", "You said Saturday the 1st, but…": in black and white,
/// set apart by its outline rather than colour.
struct NoteBadge: View {
    let note: String

    var body: some View {
        Label(note, systemImage: note == "Not booked yet" ? "hourglass" : "exclamationmark.circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "at 2:09 pm", or "on Monday at 2:09 pm" if it wasn't today.
func heardWhen(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) { return "at \(time)" }
    if Calendar.current.isDateInYesterday(date) { return "yesterday at \(time)" }
    return "on \(date.formatted(.dateTime.weekday(.wide))) at \(time)"
}

/// The system's "New Event" sheet, filled in. Since iOS 17 it needs no calendar permission.
struct EventEditor: UIViewControllerRepresentable {
    let item: ActionItem
    let done: (Bool) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = item.title
        let start = item.start ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(9 * 3600)
        event.startDate = start
        event.endDate = item.allDay ? start : start.addingTimeInterval(3600)
        event.isAllDay = item.allDay
        event.location = item.place
        var notes: [String] = []
        if let note = item.note { notes.append(note + ".") }
        if let quote = item.quote { notes.append("Heard by WTF: \u{201C}\(quote)\u{201D}") }
        if !notes.isEmpty { event.notes = notes.joined(separator: "\n") }
        let vc = EKEventEditViewController()
        vc.eventStore = store
        vc.event = event
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            done(action == .saved)
        }
    }
}
