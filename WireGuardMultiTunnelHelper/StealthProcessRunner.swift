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
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        let termDeadline = Date().addingTimeInterval(0.5)
        while Date() < termDeadline {
            if reapIfChildExited(pid: pid) {
                return
            }
            if !isAlive(pid: pid) {
                _ = reapIfChildExited(pid: pid)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isAlive(pid: pid) {
            kill(pid, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.2)
            while Date() < killDeadline {
                if reapIfChildExited(pid: pid) {
                    return
                }
                if !isAlive(pid: pid) {
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        _ = reapIfChildExited(pid: pid)
    }

    /// Reap a child if it has exited. Returns true when waitpid collected the pid.
    /// Non-child PIDs (stale from a prior helper) yield ECHILD — treat as best-effort.
    private func reapIfChildExited(pid: Int32) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == pid
    }

    func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}
