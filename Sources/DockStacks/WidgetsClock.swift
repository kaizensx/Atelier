import AppKit
import SwiftUI

private let english = Locale(identifier: "en_GB")

// MARK: - Big Clock options

enum ClockFace: String, Codable, CaseIterable, Identifiable {
    /// The old Desktop Clock, exactly: a thin, huge time under a small date, straight on the wallpaper.
    case desktop
    case thin, bold, rounded, serif, mono, words, analog, flip, stacked, dot
    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .thin: "Thin"
        case .bold: "Bold"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .mono: "Mono"
        case .words: "Word Clock"
        case .analog: "Analog"
        case .flip: "Flip"
        case .stacked: "Stacked"
        case .dot: "Minimal Dot"
        }
    }

    var digital: Bool { self != .analog && self != .words }

    var weight: ClockWeight {
        switch self {
        case .desktop, .thin: .thin
        case .bold: .heavy
        case .rounded: .semibold
        case .serif: .regular
        case .mono: .light
        case .words: .semibold
        case .analog: .medium
        case .flip: .semibold
        case .stacked: .bold
        case .dot: .medium
        }
    }

    var design: Font.Design {
        switch self {
        case .rounded, .flip: .rounded
        case .serif: .serif
        case .mono: .monospaced
        default: .default
        }
    }

    /// Letter spacing, as a share of the font size.
    var tracking: Double {
        switch self {
        case .desktop: -5.0 / 148
        case .thin: -0.035
        case .bold, .stacked: -0.045
        case .mono: -0.06
        case .words: -0.03
        default: -0.02
        }
    }

    /// The face the old Desktop Clock style maps to.
    init(_ old: ClockStyle) {
        switch old {
        // The old default face comes back as itself, not as its nearest new relative.
        case .thin: self = .desktop
        case .bold: self = .bold
        case .mono: self = .mono
        case .words: self = .words
        }
    }

    /// The old Desktop Clock style closest to this face, for the old Effects controls.
    var legacy: ClockStyle {
        switch self {
        case .desktop: .thin
        case .bold, .stacked: .bold
        case .mono: .mono
        case .words: .words
        default: .thin
        }
    }
}

enum DialStyle: String, Codable, CaseIterable, Identifiable {
    case classic, minimal, numerals, roman, dots, railway, sport, plain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "Classic"
        case .minimal: "Minimal"
        case .numerals: "Numerals"
        case .roman: "Roman"
        case .dots: "Dots"
        case .railway: "Railway"
        case .sport: "Sport"
        case .plain: "Plain"
        }
    }
}

enum ClockDate: String, Codable, CaseIterable, Identifiable {
    case none, dayMonth, full, short, numeric, iso
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .dayMonth: "8 November"
        case .full: "8 November 2026"
        case .short: "8 Nov"
        case .numeric: "08/11/2026"
        case .iso: "2026-11-08"
        }
    }
}

enum ClockWeight: String, Codable, CaseIterable, Identifiable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ultraLight: "Ultralight"
        case .semibold: "Semibold"
        default: rawValue.capitalized
        }
    }
    var font: Font.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
    /// For the slider in Settings.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 4 }
}

enum ClockWidth: String, Codable, CaseIterable, Identifiable {
    case compressed, condensed, standard, expanded
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var font: Font.Width {
        switch self {
        case .compressed: .compressed
        case .condensed: .condensed
        case .standard: .standard
        case .expanded: .expanded
        }
    }
}

enum ClockAlign: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leading: "Left"
        case .center: "Centre"
        case .trailing: "Right"
        }
    }
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Everything a Big Clock shows and how. Every field decodes on its own, so a clock saved by another build still opens.
struct ClockOptions: Codable, Equatable {
    /// New clocks start as the old Desktop Clock looked.
    var face = ClockFace.desktop
    var dial = DialStyle.classic
    /// Nil follows the Mac's own 12 or 24 hour setting.
    var hour24: Bool?
    var seconds = false
    /// Analog only: the seconds hand sweeps instead of ticking.
    var sweep = false
    var date = ClockDate.dayMonth
    var weekday = true
    var dateAbove = true
    /// Nil is the widget's ink, white on most surfaces.
    var color: WidgetTint?
    /// A second colour turns the fill into a gradient.
    var gradient: WidgetTint?
    /// 0 to 1.
    var glow = 0.0
    /// 0 to 1, a soft drop shadow under the digits.
    var shadow = 0.35
    /// Nil uses the face's own weight.
    var weight: ClockWeight?
    var width = ClockWidth.standard
    var align = ClockAlign.leading
    /// A time zone identifier. Nil is this Mac's.
    var zone: String?
    /// Analog only: a disc behind the hands.
    var dialFill = true

    init() {}

    init(legacy style: ClockStyle) {
        face = ClockFace(style)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = ClockOptions()
        face = (try? c.decodeIfPresent(ClockFace.self, forKey: .face)) ?? base.face
        dial = (try? c.decodeIfPresent(DialStyle.self, forKey: .dial)) ?? base.dial
        hour24 = try? c.decodeIfPresent(Bool.self, forKey: .hour24)
        seconds = (try? c.decodeIfPresent(Bool.self, forKey: .seconds)) ?? base.seconds
        sweep = (try? c.decodeIfPresent(Bool.self, forKey: .sweep)) ?? base.sweep
        date = (try? c.decodeIfPresent(ClockDate.self, forKey: .date)) ?? base.date
        weekday = (try? c.decodeIfPresent(Bool.self, forKey: .weekday)) ?? base.weekday
        dateAbove = (try? c.decodeIfPresent(Bool.self, forKey: .dateAbove)) ?? base.dateAbove
        color = try? c.decodeIfPresent(WidgetTint.self, forKey: .color)
        gradient = try? c.decodeIfPresent(WidgetTint.self, forKey: .gradient)
        glow = min(max((try? c.decodeIfPresent(Double.self, forKey: .glow)) ?? base.glow, 0), 1)
        shadow = min(max((try? c.decodeIfPresent(Double.self, forKey: .shadow)) ?? base.shadow, 0), 1)
        weight = try? c.decodeIfPresent(ClockWeight.self, forKey: .weight)
        width = (try? c.decodeIfPresent(ClockWidth.self, forKey: .width)) ?? base.width
        align = (try? c.decodeIfPresent(ClockAlign.self, forKey: .align)) ?? base.align
        zone = (try? c.decodeIfPresent(String.self, forKey: .zone)).flatMap { $0 }.flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }
        dialFill = (try? c.decodeIfPresent(Bool.self, forKey: .dialFill)) ?? base.dialFill
    }

    var timeZone: TimeZone { zone.flatMap(TimeZone.init(identifier:)) ?? .current }

    /// Whether this clock reads in 24 hours, its own choice or the Mac's.
    var uses24: Bool { hour24 ?? ClockOptions.system24 }

    static var system24: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    /// A city name for the zone, when it is not this Mac's.
    var place: String? {
        guard let zone, zone != TimeZone.current.identifier else { return nil }
        if let city = WorldCity.catalog.first(where: { $0.zone == zone }) { return city.name }
        return zone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
    }
}

// MARK: - Reading the time

/// The parts of a moment a clock face draws, in the clock's own zone.
struct ClockReading: Equatable {
    var hour: Int
    var minute: Int
    var second: Int
    /// Seconds since the reference date, shifted into the zone. Hands turn from this, so they never run backwards at midnight.
    var local: Double
    var date: Date

    init(_ date: Date, zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        hour = parts.hour ?? 0
        minute = parts.minute ?? 0
        second = parts.second ?? 0
        local = date.timeIntervalSinceReferenceDate.rounded(.down) + Double(zone.secondsFromGMT(for: date))
        self.date = date
    }

    func hourText(_ uses24: Bool, padded: Bool) -> String {
        let value = uses24 ? hour : (hour % 12 == 0 ? 12 : hour % 12)
        return padded || uses24 ? String(format: "%02d", value) : "\(value)"
    }

    var minuteText: String { String(format: "%02d", minute) }
    var secondText: String { String(format: "%02d", second) }
    var meridiem: String { hour < 12 ? "AM" : "PM" }

    func dateText(_ options: ClockOptions) -> String? {
        let zone = options.timeZone
        let weekday: Date.FormatStyle.Symbol.Weekday = options.date == .short || options.date == .numeric || options.date == .iso ? .abbreviated : .wide
        var style = Date.FormatStyle(locale: english, timeZone: zone)
        switch options.date {
        case .none:
            guard options.weekday else { return nil }
            return date.formatted(style.weekday(.wide))
        case .dayMonth: style = style.day().month(.wide)
        case .full: style = style.day().month(.wide).year()
        case .short: style = style.day().month(.abbreviated)
        case .numeric: style = style.day(.twoDigits).month(.twoDigits).year()
        case .iso:
            let text = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).timeZone(separator: .omitted))
            let iso = String(text.prefix(10))
            return options.weekday ? date.formatted(Date.FormatStyle(locale: english, timeZone: zone).weekday(.abbreviated)) + " " + iso : iso
        }
        let body = date.formatted(style)
        guard options.weekday else { return body }
        return date.formatted(Date.FormatStyle(locale: english, timeZone: zone).weekday(weekday)) + " " + body
    }

    /// Five-minute words, in the clock's zone.
    var words: String {
        let rounded = Int((Double(minute) / 5).rounded()) * 5
        let names = ["twelve", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven"]
        func name(_ h: Int) -> String { names[((h % 12) + 12) % 12] }
        let numbers = [5: "five", 10: "ten", 20: "twenty", 25: "twenty five"]
        switch rounded {
        case 0: return "\(name(hour)) o’clock"
        case 60: return "\(name(hour + 1)) o’clock"
        case 15: return "quarter past \(name(hour))"
        case 30: return "half past \(name(hour))"
        case 45: return "quarter to \(name(hour + 1))"
        case 5, 10, 20, 25: return "\(numbers[rounded] ?? "") past \(name(hour))"
        default: return "\(numbers[60 - rounded] ?? "") to \(name(hour + 1))"
        }
    }
}

// MARK: - Big Clock

struct BigClockWidget: View {
    let options: ClockOptions
    let size: CGSize

    private static var minuteStart: Date { Calendar.current.dateInterval(of: .minute, for: Date())?.start ?? Date() }

    var body: some View {
        // Once a second only when something on the face changes that often.
        // Lined up on the minute, so the digits change on the second the menu bar clock does.
        TimelineView(.periodic(from: Self.minuteStart, by: options.seconds ? 1 : 60)) { context in
            BigClockFace(options: options, size: size, reading: ClockReading(context.date, zone: options.timeZone))
        }
    }
}

/// One moment of a Big Clock. Separate from the timeline, so the static parts of a dial are not rebuilt each tick.
struct BigClockFace: View {
    let options: ClockOptions
    let size: CGSize
    let reading: ClockReading
    @Environment(\.widgetTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ink: AnyShapeStyle {
        let base = options.color.map { theme.light ? $0.deep : $0.color } ?? theme.ink
        if let second = options.gradient {
            return AnyShapeStyle(LinearGradient(colors: [base, theme.light ? second.deep : second.color], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(base)
    }

    private var glowColor: Color { (options.color ?? options.gradient).map(\.color) ?? .white }
    private var weight: Font.Weight { (options.weight ?? options.face.weight).font }
    private var dateText: String? { reading.dateText(options) }

    var body: some View {
        if options.face == .desktop {
            // The Desktop face carries the old clock's own shadow, scaled with it.
            content
                .shadow(color: glowColor.opacity(options.glow * 0.85), radius: 4 + 26 * options.glow)
                .frame(width: size.width, height: size.height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibility)
        } else {
            content
                .foregroundStyle(ink)
                .shadow(color: glowColor.opacity(options.glow * 0.85), radius: 4 + 26 * options.glow)
                .shadow(color: .black.opacity(options.shadow * 0.55), radius: 2 + 22 * options.shadow, y: 1 + 8 * options.shadow)
                .frame(width: size.width, height: size.height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibility)
        }
    }

    private var accessibility: String {
        let time = reading.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: english, timeZone: options.timeZone))
        return [options.place, time, dateText].compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder private var content: some View {
        switch options.face {
        case .desktop: desktop
        case .analog: analog
        case .words: words
        case .flip: flip
        case .stacked: stacked
        default: digital
        }
    }

    // MARK: Pieces

    private var inset: Double { min(size.width, size.height) * 0.08 + 6 }

    private func caption(_ fontSize: Double) -> some View {
        let text = [options.place, dateText].compactMap { $0 }.joined(separator: " · ")
        return Text(text)
            .font(.system(size: fontSize, weight: .medium, design: options.face.design == .monospaced ? .monospaced : .default))
            .opacity(0.82)
            .lineLimit(1).minimumScaleFactor(0.4)
    }

    private var hasCaption: Bool { dateText != nil || options.place != nil }

    /// The caption shares the tile with the time: a fifth of the height, never smaller than reads.
    private var captionSize: Double { min(max(size.height * 0.11, 11), 44) }

    private func stack<Time: View>(@ViewBuilder time: () -> Time) -> some View {
        VStack(alignment: options.align.horizontal, spacing: captionSize * 0.1) {
            if hasCaption && options.dateAbove { caption(captionSize) }
            time()
            if hasCaption && !options.dateAbove { caption(captionSize) }
        }
        .multilineTextAlignment(options.align.text)
        .padding(inset)
        .frame(width: size.width, height: size.height, alignment: options.align.frame)
    }

    private func clockFont(_ points: Double) -> Font {
        .system(size: points, weight: weight, design: options.face.design).width(options.width.font)
    }

    private var timeHeight: Double {
        let room = size.height - inset * 2 - (hasCaption ? captionSize * 1.35 : 0)
        return max(room, 12)
    }

    private var digital: some View {
        let points = timeHeight * 1.18
        let hour = reading.hourText(options.uses24, padded: options.face == .mono)
        let small = clockFont(points * 0.42)
        let separator: Text = options.face == .dot
            ? Text("\u{2009}•\u{2009}").foregroundStyle(theme.accent).font(clockFont(points * 0.6))
            : Text(":")
        let main = Text("\(Text(hour))\(separator)\(Text(reading.minuteText))")
        let tail: Text? = {
            var parts: [Text] = []
            if options.seconds { parts.append(Text(" " + reading.secondText).font(small).foregroundStyle(.secondary)) }
            if !options.uses24 && options.face != .dot { parts.append(Text(" " + reading.meridiem).font(clockFont(points * 0.26))) }
            guard !parts.isEmpty else { return nil }
            return parts.dropFirst().reduce(parts[0]) { Text("\($0)\($1)") }
        }()
        let line = tail.map { Text("\(main)\($0)") } ?? main
        return stack {
            line
                .font(clockFont(points))
                .tracking(points * options.face.tracking)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.05)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: reading.minute)
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: reading.second)
                .frame(maxWidth: .infinity, maxHeight: timeHeight, alignment: options.align.frame)
        }
    }

    /// The old Desktop Clock's own measurements: a 22 point date, 6 points into a 148 point time,
    /// white at 80 and 92 percent, under a 24 point shadow. Drawn at those sizes and scaled to the tile.
    private static let desktopNatural: CGSize = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 148, weight: .thin)
        let width = ("88:88" as NSString).size(withAttributes: [.font: font, .kern: -5]).width
        return CGSize(width: width + 16, height: 196)
    }()

    private var desktopDate: String? {
        // The old clock's own words, in this Mac's language: "Saturday, November 8".
        if options.date == .dayMonth && options.weekday && options.place == nil {
            return reading.date.formatted(Date.FormatStyle(timeZone: options.timeZone).weekday(.wide).month(.wide).day())
        }
        return [options.place, dateText].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    private var desktop: some View {
        let natural = Self.desktopNatural
        let k = max(min(size.width / natural.width, size.height / natural.height), 0.05)
        let hour = reading.hourText(options.uses24, padded: true)
        let custom = options.color != nil || options.gradient != nil
        let date = desktopDate.map { text in
            Text(text)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(custom ? ink : AnyShapeStyle(Color.white.opacity(0.8)))
                .padding(.leading, 8)
        }
        let anchor: UnitPoint = options.align == .center ? .bottom : options.align == .trailing ? .bottomTrailing : .bottomLeading
        return VStack(alignment: options.align.horizontal, spacing: -6) {
            if options.dateAbove { date }
            Text("\(hour):\(reading.minuteText)\(options.seconds ? ":" + reading.secondText : "")")
                .font(.system(size: 148, weight: weight).width(options.width.font))
                .tracking(-5)
                .monospacedDigit()
                .foregroundStyle(custom ? ink : AnyShapeStyle(Color.white.opacity(0.92)))
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: reading.minute)
            if !options.dateAbove { date }
        }
        .lineLimit(1)
        .fixedSize()
        .shadow(color: .black.opacity(options.shadow), radius: 24, y: 8)
        .scaleEffect(k, anchor: anchor)
        .frame(width: size.width, height: size.height, alignment: Alignment(horizontal: options.align.frame.horizontal, vertical: .bottom))
    }

    private var stacked: some View {
        let line = timeHeight / 2 * 1.16
        let hour = reading.hourText(options.uses24, padded: true)
        return stack {
            VStack(alignment: options.align.horizontal, spacing: -line * 0.2) {
                Text(hour)
                Text(reading.minuteText).opacity(0.72)
                if options.seconds {
                    Text(reading.secondText).font(clockFont(line * 0.36)).opacity(0.5).padding(.top, line * 0.12)
                }
            }
            .font(clockFont(line))
            .tracking(line * options.face.tracking)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.05)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: reading.minute)
            .frame(maxWidth: .infinity, maxHeight: timeHeight, alignment: options.align.frame)
        }
    }

    private var words: some View {
        let lines = reading.words.split(separator: " ").count > 2 ? 3 : 2
        let points = timeHeight / Double(lines) * 1.05
        return stack {
            Text(reading.words.capitalized)
                .font(clockFont(points))
                .tracking(points * options.face.tracking)
                .lineSpacing(-points * 0.08)
                .lineLimit(3)
                .minimumScaleFactor(0.05)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: reading.words)
                .frame(maxWidth: .infinity, maxHeight: timeHeight, alignment: options.align.frame)
        }
    }

    private var flip: some View {
        let hour = reading.hourText(options.uses24, padded: true)
        let digits = Array(hour + reading.minuteText + (options.seconds ? reading.secondText : ""))
        let groups = options.seconds ? 3 : 2
        let room = size.width - inset * 2
        // Cards keep a 0.68 aspect, as large as the height and width allow.
        let gaps = Double(digits.count - 1) * 0.06 + Double(groups - 1) * 0.22
        let byWidth = room / (Double(digits.count) * 0.68 + gaps * 0.68)
        let cardHeight = min(timeHeight, byWidth)
        let card = CGSize(width: cardHeight * 0.68, height: cardHeight)
        return stack {
            HStack(spacing: card.width * 0.06) {
                ForEach(Array(digits.enumerated()), id: \.offset) { index, digit in
                    FlipCard(digit: String(digit), size: card, ink: ink, light: theme.light)
                    if index % 2 == 1 && index < digits.count - 1 {
                        Spacer().frame(width: card.width * 0.16)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: options.align.frame)
        }
    }

    private var analog: some View {
        let captionRoom = hasCaption ? captionSize * 1.6 : 0
        let diameter = max(min(size.width - inset * 2, size.height - inset * 2 - captionRoom), 20)
        return VStack(spacing: captionSize * 0.35) {
            if hasCaption && options.dateAbove { caption(captionSize) }
            ZStack {
                DialFace(style: options.dial, fill: options.dialFill, light: theme.light, accent: theme.accent, diameter: diameter)
                AnalogHands(reading: reading, seconds: options.seconds, sweep: options.sweep, dial: options.dial,
                            accent: theme.accent, ink: ink, diameter: diameter)
            }
            .frame(width: diameter, height: diameter)
            if hasCaption && !options.dateAbove { caption(captionSize) }
        }
        .frame(width: size.width, height: size.height, alignment: options.align.frame)
        .padding(.horizontal, options.align == .center ? 0 : inset)
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Flip cards

/// A split-flap card. A change folds the old top half down over the new one, at display refresh, for under half a second.
struct FlipCard: View {
    let digit: String
    let size: CGSize
    let ink: AnyShapeStyle
    let light: Bool
    @State private var current: String
    @State private var previous: String
    @State private var progress = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(digit: String, size: CGSize, ink: AnyShapeStyle, light: Bool) {
        self.digit = digit
        self.size = size
        self.ink = ink
        self.light = light
        _current = State(initialValue: digit)
        _previous = State(initialValue: digit)
    }

    var body: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .modifier(FlipFold(progress: progress, current: current, previous: previous, size: size, ink: ink, light: light))
            .onChange(of: digit) { old, new in
                previous = current
                current = new
                if reduceMotion {
                    progress = 1
                } else {
                    progress = 0
                    withAnimation(.easeIn(duration: 0.42)) { progress = 1 }
                }
            }
    }
}

/// Animatable, so only the card being turned redraws while it turns.
private struct FlipFold: ViewModifier, @MainActor Animatable {
    var progress: Double
    let current: String
    let previous: String
    let size: CGSize
    let ink: AnyShapeStyle
    let light: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private func half(_ digit: String, top: Bool) -> some View {
        let radius = size.width * 0.12
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(light ? Color.white.opacity(0.9) : Color(white: 0.11).opacity(0.92))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(light ? 0 : 0.07), .clear], startPoint: .top, endPoint: .center))
            Text(digit)
                .font(.system(size: size.height * 0.8, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ink)
        }
        .frame(width: size.width, height: size.height)
        .frame(width: size.width, height: size.height / 2, alignment: top ? .top : .bottom)
        .clipped()
    }

    func body(content: Content) -> some View {
        let gap = max(size.height * 0.008, 0.75)
        VStack(spacing: gap) {
            ZStack {
                half(current, top: true)
                if progress < 0.5 {
                    half(previous, top: true)
                        .rotation3DEffect(.degrees(-180 * progress), axis: (1, 0, 0), anchor: .bottom, perspective: 0.45)
                        .brightness(-0.25 * progress)
                }
            }
            ZStack {
                half(progress < 0.5 ? previous : current, top: false)
                if progress >= 0.5 {
                    half(current, top: false)
                        .rotation3DEffect(.degrees(180 * (1 - progress)), axis: (1, 0, 0), anchor: .top, perspective: 0.45)
                        .brightness(-0.2 * (1 - progress))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.25), radius: size.height * 0.04, y: size.height * 0.02)
    }
}

// MARK: - Analog

/// The still part of a dial: markers, numerals, the disc. It takes no time, so it is drawn once and kept.
struct DialFace: View, Equatable {
    let style: DialStyle
    let fill: Bool
    let light: Bool
    let accent: Color
    let diameter: Double

    nonisolated static func == (a: DialFace, b: DialFace) -> Bool {
        a.style == b.style && a.fill == b.fill && a.light == b.light && a.diameter == b.diameter && a.accent == b.accent
    }

    private var ink: Color { light ? Color(white: 0.08) : .white }

    var body: some View {
        let r = diameter / 2
        ZStack {
            if fill {
                Circle().fill(light ? Color.white.opacity(0.55) : Color.black.opacity(0.28))
                Circle().strokeBorder(ink.opacity(0.14), lineWidth: max(diameter * 0.006, 0.5))
            }
            if style == .sport {
                Circle().strokeBorder(accent.opacity(0.9), lineWidth: diameter * 0.035).padding(diameter * 0.01)
            }
            Canvas { context, canvas in
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                func point(_ angle: Double, _ radius: Double) -> CGPoint {
                    CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                }
                func tick(_ index: Int, of count: Int, from outer: Double, length: Double, width: Double, color: Color) {
                    let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
                    var path = Path()
                    path.move(to: point(angle, outer))
                    path.addLine(to: point(angle, outer - length))
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
                let edge = r * (style == .sport ? 0.86 : 0.92)
                switch style {
                case .classic, .numerals, .roman:
                    for i in 0..<60 where i % 5 != 0 {
                        tick(i, of: 60, from: edge, length: r * 0.04, width: max(r * 0.012, 0.5), color: ink.opacity(0.35))
                    }
                    for i in 0..<12 {
                        tick(i, of: 12, from: edge, length: r * (style == .classic ? 0.12 : 0.07), width: max(r * 0.03, 1),
                             color: ink.opacity(style == .classic ? 0.85 : 0.6))
                    }
                case .minimal:
                    tick(0, of: 12, from: edge, length: r * 0.14, width: max(r * 0.04, 1.2), color: accent)
                    for i in [3, 6, 9] { tick(i, of: 12, from: edge, length: r * 0.08, width: max(r * 0.03, 1), color: ink.opacity(0.55)) }
                case .dots:
                    for i in 0..<60 {
                        let angle = Double(i) / 60 * 2 * .pi - .pi / 2
                        let big = i % 5 == 0
                        let dot = r * (big ? 0.045 : 0.018)
                        let c = point(angle, edge - r * 0.04)
                        context.fill(Path(ellipseIn: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)),
                                     with: .color(ink.opacity(big ? 0.85 : 0.35)))
                    }
                case .railway:
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - edge, y: center.y - edge, width: edge * 2, height: edge * 2)),
                                   with: .color(ink.opacity(0.5)), lineWidth: max(r * 0.01, 0.5))
                    let inner = edge - r * 0.07
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)),
                                   with: .color(ink.opacity(0.5)), lineWidth: max(r * 0.01, 0.5))
                    for i in 0..<60 {
                        tick(i, of: 60, from: edge, length: r * (i % 5 == 0 ? 0.16 : 0.07), width: max(r * (i % 5 == 0 ? 0.035 : 0.012), 0.5),
                             color: ink.opacity(0.85))
                    }
                case .sport:
                    for i in 0..<60 {
                        let major = i % 5 == 0
                        tick(i, of: 60, from: edge, length: r * (major ? 0.14 : 0.05), width: max(r * (major ? 0.05 : 0.014), 0.6),
                             color: major ? ink : ink.opacity(0.4))
                    }
                case .plain:
                    break
                }
                if style == .numerals || style == .roman {
                    let numerals = style == .roman
                        ? ["XII", "I", "II", "III", "IIII", "V", "VI", "VII", "VIII", "IX", "X", "XI"]
                        : ["12", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"]
                    for (i, label) in numerals.enumerated() {
                        let angle = Double(i) / 12 * 2 * .pi - .pi / 2
                        let text = Text(label)
                            .font(.system(size: r * (style == .roman ? 0.15 : 0.19), weight: .medium,
                                          design: style == .roman ? .serif : .rounded))
                            .foregroundStyle(ink.opacity(0.9))
                        context.draw(text, at: point(angle, edge - r * (style == .roman ? 0.24 : 0.25)))
                    }
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// The hands. The seconds hand ticks with a short spring, or sweeps at a steady pace, through SwiftUI's own
/// animation, so it moves at display refresh while the view behind it redraws once a second.
struct AnalogHands: View {
    let reading: ClockReading
    let seconds: Bool
    let sweep: Bool
    let dial: DialStyle
    let accent: Color
    let ink: AnyShapeStyle
    let diameter: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let r = diameter / 2
        // Turned from a running count, never wrapped, so no hand ever spins back the long way.
        let secondAngle = reading.local * 6
        let minuteAngle = reading.local / 10
        let hourAngle = reading.local / 120
        let bold = dial == .sport || dial == .plain || dial == .railway
        ZStack {
            hand(width: r * (bold ? 0.075 : 0.055), length: r * 0.52, tail: r * 0.08, degrees: hourAngle)
                .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: hourAngle)
            hand(width: r * (bold ? 0.055 : 0.038), length: r * 0.8, tail: r * 0.1, degrees: minuteAngle)
                .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: minuteAngle)
            if seconds {
                ZStack {
                    Capsule().fill(dial == .railway ? Color.red : accent)
                        .frame(width: max(r * 0.016, 1), height: r * 0.98)
                        .offset(y: -r * 0.98 / 2 + r * 0.16)
                    if dial == .railway {
                        Circle().fill(Color.red).frame(width: r * 0.14, height: r * 0.14).offset(y: -r * 0.62)
                    }
                }
                .rotationEffect(.degrees(secondAngle))
                .animation(reduceMotion ? nil : (sweep ? .linear(duration: 1) : .spring(response: 0.22, dampingFraction: 0.55)), value: secondAngle)
            }
            Circle().fill(seconds ? accent : Color.white).frame(width: r * 0.08, height: r * 0.08)
            Circle().fill(Color.black.opacity(0.4)).frame(width: r * 0.03, height: r * 0.03)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.25), radius: r * 0.03, y: r * 0.015)
    }

    private func hand(width: Double, length: Double, tail: Double, degrees: Double) -> some View {
        Capsule().fill(ink)
            .frame(width: width, height: length + tail)
            .offset(y: -(length + tail) / 2 + tail)
            .rotationEffect(.degrees(degrees))
    }
}
