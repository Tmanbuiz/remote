import AppIntents
import Foundation

// Siri Shortcuts for Universal Remote.
//
// The intent deliberately does its own work rather than launching the app.
// A shortcut that opens the app to turn on a TV is barely faster than
// tapping the icon; the point is "Hey Siri, turn on my TV" while the phone
// is locked and stays locked.
//
// That constrains what it can do. Roku's ECP-2 control channel needs a full
// authenticated WebSocket handshake, which is not worth reimplementing here.
// Wake-on-LAN is a single UDP broadcast, needs no session, and is precisely
// the case the app cannot otherwise cover — a TV that is off and therefore
// unreachable by every other means.

// MARK: - Reading what the Flutter app saved

/// One saved TV, as persisted by the Dart side.
///
/// shared_preferences writes to NSUserDefaults under a "flutter." prefix, so
/// this reads the same list the app wrote without any extra plumbing. Keep the
/// key in step with DeviceStore._devicesKey in lib/storage/device_store.dart.
struct SavedDevice: Decodable {
    let id: String
    let name: String
    let host: String
    let macAddress: String?

    private static let devicesKey = "flutter.paired_devices_v1"
    private static let lastUsedKey = "flutter.last_used_device_id"

    static func all() -> [SavedDevice] {
        guard let raw = UserDefaults.standard.stringArray(forKey: devicesKey) else { return [] }
        let decoder = JSONDecoder()
        return raw.compactMap { entry in
            guard let data = entry.data(using: .utf8) else { return nil }
            return try? decoder.decode(SavedDevice.self, from: data)
        }
    }

    /// The TV the user last controlled, falling back to the only/first saved one.
    static func preferred() -> SavedDevice? {
        let devices = all()
        if let lastId = UserDefaults.standard.string(forKey: lastUsedKey),
           let match = devices.first(where: { $0.id == lastId }) {
            return match
        }
        return devices.first
    }
}

// MARK: - Wake-on-LAN

enum WakeOnLan {
    /// Six 0xFF bytes followed by the MAC sixteen times. Mirrors
    /// lib/core/wake_on_lan.dart so both platforms send an identical packet.
    static func magicPacket(mac: String) -> Data? {
        let cleaned = mac.filter { $0.isHexDigit }
        guard cleaned.count == 12 else { return nil }

        var octets = [UInt8]()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            octets.append(value)
            index = next
        }
        // An unknown MAC decodes to all zeroes; sending that wakes nothing.
        guard octets.contains(where: { $0 != 0 }) else { return nil }

        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: octets) }
        return packet
    }

    /// Broadcasts the packet. Ports 9 and 7 are both used in the wild.
    ///
    /// Returns true when the packet left the phone, which is the most any
    /// wake-on-LAN implementation can confirm — nothing acknowledges it.
    @discardableResult
    static func send(mac: String) -> Bool {
        guard let packet = magicPacket(mac: mac) else { return false }

        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }

        var enabled: Int32 = 1
        guard setsockopt(handle, SOL_SOCKET, SO_BROADCAST, &enabled,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else { return false }

        var sent = false
        for port in [UInt16(9), UInt16(7)] {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_BROADCAST

            // A lone UDP datagram on busy Wi-Fi is easily dropped, and the
            // packet is idempotent, so repeat rather than hope.
            for _ in 0..<3 {
                let result = packet.withUnsafeBytes { buffer -> Int in
                    withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                            sendto(handle, buffer.baseAddress, packet.count, 0,
                                   sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if result > 0 { sent = true }
            }
        }
        return sent
    }
}

// MARK: - The intent

@available(iOS 16.0, *)
struct WakeTVIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn on my TV"
    static var description = IntentDescription(
        "Wakes the TV saved in Universal Remote, without opening the app."
    )

    // False is the whole point: this runs with the phone locked.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let device = SavedDevice.preferred() else {
            return .result(dialog: "No TV is saved in Universal Remote yet. Open the app and add one first.")
        }
        guard let mac = device.macAddress, !mac.isEmpty else {
            return .result(dialog: "\(device.name) has no wake address saved. Open the app while the TV is on, then try again.")
        }
        guard WakeOnLan.send(mac: mac) else {
            return .result(dialog: "Could not send the wake signal to \(device.name).")
        }
        return .result(dialog: "Turning on \(device.name).")
    }
}

@available(iOS 16.0, *)
struct OpenRemoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Open my remote"
    static var description = IntentDescription("Opens Universal Remote on the saved TV.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

/// Siri needs the app name inside every phrase, otherwise the shortcut is
/// registered but never matches anything the user says.
@available(iOS 16.0, *)
struct RemoteAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WakeTVIntent(),
            phrases: [
                "Turn on my TV with \(.applicationName)",
                "Wake my TV with \(.applicationName)",
                "Turn the TV on with \(.applicationName)"
            ],
            shortTitle: "Turn on my TV",
            systemImageName: "tv"
        )
        AppShortcut(
            intent: OpenRemoteIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Show my remote with \(.applicationName)"
            ],
            shortTitle: "Open my remote",
            systemImageName: "av.remote"
        )
    }
}
