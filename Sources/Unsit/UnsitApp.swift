//  UnsitApp.swift — Unsit v0.1
//  A Mac menu bar app that gets you to 10,000 steps and enough water.
//  Steps arrive from iPhone through the "Unsit Sync" shortcut (iCloud Drive).
//  Includes: guided setup, menu bar panel, gap nudge, settings.
//  Requires macOS 14+. Built by scripts/build-app.sh (not sandboxed).

import SwiftUI
import AppKit
import EventKit
import ServiceManagement
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

// MARK: - Config

enum UnsitConfig {
    /// Paste the iCloud link of your shared "Unsit Sync" shortcut here.
    static let shortcutLink = "https://www.icloud.com/shortcuts/REPLACE_WITH_YOUR_LINK"
    /// iCloud Drive › Shortcuts › Unsit › steps.json
    static let stepsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/Unsit/steps.json")
    /// Other places the shortcut's Save File action commonly ends up writing to.
    static let candidateFiles: [URL] = {
        let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents")
        let folders = [
            "iCloud~is~workflow~my~workflows/Documents/Unsit",
            "iCloud~is~workflow~my~workflows/Documents",
            "com~apple~CloudDocs/Shortcuts/Unsit",
            "com~apple~CloudDocs/Unsit",
            "com~apple~CloudDocs"
        ]
        // Shortcuts often saves text as .txt even when the name says .json, so accept both.
        return folders.flatMap { f in
            ["steps.json", "steps.txt"].map { docs.appendingPathComponent(f).appendingPathComponent($0) }
        }
    }()
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

        Window("Unsit Settings", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

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
            Image(systemName: model.goalReached ? "checkmark.circle" : (model.isNudging ? "figure.walk.motion" : "figure.walk"))
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

    /// Calendar Sync style titles start with "[Source]". Split that off so the name comes first.
    var name: String { Self.split(title).name }
    var source: String? { Self.split(title).source }

    static func split(_ t: String) -> (name: String, source: String?) {
        guard t.hasPrefix("["), let close = t.firstIndex(of: "]") else { return (t, nil) }
        let source = String(t[t.index(after: t.startIndex)..<close])
        let rest = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? (t, nil) : (rest, source)
    }
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
            // If the shortcut sends several days (one per line), only the first one counts.
            let s = (try? c.decode(String.self, forKey: .steps)) ?? ""
            let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            steps = Double(first.filter(\.isNumber)) ?? 0
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
    /// Workday start and end, in minutes after midnight (540 = 09:00).
    @Published var dayStartMinute: Int { didSet { defaults.set(dayStartMinute, forKey: "dayStartMinute"); workdayChanged() } }
    @Published var dayEndMinute: Int { didSet { defaults.set(dayEndMinute, forKey: "dayEndMinute"); workdayChanged() } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
    @Published var paused = false { didSet { evaluateNudge() } }
    /// A steps file the person picked by hand, used before the usual locations.
    @Published var customStepsPath: String? { didSet { defaults.set(customStepsPath, forKey: "customStepsPath") } }

    // Live state
    @Published private(set) var now = Date()
    @Published private(set) var steps = 0
    @Published private(set) var stepsUpdatedAt: Date?
    @Published private(set) var stepsStatus: String?
    @Published private(set) var waterML = 0
    @Published private(set) var events: [DayEvent] = []
    @Published private(set) var calendarAllowed = false
    @Published private(set) var isAway = false
    @Published private(set) var isNudging = false

    private let defaults = UserDefaults.standard
    private let store = EKEventStore()
    private var snoozeUntil: Date?
    private var timer: Timer?
    private var lastEventsFetch = Date.distantPast
    private var dayKeyInUse = ""

    init() {
        let d = UserDefaults.standard
        stepGoal = d.object(forKey: "stepGoal") as? Int ?? 10_000
        waterGoalML = d.object(forKey: "waterGoalML") as? Int ?? 2_000
        glassML = d.object(forKey: "glassML") as? Int ?? 250
        dayStartMinute = d.object(forKey: "dayStartMinute") as? Int ?? 9 * 60
        dayEndMinute = d.object(forKey: "dayEndMinute") as? Int ?? 19 * 60
        onboarded = d.bool(forKey: "onboarded")
        customStepsPath = d.string(forKey: "customStepsPath")
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
    }

    func tick() {
        now = Date()
        let allowedNow = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if allowedNow != calendarAllowed {
            calendarAllowed = allowedNow
            lastEventsFetch = .distantPast
            if !allowedNow { events = [] }
        }
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
        events = []
        lastEventsFetch = .distantPast
    }

    // MARK: Steps (from the shortcut's file)

    func refreshSteps() {
        let fm = FileManager.default
        func modified(_ u: URL) -> Date {
            ((try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date) ?? .distantPast
        }
        // Use whichever candidate exists and was written most recently.
        var candidates = UnsitConfig.candidateFiles
        if let custom = customStepsPath { candidates.insert(URL(fileURLWithPath: custom), at: 0) }
        let existing = candidates.filter { fm.fileExists(atPath: $0.path) }
        let url: URL
        if let custom = customStepsPath, fm.fileExists(atPath: custom) {
            url = URL(fileURLWithPath: custom)
        } else {
            url = existing.max { modified($0) < modified($1) } ?? UnsitConfig.stepsFile
        }
        let folder = url.deletingLastPathComponent()

        if !fm.fileExists(atPath: url.path) {
            // iCloud may keep only a placeholder until the file is downloaded.
            let placeholders = UnsitConfig.candidateFiles.filter {
                fm.fileExists(atPath: $0.deletingLastPathComponent().appendingPathComponent("." + $0.lastPathComponent + ".icloud").path)
            }
            if let p = placeholders.first {
                try? fm.startDownloadingUbiquitousItem(at: p)
                stepsStatus = "Found the file in iCloud Drive. Downloading it now…"
            } else if fm.fileExists(atPath: folder.path) {
                let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
                stepsStatus = names.isEmpty
                    ? "The Unsit folder is there but empty. Run Unsit Sync on your iPhone."
                    : "The Unsit folder has \(names.joined(separator: ", ")) but no steps file. Check the file name in the shortcut's Save File action."
            } else {
                stepsStatus = "No Unsit folder in iCloud Drive › Shortcuts yet. Run Unsit Sync on your iPhone, and check Save File points to Shortcuts › Unsit."
            }
            return
        }

        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            stepsStatus = "Unsit can't open \(url.lastPathComponent) (\(error.localizedDescription)). Allow it under System Settings › Privacy & Security › Files and Folders."
            return
        }

        // The iPhone keyboard often turns straight quotes into curly ones; accept both.
        let text = (String(data: raw, encoding: .utf8) ?? "")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{201E}", with: "\"")
            .replacingOccurrences(of: "\u{2033}", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Several days arrive as raw line breaks inside the value, which JSON doesn't allow.
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard let file = try? JSONDecoder().decode(StepsFile.self, from: Data(text.utf8)) else {
            stepsStatus = "Found \(url.lastPathComponent) but couldn't read it. It contains: \(text.prefix(120))"
            return
        }

        var stamp = Self.parseDate(file.updatedAt)
        if stamp == nil, let attrs = try? fm.attributesOfItem(atPath: url.path) {
            stamp = attrs[.modificationDate] as? Date
        }
        guard let when = stamp, Calendar.current.isDate(when, inSameDayAs: now) else {
            let day = stamp.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "an unknown day"
            stepsStatus = "Found steps from \(day), not today. Run Unsit Sync on your iPhone again."
            return
        }

        let newSteps = Int(file.steps.rounded())
        steps = newSteps
        stepsUpdatedAt = when
        stepsStatus = nil
    }

    /// Lets the person point Unsit at the steps file in Finder, once.
    func chooseStepsFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose the steps file from Unsit Sync"
        panel.message = "Pick steps.txt or steps.json in iCloud Drive › Shortcuts › Unsit."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .plainText, .text]
        let shortcutsDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents")
        panel.directoryURL = shortcutsDocs
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            customStepsPath = url.path
            refreshSteps()
        }
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
        }
    }

    // MARK: Calendar

    func requestCalendar() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted || status == .writeOnly {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
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

    /// Sets today's water to an exact number of glasses.
    func setGlasses(_ count: Int) {
        waterML = min(max(0, count) * glassML, waterGoalML * 2)
        defaults.set(waterML, forKey: "water-" + dayKeyInUse)
    }

    var glassesDrunk: Int { waterML / max(1, glassML) }
    var glassesGoal: Int { max(1, waterGoalML / max(1, glassML)) }

    // MARK: Day maths

    var dayStart: Date {
        Calendar.current.date(bySettingHour: dayStartMinute / 60, minute: dayStartMinute % 60, second: 0, of: now) ?? now
    }
    var dayEnd: Date {
        Calendar.current.date(bySettingHour: dayEndMinute / 60, minute: dayEndMinute % 60, second: 0, of: now) ?? now
    }

    /// Sets the workday, keeping it at least one hour long.
    func setWorkday(start: Int, end: Int) {
        let s = min(max(0, start), 22 * 60)
        let e = min(max(end, s + 60), 23 * 60 + 59)
        if s != dayStartMinute { dayStartMinute = s }
        if e != dayEndMinute { dayEndMinute = e }
    }

    private func workdayChanged() {
        lastEventsFetch = .distantPast
        if timer != nil { tick() }
    }

    static func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

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

    /// Every free stretch of at least 10 minutes in today's workday, past ones included.
    var freeGaps: [DateInterval] {
        var gaps: [DateInterval] = []
        var cursor = dayStart
        for e in events where e.end > cursor {
            if e.start.timeIntervalSince(cursor) >= 10 * 60 {
                gaps.append(DateInterval(start: cursor, end: min(e.start, dayEnd)))
            }
            cursor = max(cursor, e.end)
            if cursor >= dayEnd { break }
        }
        if dayEnd.timeIntervalSince(cursor) >= 10 * 60 {
            gaps.append(DateInterval(start: cursor, end: dayEnd))
        }
        return gaps
    }

    /// What the day strip shows for a moment: a meeting's name, or a gap's length and what it's worth.
    func stripInfo(at t: Date) -> (title: String, detail: String)? {
        if let e = events.first(where: { $0.start <= t && $0.end > t }) {
            let range = "\(timeText(e.start)) to \(timeText(e.end))"
            return (e.name, e.source.map { "\($0), \(range)" } ?? range)
        }
        guard let g = freeGaps.first(where: { $0.start <= t && $0.end > t }) else { return nil }
        let range = "\(timeText(g.start)) to \(timeText(g.end))"
        if g.end <= now {
            return ("\(Int(g.duration / 60)) min free", "\(range), already passed")
        }
        if g.start <= now {
            let left = Int(g.end.timeIntervalSince(now) / 60)
            let steps = Int(Double(left) * UnsitConfig.stepsPerMinute)
            return ("\(left) min left in this gap", "Until \(timeText(g.end)), up to \(steps.formatted()) steps")
        }
        let mins = Int(g.duration / 60)
        let steps = Int(Double(mins) * UnsitConfig.stepsPerMinute)
        return ("\(mins) min free", "\(range), up to \(steps.formatted()) steps")
    }

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
        if now < dayStart { return "First gap \(timeText(g.start)) to \(timeText(g.end))" }
        return g.start <= now ? "Gap open until \(timeText(g.end))"
                              : "Next gap \(timeText(g.start)) to \(timeText(g.end))"
    }

    var gapDetail: String {
        if goalReached { return "Everything from here is a bonus." }
        if now < dayStart {
            return "Your day starts at \(timeText(dayStart)). Nothing to do yet."
        }
        if behindBy == 0 { return "You're on pace. A short walk keeps it that way." }
        var s = "Walk \(walkMinutes) minutes"
        if let m = nextMeeting, let g = nextGap, m.start <= g.end.addingTimeInterval(60) {
            s += " before \(m.name)"
        }
        return s + " and you're back on pace."
    }

    var nudgeTitle: String {
        if gapOpenNow, let g = nextGap { return "Gap open until \(timeText(g.end))" }
        return "Time for a walk"
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

    var waterGoalText: String {
        (Double(waterGoalML) / 1000).formatted(.number.precision(.fractionLength(0...2))) + " L"
    }

    var waterText: String {
        (Double(waterML) / 1000).formatted(.number.precision(.fractionLength(0...2))) + " L"
    }

    // MARK: Nudge

    var shouldNudge: Bool {
        guard onboarded, !paused, isWorkday, !goalReached, !isAway, currentMeeting == nil else { return false }
        if let s = snoozeUntil, s > now { return false }
        // Only nudge when a gap is open and you're meaningfully behind pace.
        return gapOpenNow && behindBy > 300
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
        // You're on it: stay quiet for the rest of this gap.
        snoozeUntil = nextGap?.end ?? now.addingTimeInterval(Double(walkMinutes + 10) * 60)
        evaluateNudge()
    }

    func later() {
        snoozeUntil = now.addingTimeInterval(10 * 60)
        evaluateNudge()
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
                        .offset(x: min(max(0, w * pace - 12), w - 26), y: -18)
                }
            }
            .frame(height: 16)
        }
        .frame(height: 16)
    }
}

struct DayStrip: View {
    @ObservedObject var model: UnsitModel
    var height: CGFloat = 30
    var showTicks = true
    var allowsHover = true
    @State private var hoverX: CGFloat?
    @State private var tagSize: CGSize = CGSize(width: 180, height: 34)

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
                    ForEach(model.freeGaps.filter { $0.end > model.now }, id: \.start) { g in
                        let isNext = g.start == model.nextGap?.start
                        let x0 = model.fraction(of: max(g.start, model.now)) * w
                        let x1 = model.fraction(of: g.end) * w
                        if x1 - x0 > 2 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.unsitSignal.opacity(isNext && !model.goalReached ? 1 : 0.28))
                                .frame(width: x1 - x0 - 2, height: h - inset * 2)
                                .offset(x: x0 + 1, y: inset)
                        }
                    }
                    if let x = hoverX {
                        Rectangle()
                            .fill(Color.primary.opacity(0.35))
                            .frame(width: 1, height: h)
                            .offset(x: x)
                    }
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2, height: h + 10)
                        .offset(x: model.dayFraction * w - 1, y: -5)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard allowsHover else { return }
                    switch phase {
                    case .active(let p): hoverX = min(max(0, p.x), w)
                    case .ended: hoverX = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let x = hoverX, w > 0 {
                        let t = model.dayStart.addingTimeInterval(
                            Double(x / w) * model.dayEnd.timeIntervalSince(model.dayStart))
                        if let info = model.stripInfo(at: t) {
                            StripTag(title: info.title, detail: info.detail)
                                .fixedSize()
                                .offset(x: min(max(0, x - tagSize.width / 2), max(0, w - tagSize.width)),
                                        y: -(tagSize.height + 6))
                                .allowsHitTesting(false)
                                .onPreferenceChange(TagSizeKey.self) { tagSize = $0 }
                        }
                    }
                }
            }
            .frame(height: height)

            if showTicks {
                GeometryReader { geo in
                    let startM = model.dayStartMinute
                    let span = max(60, model.dayEndMinute - startM)
                    let firstH = (startM + 59) / 60
                    let lastH = model.dayEndMinute / 60
                    let stepH = (lastH - firstH) > 6 ? 2 : 1
                    let hours = firstH <= lastH ? Array(stride(from: firstH, through: lastH, by: stepH)) : []
                    let w = geo.size.width
                    ZStack(alignment: .topLeading) {
                        ForEach(hours, id: \.self) { hr in
                            let x = CGFloat(hr * 60 - startM) / CGFloat(span) * w
                            Text(String(format: "%02d", hr))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .offset(x: x <= 1 ? 0 : (x >= w - 8 ? x - 14 : x - 7))
                        }
                    }
                }
                .frame(height: 14)
            }
        }
    }
}

struct StripTag: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(2)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: 250, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .background(GeometryReader { p in Color.clear.preference(key: TagSizeKey.self, value: p.size) })
    }
}

struct TagSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
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

/// Tap a cup to fill up to it; tap the last full cup to empty it.
/// Hovering previews the result before you click.
struct WaterCups: View {
    let filled: Int
    let goal: Int
    let onSet: (Int) -> Void
    @State private var hovered: Int?

    private var total: Int { max(goal, filled) }

    private func target(for i: Int) -> Int { i == filled - 1 ? i : i + 1 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<total, id: \.self) { i in
                Button { onSet(target(for: i)) } label: {
                    cup(i)
                        .frame(width: 18, height: 22)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CupPressStyle())
                .onHover { inside in hovered = inside ? i : (hovered == i ? nil : hovered) }
                .help(i == filled - 1 ? "Remove this glass" : "Set to \(i + 1) glass\(i == 0 ? "" : "es")")
                .accessibilityLabel("Glass \(i + 1) of \(goal)")
                .accessibilityValue(i < filled ? "Full" : "Empty")
            }
        }
        .animation(.easeOut(duration: 0.15), value: filled)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    @ViewBuilder private func cup(_ i: Int) -> some View {
        let full = i < filled
        let preview: Bool = {
            guard let h = hovered else { return false }
            let t = target(for: h)
            return t > filled ? (i >= filled && i < t) : (i >= t && i < filled)
        }()
        let extra = i >= goal
        ZStack {
            if full {
                Cup().fill(Color.unsitWater.opacity(preview ? 0.35 : 1))
            } else {
                Cup().fill(Color.unsitWater.opacity(preview ? 0.35 : 0))
            }
            Cup().stroke(full || preview ? Color.unsitWater : Color.secondary.opacity(extra ? 0.25 : 0.5),
                         style: StrokeStyle(lineWidth: 1.4, dash: extra && !full ? [2, 2] : []))
        }
    }
}

struct CupPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
                Text("Today \(UnsitModel.hhmm(model.dayStartMinute)) to \(UnsitModel.hhmm(model.dayEndMinute))")
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

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Water").foregroundStyle(.secondary)
                    Spacer()
                    Text(model.waterText).fontWeight(.semibold).monospacedDigit()
                    + Text(" of \(model.waterGoalText)").foregroundColor(.secondary)
                    HStack(spacing: 0) {
                        Button { model.removeGlass() } label: {
                            Image(systemName: "minus")
                                .frame(width: 30, height: 24)
                                .contentShape(Rectangle())
                        }
                        .disabled(model.waterML == 0)
                        .help("Remove a glass")
                        Divider().frame(height: 14)
                        Button { model.addGlass() } label: {
                            Image(systemName: "plus")
                                .frame(width: 30, height: 24)
                                .contentShape(Rectangle())
                        }
                        .help("Add a glass of \(model.glassML) ml")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.unsitWater)
                    .background(Capsule().fill(Color.unsitWater.opacity(0.12)))
                }
                WaterCups(filled: model.glassesDrunk, goal: model.glassesGoal) { model.setGlasses($0) }
            }
            .font(.system(size: 13))

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
            Toggle("Open at login", isOn: openAtLoginBinding)
            Button("Settings…") {
                openWindow(id: "settings")
                NSApp.activate()
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

// MARK: - Settings

/// A Date binding for a time of day stored as minutes after midnight.
func minuteBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
    Binding(
        get: {
            let m = get()
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        },
        set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            set((c.hour ?? 0) * 60 + (c.minute ?? 0))
        }
    )
}

var openAtLoginBinding: Binding<Bool> {
    Binding(
        get: { SMAppService.mainApp.status == .enabled },
        set: { on in
            if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    )
}

struct WorkdayPickers: View {
    @EnvironmentObject var model: UnsitModel
    var body: some View {
        DatePicker("Workday starts",
                   selection: minuteBinding(get: { model.dayStartMinute },
                                            set: { model.setWorkday(start: $0, end: model.dayEndMinute) }),
                   displayedComponents: .hourAndMinute)
        DatePicker("Workday ends",
                   selection: minuteBinding(get: { model.dayEndMinute },
                                            set: { model.setWorkday(start: model.dayStartMinute, end: $0) }),
                   displayedComponents: .hourAndMinute)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: UnsitModel

    private var waterGoalText: String {
        (Double(model.waterGoalML) / 1000).formatted(.number.precision(.fractionLength(0...2))) + " L"
    }

    var body: some View {
        Form {
            Section {
                WorkdayPickers()
            } header: {
                Text("Workday")
            } footer: {
                Text("Unsit paces your steps and looks for gaps between meetings in these hours.")
                    .foregroundStyle(.secondary)
            }
            Section("Goals") {
                Stepper("Steps a day: \(model.stepGoal.formatted())", value: $model.stepGoal, in: 2_000...30_000, step: 500)
                Stepper("Water a day: \(waterGoalText)", value: $model.waterGoalML, in: 500...5_000, step: 250)
                Picker("Glass size", selection: $model.glassML) {
                    ForEach([200, 250, 330, 500], id: \.self) { Text("\($0) ml").tag($0) }
                }
            }
            Section("General") {
                Toggle("Open at login", isOn: openAtLoginBinding)
            }
            Section("Steps from iPhone") {
                LabeledContent("Last update", value: model.syncText)
                Button("Choose steps file…") { model.chooseStepsFile() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }
}

// MARK: - Floating panel (nudge)

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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
                DayStrip(model: model, height: 16, showTicks: false, allowsHover: false).frame(width: 130)
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
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Check now") { model.refreshSteps() }
                        Button("Choose the file…") { model.chooseStepsFile() }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .padding(.top, 30)
            Text(connected
                 ? "Does that match the Health app? If it shows roughly double, open the shortcut and check that Group By is set to Day."
                 : (model.stepsStatus ?? "Unsit looks for steps.json in iCloud Drive › Shortcuts › Unsit."))
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
            HStack(spacing: 18) {
                WorkdayPickers()
            }
            .padding(.top, 18)
            Toggle("Open Unsit when you log in", isOn: openAtLoginBinding)
                .padding(.top, 18)
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
