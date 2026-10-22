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
            ioSection(title: "Réseau", rates: (model.netIn, model.netOut),
                      layers: [GraphLayer(series: model.hNetIn, color: .green),
                               GraphLayer(series: model.hNetOut, color: .orange)])
            Divider()
            HStack(alignment: .top, spacing: 0) {
                memorySection
                Divider()
                ioSection(title: "Disque", rates: (model.diskRead, model.diskWrite),
                          layers: [GraphLayer(series: model.hDiskR, color: .teal),
                                   GraphLayer(series: model.hDiskW, color: .pink)],
                          stacked: true,
                          footer: model.diskSpace.map { "\(Format.bytes($0.free)) libres" })
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
                Legend(color: .blue, text: "Utilisateur \(Format.percent(model.cpuUser))")
                Legend(color: .red, text: "Système \(Format.percent(model.cpuSys))")
                if let g = model.gpu {
                    Legend(color: .purple, text: "GPU \(Format.percent(g))")
                }
                Spacer(minLength: 0)
                if let l = model.load.first {
                    Text("Charge \(String(format: "%.1f", l))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Charge moyenne 1, 5, 15 min : " + model.load.map { String(format: "%.1f", $0) }.joined(separator: " "))
                }
            }
            Graph(layers: [GraphLayer(series: model.hTotal, color: .red),
                           GraphLayer(series: model.hUser, color: .blue),
                           GraphLayer(series: model.hGPU, color: .purple, fill: false)],
                  maxValue: 1)
            CoreBars(cores: model.cores)
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
            SectionHeader(title: "Mémoire", value: Format.bytes(m.used))
            SegmentBar(segments: [(Double(m.app) / total, .blue),
                                  (Double(m.wired) / total, .orange),
                                  (Double(m.compressed) / total, .purple),
                                  (Double(m.cached) / total, .gray.opacity(0.5))])
            VStack(alignment: .leading, spacing: 2) {
                Legend(color: .blue, text: "Apps \(Format.bytes(m.app))")
                Legend(color: .orange, text: "Câblée \(Format.bytes(m.wired))")
                Legend(color: .purple, text: "Compressée \(Format.bytes(m.compressed))")
            }
            Graph(layers: [GraphLayer(series: model.hMem, color: .blue)], maxValue: 1, height: 32)
            Text("Sur \(Format.bytes(m.total)) · Swap \(Format.bytes(m.swapUsed))")
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

    /// `stacked`: one rate per line, for the half-width disk section.
    private func ioSection(title: String, rates: (down: Double, up: Double), layers: [GraphLayer],
                           stacked: Bool = false, footer: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            let legends = Group {
                Legend(color: layers[0].color, text: "↓ \(Format.rate(rates.down))")
                Legend(color: layers[1].color, text: "↑ \(Format.rate(rates.up))")
            }
            if stacked {
                VStack(alignment: .leading, spacing: 2) { legends }
            } else {
                HStack(spacing: 10) { legends }
            }
            Graph(layers: layers, minScale: 16 * 1024, mirrored: true, height: stacked ? 32 : 40)
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
                Switch(selection: $model.groupApps, options: [(true, "Apps"), (false, "Processus")])
                Spacer(minLength: 4)
                Switch(selection: $model.procWindow, options: ProcWindow.options)
                    .help("Moyenne du CPU sur cette durée")
                Spacer(minLength: 4)
                Switch(selection: $model.sortByMemory, options: [(false, "CPU"), (true, "Mém.")])
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 2)

            // Fixed slots: each tick updates the rows in place instead of
            // rebuilding and animating the list.
            VStack(spacing: 0) {
                ForEach(0..<PanelModel.rowCount, id: \.self) { i in
                    if i < model.rows.count {
                        let row = model.rows[i]
                        ProcessRowView(row: row, sortByMemory: model.sortByMemory) { force in
                            model.kill(row, force: force)
                        }
                    } else {
                        Color.clear.frame(height: ProcessRowView.height)
                    }
                }
            }

            if model.hiddenProcs > 0 {
                Text("\(model.hiddenProcs) processus système non lisibles sans privilèges")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .help("Processus d'autres utilisateurs (root). Leur conso est incluse dans le total CPU.")
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 2) {
            IconButton("waveform.path.ecg", tooltip: "Ouvrir le Moniteur d'activité") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Menu {
                Picker("Fenêtre de l'icône", selection: $model.iconWindow) {
                    ForEach([2, 6, 10, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
                Toggle("Lancer au démarrage", isOn: $model.launchAtLogin)
                Divider()
                if let update = model.update {
                    Button("Installer Monibar \(update.version)") { model.installUpdate() }
                }
                Button("Rechercher les mises à jour") { model.checkForUpdates() }
                Text("Monibar \(UpdateChecker.currentVersion)")
            } label: {
                IconGlyph(systemName: model.update == nil ? "gearshape" : "arrow.down.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: IconButton<IconGlyph>.size.width, height: IconButton<IconGlyph>.size.height)
            .help("Réglages")

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
                    .help("Durée d'historique des graphes")
                    .transition(.opacity)
            }
            Spacer()
            IconButton("power", tooltip: "Quitter") { NSApp.terminate(nil) }
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
        .onHover { h in
            hover = h
            if !h { withAnimation(Motion.resize) { confirm = false } }
        }
    }

    private var killButton: some View {
        Button {
            if confirm {
                confirm = false
                onKill(NSEvent.modifierFlags.contains(.option))
            } else {
                withAnimation(Motion.resize) { confirm = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(Motion.resize) { confirm = false }
                }
            }
        } label: {
            if confirm {
                Text("Quitter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .transition(.opacity)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(hover ? .secondary : .quaternary)
                    .frame(width: 16, height: 16)
                    .transition(.opacity)
            }
        }
        .buttonStyle(.plain)
        .help(row.isApp ? "Quitter l'app (⌥ pour forcer)" : "Envoyer SIGTERM (⌥ pour SIGKILL)")
    }
}
