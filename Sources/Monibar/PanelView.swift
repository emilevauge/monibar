import SwiftUI

/// Popover content, built like Calbar's: full-width dividers between
/// sections, and an icon footer holding the history switch.
struct PanelView: View {
    static let width: CGFloat = 380

    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cpuSection
            Divider()
            ioSection(title: String(localized: "Network"), rates: (model.netIn, model.netOut),
                      layers: [GraphLayer(series: model.hNetIn, color: .green),
                               GraphLayer(series: model.hNetOut, color: .orange)],
                      status: internetStatus, outages: model.hInternet)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                memorySection
                Divider()
                ioSection(title: String(localized: "Disk"), rates: (model.diskRead, model.diskWrite),
                          layers: [GraphLayer(series: model.hDiskR, color: .teal),
                                   GraphLayer(series: model.hDiskW, color: .pink)],
                          stacked: true,
                          space: model.diskSpace)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            processSection
            Divider()
            footer
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        // The popover's material turns nearly see-through while another
        // app is active. An opaque window background keeps it readable.
        .background { Color(nsColor: .windowBackgroundColor).padding(-20) }
    }

    // MARK: CPU

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "CPU", value: Format.percent(model.cpuUser + model.cpuSys))
            HStack(spacing: 10) {
                Legend(color: .blue, text: String(localized: "User \(Format.percent(model.cpuUser))"))
                Legend(color: .red, text: String(localized: "System \(Format.percent(model.cpuSys))"))
                if let g = model.gpu {
                    Legend(color: .purple, text: "GPU \(Format.percent(g))")
                }
                Spacer(minLength: 0)
                if let l = model.load.first {
                    Text("Load \(String(format: "%.1f", l))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(String(localized: "Load average over 1, 5 and 15 min: \(model.load.map { String(format: "%.1f", $0) }.joined(separator: " "))"))
                }
            }
            Graph(layers: [GraphLayer(series: model.hTotal, color: .red),
                           GraphLayer(series: model.hUser, color: .blue),
                           GraphLayer(series: model.hGPU, color: .purple, fill: false)],
                  maxValue: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Memory

    /// Half width, beside the disk: legends one per line.
    private var memorySection: some View {
        let m = model.mem
        let total = Double(max(m.total, 1))
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: String(localized: "Memory"), value: Format.bytes(m.used))
            SegmentBar(segments: [(Double(m.app) / total, .blue),
                                  (Double(m.wired) / total, .orange),
                                  (Double(m.compressed) / total, .purple),
                                  (Double(m.cached) / total, .gray.opacity(0.5))])
            VStack(alignment: .leading, spacing: 2) {
                Legend(color: .blue, text: String(localized: "Apps \(Format.bytes(m.app))"))
                Legend(color: .orange, text: String(localized: "Wired \(Format.bytes(m.wired))"))
                Legend(color: .purple, text: String(localized: "Compressed \(Format.bytes(m.compressed))"))
            }
            Graph(layers: [GraphLayer(series: model.hMem, color: .blue)], maxValue: 1, height: 32)
            Text("Total \(Format.bytes(m.total)) · Swap \(Format.bytes(m.swapUsed))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Network, disk

    /// Internet reachability, shown beside the network title.
    private var internetStatus: (color: Color, text: String)? {
        switch model.internet {
        case .online: (.green, String(localized: "Online"))
        case .noInternet: (.orange, String(localized: "No Internet access"))
        case .offline: (.red, String(localized: "Offline"))
        case .unknown: nil
        }
    }

    /// `stacked`: one rate per line, for the half-width disk section.
    /// `status`: a colored state at the right of the title.
    private func ioSection(title: String, rates: (down: Double, up: Double), layers: [GraphLayer],
                           stacked: Bool = false, footer: String? = nil,
                           status: (color: Color, text: String)? = nil, outages: Series? = nil,
                           space: (free: Int64, total: Int64)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let status {
                    HStack(spacing: 4) {
                        Circle().fill(status.color).frame(width: 7, height: 7)
                        Text(status.text)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.color)
                    .help("Checked every minute, on each network change and when the panel opens")
                } else if let space {
                    Text("\(Format.bytes(space.free)) free")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if let space {
                let total = Double(max(space.total, 1))
                let freeShare = Double(space.free) / total
                // Blue while there is room, orange under 10 % free, red under 5 %.
                let color: Color = freeShare < 0.05 ? .red : freeShare < 0.10 ? .orange : .blue
                SegmentBar(segments: [(1 - freeShare, color)])
                Text("\(Format.bytes(space.total - space.free)) used of \(Format.bytes(space.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            let legends = Group {
                Legend(color: layers[0].color, text: "↓ \(Format.rate(rates.down))")
                Legend(color: layers[1].color, text: "↑ \(Format.rate(rates.up))")
            }
            if stacked {
                VStack(alignment: .leading, spacing: 2) { legends }
            } else {
                HStack(spacing: 10) { legends }
            }
            Graph(layers: layers, minScale: 16 * 1024, mirrored: true, outages: outages,
                  height: stacked ? 32 : 40)
                .help(outages == nil ? "" : String(localized: "Orange background: no Internet access. Red background: offline."))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Processes

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Switch(selection: $model.groupApps, options: [(true, String(localized: "Apps")), (false, String(localized: "Processes"))])
                Spacer(minLength: 4)
                Switch(selection: $model.procWindow, options: ProcWindow.options)
                    .help("CPU averaged over this window")
                Spacer(minLength: 4)
                Switch(selection: $model.sortByMemory, options: [(false, "CPU"), (true, String(localized: "Mem."))])
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 2)

            // Fixed slots: each tick updates the rows in place instead of
            // rebuilding and animating the list.
            VStack(spacing: 0) {
                ForEach(0..<PanelModel.rowCount, id: \.self) { i in
                    if i < model.rows.count {
                        let row = model.rows[i]
                        ProcessRowView(row: row, sortByMemory: model.sortByMemory,
                                       onKill: { force in model.kill(row, force: force) },
                                       onSearch: { model.searchWeb(row) })
                    } else {
                        Color.clear.frame(height: ProcessRowView.height)
                    }
                }
            }

            if model.hiddenProcs > 0 {
                Text("\(model.hiddenProcs) system processes unreadable without privileges")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .help("Processes of other users (root). Their usage is included in the CPU total.")
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 2) {
            IconButton("waveform.path.ecg", tooltip: String(localized: "Open Activity Monitor")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Menu {
                Picker("Icon window", selection: $model.iconWindow) {
                    ForEach([2, 6, 10, 30, 60], id: \.self) { Text(verbatim: "\($0) s").tag($0) }
                }
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Divider()
                if let update = model.update {
                    Button("Install Monibar \(update.version)") { model.installUpdate() }
                }
                Button("Check for updates") { model.checkForUpdates() }
                Text(verbatim: "Monibar \(UpdateChecker.currentVersion)")
            } label: {
                IconGlyph(systemName: model.update == nil ? "gearshape" : "arrow.down.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: IconButton<IconGlyph>.size.width, height: IconButton<IconGlyph>.size.height)
            .help("Settings")

            Spacer()
            // A kill result takes the place of the history switch for 3 s.
            if let msg = model.message {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                Switch(selection: $model.range, options: HistoryRange.allCases.map { ($0, $0.label) })
                    .help("Graph history length")
                    .transition(.opacity)
            }
            Spacer()
            IconButton("power", tooltip: String(localized: "Quit")) { NSApp.terminate(nil) }
        }
        .frame(height: IconButton<IconGlyph>.size.height)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .animation(.easeOut(duration: 0.2), value: model.message)
    }
}

// MARK: - Building blocks

/// Calbar's Day | Week switch: plain segments in a faint rounded box, the
/// selected one on a raised control background.
struct Switch<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let value = options[i].0
                let selected = selection == value
                Button {
                    withAnimation(Motion.resize) { selection = value }
                } label: {
                    Text(options[i].1)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
    }
}

struct IconButton<Label: View>: View {
    static var size: CGSize { CGSize(width: 28, height: 24) }

    let tooltip: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(tooltip: String, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.tooltip = tooltip
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: Self.size.width, height: Self.size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.size.width, height: Self.size.height)
        .help(tooltip)
    }
}

extension IconButton where Label == IconGlyph {
    init(_ systemName: String, tooltip: String, action: @escaping () -> Void) {
        self.init(tooltip: tooltip, action: action) { IconGlyph(systemName: systemName) }
    }
}

/// SF Symbol in the secondary style of the popover chrome.
struct IconGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

struct SectionHeader: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
    }
}

struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct ProcessRowView: View {
    static let height: CGFloat = 26

    let row: ProcRow
    let sortByMemory: Bool
    let onKill: (_ force: Bool) -> Void
    let onSearch: () -> Void

    @State private var hover = false
    @State private var confirm = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16, height: 16)

            Text(row.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if row.count > 1 {
                Text("\(row.count)").font(.caption).foregroundStyle(.tertiary)
            }
            if hover {
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Search the web for what this is")
            }
            Spacer(minLength: 4)
            Text(Format.cpu(row.cpu))
                .frame(width: 46, alignment: .trailing)
                .foregroundStyle(sortByMemory ? .secondary : .primary)
            Text(Format.bytes(row.mem))
                .frame(width: 58, alignment: .trailing)
                .foregroundStyle(sortByMemory ? .primary : .secondary)
            killButton
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background {
            if hover {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Search the web for “\(row.name)”", action: onSearch)
            Divider()
            Button(row.isApp ? String(localized: "Quit") : String(localized: "Terminate (SIGTERM)")) { onKill(false) }
            Button(row.isApp ? String(localized: "Force Quit") : String(localized: "Kill (SIGKILL)")) { onKill(true) }
        }
        .onHover { h in
            hover = h
            if !h { withAnimation(Motion.resize) { confirm = false } }
        }
    }

    /// First click on the cross asks: quit, or force quit for an app that
    /// hangs. The choice goes away after 3 s or when the pointer leaves.
    @ViewBuilder
    private var killButton: some View {
        if confirm {
            HStack(spacing: 4) {
                choice(String(localized: "Force"), fill: Color.red.opacity(0.75),
                       help: row.isApp ? String(localized: "Force the app to quit") : String(localized: "Send SIGKILL")) { onKill(true) }
                choice(String(localized: "Quit"), fill: .red,
                       help: row.isApp ? String(localized: "Quit the app") : String(localized: "Send SIGTERM")) { onKill(false) }
            }
            .transition(.opacity)
        } else {
            Button {
                withAnimation(Motion.resize) { confirm = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(Motion.resize) { confirm = false }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(hover ? .secondary : .quaternary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(row.isApp ? String(localized: "Quit or force quit the app") : String(localized: "Terminate or kill the process"))
            .transition(.opacity)
        }
    }

    private func choice(_ title: String, fill: Color, help: String, action: @escaping () -> Void) -> some View {
        Button {
            confirm = false
            action()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
