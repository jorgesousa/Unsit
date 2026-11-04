//  UnsitApp.swift — Unsit v0.1
//  A Mac menu bar app that gets you to 10,000 steps and enough water.
//  Steps arrive from iPhone through the "Unsit Sync" shortcut (iCloud Drive).
//  Includes: guided setup, menu bar panel, corner mode, gap nudge.
//  Requires macOS 14+. Built by scripts/build-app.sh (not sandboxed).

import SwiftUI
import AppKit
import EventKit
import ServiceManagement
import CoreImage.CIFilterBuiltins

// MARK: - Config

enum UnsitConfig {
    /// Paste the iCloud link of your shared "Unsit Sync" shortcut here.
    static let shortcutLink = "https://www.icloud.com/shortcuts/REPLACE_WITH_YOUR_LINK"
    /// iCloud Drive › Shortcuts › Unsit › steps.json
    static let stepsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/Unsit/steps.json")
    static let awayAfter: TimeInterval = 5 * 60
    static let stepsPerMinute = 100.0
}

// MARK: - Brand

extension Color {
    static let unsitSignal = Color(red: 1.0, green: 0.353, blue: 0.122)    // #FF5A1F, time to move
    static let unsitWater  = Color(red: 0.184, green: 0.490, blue: 0.965)  // #2F7DF6, water only
    static let unsitTrack  = Color.primary.opacity(0.08)
    static let unsitMist   = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.34, alpha: 1)
            : NSColor(red: 0.804, green: 0.820, blue: 0.843, alpha: 1)     // #CDD1D7, meetings
    })
}

func timeText(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

// MARK: - App

@main
struct UnsitApp: App {
    @StateObject private var model = UnsitModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
                .frame(width: 360)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Unsit", id: "onboarding") {
            OnboardingView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var model: UnsitModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.isNudging ? "figure.walk" : "arrow.up")
            Text(model.menuTitle)
        }
        .onAppear {
            model.start()
            if !model.onboarded {
                openWindow(id: "onboarding")
                NSApp.activate()
            }
        }
    }
}

// MARK: - Model

struct DayEvent: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let title: String
}

struct StepsFile: Decodable {
    let steps: Double
    let updatedAt: String

    enum CodingKeys: String, CodingKey { case steps, updatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(Double.self, forKey: .steps) {
            steps = v
        } else {
            // Handles "4980", "4 980", "4,980", "4.980" and an empty value.
            let s = (try? c.decode(String.self, forKey: .steps)) ?? ""
            steps = Double(s.filter(\.isNumber)) ?? 0
        }
        updatedAt = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""
    }
}

@MainActor
final class UnsitModel: ObservableObject {
    // Settings (saved)
    @Published var stepGoal: Int { didSet { defaults.set(stepGoal, forKey: "stepGoal") } }
    @Published var waterGoalML: Int { didSet { defaults.set(waterGoalML, forKey: "waterGoalML") } }
    @Published var glassML: Int { didSet { defaults.set(glassML, forKey: "glassML") } }
    @Published var dayStartHour: Int { didSet { defaults.set(dayStartHour, forKey: "dayStartHour") } }
    @Published var dayEndHour: Int { didSet { defaults.set(dayEndHour, forKey: "dayEndHour") } }
    @Published var sitLimitMinutes: Int { didSet { defaults.set(sitLimitMinutes, forKey: "sitLimitMinutes") } }
    @Published var cornerMode: Bool { didSet { defaults.set(cornerMode, forKey: "cornerMode"); applyMode() } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded"); applyMode() } }
    @Published var paused = false { didSet { evaluateNudge() } }

    // Live state
    @Published private(set) var now = Date()
    @Published private(set) var steps = 0
    @Published private(set) var stepsUpdatedAt: Date?
    @Published private(set) var waterML = 0
    @Published private(set) var events: [DayEvent] = []
    @Published private(set) var calendarAllowed = false
    @Published private(set) var isAway = false
    @Published private(set) var isNudging = false

    private let defaults = UserDefaults.standard
    private let store = EKEventStore()
    private var lastMove = Date()
    private var snoozeUntil: Date?
    private var timer: Timer?
    private var lastEventsFetch = Date.distantPast
    private var dayKeyInUse = ""

    init() {
        let d = UserDefaults.standard
        stepGoal = d.object(forKey: "stepGoal") as? Int ?? 10_000
        waterGoalML = d.object(forKey: "waterGoalML") as? Int ?? 2_000
        glassML = d.object(forKey: "glassML") as? Int ?? 250
        dayStartHour = d.object(forKey: "dayStartHour") as? Int ?? 9
        dayEndHour = d.object(forKey: "dayEndHour") as? Int ?? 19
        sitLimitMinutes = d.object(forKey: "sitLimitMinutes") as? Int ?? 45
        cornerMode = d.bool(forKey: "cornerMode")
        onboarded = d.bool(forKey: "onboarded")
        dayKeyInUse = Self.dayKey(Date())
        waterML = d.integer(forKey: "water-" + dayKeyInUse)
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        calendarAllowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isAway = true }
            }
        }
        applyMode()
    }

    func tick() {
        now = Date()
        rollDayIfNeeded()
        refreshSteps()
        updatePresence()
        if calendarAllowed && now.timeIntervalSince(lastEventsFetch) > 300 { fetchEvents() }
        if let s = snoozeUntil, s <= now { snoozeUntil = nil }
        evaluateNudge()
    }

    private func rollDayIfNeeded() {
        let key = Self.dayKey(now)
        guard key != dayKeyInUse else { return }
        dayKeyInUse = key
        steps = 0
        stepsUpdatedAt = nil
        waterML = defaults.integer(forKey: "water-" + key)
        lastMove = now
        events = []
        lastEventsFetch = .distantPast
    }

    // MARK: Steps (from the shortcut's file)

    func refreshSteps() {
        let url = UnsitConfig.stepsFile
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // iCloud may keep only a placeholder until the file is downloaded.
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".steps.json.icloud")
            if fm.fileExists(atPath: placeholder.path) { try? fm.startDownloadingUbiquitousItem(at: url) }
            return
        }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(StepsFile.self, from: data) else { return }

        var stamp = Self.parseDate(file.updatedAt)
        if stamp == nil, let attrs = try? fm.attributesOfItem(atPath: url.path) {
            stamp = attrs[.modificationDate] as? Date
        }
        guard let when = stamp, Calendar.current.isDate(when, inSameDayAs: now) else { return }

        let newSteps = Int(file.steps.rounded())
        if stepsUpdatedAt != nil, newSteps - steps >= 300 { lastMove = now }   // you walked
        steps = newSteps
        stepsUpdatedAt = when
    }

    static func parseDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    // MARK: Presence

    private func updatePresence() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                          eventType: CGEventType(rawValue: ~0)!)
        if idle >= UnsitConfig.awayAfter {
            isAway = true
        } else if isAway && idle < 60 {
            isAway = false
            lastMove = now     // you were away from the desk, so the seated clock restarts
        }
    }

    // MARK: Calendar

    func requestCalendar() async {
        let ok = (try? await store.requestFullAccessToEvents()) ?? false
        calendarAllowed = ok
        if ok { fetchEvents() }
    }

    private func fetchEvents() {
        lastEventsFetch = now
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.availability != .free }
            .map { DayEvent(start: $0.startDate, end: $0.endDate, title: $0.title ?? "Meeting") }
            .sorted { $0.start < $1.start }
    }

    // MARK: Water

    func addGlass() {
        waterML = min(waterML + glassML, waterGoalML * 2)
        defaults.set(waterML, forKey: "water-" + dayKeyInUse)
    }

    func removeGlass() {
        waterML = max(0, waterML - glassML)
        defaults.set(waterML, forKey: "water-" + dayKeyInUse)
    }

    // MARK: Day maths

    var dayStart: Date { Calendar.current.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: now) ?? now }
    var dayEnd: Date { Calendar.current.date(bySettingHour: dayEndHour, minute: 0, second: 0, of: now) ?? now }

    func fraction(of d: Date) -> Double {
        let span = dayEnd.timeIntervalSince(dayStart)
        guard span > 0 else { return 0 }
        return min(1, max(0, d.timeIntervalSince(dayStart) / span))
    }

    var dayFraction: Double { fraction(of: now) }
    var stepProgress: Double { stepGoal > 0 ? min(1, Double(steps) / Double(stepGoal)) : 0 }
    var expectedSteps: Int { Int(Double(stepGoal) * dayFraction) }
    var behindBy: Int { max(0, expectedSteps - steps) }
    var goalReached: Bool { steps >= stepGoal }
    var isWorkday: Bool { now >= dayStart && now < dayEnd }
    var seatedMinutes: Int { isAway ? 0 : max(0, Int(now.timeIntervalSince(lastMove) / 60)) }

    var walkMinutes: Int {
        let need = isWorkday ? behindBy : max(0, stepGoal - steps)
        return min(30, max(5, Int((Double(need) / UnsitConfig.stepsPerMinute).rounded(.up))))
    }

    var currentMeeting: DayEvent? { events.first { $0.start <= now && $0.end > now } }
    var nextMeeting: DayEvent? { events.first { $0.start > now } }

    /// The next free stretch of at least 10 minutes before the end of the workday.
    var nextGap: DateInterval? {
        var cursor = max(now, dayStart)
        guard cursor < dayEnd else { return nil }
        for e in events where e.end > cursor {
            if e.start.timeIntervalSince(cursor) >= 10 * 60 {
                return DateInterval(start: cursor, end: min(e.start, dayEnd))
            }
            cursor = max(cursor, e.end)
            if cursor >= dayEnd { return nil }
        }
        return dayEnd.timeIntervalSince(cursor) >= 10 * 60 ? DateInterval(start: cursor, end: dayEnd) : nil
    }

    var gapOpenNow: Bool { nextGap.map { $0.start <= now } ?? false }

    // MARK: Words

    var menuTitle: String { steps.formatted() }

    var paceText: String {
        if goalReached { return "Goal reached" }
        if behindBy > 0 { return "\(behindBy.formatted()) behind pace" }
        return isWorkday ? "On pace" : ""
    }

    var gapTitle: String {
        if goalReached { return "Done for today" }
        guard let g = nextGap else { return isWorkday ? "No gaps left today" : "Outside your workday" }
        return g.start <= now ? "Gap open until \(timeText(g.end))"
                              : "Next gap \(timeText(g.start)) to \(timeText(g.end))"
    }

    var gapDetail: String {
        if goalReached { return "Everything from here is a bonus." }
        if behindBy == 0 { return "You're on pace. A short walk keeps it that way." }
        var s = "Walk \(walkMinutes) minutes"
        if let m = nextMeeting, let g = nextGap, m.start <= g.end.addingTimeInterval(60) {
            s += " before \(m.title)"
        }
        return s + " and you're back on pace."
    }

    var nudgeTitle: String {
        if gapOpenNow, let g = nextGap { return "Gap open until \(timeText(g.end))" }
        return "\(seatedMinutes) minutes in the chair"
    }

    var nudgeDetail: String {
        behindBy > 0
            ? "You're \(behindBy.formatted()) behind pace. Walk \(walkMinutes) minutes now and you're back on track."
            : "A short walk now keeps you on pace."
    }

    var syncText: String {
        guard let d = stepsUpdatedAt else { return "Waiting for steps from iPhone" }
        let mins = Int(now.timeIntervalSince(d) / 60)
        if mins < 1 { return "Steps from iPhone, just now" }
        if mins < 90 { return "Steps from iPhone, \(mins) min ago" }
        return "Steps from iPhone at \(timeText(d))"
    }

    var waterText: String {
        (Double(waterML) / 1000).formatted(.number.precision(.fractionLength(0...2))) + " L"
    }

    // MARK: Nudge

    var shouldNudge: Bool {
        guard onboarded, !paused, isWorkday, !goalReached, !isAway, currentMeeting == nil else { return false }
        if let s = snoozeUntil, s > now { return false }
        if seatedMinutes >= sitLimitMinutes { return true }
        return gapOpenNow && behindBy > 300 && seatedMinutes >= 15
    }

    func evaluateNudge() {
        let should = shouldNudge
        guard should != isNudging else { return }
        isNudging = should
        if should {
            NudgePanelController.shared.show(model: self)
            NSSound(named: NSSound.Name("Funk"))?.play()
        } else {
            NudgePanelController.shared.hide()
        }
    }

    func going() {
        lastMove = now
        snoozeUntil = now.addingTimeInterval(Double(walkMinutes + 10) * 60)
        evaluateNudge()
    }

    func later() {
        snoozeUntil = now.addingTimeInterval(10 * 60)
        evaluateNudge()
    }

    // MARK: Mode

    func applyMode() {
        if cornerMode && onboarded {
            CornerPanelController.shared.show(model: self)
        } else {
            CornerPanelController.shared.hide()
        }
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}

// MARK: - Small components

struct UnsitMark: View {
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Color.primary)
            .frame(width: size, height: size)
            .overlay(
                VStack(spacing: size * 0.05) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    Capsule().fill(Color.unsitSignal).frame(width: size * 0.5, height: size * 0.1)
                }
            )
    }
}

struct PaceLine: View {
    var progress: Double
    var pace: Double
    var showLabel = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.unsitTrack).frame(height: 6)
                if progress > 0 {
                    Capsule().fill(Color.primary).frame(width: max(6, w * progress), height: 6)
                }
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.unsitSignal)
                    .frame(width: 2, height: 16)
                    .offset(x: w * pace - 1)
                if showLabel {
                    Text("Pace")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.unsitSignal)
                        .fixedSize()
                        .offset(x: w * pace - 12, y: -18)
                }
            }
            .frame(height: 16)
        }
        .frame(height: 16)
    }
}

struct DayStrip: View {
    let model: UnsitModel
    var height: CGFloat = 30
    var showTicks = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let inset = h * 0.14
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.unsitTrack)
                    ForEach(model.events) { e in
                        let x0 = model.fraction(of: e.start) * w
                        let x1 = model.fraction(of: e.end) * w
                        if x1 - x0 > 2 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.unsitMist)
                                .frame(width: x1 - x0 - 2, height: h - inset * 2)
                                .offset(x: x0 + 1, y: inset)
                        }
                    }
                    if let g = model.nextGap, !model.goalReached {
                        let x0 = model.fraction(of: g.start) * w
                        let x1 = model.fraction(of: g.end) * w
                        if x1 - x0 > 2 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.unsitSignal)
                                .frame(width: x1 - x0 - 2, height: h - inset * 2)
                                .offset(x: x0 + 1, y: inset)
                        }
                    }
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2, height: h + 10)
                        .offset(x: model.dayFraction * w - 1, y: -5)
                }
            }
            .frame(height: height)

            if showTicks {
                GeometryReader { geo in
                    let span = max(1, model.dayEndHour - model.dayStartHour)
                    let hours = Array(stride(from: model.dayStartHour, through: model.dayEndHour, by: 2))
                    ZStack(alignment: .topLeading) {
                        ForEach(hours, id: \.self) { hr in
                            let x = CGFloat(hr - model.dayStartHour) / CGFloat(span) * geo.size.width
                            Text(String(format: "%02d", hr))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .offset(x: hr == model.dayStartHour ? 0 : (hr == model.dayEndHour ? x - 14 : x - 7))
                        }
                    }
                }
                .frame(height: 14)
            }
        }
    }
}

struct Cup: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.15, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.15, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct WaterCups: View {
    let filled: Int
    let total: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(1, total), id: \.self) { i in
                Group {
                    if i < filled {
                        Cup().fill(Color.unsitWater)
                    } else {
                        Cup().stroke(Color.secondary.opacity(0.5), lineWidth: 1.3)
                    }
                }
                .frame(width: 12, height: 15)
            }
        }
    }
}

// MARK: - Menu bar panel

struct PanelView: View {
    @EnvironmentObject var model: UnsitModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    UnsitMark()
                    Text("Unsit").font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Text(String(format: "Today %02d:00 to %02d:00", model.dayStartHour, model.dayEndHour))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                SettingsMenu()
            }

            Text(model.steps.formatted())
                .font(.system(size: 58, weight: .semibold).monospacedDigit())
                .tracking(-2)
                .padding(.top, 18)

            HStack {
                Text("of \(model.stepGoal.formatted()) steps").foregroundStyle(.secondary)
                Spacer()
                Text(model.paceText)
                    .fontWeight(.semibold)
                    .foregroundStyle(model.behindBy > 0 ? Color.unsitSignal : Color.secondary)
            }
            .font(.system(size: 13))
            .padding(.top, 2)

            PaceLine(progress: model.stepProgress, pace: model.dayFraction, showLabel: true)
                .padding(.top, 30)

            DayStrip(model: model).padding(.top, 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.gapTitle).font(.system(size: 15, weight: .semibold))
                Text(model.gapDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 14)

            if !model.calendarAllowed {
                Button("Allow calendar to find your gaps") { Task { await model.requestCalendar() } }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.top, 6)
            }

            Divider().padding(.vertical, 12)

            HStack(spacing: 10) {
                Text("Seated").frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
                ProgressView(value: min(1, Double(model.seatedMinutes) / Double(max(1, model.sitLimitMinutes))))
                    .tint(Color.primary)
                Text("\(model.seatedMinutes) min").fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 13))

            HStack(spacing: 10) {
                Text("Water").frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
                WaterCups(filled: model.waterML / max(1, model.glassML),
                          total: model.waterGoalML / max(1, model.glassML))
                Spacer(minLength: 4)
                Text(model.waterText).fontWeight(.semibold)
                Button("+ Glass") { model.addGlass() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.unsitWater)
                    .contextMenu { Button("Remove a glass") { model.removeGlass() } }
            }
            .font(.system(size: 13))
            .padding(.top, 10)

            Divider().padding(.vertical, 12)

            HStack {
                Text(model.syncText).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Pause", isOn: $model.paused)
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
        }
        .padding(18)
    }
}

struct SettingsMenu: View {
    @EnvironmentObject var model: UnsitModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Toggle("Corner mode", isOn: $model.cornerMode)
            Toggle("Open at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in
                    if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                }
            ))
            Menu("Daily goal") {
                ForEach([6_000, 8_000, 10_000, 12_000], id: \.self) { g in
                    Button("\(g.formatted()) steps") { model.stepGoal = g }
                }
            }
            Menu("Workday") {
                Button("08:00 to 18:00") { model.dayStartHour = 8; model.dayEndHour = 18 }
                Button("09:00 to 19:00") { model.dayStartHour = 9; model.dayEndHour = 19 }
                Button("10:00 to 20:00") { model.dayStartHour = 10; model.dayEndHour = 20 }
            }
            Menu("Nudge after") {
                ForEach([30, 45, 60], id: \.self) { m in
                    Button("\(m) minutes seated") { model.sitLimitMinutes = m }
                }
            }
            Button("Set up again…") {
                openWindow(id: "onboarding")
                NSApp.activate()
            }
            Divider()
            Button("Quit Unsit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Floating panels (corner mode and nudge)

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class CornerPanelController {
    static let shared = CornerPanelController()
    private var panel: FloatingPanel?
    let collapsedSize = NSSize(width: 170, height: 170)
    let expandedSize = NSSize(width: 380, height: 520)

    func show(model: UnsitModel) {
        if panel == nil {
            let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: collapsedSize),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            p.isMovable = false
            p.contentView = NSHostingView(rootView: CornerRoot().environmentObject(model))
            panel = p
        }
        resize(expanded: false)
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func resize(expanded: Bool) {
        guard let p = panel, let screen = NSScreen.main else { return }
        let size = expanded ? expandedSize : collapsedSize
        let vf = screen.visibleFrame
        p.setFrame(NSRect(x: vf.maxX - size.width, y: vf.minY, width: size.width, height: size.height),
                   display: true, animate: false)
    }
}

@MainActor
final class NudgePanelController {
    static let shared = NudgePanelController()
    private var panel: FloatingPanel?
    let size = NSSize(width: 540, height: 150)

    func show(model: UnsitModel) {
        guard let screen = NSScreen.main else { return }
        if panel == nil {
            let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            p.appearance = NSAppearance(named: .darkAqua)
            p.contentView = NSHostingView(rootView: NudgeView().environmentObject(model))
            panel = p
        }
        guard let p = panel else { return }
        let f = screen.frame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                          width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 1
        }
    }

    func hide() { panel?.orderOut(nil) }
}

// MARK: - Corner mode

func quarterArc(_ c: CGPoint, _ r: CGFloat, _ f0: Double, _ f1: Double) -> Path {
    // f = 0 points left of the corner, f = 1 points straight up.
    var p = Path()
    let n = max(2, Int((f1 - f0) * 80))
    for i in 0...n {
        let f = f0 + (f1 - f0) * Double(i) / Double(n)
        let a = Double.pi * (1 + 0.5 * f)
        let pt = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    return p
}

struct QuarterDisc: Shape {
    func path(in r: CGRect) -> Path {
        var p = quarterArc(CGPoint(x: r.maxX, y: r.maxY), r.width, 0, 1)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct CornerRoot: View {
    @EnvironmentObject var model: UnsitModel
    @State private var expanded = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if expanded {
                PanelView()
                    .frame(width: 380)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 26, style: .continuous))
            } else {
                CornerCollapsed()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onHover { inside in
            guard inside != expanded else { return }
            expanded = inside
            CornerPanelController.shared.resize(expanded: inside)
        }
    }
}

struct CornerCollapsed: View {
    @EnvironmentObject var model: UnsitModel

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            let c = CGPoint(x: s, y: s)
            let outer = s * 0.89
            let inner = s * 0.78
            ZStack(alignment: .bottomTrailing) {
                QuarterDisc().fill(Color(white: 0.08).opacity(0.92))

                // Outer ring: steps, with the pace tick
                quarterArc(c, outer, 0, 1)
                    .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                if model.stepProgress > 0 {
                    quarterArc(c, outer, 0, model.stepProgress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                }
                Path { p in
                    let a = Double.pi * (1 + 0.5 * model.dayFraction)
                    p.move(to: CGPoint(x: c.x + (outer - 9) * CGFloat(cos(a)), y: c.y + (outer - 9) * CGFloat(sin(a))))
                    p.addLine(to: CGPoint(x: c.x + (outer + 9) * CGFloat(cos(a)), y: c.y + (outer + 9) * CGFloat(sin(a))))
                }
                .stroke(Color.unsitSignal, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))

                // Inner ring: the day, meetings and the next gap
                quarterArc(c, inner, 0, 1).stroke(Color.white.opacity(0.10), lineWidth: 6)
                ForEach(model.events) { e in
                    let f0 = model.fraction(of: e.start)
                    let f1 = model.fraction(of: e.end)
                    if f1 - f0 > 0.01 {
                        quarterArc(c, inner, f0 + 0.004, f1 - 0.004).stroke(Color.white.opacity(0.38), lineWidth: 6)
                    }
                }
                if let g = model.nextGap, !model.goalReached {
                    let f0 = model.fraction(of: g.start)
                    let f1 = model.fraction(of: g.end)
                    if f1 - f0 > 0.01 {
                        quarterArc(c, inner, f0 + 0.004, f1 - 0.004).stroke(Color.unsitSignal, lineWidth: 6)
                    }
                }

                VStack(alignment: .trailing, spacing: 3) {
                    if let g = model.nextGap, !model.goalReached {
                        Text(g.start <= model.now ? "Gap until \(timeText(g.end))" : "Gap at \(timeText(g.start))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.unsitSignal)
                    }
                    Text(model.steps.formatted())
                        .font(.system(size: 30, weight: .semibold).monospacedDigit())
                        .tracking(-1)
                        .foregroundStyle(.white)
                    Text(model.paceText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .padding(.trailing, 18)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 170, height: 170)
    }
}

// MARK: - Nudge

struct PillStyle: ButtonStyle {
    let fill: Color
    let text: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Capsule().fill(fill))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct NudgeView: View {
    @EnvironmentObject var model: UnsitModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                UnsitMark(size: 22)
                DayStrip(model: model, height: 16, showTicks: false).frame(width: 130)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.nudgeTitle).font(.system(size: 16, weight: .semibold))
                Text(model.nudgeDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 7) {
                Button("Going") { model.going() }
                    .buttonStyle(PillStyle(fill: .unsitSignal, text: .white))
                Button("In 10 min") { model.later() }
                    .buttonStyle(PillStyle(fill: Color(white: 0.17), text: Color(white: 0.85)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 40)
        .padding(.bottom, 14)
        .frame(width: 540, height: 150)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 32, bottomTrailingRadius: 32, style: .continuous)
            .fill(Color.black))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Guided setup

func qrImage(_ string: String) -> NSImage {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
        return NSImage()
    }
    let rep = NSCIImageRep(ciImage: output)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

struct OnboardingView: View {
    @EnvironmentObject var model: UnsitModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 1
    @State private var timesDone = false
    @State private var appsDone = false
    @State private var showManual = false

    private let titles = ["Add the shortcut", "Run it once", "Keep it fresh", "Find your gaps"]

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 230)
            Divider()
            content
                .padding(.horizontal, 44)
                .padding(.top, 40)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 820, height: 560)
        .sheet(isPresented: $showManual) { ManualShortcutSheet() }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                UnsitMark(size: 24)
                Text("Unsit").font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 18)

            ForEach(1...4, id: \.self) { i in
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(i <= step ? Color.primary : Color.primary.opacity(0.1))
                            .frame(width: 22, height: 22)
                        if i < step {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        } else {
                            Text("\(i)")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(i == step ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                        }
                    }
                    Text(titles[i - 1])
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(i == step ? Color.primary : Color.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(i == step ? Color.primary.opacity(0.07) : Color.clear))
            }

            Spacer()
            Text("Takes about three minutes. Your iPhone stays in your pocket after this.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        .padding(.top, 36)
        .padding(.horizontal, 18)
        .padding(.bottom, 22)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1: stepOne
        case 2: stepTwo
        case 3: stepThree
        default: stepFour
        }
    }

    private func header(_ title: String, _ lead: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
            Text(lead)
                .font(.system(size: 14.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Bring your steps over from iPhone",
                   "Apple Health only lives on your iPhone and Watch. A free Apple shortcut copies today's steps to this Mac through iCloud Drive.")
            HStack(spacing: 28) {
                Image(nsImage: qrImage(UnsitConfig.shortcutLink))
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 150, height: 150)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scan with your iPhone camera").font(.system(size: 14, weight: .semibold))
                    Text("The link opens Shortcuts. Tap Add Shortcut and you'll see Unsit Sync in your list.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("No App Store, no account. You can delete it any time.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 250, alignment: .leading)
            }
            .padding(.top, 30)
            Spacer()
            HStack {
                Button("Build it by hand instead") { showManual = true }.buttonStyle(.link)
                Spacer()
                Button("I've added it") { step = 2 }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var stepTwo: some View {
        let connected = model.stepsUpdatedAt != nil
        return VStack(alignment: .leading, spacing: 0) {
            header("Run it once",
                   "On your iPhone, open Shortcuts and tap Unsit Sync. When Health asks, allow Steps. This Mac is listening for it.")
            HStack(spacing: 14) {
                if connected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(.green)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(connected ? "Connected" : "Waiting for your iPhone…").font(.system(size: 15, weight: .semibold))
                    Text(connected ? "Arrived from iPhone at \(timeText(model.stepsUpdatedAt ?? Date()))"
                                   : "Run Unsit Sync on your iPhone now.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if connected {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.steps.formatted()).font(.system(size: 30, weight: .semibold).monospacedDigit())
                        Text("steps today").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Check now") { model.refreshSteps() }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .padding(.top, 30)
            Text(connected
                 ? "Does that match the Health app? If it shows roughly double, open the shortcut and check that Group By is set to Day."
                 : "Unsit looks for iCloud Drive › Shortcuts › Unsit › steps.json.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Spacer()
            HStack {
                Spacer()
                Button("Back") { step = 1 }
                Button("Next") { step = 3 }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var stepThree: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Keep it fresh during the day",
                   "Your iPhone can run Unsit Sync on its own. In Shortcuts, open Automation and add these two.")
            VStack(alignment: .leading, spacing: 12) {
                automationCard(isOn: $timesDone, title: "At set times",
                               detail: "Time of Day, Daily, at 09:00, 10:30, 12:00, 13:30, 15:00, 16:30 and 18:00. Choose Run Immediately and turn off notifications.")
                automationCard(isOn: $appsDone, title: "When you open busy apps",
                               detail: "App, Is Opened: pick Slack, Teams or Mail. Same settings. Steps then refresh many times a day.")
            }
            .padding(.top, 26)
            Text("The menu bar always shows when steps last arrived, so you'll notice if an automation stops.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .padding(.top, 14)
            Spacer()
            HStack {
                Spacer()
                Button("Back") { step = 2 }
                Button("Next") { step = 4 }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func automationCard(isOn: Binding<Bool>, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: isOn).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var stepFour: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Find the gaps in your day",
                   "Unsit reads your calendar to see where meetings are and when a gap opens. Nothing leaves this Mac.")
            VStack(alignment: .leading, spacing: 0) {
                PaceLine(progress: model.stepProgress, pace: model.dayFraction, showLabel: true)
                    .padding(.top, 20)
                DayStrip(model: model, height: 26).padding(.top, 16)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .padding(.top, 26)
            HStack {
                Text("Where should Unsit live?").font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.cornerMode) {
                    Text("Menu bar").tag(false)
                    Text("Screen corner").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            .padding(.top, 20)
            Spacer()
            HStack {
                Spacer()
                Button("Skip calendar") { finish() }
                Button("Allow calendar and start") {
                    Task {
                        await model.requestCalendar()
                        finish()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        model.onboarded = true
        dismissWindow(id: "onboarding")
    }
}

struct ManualShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let steps = [
        "Open Shortcuts on your iPhone, tap + and name the shortcut \"Unsit Sync\".",
        "Add Find Health Samples: Type is Steps, Start Date is today, Group By Day, Fill Missing on.",
        "Add Get Details of Health Samples and choose Value.",
        "Add Round Number, to Integer.",
        "Add Text: {\"steps\": \"[Rounded Number]\", \"updatedAt\": \"[Current Date]\"}. Set Current Date to ISO 8601 with time.",
        "Add Save File to Shortcuts/Unsit/steps.json. Turn off Ask Where to Save, turn on Overwrite.",
        "Run it once and allow Steps when Health asks."
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Build Unsit Sync by hand").font(.system(size: 18, weight: .semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 13, weight: .semibold)).frame(width: 18)
                    Text(s).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
