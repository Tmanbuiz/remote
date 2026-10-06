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
    let nickname: String?
    let host: String
    let macAddress: String?

    /// What the user renamed this set to, falling back to what it reports.
    /// Mirrors TvDevice.displayName in lib/core/tv_device.dart — Siri matches
    /// on this, which is the point of letting them rename it at all.
    var displayName: String {
        if let nickname, !nickname.trimmingCharacters(in: .whitespaces).isEmpty {
            return nickname.trimmingCharacters(in: .whitespaces)
        }
        return name
    }

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
            let bytes = [UInt8](packet)
            for _ in 0..<3 {
                let result = withUnsafePointer(to: &address) { pointer -> Int in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        sendto(handle, bytes, bytes.count, 0,
                               sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if result > 0 { sent = true }
            }
        }
        return sent
    }
}

// MARK: - A saved TV, as something Siri can name

/// Exposes the saved TVs to Siri so a phrase can pick one.
///
/// Without this there is a single "my TV" and it is whichever was used last,
/// which is wrong in a house with more than one set: the phrase you say is
/// identical whether you mean the 43" or the 70".
@available(iOS 16.0, *)
struct TVEntity: AppEntity {
    let id: String
    let name: String
    let macAddress: String?

    init(_ device: SavedDevice) {
        id = device.id
        name = device.displayName
        macAddress = device.macAddress
    }

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "TV")
    static var defaultQuery = TVQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// EntityStringQuery rather than plain EntityQuery: the string form is what
/// lets Siri match the name the user actually said against the saved list.
@available(iOS 16.0, *)
struct TVQuery: EntityStringQuery {
    func entities(for identifiers: [TVEntity.ID]) async throws -> [TVEntity] {
        SavedDevice.all()
            .filter { identifiers.contains($0.id) }
            .map(TVEntity.init)
    }

    /// Matched loosely on purpose. Siri transcribes "the 70 inch" in ways that
    /// will not equal the stored name, so a substring test either way round
    /// beats an exact comparison that fails silently.
    func entities(matching string: String) async throws -> [TVEntity] {
        let needle = string.lowercased()
        return SavedDevice.all()
            .filter {
                let name = $0.displayName.lowercased()
                return name.contains(needle) || needle.contains(name)
            }
            .map(TVEntity.init)
    }

    /// What Siri offers when the phrase names no TV, and what the Shortcuts
    /// app lists in the picker.
    func suggestedEntities() async throws -> [TVEntity] {
        SavedDevice.all().map(TVEntity.init)
    }
}

// MARK: - The intents

@available(iOS 16.0, *)
struct WakeTVIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn on my TV"
    static var description = IntentDescription(
        "Wakes a TV saved in Universal Remote, without opening the app."
    )

    // False is the whole point: this runs with the phone locked.
    static var openAppWhenRun: Bool = false

    /// Optional so the older phrases keep working untouched. Naming no TV
    /// means the last one used, exactly as before; an optional parameter is
    /// never prompted for, so "turn on my TV" still runs without a question.
    @Parameter(title: "TV")
    var tv: TVEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Turn on \(\.$tv)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name: String
        let mac: String?

        if let chosen = tv {
            name = chosen.name
            mac = chosen.macAddress
        } else {
            guard let device = SavedDevice.preferred() else {
                return .result(dialog: "No TV is saved in Universal Remote yet. Open the app and add one first.")
            }
            name = device.displayName
            mac = device.macAddress
        }

        guard let mac, !mac.isEmpty else {
            return .result(dialog: "\(name) has no wake address saved. Open the app while the TV is on, then try again.")
        }
        guard WakeOnLan.send(mac: mac) else {
            return .result(dialog: "Could not send the wake signal to \(name).")
        }
        return .result(dialog: "Turning on \(name).")
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
                // Naming a TV. Siri fills the parameter from TVQuery.
                "Turn on \(\.$tv) with \(.applicationName)",
                "Turn on the \(\.$tv) with \(.applicationName)",
                "Wake \(\.$tv) with \(.applicationName)",
                // Naming none, which still means the TV used last.
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
            systemImageName: "appletvremote.gen4"
        )
    }
}
