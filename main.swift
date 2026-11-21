// MemoryBar — a tiny macOS menu bar app that summarises RAM usage.
// Build with ./build.sh (needs Xcode Command Line Tools). macOS 13+.

import AppKit
import Darwin
import ServiceManagement
import SwiftUI

// MARK: - Reading memory stats

struct MemStats {
    var total: UInt64
    var app: UInt64          // "App Memory" in Activity Monitor
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64       // file-backed + purgeable, reclaimable
    var free: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: Int32      // 1 = normal, 2 = warning, 4 = critical

    var used: UInt64 { app + wired + compressed }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    /// Whatever isn't app, wired, compressed or cached — keeps the bar summing to 100%.
    var remainder: UInt64 {
        let taken = used + cached
        return total > taken ? total - taken : 0
    }

    var pressureLabel: String { pressure >= 4 ? "Critical" : pressure >= 2 ? "Warning" : "Normal" }
    var pressureColor: Color { pressure >= 4 ? .red : pressure >= 2 ? .orange : .green }
    var pressureNSColor: NSColor? { pressure >= 4 ? .systemRed : pressure >= 2 ? .systemOrange : nil }
}

func readStats() -> MemStats? {
    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &vm) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }

    let page = UInt64(vm_kernel_page_size)
    let internalPages = UInt64(vm.internal_page_count)
    let purgeable = UInt64(vm.purgeable_count)

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

    var level: Int32 = 1
    var levelSize = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

    return MemStats(
        total: ProcessInfo.processInfo.physicalMemory,
        app: (internalPages > purgeable ? internalPages - purgeable : 0) * page,
        wired: UInt64(vm.wire_count) * page,
        compressed: UInt64(vm.compressor_page_count) * page,
        cached: (UInt64(vm.external_page_count) + purgeable) * page,
        free: UInt64(vm.free_count) * page,
        swapUsed: swap.xsu_used,
        swapTotal: swap.xsu_total,
        pressure: level
    )
}

struct ProcInfo: Identifiable {
    let name: String
    let bytes: UInt64
    let iconPath: String?    // .app bundle path, if the process lives in one
    var id: String { name }
}

/// Top processes by resident memory, grouped by app name (so all Chrome helpers add up).
func topProcesses(limit: Int = 6) -> [ProcInfo] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "rss=,comm="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()

    var totals: [String: UInt64] = [:]
    var bundles: [String: String] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " "),
              let kb = UInt64(trimmed[..<space]) else { continue }
        let path = trimmed[space...].trimmingCharacters(in: .whitespaces)
        let (name, bundle) = groupName(for: path)
        totals[name, default: 0] += kb * 1024
        if let bundle { bundles[name] = bundle }
    }
    return totals.sorted { $0.value > $1.value }
        .prefix(limit)
        .map { ProcInfo(name: $0.key, bytes: $0.value, iconPath: bundles[$0.key]) }
}

/// "/Applications/Google Chrome.app/.../Google Chrome Helper (Renderer)" -> ("Google Chrome", "/Applications/Google Chrome.app")
func groupName(for path: String) -> (String, String?) {
    if let range = path.range(of: ".app/") {
        let appPath = String(path[..<range.lowerBound])
        return ((appPath as NSString).lastPathComponent, appPath + ".app")
    }
    return ((path as NSString).lastPathComponent, nil)
}

func gb(_ bytes: UInt64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
}

// MARK: - Model

enum DisplayMode: String, CaseIterable {
    case percent = "Percent used"
    case used = "GB used"
    case free = "GB available"
    case iconOnly = "Icon only"
}

final class MemModel: ObservableObject {
    static let historyLength = 60   // 60 samples × 2 s = 2 minutes

    // Not @Published: sampling happens every 2 s even with the popover closed, and
    // publishing would make SwiftUI re-render a hidden view. We notify only when visible.
    private(set) var stats: MemStats?
    private(set) var history: [Double] = []
    var isVisible = false { didSet { if isVisible { objectWillChange.send() } } }
    @Published var top: [ProcInfo] = []
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var mode: DisplayMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            onChange?()
        }
    }
    var onChange: (() -> Void)?

    init() {
        mode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .percent
    }

    func sample() {
        guard let s = readStats() else { return }
        if isVisible { objectWillChange.send() }
        stats = s
        history.append(s.usedFraction)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        onChange?()
    }

    func refreshTop() {
        DispatchQueue.global(qos: .userInitiated).async {
            let procs = topProcesses()
            DispatchQueue.main.async { self.top = procs }
        }
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login setting"
            alert.informativeText = "\(error.localizedDescription)\n\nMove MemoryBar.app into /Applications and try again, or add it under System Settings → General → Login Items."
            alert.runModal()
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Menu bar icon

/// Apple's own "memorychip" SF Symbol, as a template so it follows the menu bar's
/// light/dark appearance. Tinted orange/red via contentTintColor under memory pressure.
let menuBarIcon: NSImage? = {
    let img = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Memory")?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    img?.isTemplate = true
    return img
}()

// MARK: - Popover UI

private let segmentColors: [(String, Color)] = [
    ("App", .blue), ("Wired", .orange), ("Compressed", .purple), ("Cached", .teal), ("Free", Color.primary.opacity(0.12)),
]

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 10)) }
        }
        .foregroundStyle(.secondary)
    }
}

struct MemoryBar: View {
    let fractions: [Double]
    var body: some View {
        GeometryReader { g in
            let gap: CGFloat = 1.5
            let usable = max(0, g.size.width - gap * CGFloat(fractions.count - 1))
            HStack(spacing: gap) {
                ForEach(fractions.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segmentColors[i].1.gradient)
                        .frame(width: usable * CGFloat(fractions[i]))
                }
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .animation(.easeInOut(duration: 0.4), value: fractions)
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let pts = points(in: g.size)
            ZStack {
                Path { p in
                    for f in [0.25, 0.5, 0.75] {
                        let y = g.size.height * (1 - f)
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: g.size.width, y: y))
                    }
                }
                .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))

                    Path { p in p.addLines(pts) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    Circle().fill(color)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .position(pts[pts.count - 1])
                } else {
                    Text("Collecting…").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Fixed 0–100% scale; the line grows in from the right as samples arrive.
    private func points(in size: CGSize) -> [CGPoint] {
        let n = MemModel.historyLength
        let step = size.width / CGFloat(n - 1)
        let offset = n - values.count
        let h = size.height - 4
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i + offset) * step, y: 2 + h * (1 - CGFloat(v)))
        }
    }
}

struct AppIcon: View {
    let path: String?
    var body: some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
        }
    }
}

struct ProcRow: View {
    let proc: ProcInfo
    let total: UInt64
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(path: proc.iconPath)
            Text(proc.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(gb(proc.bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
        .onHover { hover = $0 }
    }
}

struct PopoverView: View {
    @ObservedObject var model: MemModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = model.stats {
                header(s)
                breakdown(s)
                history(s)
                topApps(s)
            } else {
                Text("Couldn't read memory stats").foregroundStyle(.secondary)
            }
            footer
        }
        .padding(12)
        .frame(width: 336)
    }

    private func header(_ s: MemStats) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory").font(.system(size: 13, weight: .semibold))
                Text("\(gb(s.used)) of \(gb(s.total)) used")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int((s.usedFraction * 100).rounded()))")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("%").font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func breakdown(_ s: MemStats) -> some View {
        let parts = [s.app, s.wired, s.compressed, s.cached, s.remainder]
        let t = Double(max(s.total, 1))
        return Card {
            HStack {
                SectionLabel(text: "Breakdown")
                pressurePill(s)
            }
            MemoryBar(fractions: parts.map { Double($0) / t })
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(0..<3) { row in
                    GridRow {
                        legend(row * 2, parts)
                        if row * 2 + 1 < parts.count { legend(row * 2 + 1, parts) }
                        else { swapLegend(s) }
                    }
                }
            }
        }
    }

    private func legend(_ i: Int, _ parts: [UInt64]) -> some View {
        HStack(spacing: 6) {
            Circle().fill(segmentColors[i].1).frame(width: 7, height: 7)
            Text(segmentColors[i].0).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Text(gb(parts[i])).monospacedDigit()
        }
        .font(.system(size: 11))
    }

    private func swapLegend(_ s: MemStats) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary).frame(width: 7)
            Text("Swap").foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(gb(s.swapUsed)).monospacedDigit()
        }
        .font(.system(size: 11))
    }

    private func pressurePill(_ s: MemStats) -> some View {
        HStack(spacing: 4) {
            Circle().fill(s.pressureColor).frame(width: 6, height: 6)
            Text(s.pressureLabel)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(s.pressureColor.opacity(0.15)))
        .help("Memory pressure")
    }

    private func history(_ s: MemStats) -> some View {
        Card {
            SectionLabel(text: "Used", trailing: "last 2 min · 0–100%")
            Sparkline(values: model.history, color: s.pressure >= 2 ? s.pressureColor : .accentColor)
                .frame(height: 46)
        }
    }

    private func topApps(_ s: MemStats) -> some View {
        Card {
            SectionLabel(text: "Top apps")
            VStack(spacing: 1) {
                if model.top.isEmpty {
                    Text("Loading…").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(model.top) { ProcRow(proc: $0, total: s.total) }
            }
            .padding(.horizontal, -6)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            } label: {
                Label("Activity Monitor", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(.borderless)

            Spacer()

            Menu {
                Picker("Show in menu bar", selection: $model.mode) {
                    ForEach(DisplayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Divider()
                Button("Quit MemoryBar") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = MemModel()
    private var timer: Timer?
    private var ticks = 0
    private var lastStatusKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = menuBarIcon
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        model.onChange = { [weak self] in self?.updateStatusItem() }
        tick()
        let t = Timer(timeInterval: 2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.5   // lets macOS batch wake-ups with other work, saving power
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        model.sample()
        ticks += 1
        if popover.isShown && ticks % 2 == 0 { model.refreshTop() }
    }

    private func updateStatusItem() {
        guard let s = model.stats, let button = statusItem.button else { return }
        let text: String
        switch model.mode {
        case .percent: text = String(format: "%.0f%%", s.usedFraction * 100)
        case .used:    text = gb(s.used)
        case .free:    text = gb(s.total > s.used ? s.total - s.used : 0)
        case .iconOnly:   text = ""
        }
        // Only touch the menu bar when something visible changed (most ticks change nothing).
        let key = "\(text)|\(s.pressure)"
        if key == lastStatusKey { return }
        lastStatusKey = key

                button.contentTintColor = s.pressureNSColor
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .baselineOffset: 0.5,
        ]
        if let c = s.pressureNSColor { attrs[.foregroundColor] = c }
        button.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " " + text, attributes: attrs)
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.sample()
            model.refreshTop()
            model.loginEnabled = SMAppService.mainApp.status == .enabled
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) { model.isVisible = true }
    func popoverDidShow(_ notification: Notification) { statusItem.button?.highlight(true) }
    func popoverDidClose(_ notification: Notification) {
        model.isVisible = false
        model.top = []   // drop cached app icons while closed
        statusItem.button?.highlight(false)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
