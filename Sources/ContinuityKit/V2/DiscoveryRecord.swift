import Foundation

/// The decoded Bonjour TXT record for one Continuity v2 app instance.
public struct ContinuityV2DiscoveryRecord: Equatable, Sendable {
    public static let serviceType = "_pvcontinuity._tcp"

    public enum App: String, Sendable {
        case provenance, ifly, icube
    }

    public enum Capability: String, Sendable {
        case library = "l"
        case handoff = "c"
        case saves = "s"
    }

    public let app: App
    public let peerID: String
    public let deviceType: String?
    public let capabilities: Set<Capability>
    /// Compact PVSystems identifiers, in advertised order.
    public let systems: [String]
    public let catalogueVersionPrefix: String?
    /// Untrusted connection candidates. Transport must enforce LAN-only access.
    public let origins: [URL]
    private let originStrings: [String]
    public let runningGame: RunningGame?

    public struct RunningGame: Equatable, Sendable {
        public let system: String
        public let key: String
        public let title: String
    }

    /// Decodes individual UTF-8 TXT items before dictionary conversion can hide duplicates.
    public init?(txtItems: [Data]) {
        var fields: [String: String] = [:]
        for item in txtItems {
            guard item.count <= 255, let text = String(data: item, encoding: .utf8) else { return nil }
            let pair = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pair.first.map(String.init), Self.isKnown(key) else { continue }
            guard pair.count == 2, fields.updateValue(String(pair[1]), forKey: key) == nil else { return nil }
        }

        guard fields["v"] == "2", let app = fields["app"].flatMap(App.init(rawValue:)),
              let pid = fields["pid"], Self.isLowerHex(pid, digits: 64) else { return nil }
        self.app = app
        self.peerID = pid
        self.deviceType = fields["dt"].flatMap { ["ip", "pd", "tv", "mc"].contains($0) ? $0 : nil }
        self.capabilities = Set((fields["cap"] ?? "").compactMap { Capability(rawValue: String($0)) })

        let systemKeys = fields.keys.filter { $0.hasPrefix("sys") }
        var systems: [String] = []
        for index in 0..<systemKeys.count {
            let key = index == 0 ? "sys" : "sys\(index)"
            guard let value = fields[key], value.utf8.count <= 240 else { return nil }
            let identifiers = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard identifiers.allSatisfy(Self.isCompactSystem) else { return nil }
            systems.append(contentsOf: identifiers)
        }
        self.systems = systems

        if let prefix = fields["cv"], !Self.isLowerHex(prefix, digits: 8) { return nil }
        self.catalogueVersionPrefix = fields["cv"]

        let originCount = (0..<4).filter { fields["u\($0)"] != nil }.count
        var origins: [URL] = []
        for index in 0..<originCount {
            guard let value = fields["u\(index)"], let components = URLComponents(string: value),
                  components.scheme == "http", let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  components.path.isEmpty, components.query == nil, components.fragment == nil,
                  let url = components.url else { return nil }
            let normalizedHost = host.lowercased()
            if normalizedHost.hasSuffix(".local") || normalizedHost.hasSuffix(".local.") {
                guard index == originCount - 1 else { return nil }
            }
            origins.append(url)
        }
        self.origins = origins
        self.originStrings = (0..<originCount).compactMap { fields["u\($0)"] }

        if fields["gs"] != nil || fields["gk"] != nil || fields["gt"] != nil {
            guard capabilities.contains(.handoff), let system = fields["gs"], Self.isCompactSystem(system),
                  let key = fields["gk"], !key.isEmpty, let title = fields["gt"] else { return nil }
            self.runningGame = RunningGame(system: system, key: key, title: title)
        } else {
            self.runningGame = nil
        }
    }

    /// Encodes recognized fields as UTF-8 TXT items without DNS length octets.
    public var txtItems: [Data] {
        var items = ["v=2", "app=\(app.rawValue)", "pid=\(peerID)"]
        if let deviceType { items.append("dt=\(deviceType)") }
        if !capabilities.isEmpty {
            items.append("cap=\(capabilities.map(\.rawValue).sorted().joined())")
        }
        var chunks: [String] = []
        for system in systems {
            if let last = chunks.last, last.utf8.count + 1 + system.utf8.count <= 240 {
                let index = chunks.count - 1
                let keyLength = index == 0 ? 3 : 3 + String(index).utf8.count
                if keyLength + 1 + last.utf8.count + 1 + system.utf8.count <= 255 {
                    chunks[index] += "," + system
                    continue
                }
            }
            chunks.append(system)
        }
        for (index, chunk) in chunks.enumerated() {
            let key = index == 0 ? "sys" : "sys\(index)"
            items.append("\(key)=\(chunk)")
        }
        if let catalogueVersionPrefix { items.append("cv=\(catalogueVersionPrefix)") }
        for (index, origin) in originStrings.enumerated() {
            items.append("u\(index)=\(origin)")
        }
        if let runningGame {
            items += ["gs=\(runningGame.system)", "gk=\(runningGame.key)", "gt=\(runningGame.title)"]
        }
        return items.map { Data($0.utf8) }
    }

    private static func isKnown(_ key: String) -> Bool {
        if ["v", "app", "pid", "dt", "cap", "sys", "cv", "u0", "u1", "u2", "u3", "gs", "gk", "gt"].contains(key) {
            return true
        }
        guard key.hasPrefix("sys") else { return false }
        let suffix = key.dropFirst(3).utf8
        return suffix.first.map { (49...57).contains($0) } == true && suffix.allSatisfy { (48...57).contains($0) }
    }

    private static func isLowerHex(_ value: String, digits: Int) -> Bool {
        value.utf8.count == digits && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isCompactSystem(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("com.provenance.") && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
