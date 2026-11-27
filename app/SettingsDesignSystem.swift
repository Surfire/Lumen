import AppKit
import SwiftUI

// MARK: - Appearance & Dynamic Palette

private extension NSAppearance {
    var lumenIsDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

enum SettingsTheme {
    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let c = appearance.lumenIsDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        }))
    }

    // Surfaces
    /// Light: #F5F2ED | Dark: #161618
    static let sidebarBackground = dynamic(
        light: (0.9608, 0.9490, 0.9294, 1.0),
        dark:  (0.0863, 0.0863, 0.0941, 1.0)
    )
    /// Light: #FAF8F5 | Dark: #1C1C1F
    static let canvasBackground = dynamic(
        light: (0.9804, 0.9725, 0.9608, 1.0),
        dark:  (0.1098, 0.1098, 0.1216, 1.0)
    )
    /// Light: #FFFFFF | Dark: #232327
    static let cardBackground = dynamic(
        light: (1.0, 1.0, 1.0, 1.0),
        dark:  (0.1373, 0.1373, 0.1529, 1.0)
    )
    /// Light: rgba(0,0,0,0.08) | Dark: rgba(255,255,255,0.085)
    static let cardBorder = dynamic(
        light: (0.0, 0.0, 0.0, 0.08),
        dark:  (1.0, 1.0, 1.0, 0.085)
    )
    /// Light: #EFECE6 | Dark: #2B2B30
    static let wellBackground = dynamic(
        light: (0.9373, 0.9255, 0.9020, 1.0),
        dark:  (0.1686, 0.1686, 0.1882, 1.0)
    )
    static let wellBorder = dynamic(
        light: (0.0, 0.0, 0.0, 0.06),
        dark:  (1.0, 1.0, 1.0, 0.065)
    )
    /// Light: #1C1917 | Dark: #32323A
    static let navActiveBackground = dynamic(
        light: (0.1098, 0.0980, 0.0902, 1.0),
        dark:  (0.1961, 0.1961, 0.2275, 1.0)
    )
    /// Transparent in Light mode; warm amber bar in Dark mode.
    static let navActiveIndicator = dynamic(
        light: (0.0, 0.0, 0.0, 0.0),
        dark:  (0.8784, 0.5961, 0.2627, 1.0)
    )
    static let navActiveTitle = Color.white
    static let navActiveSubtitle = Color.white.opacity(0.72)

    // Accents & Status
    /// Light: #C47B29 | Dark: #E09843
    static let amber = dynamic(
        light: (0.7686, 0.4824, 0.1608, 1.0),
        dark:  (0.8784, 0.5961, 0.2627, 1.0)
    )
    /// Dedicated high-contrast fill for white-on-amber primary CTAs (WCAG AA in both themes).
    static let primaryCtaFill = dynamic(
        light: (0.7686, 0.4627, 0.0980, 1.0),
        dark:  (0.7059, 0.3961, 0.0667, 1.0)
    )
    static let green = dynamic(
        light: (0.1765, 0.5412, 0.3059, 1.0),
        dark:  (0.3216, 0.7686, 0.4824, 1.0)
    )
    static let red = dynamic(
        light: (0.7882, 0.2314, 0.1961, 1.0),
        dark:  (0.9176, 0.4157, 0.3765, 1.0)
    )

    // Typography & Hairlines
    static let textPrimary = dynamic(
        light: (0.1098, 0.0980, 0.0902, 1.0),
        dark:  (0.9569, 0.9569, 0.9647, 1.0)
    )
    static let textSecondary = dynamic(
        light: (0.3412, 0.3255, 0.3059, 1.0),
        dark:  (0.6902, 0.6902, 0.7294, 1.0)
    )
    static let textTertiary = dynamic(
        light: (0.4706, 0.4431, 0.4235, 1.0),
        dark:  (0.5176, 0.5176, 0.5647, 1.0)
    )
    static let hairline = dynamic(
        light: (0.0, 0.0, 0.0, 0.075),
        dark:  (1.0, 1.0, 1.0, 0.08)
    )

    // Spacing & Geometry
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingLG: CGFloat = 16
    static let spacingXL: CGFloat = 24

    static let cornerSM: CGFloat = 6
    static let cornerMD: CGFloat = 8
    static let cornerLG: CGFloat = 12
}

// MARK: - Editorial Header

struct LumenSettingsHeader: View {
    let kicker: String
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(kicker.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(SettingsTheme.textTertiary)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(SettingsTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(description)
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

// MARK: - Editorial Card

struct LumenSettingsCard<Trailing: View, Content: View>: View {
    let title: String
    let icon: String?
    let trailing: Trailing
    let content: Content

    init(
        title: String,
        icon: String? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsTheme.amber)
                        .accessibilityHidden(true)
                }
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(SettingsTheme.textTertiary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.cornerLG, style: .continuous)
                .fill(SettingsTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.cornerLG, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }
}

extension LumenSettingsCard where Trailing == EmptyView {
    init(
        title: String,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, icon: icon, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Recessed Well

struct LumenSettingsWell<Content: View>: View {
    var padding: CGFloat = 10
    let content: Content

    init(padding: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                .fill(SettingsTheme.wellBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                .strokeBorder(SettingsTheme.wellBorder, lineWidth: 0.75)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Row, Metric Tile, Pill & Hairline

struct LumenSettingsRow: View {
    let label: String
    let value: String
    var statusColor: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(SettingsTheme.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(statusColor ?? SettingsTheme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }
}

struct LumenSettingsMetricTile: View {
    let label: String
    let value: String
    var subtitle: String? = nil
    var accent: Color = SettingsTheme.amber

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsTheme.textTertiary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundStyle(SettingsTheme.textPrimary)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                .fill(SettingsTheme.wellBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                .strokeBorder(SettingsTheme.wellBorder, lineWidth: 0.75)
                .allowsHitTesting(false)
        )
    }
}

struct LumenStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

struct LumenSettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(SettingsTheme.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Editorial Controls & Modifiers

struct LumenPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                    .fill(SettingsTheme.primaryCtaFill.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1.0) : 0.42))
            )
            .contentShape(Rectangle())
    }
}

struct LumenSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SettingsTheme.textPrimary.opacity(isEnabled ? 1.0 : 0.45))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                    .fill(SettingsTheme.wellBackground.opacity(configuration.isPressed ? 0.72 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                    .strokeBorder(SettingsTheme.wellBorder, lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
    }
}

struct LumenWellFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(SettingsTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                    .fill(SettingsTheme.wellBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                    .strokeBorder(SettingsTheme.wellBorder, lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    func lumenWellField() -> some View {
        modifier(LumenWellFieldModifier())
    }
}
