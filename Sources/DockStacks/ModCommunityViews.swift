import AppKit
import DockCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Atelier Mods: collections, authors, the review sheet and setups

/// Installs and likes, small, for a card or a page. Nothing when the catalog has no counts.
struct ModStats: View {
    let entry: ModEntry
    var body: some View {
        HStack(spacing: 8) {
            if let n = entry.downloads, n > 0 {
                Label(ModCounts.installs(n), systemImage: "arrow.down.circle").labelStyle(StatLabel())
            }
            if let n = entry.likes, n > 0 {
                Label(ModCounts.short(n), systemImage: "hand.thumbsup").labelStyle(StatLabel())
                    .accessibilityLabel(ModCounts.likes(n))
            }
        }
    }

    private struct StatLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) {
                configuration.icon.font(.system(size: 9.5, weight: .semibold))
                configuration.title.font(DS.caption)
            }
            .foregroundStyle(DS.Ink.tertiary)
            .lineLimit(1).fixedSize()
        }
    }
}

/// A collection as a horizontal shelf of cards.
struct ModShelf: View {
    let title: String
    var detail: String?
    var symbol = "square.stack"
    let mods: [ModEntry]
    var featured = false
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title, symbol: symbol, detail: detail, hue: ModsHue.tint)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: DS.Space.m) {
                    ForEach(mods) { entry in
                        ModCard(entry: entry, featured: featured) { open(entry.id) }.frame(width: 250)
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.top, DS.Space.s)
        }
    }
}

/// Everyone whose name or handle matches a search, as rows that open their page.
struct ModAuthorRows: View {
    let authors: [ModAuthor]
    let index: ModIndex
    let open: (String) -> Void

    var body: some View {
        SectionHeader("Authors", symbol: "person.2", detail: "\(authors.count) found.", hue: ModsHue.tint)
        RowGroup {
            ForEach(authors) { author in
                Button { open(author.github) } label: {
                    SettingRow(title: author.name, detail: "@\(author.github) · \(count(author))", symbol: "person.crop.circle", density: .compact) {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                    }
                }
                .buttonStyle(Pressable(scale: 0.99))
            }
        }
    }

    private func count(_ author: ModAuthor) -> String {
        let n = index.mods(by: author.github).count
        return n == 1 ? "1 mod" : "\(n) mods"
    }
}

/// An author's page: who they are, a link to their GitHub, and all their mods.
struct ModAuthorPage: View {
    let author: ModAuthor
    let mods: [ModEntry]
    let back: () -> Void
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Button(action: back) {
                Label("Back", systemImage: "chevron.left").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Ink.secondary)
            }
            .buttonStyle(Pressable())

            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 26, weight: .regular))
                    .foregroundStyle(ModsHue.tint)
                    .frame(width: 44, height: 44)
                    .background(ModsHue.tint.opacity(0.14), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(author.name).font(DS.Typo.hero).foregroundStyle(DS.Ink.primary)
                    Text("@\(author.github) · \(mods.count == 1 ? "1 mod" : "\(mods.count) mods")" + installs)
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: DS.Space.s) {
                    if let profile = author.profile {
                        Button("GitHub") { NSWorkspace.shared.open(profile) }.buttonStyle(ModPill(prominent: false))
                    }
                    if let url = author.url {
                        Button("Website") { NSWorkspace.shared.open(url) }.buttonStyle(ModPill(prominent: false))
                    }
                }
            }

            SectionHeader("Mods", symbol: "square.grid.2x2", hue: ModsHue.tint)
            LazyVGrid(columns: ModCard.columns, spacing: DS.Space.m) {
                ForEach(mods) { entry in ModCard(entry: entry) { open(entry.id) } }
            }
        }
    }

    private var installs: String {
        let total = mods.compactMap(\.downloads).reduce(0, +)
        return total > 0 ? " · " + ModCounts.installs(total) : ""
    }
}

/// Before an install that needs a person: what it newly asks for, whether the author's key
/// changed, whether it is older than what is installed.
struct ModReviewSheet: View {
    let review: ModInstallReview
    let done: (Bool) -> Void
    @State private var trusted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 26)).foregroundStyle(hue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(subtitle).font(DS.caption).foregroundStyle(.secondary)
                }
            }
            if review.keyChange.needsConfirmation { keySection }
            if review.from != nil, review.diff.needsConsent { permissionSection }
            if review.isOlder {
                bullet("clock.arrow.circlepath", "Version \(review.entry.version) is older than the \(review.from ?? "") you have. Update All leaves it there until you choose Update again.")
            }
            if review.keyChange.needsConfirmation {
                Toggle("I trust whoever publishes it now", isOn: $trusted).toggleStyle(.checkbox).font(DS.body)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button(action: { done(true) }) { Text(confirmTitle) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(review.keyChange.needsConfirmation && !trusted)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var icon: String {
        review.keyChange.needsConfirmation ? "person.2.badge.key" : review.isOlder ? "clock.arrow.circlepath" : "hand.raised.fill"
    }
    private var hue: Color { review.keyChange.needsConfirmation ? ModsHue.danger : .orange }

    private var title: String {
        if review.keyChange.needsConfirmation { return "This mod changed hands" }
        if review.isOlder { return "Go back to \(review.entry.name) \(review.entry.version)?" }
        return "\(review.entry.name) \(review.entry.version) asks for more"
    }

    private var subtitle: String {
        let by = "By \(review.entry.author)" + (review.entry.github.isEmpty ? "" : " (@\(review.entry.github))")
        return by + (review.from.map { ". You have \($0)." } ?? ".")
    }

    private var confirmTitle: String {
        if review.isOlder { return "Roll Back" }
        return review.from == nil ? "Install" : "Update"
    }

    @ViewBuilder private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(review.keyChange == .dropped
                 ? "The version you have was signed by its author. This one is signed by the catalog only, not by that author."
                 : "The version you have was signed by one author key. This one is signed by a different key. The catalog's maintainers allowed the change, but it can mean someone else now publishes this mod.")
                .font(DS.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let old = review.installedKey { keyLine("Before", old) }
            if let new = review.entry.authorKey { keyLine("Now", new) }
        }
    }

    private func keyLine(_ label: String, _ key: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(DS.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Text(ModAuthorSignature.fingerprint(key)).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
        }
    }

    @ViewBuilder private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This update asks for permissions the version you have did not. It stays off until you allow them.")
                .font(DS.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(review.diff.added, id: \.self) { raw in
                let p = PluginPermission(rawValue: raw)
                bullet(p?.symbol ?? "key", "New: \(p?.title ?? raw). \(p?.detail ?? "")")
            }
            ForEach(review.diff.addedHosts, id: \.self) { host in bullet("network", "New host: \(host)") }
            if !review.diff.removed.isEmpty || !review.diff.removedHosts.isEmpty {
                bullet("minus.circle", "No longer asks for: " + (review.diff.removed.map { PluginPermission(rawValue: $0)?.title ?? $0 } + review.diff.removedHosts).joined(separator: ", "))
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(hue)
            Text(text).font(DS.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Export and import of a whole setup, at the top of Installed.
struct ModSetupRow: View {
    @ObservedObject private var store = ModStore.shared
    @State private var includeData = false
    @State private var problem: String?

    var body: some View {
        RowGroup {
            SettingRow(title: "Your setup", detail: "Save the mods, plugins and theme on this Mac to a file, to set up another Mac the same way. Secrets are never saved.",
                       symbol: "square.and.arrow.up.on.square", density: .compact) {
                HStack(spacing: DS.Space.s) {
                    Button("Export Setup…") { export() }.buttonStyle(ModPill(prominent: false))
                    Button("Import Setup…") { pick() }.buttonStyle(ModPill(prominent: false))
                }
            }
            SettingRow(title: "Include plugin data", detail: "What plugins keep in their own storage, without anything that looks like a token or password.",
                       symbol: "tray.full", density: .compact) {
                LuxSwitch(isOn: $includeData, label: "Include plugin data in the exported setup")
            }
        }
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").font(DS.caption).foregroundStyle(.orange)
                .padding(.horizontal, DS.Space.xs).fixedSize(horizontal: false, vertical: true)
        }
    }

    static var type: UTType { UTType(filenameExtension: AtelierSetup.fileExtension, conformingTo: .json) ?? .json }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "My Atelier." + AtelierSetup.fileExtension
        panel.allowedContentTypes = [Self.type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.currentSetup(includeData: includeData).data().write(to: url, options: .atomic)
            problem = nil
            store.notice = "Exported the setup to \(url.lastPathComponent)."
        } catch {
            problem = "Couldn’t save the setup: \(error.localizedDescription)"
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.type, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { problem = "Couldn’t read \(url.lastPathComponent)."; return }
        switch AtelierSetup.parse(data) {
        case .success(let setup): problem = nil; store.pendingImport = setup
        case .failure(let failure): problem = failure.description
        }
    }
}

/// What importing a setup will do, before it does it.
struct ModImportSheet: View {
    let setup: AtelierSetup
    let done: (Bool) -> Void
    @ObservedObject private var store = ModStore.shared

    var body: some View {
        let steps = setup.plan(index: store.index, installed: store.installed)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 26)).foregroundStyle(ModsHue.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import this setup?").font(.system(size: 17, weight: .semibold))
                    Text("Saved \(setup.created.formatted(date: .abbreviated, time: .shortened))" + (setup.atelier.isEmpty ? "" : " with Atelier \(setup.atelier)") + ".")
                        .font(DS.caption).foregroundStyle(.secondary)
                }
            }
            // The first dozen, then a count: a sheet, not a scrolling list.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps.prefix(12)) { step in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(step.action)).frame(width: 18).foregroundStyle(hue(step.action))
                        Text(step.name).font(DS.body).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(text(step.action)).font(DS.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if steps.count > 12 {
                    Text("and \(steps.count - 12) more").font(DS.caption).foregroundStyle(.secondary)
                }
                if steps.isEmpty { Text("No mods in this setup.").font(DS.body).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if let theme = setup.theme { note("paintpalette", "Applies the theme \(ThemeEngine.shared.theme(theme)?.document.name ?? theme).") }
                let on = setup.plugins.filter(\.enabled).count
                if on > 0 { note("power", "Turns on \(on) plugin\(on == 1 ? "" : "s"). Each one with permissions asks for them first.") }
                if setup.includesData { note("tray.full", "Puts back plugin data saved in the file.") }
            }
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Import") { done(true) }.keyboardShortcut(.defaultAction).disabled(store.index == nil)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(DS.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func symbol(_ action: AtelierSetup.Step.Action) -> String {
        switch action {
        case .install: "arrow.down.circle"
        case .change: "arrow.triangle.2.circlepath"
        case .alreadyInstalled: "checkmark.circle"
        case .unavailable: "questionmark.circle"
        }
    }

    private func hue(_ action: AtelierSetup.Step.Action) -> Color {
        switch action {
        case .install, .change: ModsHue.tint
        case .alreadyInstalled: DS.Spectrum.input
        case .unavailable: .orange
        }
    }

    private func text(_ action: AtelierSetup.Step.Action) -> String {
        switch action {
        case .install(let v): "Install \(v)"
        case .change(let from, let to): "\(from) → \(to)"
        case .alreadyInstalled: "Installed"
        case .unavailable: "Not in the catalog"
        }
    }
}
