import SwiftUI

// Small, reusable presentation primitives shared across the RunnerManager UI:
// StatusDot, UpdateBadge, BannerView, Chip, and LabeledRow.
//
// These are pure view components: they hold no state of their own and never touch
// services, the network, or secrets. They translate already-computed model values
// (a RunnerStatus.Severity, a BannerMessage, a label string, …) into SwiftUI views.

// MARK: - StatusDot

/// A small filled circle whose color encodes a runner's status severity.
///
/// Color mapping (per spec): ok = green, warn = orange, bad = red, neutral = gray.
/// We take a `RunnerStatus.Severity` rather than a full `RunnerStatus` so the same dot
/// can be reused for any severity-bearing value and so the mapping lives in one place.
struct StatusDot: View {
    let severity: RunnerStatus.Severity

    /// Diameter of the dot in points. Defaults to a row-friendly size.
    var diameter: CGFloat = 10

    /// Convenience initializer to build the dot directly from a `RunnerStatus`.
    init(status: RunnerStatus, diameter: CGFloat = 10) {
        self.severity = status.severity
        self.diameter = diameter
    }

    /// Designated initializer taking a precomputed severity.
    init(severity: RunnerStatus.Severity, diameter: CGFloat = 10) {
        self.severity = severity
        self.diameter = diameter
    }

    /// The fill color for the current severity.
    private var color: Color {
        switch severity {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        case .neutral: return .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            // A subtle outline keeps the dot legible on both light and dark backgrounds.
            .overlay(
                Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            // Expose the human-readable severity to assistive technologies.
            .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accessibilityLabel: String {
        switch severity {
        case .ok: return "OK"
        case .warn: return "Warning"
        case .bad: return "Error"
        case .neutral: return "Unknown"
        }
    }
}

// MARK: - UpdateBadge

/// A small "Update" capsule shown next to a runner that has a newer release available.
struct UpdateBadge: View {
    /// Optional text override; defaults to "Update".
    var text: String = "Update"

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.18))
            )
            .overlay(
                Capsule().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 0.5)
            )
            .foregroundColor(.accentColor)
            .accessibilityLabel(Text("Update available"))
    }
}

// MARK: - BannerView

/// A colored, dismissible bar shown at the top of the window for errors / info / success.
///
/// The bar color is chosen from the message `kind`. The dismiss button invokes `onDismiss`,
/// which the parent uses to clear `AppState.banner`. The message text is presented verbatim;
/// callers are responsible for redaction (AppState already redacts via `Log.redact`).
struct BannerView: View {
    let message: BannerMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(foreground)
                .accessibilityHidden(true)

            Text(message.text)
                .font(.callout)
                .foregroundColor(foreground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(foreground.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel(Text("Dismiss message"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(background)
        .overlay(
            // A thin bottom rule separates the banner from the content below it.
            Rectangle()
                .fill(foreground.opacity(0.25))
                .frame(height: 0.5),
            alignment: .bottom
        )
        .accessibilityElement(children: .combine)
    }

    /// Base tint color for the message kind; foreground/background derive from this.
    private var tint: Color {
        switch message.kind {
        case .error: return .red
        case .info: return .blue
        case .success: return .green
        }
    }

    /// SF Symbol matching the message kind.
    private var iconName: String {
        switch message.kind {
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var foreground: Color { tint }
    private var background: Color { tint.opacity(0.12) }
}

// MARK: - Chip

/// A small rounded "chip" used to display a single label (e.g. a runner's GitHub labels).
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.secondary.opacity(0.15))
            )
            .overlay(
                Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            .foregroundColor(.primary)
            .accessibilityLabel(Text("Label \(text)"))
    }
}

// MARK: - LabeledRow

/// A two-column "label + value" row for detail/settings layouts: a fixed-width caption on the
/// leading edge and arbitrary trailing content. Use the `String` convenience initializer for
/// plain text values, or the trailing-closure form for custom content (buttons, chips, …).
struct LabeledRow<Content: View>: View {
    let label: String
    /// Width reserved for the label column so multiple rows align.
    var labelWidth: CGFloat = 120
    let content: Content

    init(_ label: String, labelWidth: CGFloat = 120, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

extension LabeledRow where Content == Text {
    /// Convenience: a labeled row whose value is plain, selectable text.
    init(_ label: String, value: String, labelWidth: CGFloat = 120) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = Text(value)
    }
}
