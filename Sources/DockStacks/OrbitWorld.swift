import AppKit
import SwiftUI

// The SwiftUI around the field: sky, chrome, folder, menus. None of it changes per frame;
// the field and the dragged ghost are layers the engine moves on its own.

struct OrbitWorld: View {
    static let space = "orbit.world"
    @ObservedObject var orbit: Orbit

    var body: some View {
        let options = orbit.options
        ZStack(alignment: .topLeading) {
            OrbitSky(options: options, hue: orbit.skyHue)
                .opacity(orbit.entered ? 1 : 0)
                .animation(orbit.motion(DS.Motion.arrive), value: orbit.entered)
                .allowsHitTesting(false)

            OrbitLayerHost(engine: orbit.engine, ghost: false)
                .allowsHitTesting(false)

            OrbitFieldInput(orbit: orbit, slots: orbit.searching ? orbit.results : (orbit.currentPage?.slots ?? []))

            if orbit.pages.isEmpty && !orbit.searching {
                VStack(spacing: 8) {
                    DisplayTitle(text: "Gathering your apps", size: 30)
                    Text("The universe fills in a moment.").font(DS.body).foregroundStyle(DS.Ink.secondary)
                }
                .position(x: orbit.size.width / 2, y: orbit.size.height / 2)
                .allowsHitTesting(false)
            }

            if options.showRecents { OrbitRecents(orbit: orbit) }
            OrbitSearchPill(orbit: orbit)
            OrbitPageBar(orbit: orbit)

            if orbit.openFolder != nil {
                Color.black.opacity(0.34)
                    .contentShape(Rectangle())
                    .onTapGesture { orbit.backgroundTapped() }
                    .transition(.opacity)
            }
            if let folder = orbit.folderBeingShown {
                OrbitFolderPanel(orbit: orbit, entry: folder)
                    .transition(.scale(scale: 0.12, anchor: UnitPoint(x: orbit.folderOrigin.x / max(orbit.size.width, 1),
                                                                      y: orbit.folderOrigin.y / max(orbit.size.height, 1)))
                        .combined(with: .opacity))
            }
            if let menu = orbit.menu {
                Color.clear.contentShape(Rectangle()).onTapGesture { orbit.dismissMenu() }
                OrbitMenuView(orbit: orbit, menu: menu)
                    .position(menu.point)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
            }
            if let toast = orbit.toast {
                Text(toast)
                    .font(DS.title)
                    .foregroundStyle(DS.Ink.primary)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .atelierGlass(.regular, in: .capsule)
                    .position(x: orbit.size.width / 2, y: orbit.size.height - 118 - orbit.bottomInset)
                    .transition(.offset(y: 12).combined(with: .opacity))
            }

            OrbitLayerHost(engine: orbit.engine, ghost: true)
                .allowsHitTesting(false)
        }
        .frame(width: orbit.size.width, height: orbit.size.height)
        .background {
            // The public material: its strength fades in once, it is never animated per frame by us.
            if options.blur > 0.01 {
                OrbitVeil().opacity(orbit.entered ? options.blur : 0).animation(.easeOut(duration: 0.25), value: orbit.entered)
            }
        }
        .coordinateSpace(.named(Self.space))
        .ignoresSafeArea()
    }
}

/// Hosts the engine's layers in the SwiftUI tree.
private struct OrbitLayerHost: NSViewRepresentable {
    let engine: OrbitEngine
    let ghost: Bool

    func makeNSView(context: Context) -> OrbitLayerView { OrbitLayerView(engine: engine, ghostOnly: ghost) }
    func updateNSView(_ view: OrbitLayerView, context: Context) {}
}

/// The field's pointer surface. Hit testing asks the engine where things are now.
private struct OrbitFieldInput: View {
    let orbit: Orbit
    let slots: [OrbitSlot]

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named(OrbitWorld.space)) { phase in
                switch phase {
                case .active(let point): orbit.fieldHover(point)
                case .ended: orbit.fieldHover(nil)
                }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(OrbitWorld.space))
                .onChanged { orbit.fieldPressChanged(start: $0.startLocation, location: $0.location) }
                .onEnded { orbit.fieldPressEnded(location: $0.location) })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Apps")
            .accessibilityChildren {
                ForEach(slots) { slot in
                    Text(slot.entry.name)
                        .accessibilityLabel(slot.entry.isFolder ? "\(slot.entry.name), folder of \(slot.entry.paths.count)" : slot.entry.name)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { orbit.activate(slot.key) }
                        .accessibilityAction(named: "Show Actions") { orbit.presentMenu(for: slot.key) }
                }
            }
    }
}

/// Darkened, tinted sky with a wash of colour. Stars live on the field's layers.
struct OrbitSky: View {
    let options: OrbitOptions
    let hue: OrbitRGB

    var body: some View {
        ZStack {
            if options.liveWallpaper, LiveWallpaper.shared.available {
                LivingPreview(shader: LiveWallpaper.shared.shader)
            }
            Color.black.opacity(options.dim)
            if options.tintAmount > 0.001 { options.tint.color.opacity(options.tintAmount) }
            RadialGradient(colors: [hue.color.opacity(options.nebulaStrength), hue.color.opacity(options.nebulaStrength * 0.27), .clear],
                           center: .center, startRadius: 40, endRadius: 760)
                .animation(.spring(response: 0.9, dampingFraction: 1), value: hue)
        }
    }
}

// MARK: - Folder

private struct OrbitFolderPanel: View {
    @ObservedObject var orbit: Orbit
    let entry: OrbitEntry
    @State private var name = ""

    var body: some View {
        let frame = OrbitLayout.folderFrame(count: entry.paths.count, size: orbit.size, cell: orbit.cell)
        ZStack(alignment: .topLeading) {
            Color.clear
                .atelierGlass(.regular, in: .rect(cornerRadius: DS.Radius.panel))
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .onTapGesture { orbit.endEditing() }
                .position(x: frame.midX, y: frame.midY)

            TextField("Folder Name", text: $name)
                .textFieldStyle(.plain)
                .font(DS.display(26))
                .multilineTextAlignment(.center)
                .foregroundStyle(DS.Ink.primary)
                .frame(width: frame.width - 60)
                .position(x: frame.midX, y: frame.minY + 46)
                .onSubmit { orbit.endEditing() }
                .onChange(of: name) { _, value in
                    let clean = value.trimmingCharacters(in: .whitespaces)
                    if !clean.isEmpty, let id = entry.folder { orbit.rename(id, to: clean) }
                }

            ForEach(orbit.folderSlots(entry)) { slot in
                OrbitFolderCell(orbit: orbit, slot: slot, folder: entry.folder, selected: orbit.selection == slot.key,
                                lifted: orbit.liftedKey == slot.key)
                    .position(slot.spot.center)
            }
        }
        .frame(width: orbit.size.width, height: orbit.size.height, alignment: .topLeading)
        .onAppear { name = entry.name }
    }
}

private struct OrbitFolderCell: View {
    let orbit: Orbit
    let slot: OrbitSlot
    let folder: UUID?
    let selected: Bool
    let lifted: Bool
    @State private var hovering = false
    @State private var pressed = false
    @State private var travelled = 0.0

    var body: some View {
        let icon = orbit.options.iconSize
        VStack(spacing: 8) {
            OrbitIconStore.shared.image(slot.entry.path)
                .resizable()
                .interpolation(.high)
                .frame(width: icon, height: icon)
                .shadow(color: .black.opacity(0.3), radius: 7, y: 4)
            if orbit.options.labels != .never {
                Text(slot.entry.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
            }
        }
        .frame(width: orbit.cell, height: orbit.cell)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(DS.Ink.accent.opacity(0.9), lineWidth: 1.5) }
            }
        }
        .contentShape(.rect(cornerRadius: 22, style: .continuous))
        .opacity(lifted ? 0 : 1)
        .scaleEffect(pressed ? 0.93 : hovering ? orbit.options.hoverScale : 1)
        .animation(DS.Motion.touch, value: hovering)
        .animation(DS.Motion.touch, value: pressed)
        .onHover { inside in
            hovering = inside
            orbit.hover(slot.key, inside)
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(OrbitWorld.space))
            .onChanged { value in
                pressed = true
                travelled = max(travelled, hypot(value.translation.width, value.translation.height))
                if travelled > 6 {
                    pressed = false
                    orbit.dragChanged(slot.entry, key: slot.key, origin: slot.spot.center, location: value.location, fromFolder: folder)
                }
            }
            .onEnded { value in
                pressed = false
                let wasDrag = travelled > 6
                travelled = 0
                if wasDrag { orbit.dragEnded(location: value.location) } else { orbit.activate(slot.key) }
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slot.entry.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { orbit.activate(slot.key) }
    }
}

// MARK: - Chrome

private struct OrbitSearchPill: View {
    @ObservedObject var orbit: Orbit

    var body: some View {
        let prompt = orbit.options.typeToSearch || orbit.searchArmed ? "Start typing to find an app" : "Press / to search"
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(orbit.searchArmed ? DS.Ink.accent : DS.Ink.secondary)
            if orbit.query.isEmpty {
                Text(prompt)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.Ink.tertiary)
            } else {
                Text(orbit.query)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: 420, height: 44)
        .atelierGlass(.regular, in: .capsule)
        .scaleEffect(orbit.entered ? 1 : 0.9)
        .opacity(orbit.entered ? 1 : 0)
        .offset(y: orbit.entered ? 0 : -18)
        .animation(orbit.motion(DS.Motion.arrive), value: orbit.entered)
        .position(x: orbit.size.width / 2, y: 58)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search")
        .accessibilityValue(orbit.query)
    }
}

private struct OrbitRecents: View {
    @ObservedObject var orbit: Orbit

    var body: some View {
        let visible = !orbit.recents.isEmpty && !orbit.searching
        ZStack(alignment: .topLeading) {
            if !orbit.recents.isEmpty {
                Capsule()
                    .fill(.clear)
                    .atelierGlass(.regular, in: .capsule)
                    .frame(width: OrbitLayout.recentStep * Double(orbit.recents.count) + 14, height: 60)
                    .position(x: orbit.size.width / 2, y: 122)
                    .allowsHitTesting(false)
            }
            if let key = orbit.selection, let slot = orbit.recents.first(where: { $0.key == key }) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(DS.Ink.accent.opacity(0.9), lineWidth: 1.5)
                    }
                    .frame(width: 54, height: 54)
                    .position(slot.spot.center)
            }
            ForEach(orbit.recents) { slot in
                OrbitRecentCell(orbit: orbit, slot: slot)
                    .position(slot.spot.center)
            }
        }
        .scaleEffect(orbit.entered ? 1 : 0.92, anchor: .top)
        .opacity(visible && orbit.entered ? 1 : 0)
        .offset(y: visible && orbit.entered ? 0 : -10)
        .animation(orbit.motion(DS.Motion.arrive), value: visible)
        .animation(orbit.motion(DS.Motion.arrive), value: orbit.entered)
        .allowsHitTesting(visible)
    }
}

private struct OrbitRecentCell: View {
    let orbit: Orbit
    let slot: OrbitSlot
    @State private var hovering = false

    var body: some View {
        Button { orbit.activate(slot.key) } label: {
            OrbitIconStore.shared.image(slot.entry.path)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
                .scaleEffect(hovering ? 1.16 : 1)
                .animation(DS.Motion.touch, value: hovering)
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.9))
        .onHover { inside in
            hovering = inside
            orbit.hover(slot.key, inside)
        }
        .overlay(alignment: .bottom) {
            if hovering {
                Text(slot.entry.name)
                    .font(DS.caption)
                    .foregroundStyle(DS.Ink.primary)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .fixedSize()
                    .offset(y: 30)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .accessibilityLabel(slot.entry.name)
    }
}

private struct OrbitPageBar: View {
    @ObservedObject var orbit: Orbit
    @Namespace private var pill

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(Array(orbit.pages.enumerated()), id: \.element.id) { index, page in
                    Button { orbit.go(to: index) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: page.group.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(index == orbit.page ? page.group.rgb.color : DS.Ink.tertiary)
                            if index == orbit.page {
                                Text(page.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DS.Ink.primary)
                                    .fixedSize()
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background {
                            if index == orbit.page {
                                Capsule().fill(DS.Ink.fillStrong).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(Pressable(scale: 0.95))
                    .accessibilityLabel(page.title)
                    .accessibilityAddTraits(index == orbit.page ? .isSelected : [])
                }
            }
            .padding(4)
            .atelierGlass(.regular, in: .capsule)

            Text("Return opens  ·  Shift-Return or right-click for actions  ·  Drag onto an app to make a folder")
                .font(DS.caption)
                .foregroundStyle(DS.Ink.tertiary)
        }
        .scaleEffect(orbit.entered ? 1 : 0.92)
        .opacity(orbit.entered && !orbit.searching ? 1 : 0)
        .offset(y: orbit.entered ? 0 : 22)
        .animation(orbit.motion(DS.Motion.arrive), value: orbit.entered)
        .animation(orbit.motion(DS.Motion.arrive), value: orbit.searching)
        .animation(orbit.motion(DS.Motion.settle), value: orbit.page)
        .position(x: orbit.size.width / 2, y: orbit.size.height - 54 - orbit.bottomInset)
    }
}

private struct OrbitMenuView: View {
    @ObservedObject var orbit: Orbit
    let menu: OrbitActionMenu

    var body: some View {
        let actions = orbit.menuActions
        VStack(alignment: .leading, spacing: 2) {
            switch menu.mode {
            case .stacks: Eyebrow(text: "Add to Stack").padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            case .constellations: Eyebrow(text: "Move to").padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            case .main: EmptyView()
            }
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                Button { action.run() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 20)
                            .foregroundStyle(DS.Ink.secondary)
                        Text(action.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DS.Ink.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(DS.Ink.fillStrong.opacity(index == menu.selection ? 1 : 0),
                                in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable(scale: 0.98))
                .onHover { if $0 { orbit.highlightMenuRow(index) } }
            }
        }
        .padding(6)
        .frame(width: 236)
        .atelierGlass(.regular, in: .rect(cornerRadius: DS.Radius.card))
        .animation(orbit.motion(DS.Motion.touch), value: menu.selection)
    }
}
