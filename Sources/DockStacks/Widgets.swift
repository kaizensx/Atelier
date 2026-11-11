import AppKit
import DockCore
import SwiftUI

// MARK: - Model

enum WidgetSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// How the gallery in Settings groups the kinds.
enum WidgetCategory: String, CaseIterable, Identifiable {
    case time, system, productivity, media, fun
    var id: String { rawValue }
    var title: String {
        switch self {
        case .time: "Time"
        case .system: "System"
        case .productivity: "Productivity"
        case .media: "Media"
        case .fun: "Fun"
        }
    }
}

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case calendar, notes, rings, clocks, pomodoro
    case activity, network, battery, progress, countdown, moon, sticker, photo
    case weather, events, reminders, checklist, habits, launcher, stopwatch
    case devices, clipboard, storage, slideshow, stack
    case bigClock, vitals
    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .notes: "Notes"
        case .rings: "System Rings"
        case .clocks: "World Clocks"
        case .pomodoro: "Pomodoro"
        case .activity: "Activity"
        case .network: "Network"
        case .battery: "Battery & Power"
        case .progress: "Day Progress"
        case .countdown: "Countdown"
        case .moon: "Moon Phase"
        case .sticker: "Text Sticker"
        case .photo: "Photo Frame"
        case .weather: "Weather"
        case .events: "Up Next"
        case .reminders: "Reminders"
        case .checklist: "Checklist"
        case .habits: "Habits"
        case .launcher: "Launcher"
        case .stopwatch: "Stopwatch & Timer"
        case .devices: "Device Batteries"
        case .clipboard: "Clipboard"
        case .storage: "Storage"
        case .slideshow: "Slideshow"
        case .stack: "Smart Stack"
        case .bigClock: "Big Clock"
        case .vitals: "Vitals"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .notes: "note.text"
        case .rings: "circle.circle"
        case .clocks: "globe"
        case .pomodoro: "timer"
        case .activity: "waveform.path.ecg"
        case .network: "arrow.up.arrow.down"
        case .battery: "battery.75percent"
        case .progress: "chart.bar.fill"
        case .countdown: "hourglass"
        case .moon: "moon.stars"
        case .sticker: "quote.opening"
        case .photo: "photo"
        case .weather: "cloud.sun"
        case .events: "calendar.day.timeline.left"
        case .reminders: "checklist"
        case .checklist: "checkmark.circle"
        case .habits: "flame"
        case .launcher: "square.grid.2x2"
        case .stopwatch: "stopwatch"
        case .devices: "keyboard"
        case .clipboard: "doc.on.clipboard"
        case .storage: "internaldrive"
        case .slideshow: "photo.stack"
        case .stack: "square.stack"
        case .bigClock: "clock"
        case .vitals: "gauge.with.dots.needle.67percent"
        }
    }

    /// One line for the gallery in Settings.
    var blurb: String {
        switch self {
        case .calendar: "Today and the month around it."
        case .notes: "A note you write in place."
        case .rings: "CPU, memory, disk and battery at a glance."
        case .clocks: "Up to four cities, day and night."
        case .pomodoro: "Focus rounds with breaks."
        case .activity: "Live CPU and memory graphs, load and uptime."
        case .network: "Download and upload speed, live."
        case .battery: "Charge, time left, power draw and health."
        case .progress: "How much of the day, week, month and year is gone."
        case .countdown: "Days until a date that matters."
        case .moon: "Tonight’s phase, worked out on this Mac."
        case .sticker: "A line, a quote, a reminder."
        case .photo: "A picture you choose."
        case .weather: "Now, the next hours and the week, for any city. From Open-Meteo."
        case .events: "Your next events from Calendar."
        case .reminders: "What is due, ticked off right on the desktop."
        case .checklist: "A list you tick off on the desktop."
        case .habits: "Mark today, keep the streak going."
        case .launcher: "Apps, folders and links, one click away."
        case .stopwatch: "A stopwatch with laps, or a countdown timer."
        case .devices: "Keyboard, mouse and trackpad charge."
        case .clipboard: "The last few things you copied, click to copy again."
        case .storage: "Free space on every mounted volume, and uptime."
        case .slideshow: "A folder of pictures, crossfading."
        case .stack: "Several widgets in one tile. Scroll through them."
        case .bigClock: "The time, as large as you like: ten faces, analog dials, flip cards, any time zone."
        case .vitals: "CPU, memory, disk, battery, network and more, as rings, bars, gauges or numbers."
        }
    }

    /// Nil for the stack, which the gallery shows on its own.
    var category: WidgetCategory? {
        switch self {
        case .calendar, .clocks, .bigClock, .weather, .progress, .countdown, .stopwatch: .time
        case .rings, .vitals, .activity, .network, .battery, .storage, .devices: .system
        case .notes, .checklist, .reminders, .events, .habits, .pomodoro, .launcher, .clipboard: .productivity
        case .photo, .slideshow, .sticker: .media
        case .moon: .fun
        case .stack: nil
        }
    }

    var sizes: [WidgetSize] {
        switch self {
        case .pomodoro: [.small]
        case .calendar, .habits, .stopwatch, .devices, .storage, .stack: [.small, .medium]
        case .notes, .sticker, .photo, .weather, .events, .reminders, .checklist, .launcher, .clipboard, .slideshow, .bigClock, .vitals: [.small, .medium, .large]
        default: [.small, .medium]
        }
    }

    /// The size a new widget starts at. Saved widgets from before sizes existed come back at this size too,
    /// so it matches the spans they used to have.
    var defaultSize: WidgetSize {
        switch self {
        case .calendar, .notes, .rings, .clocks, .activity, .network, .battery, .progress, .moon, .sticker, .bigClock, .vitals: .medium
        case .pomodoro, .countdown, .photo: .small
        case .weather, .events, .reminders, .checklist, .launcher, .clipboard, .storage, .devices, .habits: .medium
        case .stopwatch, .slideshow, .stack: .small
        }
    }

    /// Width and height in grid cells.
    func span(_ size: WidgetSize) -> (columns: Int, rows: Int) {
        let size = sizes.contains(size) ? size : defaultSize
        switch (self, size) {
        case (_, .small): return (2, 2)
        case (.calendar, .medium), (.notes, .medium), (.checklist, .medium), (.reminders, .medium): return (3, 3)
        case (_, .medium): return (4, 2)
        case (_, .large): return (4, 4)
        }
    }

    var span: (columns: Int, rows: Int) { span(defaultSize) }

    /// Kinds that take any span the owner drags them to, not only the three sizes.
    var freeSpan: Bool {
        switch self {
        case .bigClock, .vitals, .photo, .sticker, .slideshow: true
        default: false
        }
    }

    /// The smallest free span that still reads.
    var minimumSpan: WidgetSpan {
        switch self {
        case .bigClock, .sticker: WidgetSpan(columns: 2, rows: 1)
        case .vitals: WidgetSpan(columns: 1, rows: 1)
        default: WidgetSpan(columns: 2, rows: 2)
        }
    }

    static let maximumSpan = WidgetSpan(columns: 14, rows: 9)

    /// Widgets with controls inside are dragged by a strip along the top, the rest by their whole face.
    var gripHeight: Double? {
        switch self {
        case .notes, .pomodoro: 30
        default: nil
        }
    }

    /// Kinds that make sense more than once on the desktop.
    var allowsMultiple: Bool {
        switch self {
        case .countdown, .sticker, .photo, .weather, .checklist, .habits, .launcher, .stopwatch, .slideshow, .stack, .bigClock, .vitals: true
        default: false
        }
    }

    /// Kinds with controls that want clicks while the board is at rest, when Interactive Widgets is on.
    var needsClicks: Bool {
        switch self {
        case .checklist, .habits, .launcher, .stopwatch, .clipboard, .reminders, .pomodoro, .stack: true
        default: false
        }
    }

    /// A picture is its own surface, edge to edge.
    var edgeToEdge: Bool { self == .photo || self == .slideshow }

    /// Live meters say how often they sample, so the cost is never a surprise.
    var cadence: String? {
        switch self {
        case .activity, .network: "Samples every 2 seconds, only while it is on screen."
        case .battery: "Updates when power changes, and every 30 seconds."
        case .rings, .vitals: "Samples every 2 seconds, only while it is on screen."
        case .bigClock: "Redraws once a minute, or once a second with seconds on, and only while it is on screen."
        case .weather: "Asks Open-Meteo every 30 minutes while it is on screen, and keeps the last forecast for when you are offline."
        case .devices: "Reads the battery level devices report every 2 minutes, only while it is on screen."
        case .clipboard: "Looks for a new copy once a second while it is on screen. Nothing is saved to disk, and passwords marked secret are skipped."
        case .storage: "Reads every volume every 2 minutes, and when a disk mounts or ejects."
        case .events, .reminders: "Updates when Calendar or Reminders change, and every 5 minutes."
        default: nil
        }
    }
}

/// A curated palette: every colour works as glass tint and as accent, on dark and on light.
enum WidgetTint: String, Codable, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, amber, green, mint, teal, graphite
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// For dark faces.
    var color: Color {
        switch self {
        case .blue: DS.Ink.accent
        case .indigo: Color(red: 0.6, green: 0.6, blue: 1)
        case .purple: Color(red: 0.76, green: 0.56, blue: 1)
        case .pink: Color(red: 1, green: 0.55, blue: 0.75)
        case .red: Color(red: 1, green: 0.48, blue: 0.45)
        case .orange: Color(red: 1, green: 0.64, blue: 0.36)
        case .amber: Color(red: 1, green: 0.8, blue: 0.34)
        case .green: Color(red: 0.5, green: 0.88, blue: 0.5)
        case .mint: Color(red: 0.4, green: 0.92, blue: 0.78)
        case .teal: Color(red: 0.36, green: 0.82, blue: 0.92)
        case .graphite: Color(white: 0.78)
        }
    }

    /// For light faces, where the pastel would wash out.
    var deep: Color {
        switch self {
        case .blue: Color(red: 0.1, green: 0.4, blue: 0.9)
        case .indigo: Color(red: 0.3, green: 0.3, blue: 0.82)
        case .purple: Color(red: 0.5, green: 0.26, blue: 0.82)
        case .pink: Color(red: 0.85, green: 0.2, blue: 0.5)
        case .red: Color(red: 0.84, green: 0.2, blue: 0.18)
        case .orange: Color(red: 0.88, green: 0.42, blue: 0.08)
        case .amber: Color(red: 0.72, green: 0.5, blue: 0)
        case .green: Color(red: 0.14, green: 0.6, blue: 0.24)
        case .mint: Color(red: 0, green: 0.6, blue: 0.5)
        case .teal: Color(red: 0, green: 0.52, blue: 0.66)
        case .graphite: Color(white: 0.32)
        }
    }
}

enum WidgetMaterial: String, Codable, CaseIterable, Identifiable {
    case glass, clear, tinted, dark, frosted, outline, bare
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bare: "None"
        case .glass: "Glass"
        case .clear: "Clear"
        case .tinted: "Tinted"
        case .dark: "Dark"
        case .frosted: "Frosted"
        case .outline: "Outline"
        }
    }
    var light: Bool { self == .frosted }
}

enum WidgetFont: String, Codable, CaseIterable, Identifiable {
    case system, rounded, serif, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "SF"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }
    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
    }
}

struct WidgetStyle: Codable, Equatable {
    var material = WidgetMaterial.glass
    var tint = WidgetTint.blue
    var accent = WidgetTint.blue
    var radius = 26.0
    var opacity = 1.0
    var font = WidgetFont.system
    /// 0 is flat, 1 a deep, soft drop shadow.
    var shadow = 0.0
    /// An extra rim, in points. 0 draws none.
    var border = 0.0
    /// Room added inside the edge, in points.
    var padding = 0.0
    /// Text and everything with it, from 85% to 120%.
    var scale = 1.0
    /// A gradient laid under the content, over the material.
    var gradient: WidgetGradient?
    /// A picture laid under the content, by file name in Widget Photos. Wins over the gradient.
    var image: String?
    /// How much the surface blurs what is behind it, or how soft the background picture is. 0 leaves both alone.
    var blur = 0.0

    static let radii = 10.0...40.0
    static let opacities = 0.35...1.0
    static let shadows = 0.0...1.0
    static let borders = 0.0...2.0
    static let paddings = 0.0...14.0
    static let scales = 0.85...1.2
    static let blurs = 0.0...1.0

    init() {}

    /// Every field is optional on disk, so a style saved by an older or newer build still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = WidgetStyle()
        material = (try? c.decodeIfPresent(WidgetMaterial.self, forKey: .material)) ?? base.material
        tint = (try? c.decodeIfPresent(WidgetTint.self, forKey: .tint)) ?? base.tint
        accent = (try? c.decodeIfPresent(WidgetTint.self, forKey: .accent)) ?? base.accent
        radius = clamp((try? c.decodeIfPresent(Double.self, forKey: .radius)) ?? base.radius, Self.radii)
        opacity = clamp((try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? base.opacity, Self.opacities)
        font = (try? c.decodeIfPresent(WidgetFont.self, forKey: .font)) ?? base.font
        shadow = clamp((try? c.decodeIfPresent(Double.self, forKey: .shadow)) ?? base.shadow, Self.shadows)
        border = clamp((try? c.decodeIfPresent(Double.self, forKey: .border)) ?? base.border, Self.borders)
        padding = clamp((try? c.decodeIfPresent(Double.self, forKey: .padding)) ?? base.padding, Self.paddings)
        scale = clamp((try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? base.scale, Self.scales)
        gradient = try? c.decodeIfPresent(WidgetGradient.self, forKey: .gradient)
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        blur = clamp((try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? base.blur, Self.blurs)
    }

    /// No surface at all: the content sits straight on the wallpaper, like the old Desktop Clock.
    static var bare: WidgetStyle {
        var style = WidgetStyle()
        style.material = .bare
        return style
    }

    /// The notes widget has always been a warm, rounded sheet.
    static var note: WidgetStyle {
        var style = WidgetStyle()
        style.material = .tinted
        style.tint = .amber
        style.accent = .amber
        style.font = .rounded
        return style
    }
}

/// Two colours and a direction, for a widget's background.
struct WidgetGradient: Codable, Equatable {
    var from = WidgetTint.indigo
    var to = WidgetTint.pink
    /// Degrees, 0 runs left to right, 90 top to bottom.
    var angle = 45.0

    var points: (start: UnitPoint, end: UnitPoint) {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2, dy = sin(radians) / 2
        return (UnitPoint(x: 0.5 - dx, y: 0.5 - dy), UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

/// A span in grid cells, for widgets that take any size.
struct WidgetSpan: Codable, Equatable, Hashable {
    var columns: Int
    var rows: Int
    var tuple: (columns: Int, rows: Int) { (columns, rows) }
    var title: String { "\(columns) × \(rows)" }
}

/// Board-wide looks, one click each.
enum BoardTheme: String, CaseIterable, Identifiable {
    case standard, ice, noir, sunset, aurora, mono, paper
    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Glass"
        case .ice: "Ice"
        case .noir: "Noir"
        case .sunset: "Sunset"
        case .aurora: "Aurora"
        case .mono: "Mono"
        case .paper: "Paper"
        }
    }

    var style: WidgetStyle {
        var style = WidgetStyle()
        switch self {
        case .standard: break
        case .ice:
            style.material = .tinted; style.tint = .teal; style.accent = .teal; style.radius = 28; style.shadow = 0.3
        case .noir:
            style.material = .dark; style.accent = .amber; style.font = .serif; style.radius = 18; style.shadow = 0.6; style.border = 0.5
        case .sunset:
            style.material = .tinted; style.tint = .orange; style.accent = .pink; style.font = .rounded; style.radius = 30; style.shadow = 0.35
        case .aurora:
            style.material = .tinted; style.tint = .purple; style.accent = .mint; style.radius = 26; style.shadow = 0.3
        case .mono:
            style.material = .outline; style.accent = .graphite; style.font = .mono; style.radius = 14
        case .paper:
            style.material = .frosted; style.accent = .orange; style.font = .serif; style.radius = 22; style.shadow = 0.25
        }
        return style
    }

    /// Two colours for the chip that stands for the theme in Settings.
    var swatch: [Color] {
        switch self {
        case .standard: [Color(white: 0.55), Color(white: 0.3)]
        case .ice: [WidgetTint.teal.color, Color(red: 0.12, green: 0.3, blue: 0.4)]
        case .noir: [Color(white: 0.1), WidgetTint.amber.color]
        case .sunset: [WidgetTint.orange.color, WidgetTint.pink.color]
        case .aurora: [WidgetTint.purple.color, WidgetTint.mint.color]
        case .mono: [Color(white: 0.85), Color(white: 0.15)]
        case .paper: [Color(white: 0.96), WidgetTint.orange.deep]
        }
    }
}

/// Where a widget sits: down on the desktop, or floating above windows like a sticky note.
enum WidgetLayer: String, Codable, CaseIterable, Identifiable {
    case desktop, floating
    var id: String { rawValue }
    var title: String { self == .desktop ? "On Desktop" : "Above Windows" }
}

struct CheckItem: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var text: String
    var done = false
}

struct Habit: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var symbol = "checkmark"
    /// Days marked done, as yyyy-MM-dd in the local calendar.
    var marks: [String] = []
}

struct LaunchLink: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case app, folder, url }
    var id = UUID().uuidString
    var kind: Kind
    var name: String
    /// A file path for apps and folders, a URL string for links.
    var target: String
}

struct WeatherPlace: Codable, Hashable {
    var name: String
    var region: String?
    var latitude: Double
    var longitude: Double
    var key: String { String(format: "%.3f,%.3f", latitude, longitude) }
}

/// What a widget shows, for kinds that hold content of their own.
struct WidgetOptions: Codable, Equatable {
    /// Countdown title, or a sticker's attribution, or a photo's caption, or a checklist's name.
    var title: String?
    /// A sticker's text.
    var text: String?
    /// The countdown target, and when the countdown was set, for its progress bar.
    var date: Date?
    var start: Date?
    /// File name of the photo inside Application Support.
    var photo: String?
    /// The moon as seen from the southern hemisphere.
    var southern: Bool?
    var items: [CheckItem]?
    var habits: [Habit]?
    var links: [LaunchLink]?
    var place: WeatherPlace?
    var fahrenheit: Bool?
    /// Slideshow folder, as a path.
    var folder: String?
    /// Slideshow interval, or the timer's length, in minutes.
    var minutes: Double?
    /// Timer instead of stopwatch.
    var timer: Bool?
    /// The widgets inside a Smart Stack, and whether it turns by itself.
    var stack: [WidgetPlacement]?
    var rotate: Bool?
    /// Big Clock and Vitals keep everything they show in one place each.
    var clock: ClockOptions?
    var vitals: VitalsOptions?

    init() {}

    /// Field by field, so one value an older or newer build wrote never costs the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        date = try? c.decodeIfPresent(Date.self, forKey: .date)
        start = try? c.decodeIfPresent(Date.self, forKey: .start)
        photo = try? c.decodeIfPresent(String.self, forKey: .photo)
        southern = try? c.decodeIfPresent(Bool.self, forKey: .southern)
        items = try? c.decodeIfPresent([CheckItem].self, forKey: .items)
        habits = try? c.decodeIfPresent([Habit].self, forKey: .habits)
        links = try? c.decodeIfPresent([LaunchLink].self, forKey: .links)
        place = try? c.decodeIfPresent(WeatherPlace.self, forKey: .place)
        fahrenheit = try? c.decodeIfPresent(Bool.self, forKey: .fahrenheit)
        folder = try? c.decodeIfPresent(String.self, forKey: .folder)
        minutes = try? c.decodeIfPresent(Double.self, forKey: .minutes)
        timer = try? c.decodeIfPresent(Bool.self, forKey: .timer)
        stack = try? c.decodeIfPresent([WidgetPlacement].self, forKey: .stack)
        rotate = try? c.decodeIfPresent(Bool.self, forKey: .rotate)
        clock = try? c.decodeIfPresent(ClockOptions.self, forKey: .clock)
        vitals = try? c.decodeIfPresent(VitalsOptions.self, forKey: .vitals)
    }
}

struct WidgetPlacement: Codable, Identifiable, Equatable {
    var kind: WidgetKind
    var column: Int
    var row: Int
    /// UUID of the display it lives on. A missing display sends it to the main screen.
    var screen: String
    var uid: String
    var size: WidgetSize
    /// Nil follows the board style.
    var style: WidgetStyle?
    var options: WidgetOptions
    var layer = WidgetLayer.desktop
    /// A locked widget keeps its place while the board is arranged.
    var locked = false
    /// Any span the owner dragged it to, for kinds that take one. Nil uses the size.
    var custom: WidgetSpan?
    var id: String { uid }

    init(kind: WidgetKind, column: Int, row: Int, screen: String, uid: String = UUID().uuidString,
         size: WidgetSize? = nil, style: WidgetStyle? = nil, options: WidgetOptions = WidgetOptions()) {
        self.kind = kind
        self.column = column
        self.row = row
        self.screen = screen
        self.uid = uid
        self.size = size ?? kind.defaultSize
        self.style = style
        self.options = options
    }

    var span: (columns: Int, rows: Int) {
        if kind.freeSpan, let custom { return custom.tuple }
        return kind.span(size)
    }

    /// The size as the owner reads it: Small, Medium, Large, or the cells of a free span.
    var sizeTitle: String { kind.freeSpan && custom != nil ? custom?.title ?? size.title : size.title }

    /// Placements saved before sizes and styles existed carry only kind, column, row and screen.
    /// There was one of each kind then, so the kind doubles as a stable id.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(WidgetKind.self, forKey: .kind)
        column = try c.decode(Int.self, forKey: .column)
        row = try c.decode(Int.self, forKey: .row)
        screen = try c.decode(String.self, forKey: .screen)
        let saved = try? c.decodeIfPresent(String.self, forKey: .uid)
        uid = saved ?? kind.rawValue
        let size = (try? c.decodeIfPresent(WidgetSize.self, forKey: .size)) ?? kind.defaultSize
        self.size = kind.sizes.contains(size) ? size : kind.defaultSize
        style = try? c.decodeIfPresent(WidgetStyle.self, forKey: .style)
        options = (try? c.decodeIfPresent(WidgetOptions.self, forKey: .options)) ?? WidgetOptions()
        layer = (try? c.decodeIfPresent(WidgetLayer.self, forKey: .layer)) ?? .desktop
        locked = (try? c.decodeIfPresent(Bool.self, forKey: .locked)) ?? false
        if let span = try? c.decodeIfPresent(WidgetSpan.self, forKey: .custom), span.columns > 0, span.rows > 0 {
            custom = WidgetSpan(columns: min(span.columns, WidgetKind.maximumSpan.columns), rows: min(span.rows, WidgetKind.maximumSpan.rows))
        }
        // The old notes widget wore an amber glass of its own. Keep it that way.
        if saved == nil, kind == .notes, style == nil { style = .note }
    }
}

/// A named arrangement the owner can come back to.
struct WidgetLayout: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var placements: [WidgetPlacement]
    var style: WidgetStyle
    var saved = Date()
}

/// Decodes what it can, so one unreadable entry never costs the rest of the board.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

private func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double { min(max(value, range.lowerBound), range.upperBound) }

struct WorldCity: Codable, Hashable, Identifiable {
    let name: String
    let zone: String
    var id: String { zone }
    var timeZone: TimeZone { TimeZone(identifier: zone) ?? .current }

    static let catalog = [
        WorldCity(name: "San Francisco", zone: "America/Los_Angeles"), WorldCity(name: "Chicago", zone: "America/Chicago"),
        WorldCity(name: "New York", zone: "America/New_York"), WorldCity(name: "São Paulo", zone: "America/Sao_Paulo"),
        WorldCity(name: "London", zone: "Europe/London"), WorldCity(name: "Lisbon", zone: "Europe/Lisbon"),
        WorldCity(name: "Paris", zone: "Europe/Paris"), WorldCity(name: "Berlin", zone: "Europe/Berlin"),
        WorldCity(name: "Istanbul", zone: "Europe/Istanbul"), WorldCity(name: "Dubai", zone: "Asia/Dubai"),
        WorldCity(name: "Mumbai", zone: "Asia/Kolkata"), WorldCity(name: "Singapore", zone: "Asia/Singapore"),
        WorldCity(name: "Hong Kong", zone: "Asia/Hong_Kong"), WorldCity(name: "Tokyo", zone: "Asia/Tokyo"),
        WorldCity(name: "Seoul", zone: "Asia/Seoul"), WorldCity(name: "Sydney", zone: "Australia/Sydney"),
        WorldCity(name: "Auckland", zone: "Pacific/Auckland"),
    ]
}

@MainActor
final class Pomodoro: ObservableObject {
    enum Phase: Equatable {
        case focus, rest, longRest
        var title: String {
            switch self {
            case .focus: "Focus"
            case .rest: "Break"
            case .longRest: "Long Break"
            }
        }
    }

    @Published private(set) var phase = Phase.focus
    @Published private(set) var running = false
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var finished = 0
    @Published var focusMinutes: Double {
        didSet {
            UserDefaults.standard.set(focusMinutes, forKey: "pomodoroMinutes")
            if !running, phase == .focus { remaining = total }
        }
    }
    private var end: Date?
    private var timer: Timer?

    init() {
        let saved = UserDefaults.standard.double(forKey: "pomodoroMinutes")
        focusMinutes = saved > 0 ? saved : 25
        remaining = (saved > 0 ? saved : 25) * 60
    }

    var total: TimeInterval {
        switch phase {
        case .focus: (focusMinutes * 60).rounded()
        case .rest: 5 * 60
        case .longRest: 15 * 60
        }
    }

    var progress: Double { min(max(remaining / total, 0), 1) }

    func toggle() {
        if running {
            remaining = end?.timeIntervalSinceNow ?? remaining
            halt()
        } else {
            resume()
        }
    }

    func reset() {
        halt()
        phase = .focus
        finished = 0
        remaining = total
    }

    private func resume() {
        end = Date().addingTimeInterval(remaining)
        running = true
        let tick = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { WidgetBoard.shared.pomodoro.tick() }
        }
        tick.tolerance = 0.1
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    private func halt() {
        timer?.invalidate()
        timer = nil
        end = nil
        running = false
    }

    private func tick() {
        guard let end else { return }
        remaining = max(end.timeIntervalSinceNow, 0)
        guard remaining <= 0 else { return }
        halt()
        NSSound(named: "Glass")?.play()
        if phase == .focus {
            finished += 1
            phase = finished % 4 == 0 ? .longRest : .rest
        } else {
            phase = .focus
        }
        remaining = total
        resume()
    }
}

/// What changes while arranging: the selection, the drop ghost and the alignment guides.
/// Kept apart from the board, so a drag never redraws the Studio stage, which watches the board.
@MainActor
final class WidgetSession: ObservableObject {
    static let shared = WidgetSession()
    /// The widget open in the inspector in Settings.
    @Published var selection: String?
    /// Where the widget being dragged would land.
    @Published var ghost: WidgetPlacement?
    /// Edges of other widgets the ghost lines up with, in canvas points.
    @Published var guides = AlignmentGuides()
    /// When the board last came on screen, so tiles arrive with a cascade only then.
    var entrance = Date.distantPast
    /// When arranging last began, so tiles give one small wiggle then, and only then.
    var arrangeStarted = Date.distantPast
    /// The widget being resized by its corner, and the span it would take.
    @Published var resizing: (uid: String, span: WidgetSpan)?
}

struct AlignmentGuides: Equatable {
    var vertical: [Double] = []
    var horizontal: [Double] = []
    var isEmpty: Bool { vertical.isEmpty && horizontal.isEmpty }
}

/// Our own widgets, drawn on the desktop. Click-through until the owner asks to arrange them.
@MainActor
final class WidgetBoard: ObservableObject {
    static let shared = WidgetBoard()

    static let pitch = 104.0
    static let gap = 12.0
    static let inset = 24.0
    /// Room around a widget in its own window, for the shadow and the hover lift.
    static let margin = 28.0

    private let store = UserDefaults.standard
    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "boardOn"); apply() } }
    @Published var editing = false { didSet { applyEditing() } }
    @Published var placements: [WidgetPlacement] = [] { didSet { save(); syncDetached() } }
    @Published var note: String { didSet { store.set(note, forKey: "boardNote") } }
    @Published var cities: [WorldCity] { didSet { store.set(try? JSONEncoder().encode(cities), forKey: "boardCities") } }
    /// The look every widget wears unless it has a style of its own.
    @Published var style: WidgetStyle { didSet { store.set(try? JSONEncoder().encode(style), forKey: "boardStyle") } }
    /// Lets clicks reach widgets with controls while the board is at rest. Everything else stays click-through.
    @Published var interactive: Bool { didSet { store.set(interactive, forKey: "boardInteractive"); syncDetached() } }
    /// Saved arrangements.
    @Published var layouts: [WidgetLayout] { didSet { store.set(try? JSONEncoder().encode(layouts), forKey: "boardLayouts") } }
    /// How widgets make room for Finder's desktop icons that sit over them.
    @Published var harmony: IconHarmony { didSet { store.set(harmony.rawValue, forKey: "boardHarmony"); syncIcons() } }
    let pomodoro = Pomodoro()
    let session = WidgetSession.shared

    /// Compatibility with code that predates the session: these live there now.
    var selection: String? {
        get { session.selection }
        set { session.selection = newValue }
    }

    private var panels: [String: FloatingPanel] = [:]
    /// Widgets with a window of their own: above windows, or taking clicks.
    private var detached: [String: FloatingPanel] = [:]
    private var started = false
    private var keyMonitor: Any?

    private init() {
        enabled = store.bool(forKey: "boardOn")
        note = store.string(forKey: "boardNote") ?? ""
        cities = (store.data(forKey: "boardCities")).flatMap { try? JSONDecoder().decode([WorldCity].self, from: $0) }
            ?? [WorldCity(name: "New York", zone: "America/New_York"), WorldCity(name: "London", zone: "Europe/London"), WorldCity(name: "Tokyo", zone: "Asia/Tokyo")]
        style = store.data(forKey: "boardStyle").flatMap { try? JSONDecoder().decode(WidgetStyle.self, from: $0) } ?? WidgetStyle()
        interactive = store.bool(forKey: "boardInteractive")
        harmony = IconHarmony(rawValue: store.string(forKey: "boardHarmony") ?? "") ?? .halo
        layouts = store.data(forKey: "boardLayouts").flatMap { try? JSONDecoder().decode([Lenient<WidgetLayout>].self, from: $0) }?
            .compactMap(\.value) ?? []
        if let data = store.data(forKey: "boardPlacements") {
            placements = Self.decode(data)
        }
    }

    /// Reads saved placements from any build, dropping only entries that cannot be read and duplicate ids.
    static func decode(_ data: Data) -> [WidgetPlacement] {
        guard let entries = try? JSONDecoder().decode([Lenient<WidgetPlacement>].self, from: data) else { return [] }
        var seen = Set<String>()
        return entries.compactMap(\.value).filter { seen.insert($0.uid).inserted }
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WidgetBoard.shared.apply() }
        }
        apply()
    }

    private func save() {
        store.set(try? JSONEncoder().encode(placements), forKey: "boardPlacements")
    }

    // MARK: Windows

    static func key(for screen: NSScreen) -> String {
        guard let id = screen.displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "main" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private var mainKey: String { NSScreen.screens.first.map(Self.key) ?? "main" }

    private var editLevel: NSWindow.Level { NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2) }
    private var restLevel: NSWindow.Level { NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1) }
    /// Above Finder's icons, so clicks land on the widget, but below every app window.
    private var clickLevel: NSWindow.Level { NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1) }

    /// Whether this widget is drawn in a window of its own while the board is at rest.
    func isDetached(_ placement: WidgetPlacement) -> Bool {
        placement.layer == .floating || (interactive && placement.kind.needsClicks)
    }

    /// Whether clicks reach this widget while the board is at rest.
    func takesClicks(_ placement: WidgetPlacement) -> Bool { interactive && placement.kind.needsClicks }

    private func apply() {
        guard started else { return }
        guard enabled else {
            if editing { editing = false }
            // Tearing the views down lets every live meter they hold stop sampling.
            panels.values.forEach { $0.orderOut(nil); $0.contentView = nil }
            panels = [:]
            syncDetached()
            syncIcons()
            return
        }
        if placements.isEmpty, store.data(forKey: "boardPlacements") == nil, let screen = NSScreen.screens.first {
            add(.calendar, screen: screen)
            add(.clocks, screen: screen)
        }
        var wanted: [String: NSScreen] = [:]
        for screen in NSScreen.screens { wanted[Self.key(for: screen)] = screen }
        for (key, panel) in panels where wanted[key] == nil {
            panel.orderOut(nil)
            panel.contentView = nil
            panels[key] = nil
        }
        if panels.isEmpty { session.entrance = Date() }
        for (key, screen) in wanted {
            let frame = screen.visibleFrame
            let root = BoardCanvas(board: self, session: session, screen: key, fallback: key == mainKey, size: frame.size)
                .frame(width: frame.width, height: frame.height)
            if let panel = panels[key] {
                (panel.contentView as? NSHostingView<BoardRoot>)?.rootView = AnyView(root)
                panel.setFrame(frame, display: true)
                continue
            }
            let panel = FloatingPanel(frame: frame)
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            let host = NSHostingView<BoardRoot>(rootView: AnyView(root))
            host.sizingOptions = []
            panel.contentView = host
            panel.setFrame(frame, display: true)
            panels[key] = panel
            setMode(panel)
            panel.orderFrontRegardless()
        }
        syncDetached()
        syncIcons()
    }

    /// Finder's icon frames are read only while the board is on screen and something uses them.
    func syncIcons() {
        DesktopIcons.shared.run(started && enabled && (harmony != .off || editing))
    }

    private func setMode(_ panel: FloatingPanel) {
        panel.level = editing ? editLevel : restLevel
        panel.ignoresMouseEvents = !editing
    }

    /// The frame, in screen points, of the window a widget gets of its own.
    static func detachedFrame(_ placement: WidgetPlacement, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let origin = Self.origin(column: placement.column, row: placement.row)
        let tile = Self.tileSize(placement)
        return NSRect(x: visible.minX + origin.x - margin, y: visible.maxY - origin.y - tile.height - margin,
                      width: tile.width + margin * 2, height: tile.height + margin * 2)
    }

    /// Gives floating and interactive widgets their own small windows while the board is at rest.
    /// Only frames and levels change on later calls; the views inside watch the board themselves.
    private func syncDetached() {
        guard started else { return }
        let screens = NSScreen.screens
        var wanted: [String: (WidgetPlacement, NSScreen)] = [:]
        if enabled, !editing {
            for placement in placements where isDetached(placement) {
                guard let screen = screens.first(where: { Self.key(for: $0) == placement.screen }) ?? screens.first else { continue }
                wanted[placement.uid] = (placement, screen)
            }
        }
        for (uid, panel) in detached where wanted[uid] == nil {
            panel.orderOut(nil)
            panel.contentView = nil
            detached[uid] = nil
        }
        for (uid, entry) in wanted {
            let (placement, screen) = entry
            let frame = Self.detachedFrame(placement, on: screen)
            let panel: FloatingPanel
            if let existing = detached[uid] {
                panel = existing
                if panel.frame != frame { panel.setFrame(frame, display: true) }
            } else {
                panel = FloatingPanel(frame: frame)
                panel.appearance = NSAppearance(named: .darkAqua)
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
                let host = NSHostingView<BoardRoot>(rootView: AnyView(DetachedTile(board: self, uid: uid)))
                host.sizingOptions = []
                panel.contentView = host
                panel.setFrame(frame, display: true)
                detached[uid] = panel
            }
            let level = placement.layer == .floating ? NSWindow.Level.floating : clickLevel
            if panel.level != level { panel.level = level }
            let ignores = !takesClicks(placement)
            if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func applyEditing() {
        guard !editing || enabled else {
            enabled = true
            applyEditing()
            return
        }
        session.ghost = nil
        session.guides = AlignmentGuides()
        if editing { session.arrangeStarted = Date() }
        syncDetached()
        syncIcons()
        for panel in panels.values {
            setMode(panel)
            panel.orderFrontRegardless()
            if !editing { panel.makeFirstResponder(nil) }
        }
        if editing {
            let mouse = NSEvent.mouseLocation
            (panels.values.first { $0.frame.contains(mouse) } ?? panels.values.first)?.makeKey()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let code = event.keyCode, command = event.modifierFlags.contains(.command)
                let handled = MainActor.assumeIsolated { WidgetBoard.shared.handleEditKey(code, command: command) }
                return handled ? nil : event
            }
        } else if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
            // A non-activating panel keeps the keyboard until it leaves the screen for a moment.
            for panel in panels.values where panel.isKeyWindow {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
    }

    /// Esc ends arranging. Arrows nudge the selected widget a cell, ⌘D duplicates it, Delete removes it,
    /// unless a text field has the keyboard.
    private func handleEditKey(_ keyCode: UInt16, command: Bool) -> Bool {
        if keyCode == 53 {
            editing = false
            return true
        }
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        guard let id = session.selection, let current = placement(id), placements.contains(where: { $0.uid == id }) else { return false }
        switch keyCode {
        case 123: nudge(id, columns: -1, rows: 0); return true
        case 124: nudge(id, columns: 1, rows: 0); return true
        case 125: nudge(id, columns: 0, rows: 1); return true
        case 126: nudge(id, columns: 0, rows: -1); return true
        case 51, 117:
            guard !current.locked else { NSSound.beep(); return true }
            withAnimation(DS.Motion.arrive) { remove(id) }
            return true
        case 2 where command:
            withAnimation(DS.Motion.arrive) { if let copy = duplicate(id) { session.selection = copy } }
            return true
        default:
            return false
        }
    }

    // MARK: Layout

    static func cells(in size: CGSize) -> (columns: Int, rows: Int) {
        (max(Int((size.width - inset * 2 + gap) / pitch), 1), max(Int((size.height - inset * 2 + gap) / pitch), 1))
    }

    static func tileSize(span: (columns: Int, rows: Int)) -> CGSize {
        CGSize(width: Double(span.columns) * pitch - gap, height: Double(span.rows) * pitch - gap)
    }

    static func tileSize(_ placement: WidgetPlacement) -> CGSize { tileSize(span: placement.span) }

    /// The size of the first widget of this kind on the board, or of a new one.
    static func tileSize(_ kind: WidgetKind) -> CGSize {
        tileSize(span: shared.placements.first { $0.kind == kind }?.span ?? kind.span)
    }

    static func origin(column: Int, row: Int) -> CGPoint {
        CGPoint(x: inset + Double(column) * pitch, y: inset + Double(row) * pitch)
    }

    /// A widget's tile in canvas points.
    static func frame(of placement: WidgetPlacement) -> CGRect {
        CGRect(origin: origin(column: placement.column, row: placement.row), size: tileSize(placement))
    }

    func placements(on screen: String, fallback: Bool) -> [WidgetPlacement] {
        let connected = Set(NSScreen.screens.map(Self.key))
        return placements.filter { $0.screen == screen || (fallback && !connected.contains($0.screen)) }
    }

    private func others(_ id: String?, screen: String, fallback: Bool) -> [WidgetPlacement] {
        placements(on: screen, fallback: fallback).filter { $0.uid != id }
    }

    private static func overlaps(_ c: Int, _ r: Int, _ span: (columns: Int, rows: Int), _ other: WidgetPlacement) -> Bool {
        !(c + span.columns <= other.column || other.column + other.span.columns <= c
            || r + span.rows <= other.row || other.row + other.span.rows <= r)
    }

    /// The free slot closest to where the widget was asked to go.
    /// Anywhere on the screen is fair game, the column under Finder's icons too. Only new widgets,
    /// with `avoidIcons`, start clear of that column, unless the screen has no other room.
    func slot(span: (columns: Int, rows: Int), excluding id: String?, column: Int, row: Int, screen: String, fallback: Bool, size: CGSize,
              avoidIcons: Bool = false) -> (column: Int, row: Int) {
        let grid = Self.cells(in: size)
        let lane = avoidIcons && Self.desktopIconsShown ? Int((120 / Self.pitch).rounded(.up)) : 0
        let maxColumn = max(grid.columns - span.columns - lane, 0), maxRow = max(grid.rows - span.rows, 0)
        let others = others(id, screen: screen, fallback: fallback)
        var best = (column: min(max(column, 0), maxColumn), row: min(max(row, 0), maxRow))
        var bestDistance = Int.max
        for c in 0...maxColumn {
            for r in 0...maxRow where !others.contains(where: { Self.overlaps(c, r, span, $0) }) {
                let distance = (c - column) * (c - column) + (r - row) * (r - row)
                if distance < bestDistance { bestDistance = distance; best = (c, r) }
            }
        }
        return best
    }

    /// Edges of other widgets that a widget at this spot lines up with, for the guides drawn while dragging.
    func guides(for ghost: WidgetPlacement, fallback: Bool) -> AlignmentGuides {
        let others = others(ghost.uid, screen: ghost.screen, fallback: fallback)
        let a = WidgetBoard.origin(column: ghost.column, row: ghost.row), size = WidgetBoard.tileSize(ghost)
        let xs = [a.x, a.x + size.width / 2, a.x + size.width], ys = [a.y, a.y + size.height / 2, a.y + size.height]
        var result = AlignmentGuides()
        for other in others {
            let b = WidgetBoard.origin(column: other.column, row: other.row), s = WidgetBoard.tileSize(other)
            for x in [b.x, b.x + s.width / 2, b.x + s.width] where xs.contains(where: { abs($0 - x) < 0.5 }) { result.vertical.append(x) }
            for y in [b.y, b.y + s.height / 2, b.y + s.height] where ys.contains(where: { abs($0 - y) < 0.5 }) { result.horizontal.append(y) }
        }
        result.vertical = Array(Set(result.vertical)).sorted()
        result.horizontal = Array(Set(result.horizontal)).sorted()
        return result
    }

    /// Finder's `CreateDesktop`, and from macOS 14 Desktop & Dock's "Show Items: On Desktop",
    /// either of which can hide the icons. Read however each was written (bool, number or string).
    private static var desktopIconsShown: Bool {
        DesktopCompat.finderShowsIcons(
            createDesktop: UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop"),
            standardHideDesktopIcons: UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "StandardHideDesktopIcons"),
            major: MacPlatform.major)
    }

    // MARK: Editing the board

    func isOn(_ kind: WidgetKind) -> Bool { placements.contains { $0.kind == kind } }

    /// A widget on the board, or one inside a Smart Stack.
    func placement(_ id: String) -> WidgetPlacement? {
        if let top = placements.first(where: { $0.uid == id }) { return top }
        for stack in placements where stack.kind == .stack {
            if let inner = stack.options.stack?.first(where: { $0.uid == id }) { return inner }
        }
        return nil
    }

    /// The stack a widget sits in, if it sits in one.
    func stack(containing id: String) -> WidgetPlacement? {
        placements.first { $0.kind == .stack && $0.options.stack?.contains { $0.uid == id } == true }
    }

    func update(_ id: String, _ change: (inout WidgetPlacement) -> Void) {
        if let index = placements.firstIndex(where: { $0.uid == id }) {
            var copy = placements[index]
            change(&copy)
            if copy != placements[index] { placements[index] = copy }
            return
        }
        guard let index = placements.firstIndex(where: { $0.kind == .stack && $0.options.stack?.contains { $0.uid == id } == true }),
              var inner = placements[index].options.stack, let at = inner.firstIndex(where: { $0.uid == id }) else { return }
        var copy = inner[at]
        change(&copy)
        guard copy != inner[at] else { return }
        inner[at] = copy
        placements[index].options.stack = inner
    }

    func style(for placement: WidgetPlacement) -> WidgetStyle { placement.style ?? style }

    func set(_ kind: WidgetKind, on: Bool) {
        if on, !isOn(kind) {
            add(kind)
        } else if !on {
            placements.filter { $0.kind == kind }.forEach { remove($0.uid) }
        }
    }

    /// Adds a widget to the display under the pointer and opens it in the inspector.
    @discardableResult
    func add(_ kind: WidgetKind) -> String? {
        if !kind.allowsMultiple, let existing = placements.first(where: { $0.kind == kind }) {
            selection = existing.uid
            return existing.uid
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first else { return nil }
        let id = add(kind, screen: screen)
        selection = id
        return id
    }

    /// What a new widget of this kind starts with.
    static func starter(_ kind: WidgetKind) -> WidgetOptions {
        var options = WidgetOptions()
        switch kind {
        case .countdown: options.start = Date()
        case .checklist:
            options.title = "Today"
            options.items = []
        case .habits: options.habits = []
        case .launcher: options.links = []
        case .slideshow: options.minutes = 5
        case .stopwatch: options.minutes = 5
        case .bigClock: options.clock = ClockOptions()
        case .vitals: options.vitals = VitalsOptions()
        case .stack:
            options.rotate = false
            options.stack = [WidgetKind.calendar, .progress].map {
                WidgetPlacement(kind: $0, column: 0, row: 0, screen: "", size: .small, options: starter($0))
            }
        default: break
        }
        return options
    }

    /// A Big Clock starts with no surface, its text straight on the wallpaper. Notes wear their amber sheet.
    static func starterStyle(_ kind: WidgetKind) -> WidgetStyle? {
        switch kind {
        case .notes: .note
        case .bigClock, .vitals: .bare
        default: nil
        }
    }

    static func starterSpan(_ kind: WidgetKind) -> WidgetSpan? {
        kind == .bigClock ? WidgetSpan(columns: 5, rows: 2) : nil
    }

    /// New widgets start in the top right, the corner the Desktop Clock leaves free, but clear
    /// of the column where Finder lines up desktop icons.
    @discardableResult
    private func add(_ kind: WidgetKind, screen: NSScreen) -> String {
        let key = Self.key(for: screen)
        let size = screen.visibleFrame.size
        var placement = WidgetPlacement(kind: kind, column: 0, row: 0, screen: key,
                                        uid: kind.allowsMultiple ? UUID().uuidString : kind.rawValue,
                                        style: Self.starterStyle(kind), options: Self.starter(kind))
        placement.custom = Self.starterSpan(kind)
        let span = placement.span
        let column = Self.cells(in: size).columns - span.columns
        let place = slot(span: span, excluding: nil, column: column, row: 0, screen: key, fallback: key == mainKey, size: size, avoidIcons: true)
        placement.column = place.column
        placement.row = place.row
        placements.append(placement)
        return placement.uid
    }

    /// Photo files still in use by the board, a stack or a saved layout, as a photo or as a background.
    func photoInUse(_ name: String) -> Bool {
        func uses(_ list: [WidgetPlacement]) -> Bool {
            list.contains { $0.options.photo == name || $0.style?.image == name || uses($0.options.stack ?? []) }
        }
        return style.image == name || uses(placements) || layouts.contains { $0.style.image == name || uses($0.placements) }
    }

    /// Every picture a list of placements holds, photos and backgrounds alike.
    static func pictures(_ list: [WidgetPlacement]) -> [String] {
        list.flatMap { [$0.options.photo, $0.style?.image].compactMap { $0 } + pictures($0.options.stack ?? []) }
    }

    /// Deletes a picture file once nothing refers to it any more.
    func release(picture name: String?) {
        guard let name, !photoInUse(name) else { return }
        WidgetPhotos.delete(name)
    }

    func remove(_ id: String) {
        if let stack = stack(containing: id) {
            update(stack.uid) { $0.options.stack?.removeAll { $0.uid == id } }
            if selection == id { selection = stack.uid }
            return
        }
        guard let gone = placement(id) else { return }
        placements.removeAll { $0.uid == id }
        if selection == id { selection = nil }
        for photo in Set(Self.pictures([gone])) where !photoInUse(photo) { WidgetPhotos.delete(photo) }
    }

    func move(_ id: String, column: Int, row: Int, screen: String) {
        update(id) {
            $0.column = column
            $0.row = row
            $0.screen = screen
        }
    }

    private func screenSize(for key: String) -> (size: CGSize, fallback: Bool) {
        let screen = NSScreen.screens.first { Self.key(for: $0) == key } ?? NSScreen.screens.first
        let frame = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return (frame, screen.map { Self.key(for: $0) == mainKey } ?? true)
    }

    /// Changes size and finds the nearest place where the new span fits.
    func resize(_ id: String, to size: WidgetSize) {
        guard let current = placement(id), current.kind.sizes.contains(size), current.size != size || current.custom != nil else { return }
        guard stack(containing: id) == nil else { return }
        let area = screenSize(for: current.screen)
        let place = slot(span: current.kind.span(size), excluding: id, column: current.column, row: current.row,
                         screen: current.screen, fallback: area.fallback, size: area.size)
        update(id) {
            $0.size = size
            $0.custom = nil
            $0.column = place.column
            $0.row = place.row
        }
    }

    /// The span a free-span widget can take at this spot: within its kind's limits and the screen.
    func clampedSpan(_ span: WidgetSpan, for placement: WidgetPlacement) -> WidgetSpan {
        let grid = Self.cells(in: screenSize(for: placement.screen).size)
        let low = placement.kind.minimumSpan, high = WidgetKind.maximumSpan
        return WidgetSpan(columns: min(max(span.columns, low.columns), high.columns, max(grid.columns, low.columns)),
                          rows: min(max(span.rows, low.rows), high.rows, max(grid.rows, low.rows)))
    }

    /// Any span, for kinds that take one. The widget keeps its corner if the new span fits there.
    func resize(_ id: String, span: WidgetSpan) {
        guard let current = placements.first(where: { $0.uid == id }), current.kind.freeSpan else { return }
        let span = clampedSpan(span, for: current)
        guard span.tuple != current.span else { return }
        let area = screenSize(for: current.screen)
        let place = slot(span: span.tuple, excluding: id, column: current.column, row: current.row,
                         screen: current.screen, fallback: area.fallback, size: area.size)
        update(id) {
            $0.custom = span
            $0.column = place.column
            $0.row = place.row
        }
    }

    func cycleSize(_ id: String) {
        guard let current = placement(id) else { return }
        let sizes = current.kind.sizes
        guard let index = sizes.firstIndex(of: current.size), sizes.count > 1 else { return }
        resize(id, to: current.custom != nil ? current.size : sizes[(index + 1) % sizes.count])
    }

    /// One cell in a direction, if that spot is free and on the screen.
    func nudge(_ id: String, columns: Int, rows: Int) {
        guard let current = placements.first(where: { $0.uid == id }), !current.locked else { return }
        let area = screenSize(for: current.screen)
        let grid = Self.cells(in: area.size), span = current.span
        let c = current.column + columns, r = current.row + rows
        guard c >= 0, r >= 0, c + span.columns <= grid.columns, r + span.rows <= grid.rows,
              !others(id, screen: current.screen, fallback: area.fallback).contains(where: { Self.overlaps(c, r, span, $0) }) else {
            NSSound.beep()
            return
        }
        withAnimation(DS.Motion.settle) { move(id, column: c, row: r, screen: current.screen) }
    }

    /// A copy beside the original, for kinds that can appear more than once.
    @discardableResult
    func duplicate(_ id: String) -> String? {
        guard let original = placements.first(where: { $0.uid == id }), original.kind.allowsMultiple else { return nil }
        var copy = original
        copy.uid = UUID().uuidString
        copy.locked = false
        copy.options.stack = copy.options.stack?.map { var inner = $0; inner.uid = UUID().uuidString; return inner }
        let area = screenSize(for: original.screen)
        let place = slot(span: original.span, excluding: nil, column: original.column + original.span.columns, row: original.row,
                         screen: original.screen, fallback: area.fallback, size: area.size)
        copy.column = place.column
        copy.row = place.row
        placements.append(copy)
        return copy.uid
    }

    var screenCount: Int { NSScreen.screens.count }

    func sendToNextScreen(_ id: String) {
        let screens = NSScreen.screens
        guard screens.count > 1, let current = placement(id) else { return }
        let index = screens.firstIndex { Self.key(for: $0) == current.screen } ?? 0
        let next = screens[(index + 1) % screens.count]
        let key = Self.key(for: next)
        let place = slot(span: current.span, excluding: id, column: current.column, row: current.row, screen: key,
                         fallback: key == mainKey, size: next.visibleFrame.size)
        move(id, column: place.column, row: place.row, screen: key)
    }

    // MARK: Stacks

    /// Kinds that can go inside a stack of this size.
    static func stackable(for size: WidgetSize) -> [WidgetKind] {
        WidgetKind.allCases.filter { $0 != .stack && $0.sizes.contains(size) && !$0.edgeToEdge }
    }

    func addToStack(_ id: String, kind: WidgetKind) {
        guard let stack = placements.first(where: { $0.uid == id }), stack.kind == .stack else { return }
        let inner = WidgetPlacement(kind: kind, column: 0, row: 0, screen: "", size: stack.size, options: Self.starter(kind))
        update(id) { $0.options.stack = ($0.options.stack ?? []) + [inner] }
    }

    func moveInStack(_ id: String, by offset: Int) {
        guard let stack = stack(containing: id), var list = stack.options.stack, let index = list.firstIndex(where: { $0.uid == id }) else { return }
        let target = index + offset
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        update(stack.uid) { $0.options.stack = list }
    }

    // MARK: Themes and layouts

    func apply(theme: BoardTheme, everywhere: Bool) {
        style = theme.style
        if everywhere {
            for index in placements.indices where placements[index].style != nil { placements[index].style = nil }
        }
    }

    func saveLayout(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Layout \(layouts.count + 1)" : trimmed
        let layout = WidgetLayout(name: title, placements: placements, style: style)
        if let index = layouts.firstIndex(where: { $0.name == title }) {
            layouts[index] = WidgetLayout(id: layouts[index].id, name: title, placements: placements, style: style)
        } else {
            layouts.append(layout)
        }
    }

    func restore(_ layout: WidgetLayout) {
        style = layout.style
        placements = layout.placements
        session.selection = nil
    }

    func deleteLayout(_ id: String) {
        guard let gone = layouts.first(where: { $0.id == id }) else { return }
        layouts.removeAll { $0.id == id }
        for photo in Set(Self.pictures(gone.placements) + [gone.style.image].compactMap { $0 }) where !photoInUse(photo) { WidgetPhotos.delete(photo) }
    }
}

typealias BoardRoot = AnyView

// MARK: - Board

struct BoardCanvas: View {
    @ObservedObject var board: WidgetBoard
    @ObservedObject var session: WidgetSession
    let screen: String
    let fallback: Bool
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where this canvas sits in global top-left coordinates, the ones Accessibility reports Finder's icons in.
    private var globalOrigin: CGPoint {
        let screens = NSScreen.screens
        let match = screens.first { WidgetBoard.key(for: $0) == screen } ?? screens.first
        guard let visible = match?.visibleFrame, let primary = screens.first?.frame else { return .zero }
        return CGPoint(x: visible.minX, y: primary.maxY - visible.maxY)
    }

    var body: some View {
        let shown = board.placements(on: screen, fallback: fallback).filter { board.editing || !board.isDetached($0) }
        let origin = globalOrigin
        ZStack(alignment: .topLeading) {
            if board.editing {
                Color.black.opacity(0.26).transition(.opacity)
                GridDots(size: size).transition(.opacity)
                IconMarks(origin: origin, size: size).transition(.opacity)
            }
            if let ghost = session.ghost, ghost.screen == screen {
                GhostTile(ghost: ghost, radius: board.style(for: ghost).radius)
                    .animation(reduceMotion ? nil : DS.Motion.touch, value: ghost)
                GuideLines(guides: session.guides, size: size)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, placement in
                BoardTile(board: board, placement: placement, screen: screen, fallback: fallback, canvas: size, order: index, globalOrigin: origin)
            }
            if board.editing {
                ArrangeBar(board: board, tiles: shown.map { WidgetBoard.frame(of: $0) }, canvas: size)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.9)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : DS.Motion.arrive, value: board.editing)
    }
}

private struct GhostTile: View {
    let ghost: WidgetPlacement
    let radius: Double

    var body: some View {
        let origin = WidgetBoard.origin(column: ghost.column, row: ghost.row)
        let tile = WidgetBoard.tileSize(ghost)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(DS.Ink.accent.opacity(0.16))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Ink.accent.opacity(0.7), lineWidth: 1)
            }
            .frame(width: tile.width, height: tile.height)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
    }
}

/// Hairlines where the dragged widget's edges or centre meet another widget's.
private struct GuideLines: View {
    let guides: AlignmentGuides
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for x in guides.vertical {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in guides.horizontal {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(DS.Ink.accent.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

struct GridDots: View {
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            let grid = WidgetBoard.cells(in: size)
            var path = Path()
            for column in 0..<grid.columns {
                for row in 0..<grid.rows {
                    let origin = WidgetBoard.origin(column: column, row: row)
                    let cell = CGRect(x: origin.x, y: origin.y, width: WidgetBoard.pitch - WidgetBoard.gap, height: WidgetBoard.pitch - WidgetBoard.gap)
                    path.addRoundedRect(in: cell, cornerSize: CGSize(width: 12, height: 12), style: .continuous)
                }
            }
            context.fill(path, with: .color(.white.opacity(0.035)))
        }
        .allowsHitTesting(false)
    }
}

/// Tiles arrive with a short cascade when the board first comes on screen, and simply appear otherwise.
struct Entrance: ViewModifier {
    let order: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.94)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear {
                let fresh = Date().timeIntervalSince(WidgetSession.shared.entrance) < 1.5
                guard fresh, !reduceMotion else { shown = true; return }
                withAnimation(DS.Motion.arrive.delay(0.08 + min(Double(order), 10) * 0.045)) { shown = true }
            }
    }
}

struct BoardTile: View {
    @ObservedObject var board: WidgetBoard
    let placement: WidgetPlacement
    let screen: String
    let fallback: Bool
    let canvas: CGSize
    var order = 0
    /// The canvas's top-left corner in global top-left coordinates, for Icon Harmony.
    var globalOrigin = CGPoint.zero
    @State private var drag = CGSize.zero
    @State private var lifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: WidgetKind { placement.kind }
    private var session: WidgetSession { board.session }

    private func target(for translation: CGSize) -> (column: Int, row: Int) {
        let span = placement.span, grid = WidgetBoard.cells(in: canvas)
        let column = placement.column + Int((translation.width / WidgetBoard.pitch).rounded())
        let row = placement.row + Int((translation.height / WidgetBoard.pitch).rounded())
        return board.slot(span: span, excluding: placement.uid, column: min(max(column, 0), max(grid.columns - span.columns, 0)),
                          row: min(max(row, 0), max(grid.rows - span.rows, 0)), screen: screen, fallback: fallback, size: canvas)
    }

    private var dragging: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { gesture in
                if !lifted { withAnimation(DS.Motion.touch) { lifted = true } }
                // The tile tracks the pointer 1:1. A new grab catches it wherever the spring has it.
                drag = gesture.translation
                let place = target(for: gesture.translation)
                // Only a new cell is news: the ghost and guides change a few times per drag, not every frame.
                guard session.ghost?.column != place.column || session.ghost?.row != place.row || session.ghost?.uid != placement.uid else { return }
                var ghost = placement
                ghost.column = place.column
                ghost.row = place.row
                ghost.screen = screen
                session.ghost = ghost
                session.guides = board.guides(for: ghost, fallback: fallback)
            }
            .onEnded { gesture in
                let place = target(for: gesture.translation)
                let old = WidgetBoard.origin(column: placement.column, row: placement.row)
                let new = WidgetBoard.origin(column: place.column, row: place.row)
                // Swap the base position in one step, leaving the visual spot unchanged, then let the offset spring home.
                board.move(placement.uid, column: place.column, row: place.row, screen: screen)
                drag = CGSize(width: old.x + drag.width - new.x, height: old.y + drag.height - new.y)
                session.ghost = nil
                session.guides = AlignmentGuides()
                session.selection = placement.uid
                withAnimation(reduceMotion ? nil : DS.Motion.settle) {
                    drag = .zero
                    lifted = false
                }
            }
    }

    var body: some View {
        let size = WidgetBoard.tileSize(placement)
        let origin = WidgetBoard.origin(column: placement.column, row: placement.row)
        let style = board.style(for: placement)
        let global = CGRect(x: globalOrigin.x + origin.x, y: globalOrigin.y + origin.y, width: size.width, height: size.height)
        WidgetFace(kind: kind, board: board, size: size, placement: placement)
            .modifier(IconHarmonyLayer(mode: IconHarmony.effective(board.harmony, style: style, above: false),
                                       rect: global, radius: style.radius, active: !board.editing))
            .overlay {
                if board.editing {
                    RoundedRectangle(cornerRadius: style.radius, style: .continuous)
                        .strokeBorder(.white.opacity(lifted ? 0.5 : (style.material == .bare ? 0.3 : 0.22)),
                                      style: StrokeStyle(lineWidth: 1, dash: style.material == .bare ? [5, 4] : []))
                }
            }
            .overlay(alignment: .top) {
                if board.editing && !placement.locked {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(height: kind.gripHeight ?? size.height)
                        .atelierPointer(lifted ? .grabActive : .grabIdle)
                        .gesture(dragging)
                        .simultaneousGesture(TapGesture().onEnded { session.selection = placement.uid })
                        .overlay(alignment: .top) {
                            if kind.gripHeight != nil {
                                Capsule().fill(.white.opacity(0.34)).frame(width: 34, height: 4).padding(.top, 8)
                            }
                        }
                        .accessibilityLabel("Move \(kind.title)")
                }
            }
            .overlay {
                if board.editing {
                    TileChrome(board: board, placement: placement, canvas: canvas, radius: style.radius, lifted: lifted)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .modifier(Wiggle(order: order, active: board.editing && !lifted))
            .scaleEffect(lifted && !reduceMotion ? 1.03 : 1)
            .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: lifted ? 26 : 0, y: lifted ? 16 : 0)
            .modifier(Entrance(order: order))
            .offset(x: origin.x + drag.width, y: origin.y + drag.height)
            .zIndex(lifted ? 1 : 0)
            .animation(reduceMotion ? nil : DS.Motion.arrive, value: placement.size)
            .animation(reduceMotion ? nil : DS.Motion.arrive, value: placement.custom)
            .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.92)))
    }
}

/// A widget in a window of its own: floating above windows, or taking clicks on the desktop.
struct DetachedTile: View {
    @ObservedObject var board: WidgetBoard
    let uid: String
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tile in global top-left coordinates, worked out from the window frame the board gives it.
    private func global(_ placement: WidgetPlacement) -> CGRect {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { WidgetBoard.key(for: $0) == placement.screen }) ?? screens.first,
              let primary = screens.first?.frame else { return .zero }
        let frame = WidgetBoard.detachedFrame(placement, on: screen)
        let tile = WidgetBoard.tileSize(placement)
        return CGRect(x: frame.minX + WidgetBoard.margin, y: primary.maxY - frame.maxY + WidgetBoard.margin, width: tile.width, height: tile.height)
    }

    var body: some View {
        if let placement = board.placements.first(where: { $0.uid == uid }) {
            let size = WidgetBoard.tileSize(placement)
            let clicks = board.takesClicks(placement)
            let lift = clicks && hovering && !reduceMotion
            let style = board.style(for: placement)
            WidgetFace(kind: placement.kind, board: board, size: size, placement: placement)
                .environment(\.widgetInteractive, clicks)
                // Above Finder's icons, so the only way to keep them in sight is to let them show through.
                .modifier(IconHarmonyLayer(mode: IconHarmony.effective(board.harmony, style: style, above: placement.layer == .desktop),
                                           rect: global(placement), radius: style.radius, active: placement.layer == .desktop))
                .scaleEffect(lift ? 1.012 : 1)
                .shadow(color: .black.opacity(lift ? 0.28 : 0), radius: lift ? 16 : 0, y: lift ? 8 : 0)
                .animation(DS.Motion.touch, value: lift)
                .onHover { inside in if clicks { hovering = inside } }
                .modifier(Entrance(order: 0))
                .frame(width: size.width + WidgetBoard.margin * 2, height: size.height + WidgetBoard.margin * 2)
        }
    }
}

// MARK: - Widget faces

/// Colours a face draws with, worked out from its style.
struct WidgetTheme {
    var ink = Color.white
    var accent = DS.Ink.accent
    var light = false
    var size = WidgetSize.medium

    init() {}

    init(style: WidgetStyle, size: WidgetSize) {
        light = style.material.light
        ink = light ? Color(white: 0.08) : .white
        accent = light ? style.accent.deep : style.accent.color
        self.size = size
    }

    var secondary: Color { ink.opacity(light ? 0.6 : 0.62) }
    var tertiary: Color { ink.opacity(light ? 0.42 : 0.38) }
    var track: Color { ink.opacity(light ? 0.1 : 0.13) }
    /// Text that sits on an accent fill.
    var onAccent: Color { light ? .white : .black }
    var small: Bool { size == .small }
}

extension EnvironmentValues {
    @Entry var widgetTheme = WidgetTheme()
    /// True where clicks reach the face: in its own window with Interactive Widgets on.
    @Entry var widgetInteractive = false
}

struct WidgetFace: View {
    static let radius = 26.0
    let kind: WidgetKind
    @ObservedObject var board: WidgetBoard
    let size: CGSize
    /// Which widget of this kind. Nil draws the first one on the board.
    var placement: WidgetPlacement?

    init(kind: WidgetKind, board: WidgetBoard, size: CGSize, placement: WidgetPlacement? = nil) {
        self.kind = kind
        self.board = board
        self.size = size
        self.placement = placement
    }

    private var resolved: WidgetPlacement {
        if let placement, let live = board.placement(placement.uid) { return live }
        return placement ?? board.placements.first { $0.kind == kind }
            ?? WidgetPlacement(kind: kind, column: 0, row: 0, screen: "main", uid: kind.rawValue, options: WidgetBoard.starter(kind))
    }

    var body: some View {
        let placement = resolved
        let style = board.style(for: placement)
        let pad = kind.edgeToEdge ? 0 : style.padding
        let scale = kind.edgeToEdge ? 1 : style.scale
        // Laid out at the size the text scale leaves room for, then scaled to fill the tile.
        let inner = CGSize(width: max((size.width - pad * 2) / scale, 60), height: max((size.height - pad * 2) / scale, 60))
        // Sized by the frame it is given, so a face never overflows its tile.
        let fitted = inner.width < 250 ? WidgetSize.small : placement.size
        let theme = WidgetTheme(style: style, size: fitted)
        WidgetContent(kind: kind, placement: placement, board: board, size: inner)
            .frame(width: inner.width, height: inner.height)
            .scaleEffect(scale)
            .frame(width: size.width, height: size.height)
            .foregroundStyle(theme.ink)
            .fontDesign(style.font.design)
            .environment(\.widgetTheme, theme)
            .modifier(WidgetBackdrop(style: style, ink: theme.ink, photo: kind.edgeToEdge))
            .opacity(style.opacity)
    }
}

/// What a face shows, without its surface. A Smart Stack draws these inside its own.
struct WidgetContent: View {
    let kind: WidgetKind
    let placement: WidgetPlacement
    @ObservedObject var board: WidgetBoard
    let size: CGSize
    @Environment(\.widgetInteractive) private var interactive

    var body: some View {
        switch kind {
        case .calendar: MonthWidget()
        case .notes: NoteWidget(board: board)
        case .rings: RingsWidget()
        case .clocks: ClocksWidget(board: board)
        case .pomodoro: PomodoroWidget(model: board.pomodoro, editing: board.editing || interactive)
        case .activity: ActivityWidget()
        case .network: NetworkWidget()
        case .battery: BatteryWidget()
        case .progress: ProgressWidget()
        case .countdown: CountdownWidget(options: placement.options)
        case .moon: MoonWidget(southern: placement.options.southern ?? false)
        case .sticker: StickerWidget(options: placement.options)
        case .photo: PhotoWidget(options: placement.options, pixels: max(size.width, size.height) * 2)
        case .weather: WeatherWidget(options: placement.options)
        case .events: EventsWidget()
        case .reminders: RemindersWidget()
        case .checklist: ChecklistWidget(board: board, uid: placement.uid, options: placement.options)
        case .habits: HabitsWidget(board: board, uid: placement.uid, options: placement.options)
        case .launcher: LauncherWidget(options: placement.options)
        case .stopwatch: ChronoWidget(model: Chrono.model(placement.uid), options: placement.options)
        case .devices: DevicesWidget()
        case .clipboard: ClipboardWidget()
        case .storage: StorageWidget()
        case .slideshow: SlideshowWidget(options: placement.options, pixels: max(size.width, size.height) * 2)
        case .stack: StackWidget(board: board, placement: placement, size: size)
        case .bigClock: BigClockWidget(options: placement.options.clock ?? ClockOptions(), size: size)
        case .vitals: VitalsWidget(options: placement.options.vitals ?? VitalsOptions(), size: size)
        }
    }
}

/// The surface under a face: Liquid Glass, clear or tinted glass, solid dark, frosted light, a bare outline
/// or nothing at all, with an optional gradient or picture laid in, a blur, a shadow and a rim.
struct WidgetBackdrop: ViewModifier {
    let style: WidgetStyle
    let ink: Color
    var photo = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
        surface(content, shape)
            .background {
                if style.shadow > 0, style.material != .bare { WidgetShadow(shape: shape, depth: style.shadow) }
            }
            .overlay {
                if style.border > 0 { shape.strokeBorder(ink.opacity(0.28), lineWidth: style.border) }
            }
    }

    /// A gradient or picture, laid between the material and the content.
    @ViewBuilder private func fill(_ shape: RoundedRectangle) -> some View {
        if let name = style.image {
            Color.clear
                .overlay {
                    if let image = WidgetPhotos.image(name, pixels: 1400) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                            .blur(radius: style.blur * 26, opaque: true)
                    }
                }
                // A light scrim keeps white text readable on bright pictures.
                .overlay { LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.26)], startPoint: .top, endPoint: .bottom) }
                .clipShape(shape)
        } else if let gradient = style.gradient {
            let points = gradient.points
            shape.fill(LinearGradient(colors: [gradient.from.deep, gradient.to.deep], startPoint: points.start, endPoint: points.end))
                .opacity(style.material == .glass || style.material == .clear || style.material == .tinted ? 0.82 : 1)
        }
    }

    /// Backdrop blur strength, as the system's material steps.
    private var frost: Material? {
        guard style.blur > 0.02, style.image == nil else { return nil }
        switch style.blur {
        case ..<0.2: return .ultraThinMaterial
        case ..<0.4: return .thinMaterial
        case ..<0.6: return .regularMaterial
        case ..<0.8: return .thickMaterial
        default: return .ultraThickMaterial
        }
    }

    @ViewBuilder private func surface(_ content: Content, _ shape: RoundedRectangle) -> some View {
        if photo {
            // A photo is its own surface. Glass would only frost it.
            content
                .clipShape(shape)
                .overlay { shape.strokeBorder(.white.opacity(style.material == .outline ? 0.5 : 0.12), lineWidth: style.material == .outline ? 1.2 : 0.5) }
        } else {
            let filled = content.background { fill(shape) }
            switch style.material {
            case .glass:
                filled.atelierGlass(.regular, in: shape).background { if let frost { shape.fill(frost) } }
            case .clear:
                filled.atelierGlass(.clear, in: shape).background { if let frost { shape.fill(frost) } }
            case .tinted:
                filled.atelierGlass(.regular.tint(style.tint.color.opacity(0.3)), in: shape).background { if let frost { shape.fill(frost) } }
            case .dark:
                filled
                    .background(Color(white: 0.075).opacity(0.94), in: shape)
                    .overlay { shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5) }
            case .frosted:
                filled
                    .background(Color.white.opacity(0.62), in: shape)
                    .atelierGlass(.regular, in: shape)
                    .background { if let frost { shape.fill(frost) } }
            case .outline:
                filled
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .overlay { shape.strokeBorder(ink.opacity(0.42), lineWidth: 1.2) }
                    .contentShape(shape)
            case .bare:
                // Straight on the wallpaper. The shadow, if any, falls from the content itself.
                if style.shadow > 0 {
                    filled.shadow(color: .black.opacity(0.2 + 0.4 * style.shadow), radius: 3 + 18 * style.shadow, y: 1 + 6 * style.shadow)
                        .contentShape(shape)
                } else {
                    filled.contentShape(shape)
                }
            }
        }
    }
}

/// A soft drop shadow that stays outside the shape, so it never darkens glass from behind.
private struct WidgetShadow: View {
    let shape: RoundedRectangle
    let depth: Double

    var body: some View {
        shape.fill(.black)
            .shadow(color: .black.opacity(0.22 + 0.3 * depth), radius: 6 + 20 * depth, y: 3 + 10 * depth)
            .mask {
                Rectangle().padding(-60)
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

private let english = Locale(identifier: "en_GB")

struct MonthWidget: View {
    @Environment(\.widgetTheme) private var theme

    private func month(_ date: Date) -> (title: String, year: String, heads: [String], cells: [Int?], today: Int, weekend: Set<Int>) {
        var calendar = Calendar.current
        let first = calendar.firstWeekday
        calendar.locale = english
        calendar.firstWeekday = first
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let start = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: 1)) ?? date
        let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let lead = (calendar.component(.weekday, from: start) - first + 7) % 7
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let heads = (0..<7).map { symbols[(first - 1 + $0) % 7] }
        let weekend = Set((0..<7).filter { [1, 7].contains((first - 1 + $0) % 7 + 1) })
        let cells: [Int?] = Array(repeating: nil, count: lead) + (1...days).map { Optional($0) }
        return (date.formatted(.dateTime.month(.wide).locale(english)), date.formatted(.dateTime.year().locale(english)), heads, cells, parts.day ?? 1, weekend)
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            if theme.small { today(context.date) } else { grid(context.date) }
        }
    }

    private func today(_ date: Date) -> some View {
        var calendar = Calendar.current
        calendar.locale = english
        let week = calendar.component(.weekOfYear, from: date)
        return VStack(alignment: .leading, spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.wide).locale(english)).uppercased())
                .font(.system(size: 12, weight: .semibold)).tracking(0.8).foregroundStyle(theme.accent)
            Text(date.formatted(.dateTime.day().locale(english)))
                .font(.system(size: 76, weight: .semibold)).tracking(-3).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
            Spacer(minLength: 0)
            Text(date.formatted(.dateTime.month(.wide).year().locale(english)))
                .font(.system(size: 13, weight: .medium))
            Text("Week \(week)").font(DS.caption).foregroundStyle(theme.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func grid(_ date: Date) -> some View {
        let info = month(date)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(info.title).font(.system(size: 21, weight: .semibold)).tracking(-0.5)
                Text(info.year).font(.system(size: 13, weight: .regular)).foregroundStyle(theme.tertiary)
            }
            Grid(horizontalSpacing: 0, verticalSpacing: 3) {
                GridRow {
                    ForEach(0..<7, id: \.self) { index in
                        Text(info.heads[index]).font(DS.eyebrow)
                            .foregroundStyle(theme.tertiary).frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<6, id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { index in
                            let position = week * 7 + index
                            let day = position < info.cells.count ? info.cells[position] : nil
                            dayCell(day, today: day == info.today, weekend: info.weekend.contains(index))
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func dayCell(_ day: Int?, today: Bool, weekend: Bool) -> some View {
        ZStack {
            if today { Circle().fill(theme.accent).frame(width: 30, height: 30) }
            if let day {
                Text("\(day)")
                    .font(.system(size: 13, weight: today ? .bold : .medium)).monospacedDigit()
                    .foregroundStyle(today ? theme.onAccent : weekend ? theme.tertiary : theme.ink)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32)
    }
}

struct NoteWidget: View {
    @ObservedObject var board: WidgetBoard
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        Group {
            if board.editing {
                TextEditor(text: $board.note)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .accessibilityLabel("Note")
            } else if board.note.isEmpty {
                Text("An empty note. Arrange Widgets to write here.")
                    .foregroundStyle(theme.tertiary)
                    .padding(.horizontal, 5)
            } else {
                Text(board.note).padding(.horizontal, 5)
            }
        }
        .font(.system(size: theme.small ? 14 : 16, weight: .medium))
        .lineSpacing(3)
        .padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RingsWidget: View {
    @ObservedObject private var activity = ActivityMeter.shared
    @ObservedObject private var disk = DiskMeter.shared
    @ObservedObject private var power = BatteryMeter.shared
    @Environment(\.widgetTheme) private var theme

    private var rings: [(String, Double, Color)] {
        var list: [(String, Double, Color)] = [
            ("CPU", activity.cpu, theme.accent),
            ("Memory", activity.memory, Color(red: 0.72, green: 0.52, blue: 1)),
            ("Disk", disk.used, Color(red: 0.36, green: 0.86, blue: 0.8)),
        ]
        if power.state.hasBattery { list.append(("Battery", power.state.level, Color(red: 0.5, green: 0.9, blue: 0.5))) }
        return list
    }

    var body: some View {
        Group {
            if theme.small {
                let list = rings
                Grid(horizontalSpacing: 6, verticalSpacing: 10) {
                    GridRow { ForEach(0..<min(2, list.count), id: \.self) { ring(list[$0], 52) } }
                    GridRow { ForEach(2..<list.count, id: \.self) { ring(list[$0], 52) } }
                }
                .padding(12)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(rings.enumerated()), id: \.offset) { _, item in ring(item, 68) }
                }
                .padding(.horizontal, 12)
            }
        }
        .metered(ActivityMeter.shared.ticker)
        .metered(DiskMeter.shared.ticker)
        .metered(BatteryMeter.shared.ticker)
    }

    private func ring(_ item: (String, Double, Color), _ diameter: Double) -> some View {
        MiniRing(title: item.0, value: item.1, tint: item.2, diameter: diameter)
    }
}

struct MiniRing: View {
    let title: String
    let value: Double
    let tint: Color
    var diameter = 68.0
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        let line = diameter > 60 ? 7.0 : 5.5
        VStack(spacing: diameter > 60 ? 11 : 6) {
            ZStack {
                Circle().stroke(theme.track, lineWidth: line)
                Circle().trim(from: 0, to: shown)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: diameter > 60 ? 14 : 12, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: diameter, height: diameter)
            Text(title).font(.system(size: diameter > 60 ? 11.5 : 10.5)).foregroundStyle(theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if reduceMotion { shown = value } else { withAnimation(.spring(response: 1.1, dampingFraction: 1)) { shown = value } }
        }
        .onChange(of: value) { _, new in
            if reduceMotion { shown = new } else { withAnimation(DS.Motion.arrive) { shown = new } }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ClocksWidget: View {
    @ObservedObject var board: WidgetBoard
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        TimelineView(.everyMinute) { context in
            if theme.small, let city = board.cities.first {
                VStack(spacing: 10) {
                    CityDial(city: city, date: context.date, diameter: 112, showsName: false)
                    VStack(spacing: 1) {
                        Text(city.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: english, timeZone: city.timeZone)))
                            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(theme.tertiary)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(board.cities.prefix(4)) { city in
                        CityDial(city: city, date: context.date).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }
}

struct CityDial: View {
    let city: WorldCity
    let date: Date
    var diameter = 68.0
    var showsName = true
    @Environment(\.widgetTheme) private var theme

    private var local: (hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = city.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0, parts.minute ?? 0)
    }

    private var difference: String {
        let hours = Double(city.timeZone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)) / 3600
        if hours == 0 { return "Here" }
        let text = hours.formatted(.number.precision(.fractionLength(0...1)).locale(english))
        return hours > 0 ? "+\(text)h" : "\(text)h".replacingOccurrences(of: "-", with: "−")
    }

    var body: some View {
        let time = local
        let day = (7..<19).contains(time.hour)
        let face = day ? Color.white.opacity(0.92) : Color.black.opacity(theme.light ? 0.78 : 0.32)
        let ink = day ? Color.black : Color.white
        let k = diameter / 68
        VStack(spacing: 9) {
            ZStack {
                Circle().fill(face)
                Circle().strokeBorder(theme.light && day ? .black.opacity(0.12) : .white.opacity(day ? 0 : 0.14), lineWidth: 0.5)
                ForEach(0..<12, id: \.self) { index in
                    Capsule().fill(ink.opacity(index % 3 == 0 ? 0.65 : 0.25))
                        .frame(width: 1.5 * k, height: (index % 3 == 0 ? 6 : 3.5) * k)
                        .offset(y: (-34 + (index % 3 == 0 ? 3 : 1.75) + 3) * k)
                        .rotationEffect(.degrees(Double(index) * 30))
                }
                hand(width: 3 * k, length: 19 * k, ink: ink, degrees: (Double(time.hour % 12) + Double(time.minute) / 60) * 30)
                hand(width: 2.2 * k, length: 27 * k, ink: ink, degrees: Double(time.minute) * 6)
                Circle().fill(theme.accent).frame(width: 5 * k, height: 5 * k)
            }
            .frame(width: diameter, height: diameter)
            if showsName {
                VStack(spacing: 1) {
                    Text(city.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(difference).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(theme.tertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(city.name), \(time.hour):\(String(format: "%02d", time.minute))")
    }

    private func hand(width: Double, length: Double, ink: Color, degrees: Double) -> some View {
        Capsule().fill(ink).frame(width: width, height: length)
            .offset(y: -length / 2 + 2)
            .rotationEffect(.degrees(degrees))
    }
}

struct PomodoroWidget: View {
    @ObservedObject var model: Pomodoro
    /// Shows the controls: while arranging, or when clicks reach the widget.
    let editing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(theme.track, lineWidth: 8)
                Circle().trim(from: 0, to: model.progress)
                    .stroke(model.phase == .focus ? theme.accent : Color(red: 0.5, green: 0.9, blue: 0.6),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : DS.Motion.arrive, value: model.progress)
                Text(Duration.seconds(max(model.remaining.rounded(.up), 0)), format: .time(pattern: .minuteSecond))
                    .font(.system(size: 25, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
            .frame(width: 112, height: 112)
            if editing {
                HStack(spacing: 8) {
                    PomodoroButton(symbol: model.running ? "pause.fill" : "play.fill", label: model.running ? "Pause" : "Start", action: model.toggle)
                    PomodoroButton(symbol: "arrow.counterclockwise", label: "Reset", action: model.reset)
                }
            } else {
                Text(model.phase.title).font(DS.caption).foregroundStyle(theme.secondary)
                    .contentTransition(.opacity)
            }
        }
        .padding(.top, 8)
    }
}

struct PomodoroButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Ink.primary)
                .frame(width: 42, height: 26)
                .background(DS.Ink.fillStrong, in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.93))
        .accessibilityLabel(label)
    }
}
