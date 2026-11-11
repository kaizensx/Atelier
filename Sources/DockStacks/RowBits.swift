import DockCore
import SwiftUI

// MARK: - Demoted row furniture

/// When a change lands, as one glyph. The full sentence is in the help tag. Instant changes say nothing.
struct ApplyHint: View {
    enum Kind {
        case restart, reopen, logout

        var symbol: String {
            switch self {
            case .restart: "arrow.triangle.2.circlepath"
            case .reopen: "arrow.clockwise"
            case .logout: "rectangle.portrait.and.arrow.right"
            }
        }

        var short: String {
            switch self {
            case .restart: "Restarts after a change"
            case .reopen: "Applies when the app reopens"
            case .logout: "Applies after you log out"
            }
        }
    }

    let kind: Kind?
    /// The whole sentence, shown on hover.
    let sentence: String

    init(kind: Kind?, sentence: String) {
        self.kind = kind
        self.sentence = sentence
    }

    /// From a catalogue setting's effect. While Atelier restarts the process, the sentence says so.
    init(effect: PersonalEffect, restarting: String? = nil) {
        switch effect {
        case .immediate, .nextUse:
            self.init(kind: nil, sentence: effect.label)
        case let .restart(process):
            let sentence = restarting == process ? "Restarting \(process)…" : "Restarts \(process) once after a change."
            self.init(kind: .restart, sentence: sentence)
        case let .relaunch(app):
            self.init(kind: .reopen, sentence: "\(app) reads this when it opens. Reopen \(app) to see the change.")
        case .relaunchApps:
            self.init(kind: .reopen, sentence: "Apps pick this up when they reopen.")
        case .logout:
            self.init(kind: .logout, sentence: "Needs you to log out and back in.")
        }
    }

    var body: some View {
        if let kind {
            Image(systemName: kind.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DS.Ink.tertiary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
                .help(sentence)
                .accessibilityLabel(kind.short)
                .accessibilityHint(sentence)
        }
    }
}

/// A hidden switch with no home in System Settings.
struct BetaBadge: View {
    var body: some View {
        Text("BETA").font(DS.Typo.badge).tracking(0.6)
            .foregroundStyle(Color.orange.opacity(0.95))
            .padding(.horizontal, 5).frame(height: 15)
            .background(Color.orange.opacity(0.14), in: .capsule)
            .help("Experimental: a hidden switch with no setting in System Settings.")
            .accessibilityLabel("Experimental")
    }
}

/// Inline ↺: puts back the value from before Atelier's first change.
struct RevertGlyph: View {
    /// What the value goes back to, said plainly ("Off", "macOS default").
    let was: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(Pressable(scale: 0.9))
        .foregroundStyle(DS.Ink.secondary)
        .help("Back to \(was)")
        .accessibilityLabel("Revert to \(was)")
    }
}

// MARK: - Tweak presentation

extension Tweak {
    private static let reopenTail = " Apps pick it up when reopened."
    private static let logoutTail = " Takes effect after logging out."

    /// The detail without the when-it-applies sentence; that moves to the ApplyHint glyph.
    var shortDetail: String {
        var text = detail
        for tail in [Self.reopenTail, Self.logoutTail] where text.hasSuffix(tail) { text.removeLast(tail.count) }
        for tail in [Self.reopenTail, Self.logoutTail] where text.hasSuffix(tail) { text.removeLast(tail.count) }
        return text
    }

    @MainActor var applyHint: ApplyHint {
        if detail.contains(Self.logoutTail) { return ApplyHint(kind: .logout, sentence: "Needs you to log out and back in.") }
        if let process { return ApplyHint(kind: .restart, sentence: "Restarts \(process) once after a change.") }
        if detail.hasSuffix(Self.reopenTail) { return ApplyHint(kind: .reopen, sentence: "Apps pick this up when they reopen.") }
        return ApplyHint(kind: nil, sentence: "")
    }

    /// Where the key lives and how sure we are. Debug builds only: never in release UI.
    var debugHelp: String {
        #if DEBUG
        return "\(domain) · \(key)\n\(proof.rawValue)"
        #else
        return ""
        #endif
    }
}

extension PersonalSetting {
    /// Plist key and evidence. Debug builds only: never in release UI.
    var debugHelp: String? {
        #if DEBUG
        return "\(domain) · \(key)\nFound by \(evidence)"
        #else
        return nil
        #endif
    }
}

// MARK: - Settings this macOS does not read

/// One row of the "Not on this macOS" group: what it is and which release it needs.
struct SettingsCompatHiddenItem: Identifiable {
    let id: String
    let title: String
    let requirement: String
}

extension PersonalSetting {
    var compatHiddenItem: SettingsCompatHiddenItem {
        SettingsCompatHiddenItem(id: id, title: title, requirement: availability.requirement(onMajor: PersonalAvailability.runningMajor))
    }
}

extension Tweak {
    var compatHiddenItem: SettingsCompatHiddenItem {
        SettingsCompatHiddenItem(id: id, title: title, requirement: availability.requirement(onMajor: PersonalAvailability.runningMajor))
    }
}

/// Settings the running macOS would ignore or misread, collapsed under one quiet line. They are
/// listed, not hidden outright, so nobody wonders where a setting from another Mac went; they
/// have no control, so nothing is ever written for them.
struct SettingsCompatHiddenGroup: View {
    let items: [SettingsCompatHiddenItem]
    @State private var open = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Button {
                    withAnimation(DS.Motion.arrive) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text("Not on this macOS (\(items.count))").font(DS.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(DS.Ink.tertiary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("These settings exist on other versions of macOS. This Mac runs macOS \(PersonalAvailability.runningMajor), which does not read them.")
                .accessibilityLabel("Not on this macOS, \(items.count) settings")
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                if open {
                    RowGroup {
                        ForEach(items) { item in
                            SettingRow(title: item.title, density: .compact) {
                                Text(item.requirement).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                            }
                            .padding(.vertical, DS.Space.s)
                            .opacity(0.7)
                        }
                    }
                }
            }
        }
    }
}
