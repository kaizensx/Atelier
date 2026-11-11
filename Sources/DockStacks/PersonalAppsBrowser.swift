import AppKit
import DockCore
import SwiftUI

/// The Apps chapter: one app at a time, picked from a strip of app chips. Each app shows its
/// icon card, a Full Disk Access gate when macOS keeps its settings private, its settings,
/// and its experimental ones last. Settings in the `.apps` area that belong to no app
/// ("All Apps") follow at the end.
struct PersonalAppsBrowser: View {
    @ObservedObject private var personal = PersonalModel.shared
    @AppStorage("personal.apps.selected") private var selected = "Safari"

    private var apps: [PersonalApp] {
        PersonalCatalog.apps.filter { app in
            FileManager.default.fileExists(atPath: app.path) && !settings(of: app).isEmpty
        }
    }

    /// The app's settings this macOS reads; the others are listed under "Not on this macOS".
    private func settings(of app: PersonalApp) -> [PersonalSetting] {
        PersonalAvailability.partition(PersonalCatalog.settings(in: .apps).filter { $0.section == app.name }).supported
    }

    private func unsupported(of app: PersonalApp) -> [PersonalSetting] {
        PersonalAvailability.partition(PersonalCatalog.settings(in: .apps).filter { $0.section == app.name }).unsupported
    }

    var body: some View {
        let apps = apps
        let app = apps.first { $0.name == selected } ?? apps.first
        SectionHeader("Apple's apps", symbol: "square.grid.2x2",
                      detail: "Pick an app. Each setting says when the app reads it; Revert puts back what was there.",
                      hue: DS.Spectrum.input)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(apps) { item in
                    AppChip(app: item, count: settings(of: item).count, selected: item == app) { selected = item.name }
                }
            }
            .padding(.vertical, 2)
        }
        if let app {
            AppHeaderCard(app: app, settings: settings(of: app))
            AppIconCard(app: app)
            let rows = settings(of: app)
            let shown = rows.filter { !$0.experimental }
            if !shown.isEmpty {
                RowGroup { ForEach(shown) { PersonalRow(setting: $0, grouped: true) } }
            }
            let hidden = rows.filter(\.experimental)
            if !hidden.isEmpty {
                SectionHeader("Experimental", symbol: "flask",
                              detail: "Found in \(app.name)'s code but not in its settings. They may do nothing on public builds.",
                              hue: DS.Spectrum.input)
                RowGroup { ForEach(hidden) { PersonalRow(setting: $0, grouped: true) } }
            }
            SettingsCompatHiddenGroup(items: unsupported(of: app).map(\.compatHiddenItem))
        }
        let names = Set(PersonalCatalog.apps.map(\.name))
        ForEach(PersonalCatalog.sections(in: .apps).filter { !names.contains($0) }, id: \.self) { section in
            SectionHeader(section, symbol: PersonalRows.symbol(section), hue: DS.Spectrum.input)
            RowGroup {
                ForEach(PersonalAvailability.partition(PersonalCatalog.settings(in: .apps).filter { $0.section == section }).supported) {
                    PersonalRow(setting: $0, grouped: true)
                }
            }
        }
    }
}

private struct AppChip: View {
    let app: PersonalApp
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 18, height: 18)
                Text(app.name).font(.system(size: 12, weight: .medium))
                Text("\(count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(selected ? DS.Spectrum.input : DS.Ink.tertiary)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(selected ? DS.Spectrum.input.opacity(0.18) : (hover ? DS.Ink.fillStrong : DS.Ink.fill), in: .capsule)
            .overlay { Capsule().strokeBorder(selected ? DS.Spectrum.input.opacity(0.8) : DS.Ink.hairline, lineWidth: selected ? 1 : 0.5) }
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.95))
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
        .accessibilityLabel("\(app.name), \(count) settings")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Name, whether it is open, a Relaunch button once something changed, and the privacy gate.
struct AppHeaderCard: View {
    let app: PersonalApp
    let settings: [PersonalSetting]
    @ObservedObject private var personal = PersonalModel.shared

    var body: some View {
        let _ = personal.revision
        let changed = settings.contains { personal.isChanged($0) }
        let blocker = settings.lazy.compactMap { personal.engine.prefs.blocker($0) }.first
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(DS.Typo.hero).tracking(-0.3)
                        Text(personal.isRunning(app.name) ? "Open now. Changes apply when it reopens." : "Not open. Changes apply next time it opens.")
                            .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    }
                    Spacer(minLength: 8)
                    if changed, personal.isRunning(app.name) { Chip("Relaunch \(app.name)") { personal.relaunch(appNamed: app.name) } }
                }
                if let blocker {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill").foregroundStyle(.orange)
                        Text(blocker).font(DS.caption).foregroundStyle(.orange.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        if blocker.contains("Full Disk Access") {
                            Chip("Open Full Disk Access") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The app's icon from macOSicons, where macOS allows it. Apple's apps on the sealed
/// system volume cannot take a custom icon, and the card says so instead of offering it.
struct AppIconCard: View {
    let app: PersonalApp
    @State private var picking = false
    @ObservedObject private var icons = CustomIcons.shared

    /// Safari's path is a link into a system cryptex, so resolve before judging.
    private var path: String { URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path }

    var body: some View {
        let changeable = IconLibrary.canApply(toApp: path)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SettingRow(title: "Icon", detail: changeable
                           ? "Pick a replacement from macOSicons. Restore puts the original back."
                           : "Sealed by macOS. Atelier can still show another icon in its Dock, Orbit and widgets.",
                           symbol: "app.badge", density: .compact) {
                    HStack(spacing: 6) {
                        if changeable {
                            // Through CustomIcons, like Folder & App Icons, so the change is listed there
                            // and Restore works from either place.
                            if icons.hasCustomIcon(path) { Chip("Restore") { icons.revert(path) } }
                            Chip("Choose…") { picking = true }
                        } else {
                            // Keyed by the path the Dock and Orbit know the app by, not the resolved one.
                            IconChooserMenu(query: app.name, canReset: AtelierIcons.shared.has(app.path),
                                            onPick: { AtelierIcons.shared.set($0, for: app.path) },
                                            onReset: { AtelierIcons.shared.reset(app.path) })
                        }
                    }
                }
                .help(changeable ? "" : "\(app.name) lives on macOS's sealed system volume, so Finder keeps its icon. Atelier can still show another one everywhere it draws \(app.name): the Atelier Dock, Orbit, widgets.")
                CustomIconsNotice()
            }
        }
        .onChange(of: app) { icons.notice = nil }
        .sheet(isPresented: $picking) {
            VStack(alignment: .trailing, spacing: 0) {
                IconLibraryPicker(query: app.name) { image in
                    picking = false
                    icons.set(image, on: URL(fileURLWithPath: path))
                }
                Button("Cancel") { picking = false }.keyboardShortcut(.cancelAction).padding([.horizontal, .bottom], 16)
            }
            .frame(width: 420)
        }
    }
}


/// The header and icon cards for one app's own page in the sidebar.
struct PersonalAppHeader: View {
    let name: String

    var body: some View {
        if let app = PersonalCatalog.app(named: name) {
            AppHeaderCard(app: app, settings: PersonalAvailability.partition(
                PersonalCatalog.all.filter { $0.area == .apps && $0.section == name }).supported)
            AppIconCard(app: app)
        }
    }
}
