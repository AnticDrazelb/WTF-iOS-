import SwiftData
import SwiftUI
import WTFCore

/// Settings › Things WTF Knows: facts it picked up that last beyond the day ("Mum's birthday is
/// 2 November"), given to the AI when they're relevant. Change, remove or add your own.
struct FactsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Fact.created, order: .reverse) private var facts: [Fact]
    @State private var draft = ""
    @State private var editing: Fact?
    @State private var typed = ""

    var body: some View {
        List {
            Section {
                ForEach(facts) { f in
                    Button {
                        typed = f.text
                        editing = f
                    } label: {
                        Text(f.text).foregroundStyle(.primary)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(facts[i]) }
                    try? context.save()
                }
                HStack(spacing: 14) {
                    Image(systemName: "plus.circle").font(.title2).foregroundStyle(.tertiary)
                    TextField("Add something to remember", text: $draft)
                        .onSubmit(add)
                }
            } footer: {
                Text("Picked up from your conversations, or added by you, and used when they\u{2019}re relevant: \u{201C}her birthday\u{201D} means something next week. Swipe to remove one.")
            }
        }
        .navigationTitle("Things WTF Knows")
        .alert("Edit", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Fact", text: $typed)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                if let f = editing, !t.isEmpty { f.text = t; try? context.save() }
            }
        }
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        context.insert(Fact(text: t))
        try? context.save()
        draft = ""
    }
}

/// Settings › Words You've Corrected: the fixes WTF learnt from you, which it uses to catch the
/// same mistakes. Swipe to forget one.
struct FixesView: View {
    @State private var fixes = Learned.fixes

    var body: some View {
        List {
            Section {
                ForEach(Array(fixes.enumerated()), id: \.offset) { _, f in
                    HStack {
                        Text(f.heard).foregroundStyle(.secondary).strikethrough()
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        Text(f.meant)
                        Spacer()
                        if f.count > 1 { Text("\u{00D7}\(f.count)").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .onDelete { offsets in
                    fixes.remove(atOffsets: offsets)
                    Learned.fixes = fixes
                }
            } footer: {
                Text(fixes.isEmpty ? "Hold a line in any transcript and choose Fix Words to correct what was misheard. WTF learns from it."
                     : "What you meant is given to the recogniser as words to expect, and the mistakes to the AI that fixes misheard words.")
            }
        }
        .navigationTitle("Words You\u{2019}ve Corrected")
    }
}
