import Foundation

protocol StealthProcessRunning {
    func start(executable: String, arguments: [String]) throws -> Int32
    func stop(pid: Int32)
    func isAlive(pid: Int32) -> Bool
}

struct StealthToolPaths {
    var awgQuick: String?
    var amneziaGo: String?
    var udp2raw: String?
    var wstunnel: String?
}

enum RealStealthProcessRunner: StealthProcessRunning {
    case shared

    func start(executable: String, arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        return task.processIdentifier
    }

    func stop(pid: Int32) {
        kill(pid, SIGTERM)
    }

    func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}
