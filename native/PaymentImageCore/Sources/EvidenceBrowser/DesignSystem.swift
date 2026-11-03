#if os(macOS) || os(iOS)
import SwiftUI
import Observation

/// Shared visual language for macOS and iOS: spacing, semantic colors and the
/// small set of components every page is built from.
enum DS {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24
    static let corner: CGFloat = 12
    static let accent = Color.teal
    static let pending = Color.orange
    static let failure = Color.red
    static let draft = Color.blue
    static let confirmed = Color.green
    #if os(macOS)
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    #else
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    #endif
}

enum BadgeTone { case pending, failure, draft, confirmed, accent, neutral
    var color: Color {
        switch self {
        case .pending: DS.pending
        case .failure: DS.failure
        case .draft: DS.draft
        case .confirmed: DS.confirmed
        case .accent: DS.accent
        case .neutral: .secondary
        }
    }
}

struct StatusBadge: View {
    let text: String
    var tone: BadgeTone = .pending
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tone.color)
            .background(tone.color.opacity(0.14), in: Capsule())
    }
}

/// Selectable capsule used for queue types, scopes and filters.
struct FilterChip: View {
    let title: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.xs) {
                Text(title)
                if let count { Text("\(count)").monospacedDigit().opacity(0.75) }
            }
            .font(.callout).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? AnyShapeStyle(DS.accent) : AnyShapeStyle(.quaternary), in: Capsule())
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Long explanations live behind ⓘ instead of permanent captions.
struct InfoButton: View {
    let text: String
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .accessibilityLabel("说明")
            .popover(isPresented: $shown) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading).padding(DS.l)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

struct SectionHeader: View {
    let title: String
    var info: String? = nil
    var body: some View {
        HStack(spacing: DS.s) {
            Text(title).font(.headline)
            if let info { InfoButton(text: info) }
            Spacer(minLength: 0)
        }
    }
}

/// Inline status line for messages and errors that belong to the page.
struct NoticeText: View {
    let text: String
    var tone: BadgeTone = .neutral
    var body: some View {
        Label(text, systemImage: tone == .failure ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.callout).foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
            .textSelection(.enabled)
    }
}

@Observable @MainActor final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID(); let text: String; let undoTitle: String?
        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }
    static let shared = ToastCenter()
    private(set) var current: Toast?
    @ObservationIgnored private var undoAction: (() -> Void)?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ text: String, undoTitle: String? = nil, undo: (() -> Void)? = nil) {
        current = Toast(text: text, undoTitle: undo == nil ? nil : (undoTitle ?? "撤销"))
        undoAction = undo
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
    func performUndo() { let action = undoAction; dismiss(); action?() }
    func dismiss() { dismissTask?.cancel(); current = nil; undoAction = nil }
}

struct ToastOverlay: ViewModifier {
    @State private var center = ToastCenter.shared
    var bottomPadding: CGFloat = DS.xl
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                HStack(spacing: DS.m) {
                    Text(toast.text).font(.callout)
                    if let undo = toast.undoTitle {
                        Button(undo) { center.performUndo() }.buttonStyle(.borderless).fontWeight(.semibold).foregroundStyle(DS.accent)
                    }
                }
                .padding(.horizontal, DS.l).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.bottom, bottomPadding)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }.animation(.snappy, value: center.current)
    }
}

extension Notification.Name {
    /// Posted with a completion entry id to adopt its category suggestion from a keyboard command.
    static let adoptCategorySuggestion = Notification.Name("AdoptCategorySuggestion")
}

extension View {
    func toastOverlay(bottomPadding: CGFloat = DS.xl) -> some View { modifier(ToastOverlay(bottomPadding: bottomPadding)) }
    /// Card container shared by both platforms.
    func cardStyle(padding: CGFloat = DS.l) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.cardBackground, in: RoundedRectangle(cornerRadius: DS.corner))
    }
}
#endif
