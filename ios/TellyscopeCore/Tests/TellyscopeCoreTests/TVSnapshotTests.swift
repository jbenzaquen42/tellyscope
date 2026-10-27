import XCTest
@testable import TellyscopeCore

final class TVSnapshotTests: XCTestCase {
    func testReadKeepsMissingFieldsNilAndParsesReportedValues() async throws {
        let shell = SnapshotShell()
        let snapshot = try await TVSnapshotReader(executor: shell).read()

        XCTAssertEqual(snapshot.model, "Living Room")
        XCTAssertEqual(snapshot.brand, "TCL")
        XCTAssertEqual(snapshot.sdk, 34)
        XCTAssertEqual(snapshot.securityPatch, "2025-03-01")
        XCTAssertEqual(snapshot.storageTotalBytes, 2_000_000 * 1024)
        XCTAssertEqual(snapshot.storageUsedBytes, 1_200_000 * 1024)
        XCTAssertEqual(snapshot.storageFreeBytes, 800_000 * 1024)
        XCTAssertEqual(snapshot.memoryAvailableBytes, 800_000 * 1024)
        XCTAssertEqual(snapshot.memoryUsedBytes, 1_200_000 * 1024)
        XCTAssertEqual(snapshot.temperatureCelsius, 45)
        XCTAssertEqual(snapshot.uptimeSeconds, 12345.67)
        XCTAssertEqual(snapshot.cpuPercent ?? 0, 100.0 * 70 / 170, accuracy: 0.01)
        XCTAssertEqual(abs((snapshot.networkBytesPerSecond ?? 0) - 400) < 100, true)
        XCTAssertEqual(snapshot.networkInterfaces?.first?.addresses, ["192.168.1.20", "fe80::1"])
        XCTAssertEqual(snapshot.networkInterfaces?.first?.rxBytes, 1100)
        XCTAssertNil(snapshot.manufacturer)
        XCTAssertEqual(shell.commands.count, 3)
    }

    func testAdvancedSeparatesUIDTrafficConnectionsADBAccessAndBluetooth() async {
        let shell = SnapshotShell()
        let advanced = await TVSnapshotReader(executor: shell, adbPort: 5555).advanced()

        XCTAssertEqual(advanced.processes?.first?.name, "com.example.video")
        XCTAssertEqual(advanced.processes?.first?.packageName, "com.example.video")
        XCTAssertEqual(advanced.processes?.first?.rssBytes, 10 * 1024 * 1024)
        XCTAssertEqual(advanced.packageUIDs?[10123], ["com.example.video"])
        XCTAssertEqual(advanced.trafficByUID?[10123], TVTraffic(rxBytes: 1024, txBytes: 2048))
        XCTAssertEqual(advanced.connections?.first?.packageName, "com.example.video")
        XCTAssertEqual(advanced.connections?.first?.address, "8.8.8.8")
        XCTAssertEqual(advanced.connectedADBClients?.first?.port, 49153)
        XCTAssertEqual(advanced.allowedADBKeys?.first?.name, "alice@phone")
        XCTAssertFalse(advanced.allowedADBKeys?.first?.fingerprint.contains("QAAAA") ?? true)
        XCTAssertEqual(advanced.pairedPeripherals, ["Living Room Remote"])
        XCTAssertEqual(shell.commands.count, 1)
    }
}

private final class SnapshotShell: ShellExecutor {
    private(set) var commands: [String] = []

    func run(_ command: String) async throws -> ShellResult {
        commands.append(command)
        if command.contains("df -k /data") {
            return ShellResult(output: """
                [ro.product.model]: [Living Room]
                [ro.product.brand]: [TCL]
                [ro.build.version.sdk]: [34]
                [ro.build.version.security_patch]: [2025-03-01]
                @@tellyscope-ios@@
                Filesystem 1K-blocks Used Available Use% Mounted on
                /dev/block/dm-0 2000000 1200000 800000 60% /data
                @@tellyscope-ios@@
                12345.67 0.00
                @@tellyscope-ios@@
                soc=45000
                """, exitCode: 0)
        }
        if command.contains("cat /proc/stat") && command.contains("cat /proc/meminfo") {
            return ShellResult(output: """
                cpu 100 0 50 800 10 0 0 0
                @@tellyscope-ios@@
                MemTotal: 2000000 kB
                MemAvailable: 800000 kB
                @@tellyscope-ios@@
                Inter-| Receive | Transmit
                 wlan0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0
                """, exitCode: 0)
        }
        if command.contains("ip -o addr show") {
            return ShellResult(output: """
                cpu 150 0 70 900 10 0 0 0
                @@tellyscope-ios@@
                Inter-| Receive | Transmit
                 wlan0: 1100 0 0 0 0 0 0 0 2100 0 0 0 0 0 0 0
                @@tellyscope-ios@@
                2: wlan0 inet 192.168.1.20/24 scope global wlan0
                2: wlan0 inet6 fe80::1/64 scope link
                """, exitCode: 0)
        }
        if command.contains("top -b") {
            return ShellResult(output: """
                PID USER RES %CPU NAME
                123 u0_a123 10M 12.5 com.example.video
                @@tellyscope-advanced@@
                package:com.example.video uid:10123
                @@tellyscope-advanced@@
                UID stats:
                  ident=[{type=1, rat=0, subId=1, networkId=1}, uid=10123]
                    st=1 rb=1024 tb=2048
                @@tellyscope-ios@@
                @@tellyscope-advanced@@
                sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode
                0: 0100007F:1F90 08080808:01BB 01 00000000:00000000 00:00000000 00000000 10123 0 1
                1: 00000000:15B3 0100007F:C001 01 00000000:00000000 00:00000000 00000000 1000 0 2
                @@tellyscope-advanced@@
                debugging_manager {
                  user_keys=QAAAAAA= alice@phone
                }
                @@tellyscope-advanced@@
                5555
                @@tellyscope-advanced@@
                Bonded devices:
                AA:BB:CC:DD:EE:FF [1] Living Room Remote

                """, exitCode: 0)
        }
        return ShellResult(output: "", exitCode: 0)
    }
}
