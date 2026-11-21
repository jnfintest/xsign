import SwiftUI
import XSignCore

// MARK: - Theme

enum Theme {
    static let accent = Color(hex: "#F0435A")
    static let beta = Color(hex: "#B07CFF")
    static let card = Color(.secondarySystemBackground)
    static let stroke = Color.primary.opacity(0.07)

    static func mono(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}

extension Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// Faint square grid behind every screen.
struct GridBackground: View {
    var spacing: CGFloat = 46

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing
            }
            context.stroke(path, with: .color(Theme.accent.opacity(0.09)), lineWidth: 0.6)
        }
        .background(Color(.systemBackground))
        .ignoresSafeArea()
    }
}

extension View {
    /// Grid background + room for the floating tab bar.
    func screen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(GridBackground())
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 84) }
    }
}

// MARK: - Building blocks

/// Spaced-out uppercase section label, e.g. "SIGNED APPS".
struct SectionLabel: View {
    let text: String
    var trailing: AnyView?

    init(_ text: String, trailing: AnyView? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(Theme.mono(.footnote, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }
}

/// Round icon button used in screen headers (✓ and +).
struct CircleButton: View {
    let systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 46, height: 46)
                .background(Theme.card, in: Circle())
                .overlay(Circle().stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

/// Large title header with optional leading/trailing round buttons.
struct ScreenHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                leading
                Spacer()
                trailing
            }
            .frame(minHeight: 46)
            Text(title).font(.system(size: 38, weight: .bold))
        }
        .padding(.top, 8)
    }
}

extension ScreenHeader where Leading == EmptyView {
    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.leading = EmptyView()
        self.trailing = trailing()
    }
}

extension ScreenHeader where Leading == EmptyView, Trailing == EmptyView {
    init(title: String) {
        self.title = title
        self.leading = EmptyView()
        self.trailing = EmptyView()
    }
}

/// App icon: cached icon file, then remote icon URL, then a monogram.
struct AppIconView: View {
    let name: String
    var iconFileName: String?
    var iconURL: URL?
    var tintHex: String?
    var size: CGFloat = 60

    var body: some View {
        Group {
            if let iconFileName,
               let image = UIImage(contentsOfFile: AppPaths.icons.appendingPathComponent(iconFileName).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { monogram }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 0.5))
    }

    private var monogram: some View {
        let tint = tintHex.map(Color.init(hex:)) ?? Theme.accent
        return ZStack {
            LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

/// Capsule action button that becomes a progress ring while a job runs.
struct ActionPill: View {
    let title: String
    var prominent: Bool = true
    var phase: JobPhase?
    var action: () -> Void
    var cancel: (() -> Void)?

    var body: some View {
        if let phase, phase.isBusy {
            Button { cancel?() } label: {
                ZStack {
                    ProgressRing(progress: phase.progress)
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
                }
                .frame(width: 32, height: 32)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
        } else {
            Button {
                Haptics.tap()
                action()
            } label: {
                Text(title.uppercased())
                    .font(Theme.mono(.subheadline, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .foregroundStyle(prominent ? Color.white : Theme.accent)
                    .background(prominent ? Theme.accent : Theme.accent.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Square icon button (the install / re-sign / share row).
struct SquareIconButton: View {
    let systemImage: String
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(width: 44, height: 44)
                .background(prominent ? Theme.accent : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

struct ProgressRing: View {
    let progress: Double?
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 3)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = true }
            }
        }
    }
}

struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(Theme.mono(.caption, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

/// One-line status under a row title: job progress or error.
struct PhaseText: View {
    let phase: JobPhase
    var onDismiss: () -> Void

    var body: some View {
        Text(phase.label)
            .font(Theme.mono(.caption))
            .foregroundStyle(phase.isBusy ? Theme.accent : (phase == .finished ? Color.green : Color.red))
            .lineLimit(phase.isBusy || phase == .finished ? 3 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .onTapGesture(perform: onDismiss)
    }
}

// MARK: - Formatting helpers

extension Date {
    var relative: String { RelativeDateTimeFormatter().localizedString(for: self, relativeTo: Date()) }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension CertificateRecord {
    var daysLeft: Int? {
        expirationDate.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 }
    }

    var expiryText: String {
        guard let days = daysLeft else { return "No expiry" }
        if isExpired { return "Expired" }
        return days <= 1 ? "Expires today" : "\(days) days left"
    }

    var expiryTint: Color {
        guard let days = daysLeft else { return .secondary }
        if isExpired { return .red }
        return days < 7 ? .orange : .green
    }
}
