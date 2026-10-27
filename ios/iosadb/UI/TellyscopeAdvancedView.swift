// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TellyscopeCore

struct TellyscopeAdvancedView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: TVSnapshot?
    @State private var advanced: TVAdvancedSnapshot?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let failure {
                        TellyscopeCard {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    telemetry
                    network
                    processes
                    access
                    peripherals
                }
                .padding(16)
            }
            .background(TellyscopeStyle.background)
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading || model.isBusy)
                }
            }
            .overlay { if loading { ProgressView("Reading TV").padding().background(.regularMaterial, in: Capsule()) } }
            .task { await refresh() }
            .refreshable { await refresh() }
        }
        .tint(TellyscopeStyle.accent)
    }

    private var telemetry: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("TV details").font(.headline)
                row("Model", snapshot?.model)
                row("Manufacturer", snapshot?.manufacturer)
                row("Brand", snapshot?.brand)
                row("Android", snapshot?.androidVersion.map { version in snapshot?.sdk.map { "\(version) (API \($0))" } ?? version })
                row("Security patch", snapshot?.securityPatch)
                row("Uptime", snapshot?.uptimeSeconds.map(Self.uptime))
                row("Storage", snapshot.flatMap { totalUsed($0.storageUsedBytes, $0.storageTotalBytes) })
                row("Free storage", snapshot?.storageFreeBytes.map(Self.bytes))
                row("Memory", snapshot.flatMap { totalUsed($0.memoryUsedBytes, $0.memoryTotalBytes) })
                row("CPU", snapshot?.cpuPercent.map { String(format: "%.1f%%", $0) })
                row("Temperature", snapshot?.temperatureCelsius.map { String(format: "%.1f°C", $0) })
            }
        }
    }

    private var network: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Network").font(.headline)
                row("Traffic rate", snapshot?.networkBytesPerSecond.map { "\(Self.bytes(Int64($0)))/s" })
                if let interfaces = snapshot?.networkInterfaces {
                    if interfaces.isEmpty { Text("No network interfaces reported").foregroundStyle(.secondary) }
                    ForEach(interfaces, id: \.name) { item in
                        Divider()
                        Text(item.name).font(.subheadline.weight(.semibold))
                        row("Addresses", item.addresses.isEmpty ? nil : item.addresses.joined(separator: ", "))
                        row("Received", Self.bytes(item.rxBytes))
                        row("Sent", Self.bytes(item.txBytes))
                    }
                } else { unavailable("Network interface details are unavailable") }
                Divider()
                Text("App traffic since boot").font(.subheadline.weight(.semibold))
                if let traffic = advanced?.trafficByUID {
                    let rows = trafficRows(traffic)
                    if rows.isEmpty { Text("No per-app traffic reported").foregroundStyle(.secondary) }
                    ForEach(rows, id: \.uid) { row in
                        HStack {
                            Text(row.name).lineLimit(1)
                            Spacer()
                            Text("↓ \(Self.bytes(row.rx))  ↑ \(Self.bytes(row.tx))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } else { unavailable("Per-app traffic is unavailable") }
                Divider()
                Text("Open connections").font(.subheadline.weight(.semibold))
                if let connections = advanced?.connections {
                    if connections.isEmpty { Text("No open connections reported").foregroundStyle(.secondary) }
                    ForEach(Array(connections.prefix(40).enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.packageName ?? "Android system").lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(item.address):\(item.port)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if connections.count > 40 { Text("Showing 40 of \(connections.count)").font(.caption).foregroundStyle(.secondary) }
                } else { unavailable("Open connections are unavailable") }
            }
        }
    }

    private var processes: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Processes").font(.headline)
                if let processes = advanced?.processes {
                    if processes.isEmpty { Text("No processes reported").foregroundStyle(.secondary) }
                    ForEach(Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(30)), id: \.pid) { process in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(process.packageName ?? process.name).lineLimit(1)
                                Text("PID \(process.pid) · \(process.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(String(format: "%.1f%%", process.cpuPercent)).font(.caption.monospacedDigit())
                            Text(Self.bytes(process.rssBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } else { unavailable("Process details are unavailable") }
            }
        }
    }

    private var access: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("ADB access").font(.headline)
                Text("Allowed computers").font(.subheadline.weight(.semibold))
                if let keys = advanced?.allowedADBKeys {
                    if keys.isEmpty { Text("No allowed keys reported").foregroundStyle(.secondary) }
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(key.name ?? "Computer").font(.subheadline)
                            Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                            if let seen = key.lastSeenMilliseconds {
                                Text("TV-reported last connection: \(Date(timeIntervalSince1970: Double(seen) / 1000), style: .date)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } else { unavailable("This Android version does not report its allowed-key list") }
                Divider()
                Text("Connected ADB clients").font(.subheadline.weight(.semibold))
                if let clients = advanced?.connectedADBClients {
                    if clients.isEmpty { Text("No connected clients reported").foregroundStyle(.secondary) }
                    ForEach(Array(clients.enumerated()), id: \.offset) { _, client in
                        row("\(client.address):\(client.port)", "Connected")
                    }
                } else { unavailable("Connected clients are unavailable") }
                Divider()
                Text("To remove an allowed computer, use the TV’s Settings → Developer options → Revoke USB debugging authorizations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var peripherals: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paired Bluetooth devices").font(.headline)
                if let devices = advanced?.pairedPeripherals {
                    if devices.isEmpty { Text("No paired devices reported").foregroundStyle(.secondary) }
                    ForEach(devices, id: \.self) { Label($0, systemImage: "dot.radiowaves.left.and.right") }
                } else { unavailable("Bluetooth device details are unavailable") }
            }
        }
    }

    @MainActor private func refresh() async {
        guard !loading, !model.isBusy else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let executor = try model.portExecutor()
            let reader = TVSnapshotReader(executor: executor, adbPort: Int(model.currentDevice?.port ?? 0))
            snapshot = try await reader.read()
            advanced = await reader.advanced()
        } catch {
            snapshot = nil
            advanced = nil
            failure = error.localizedDescription
        }
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? "—").multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func unavailable(_ message: String) -> some View { Text(message).font(.subheadline).foregroundStyle(.secondary) }

    private func trafficRows(_ traffic: [Int: TVTraffic]) -> [(uid: Int, name: String, rx: Int64, tx: Int64)] {
        let packageUIDs = advanced?.packageUIDs ?? [:]
        let rows: [(uid: Int, name: String, rx: Int64, tx: Int64)] = traffic.map { uid, value in
            (uid: uid, name: packageUIDs[uid]?.first ?? "UID \(uid)", rx: value.rxBytes, tx: value.txBytes)
        }
        return Array(rows.sorted { $0.rx + $0.tx > $1.rx + $1.tx }.prefix(20))
    }

    private func totalUsed(_ used: Int64?, _ total: Int64?) -> String? {
        guard let used, let total else { return nil }
        return "\(Self.bytes(used)) of \(Self.bytes(total))"
    }

    private static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    private static func uptime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400, hours = (total / 3_600) % 24, minutes = (total / 60) % 60
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }
}
