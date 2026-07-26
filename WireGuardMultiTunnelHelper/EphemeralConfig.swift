import Foundation

enum EphemeralConfigError: Error, Equatable {
    case missingPeerEndpoint
}

enum EphemeralConfig {
    private static let amneziaKeys: Set<String> = [
        "Jc", "Jmin", "Jmax", "S1", "S2", "H1", "H2", "H3", "H4",
    ]

    static func rewrite(configText: String, profile: StealthProfile, localEndpoint: String?) throws -> String {
        var rewriter = Rewriter(profile: profile, localEndpoint: localEndpoint)
        try rewriter.process(configText: configText)
        return rewriter.result
    }

    private static func amneziaLines(from settings: AmneziaSettings) -> [String] {
        [
            "Jc = \(settings.jc)",
            "Jmin = \(settings.jmin)",
            "Jmax = \(settings.jmax)",
            "S1 = \(settings.s1)",
            "S2 = \(settings.s2)",
            "H1 = \(settings.h1)",
            "H2 = \(settings.h2)",
            "H3 = \(settings.h3)",
            "H4 = \(settings.h4)",
        ]
    }

    private static func iniKey(from trimmedLine: String) -> String? {
        guard let equals = trimmedLine.firstIndex(of: "=") else { return nil }
        let key = trimmedLine[..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private struct Rewriter {
        let profile: StealthProfile
        let localEndpoint: String?
        var output: [String] = []
        var section = ""
        var injectedAmnezia = false
        var rewrittenEndpoint = false

        var result: String {
            output.joined(separator: "\n")
        }

        mutating func process(configText: String) throws {
            let lines = configText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for line in lines {
                handle(line: line)
            }
            flushAmneziaIfNeeded()
            insertEndpointIfMissing()
            if localEndpoint != nil, !rewrittenEndpoint {
                throw EphemeralConfigError.missingPeerEndpoint
            }
        }

        mutating func handle(line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                flushAmneziaIfNeeded()
                insertEndpointIfMissing()
                enterSection(String(trimmed.dropFirst().dropLast()))
                output.append(line)
                return
            }
            if trimmed.isEmpty {
                flushAmneziaIfNeeded()
                output.append(line)
                return
            }
            if shouldDropAmneziaKey(trimmed) {
                return
            }
            if rewriteEndpointIfNeeded(trimmed) {
                return
            }
            output.append(line)
        }

        mutating func enterSection(_ name: String) {
            section = name
        }

        mutating func flushAmneziaIfNeeded() {
            guard section == "Interface", profile.amnezia.enabled, !injectedAmnezia else { return }
            output.append(contentsOf: EphemeralConfig.amneziaLines(from: profile.amnezia))
            injectedAmnezia = true
        }

        mutating func insertEndpointIfMissing() {
            guard section == "Peer", let localEndpoint, !rewrittenEndpoint else { return }
            output.append("Endpoint = \(localEndpoint)")
            rewrittenEndpoint = true
        }

        func shouldDropAmneziaKey(_ trimmed: String) -> Bool {
            guard section == "Interface", profile.amnezia.enabled,
                  let key = EphemeralConfig.iniKey(from: trimmed)
            else { return false }
            return amneziaKeys.contains(key)
        }

        mutating func rewriteEndpointIfNeeded(_ trimmed: String) -> Bool {
            guard section == "Peer",
                  let key = EphemeralConfig.iniKey(from: trimmed),
                  key == "Endpoint",
                  let localEndpoint
            else { return false }
            output.append("Endpoint = \(localEndpoint)")
            rewrittenEndpoint = true
            return true
        }
    }
}
