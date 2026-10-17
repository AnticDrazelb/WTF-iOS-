import SwiftUI
import WTFCore

/// The thread map: the topics a conversation wandered through, left to right. Ones dropped
/// part-way have a dashed outline; tap any to get back to where you were with it (not while
/// another answer's being written, as that tap would be lost).
struct ThreadTrail: View {
    @Environment(AppModel.self) private var model
    let threads: [TopicThread]
    let onTap: (TopicThread) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(threads.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).accessibilityHidden(true) }
                        Button { onTap(t) } label: { ThreadChip(thread: t) }
                            .buttonStyle(.plain)
                            .disabled(model.status != nil)
                            .id(t.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(threads.last?.id, anchor: .trailing) }
            .onChange(of: threads.count) { withAnimation(.snappy) { proxy.scrollTo(threads.last?.id, anchor: .trailing) } }
        }
    }
}

struct ThreadChip: View {
    let thread: TopicThread

    private var hanging: Bool { thread.status == .hanging }
    private var current: Bool { thread.status == .current }
    private var color: Color { current || hanging ? .primary : .secondary }

    var body: some View {
        HStack(spacing: 5) {
            if hanging {
                Image(systemName: "ellipsis.bubble.fill")
            } else if current {
                // Not the waveform: that's kept for listening.
                Image(systemName: "smallcircle.filled.circle")
            }
            Text(thread.title).lineLimit(1)
        }
        .font(.subheadline.weight(current ? .semibold : .regular))
        .foregroundStyle(color)
        .padding(.horizontal, 12).padding(.vertical, 7)
        // Left hanging: an open, dashed outline, as if it's waiting to be finished.
        .background(Capsule().fill(Color.primary.opacity(current ? 0.1 : 0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).opacity(hanging ? 1 : 0))
        .accessibilityLabel(thread.title + (hanging ? ", left hanging" : current ? ", talking about now" : ""))
    }
}

/// The threads as a list, for a conversation's page. A tap asks where you were with it, in Ask;
/// not while another answer's being written, as that tap would be lost.
struct ThreadList: View {
    @Environment(AppModel.self) private var model
    let threads: [TopicThread]
    let onTap: (TopicThread) -> Void

    var body: some View {
        ForEach(threads) { t in
            Button { onTap(t) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon(t)).foregroundStyle(t.status == .current || t.status == .hanging ? Color.primary : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).foregroundStyle(.primary)
                        if let facts = t.facts, !facts.isEmpty {
                            Text(facts).font(.footnote).foregroundStyle(.secondary)
                        }
                        if t.status == .hanging, let left = t.leftAt, !left.isEmpty {
                            Text(left.prefix(1).uppercased() + left.dropFirst()).font(.footnote).italic().foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(t.start, format: .dateTime.hour().minute()).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(model.status != nil)
            .accessibilityHint("Asks where you were with this topic")
        }
    }

    private func icon(_ t: TopicThread) -> String {
        switch t.status {
        case .hanging: return "ellipsis.bubble.fill"
        case .current: return "smallcircle.filled.circle"
        case .resumed: return "arrow.uturn.backward.circle"
        case .finished: return "checkmark.circle"
        }
    }
}
