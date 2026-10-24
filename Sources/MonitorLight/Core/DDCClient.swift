import Foundation
import Darwin

struct DisplayInfo: Codable, Identifiable, Equatable {
    let id: UInt32
    let uuid: String
    let name: String
    let ddc: Bool
    /// The helper names unnamed displays with a localization key ("外接显示器").
    var displayName: String { L(name) }
}
struct DDCValue: Codable, Equatable {
    let current: Int
    let maximum: Int
    var percent: Double { Double(current) * 100 / Double(maximum) }
    init(current: Int, maximum: Int) { self.current = current; self.maximum = maximum }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        current = try values.decode(Int.self, forKey: .current)
        maximum = try values.decode(Int.self, forKey: .maximum)
        guard (1...65535).contains(maximum), (0...maximum).contains(current) else {
            throw DecodingError.dataCorruptedError(forKey: .current, in: values, debugDescription: "Invalid display value range")
        }
    }
}
enum Feature: String, CaseIterable {
    case brightness, volume
    var title: String {
        switch self { case .brightness: return L("亮度"); case .volume: return L("显示器音量") }
    }
    var symbol: String {
        switch self { case .brightness: return "sun.max.fill"; case .volume: return "speaker.wave.2.fill" }
    }
}
struct ControlState {
    var value: DDCValue?
    var requested: Double?
    var error: String?
    var isWriting = false
    var percent: Double { requested ?? value?.percent ?? 0 }
}
struct DDCFailure: LocalizedError {
    let message: String
    var writeSent: Bool = false
    var errorDescription: String? { message }
}

/// Every operation, including CLI diagnostics, shares the helper's process lock.
/// Keeping IOKit in a bounded subprocess protects the menu bar from driver stalls.
protocol DDCProviding {
    func perform(_ arguments: [String], completion: @escaping (Result<Data, Error>) -> Void)
}
final class DDCClient: DDCProviding {
    private let queue = DispatchQueue(label: "local.monitorlight.ddc", qos: .userInitiated)
    private let executable: URL
    init(executable: URL? = nil) {
        self.executable = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/monitor-ddc")
    }
    func perform(_ arguments: [String], completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            let result = Result { try self.run(arguments) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    private func run(_ arguments: [String]) throws -> Data {
        do { return try execute(arguments) }
        catch let failure as DDCFailure {
            guard failure.writeSent, arguments.count == 4, arguments[0] == "set",
                  let expected = Int(arguments[3]) else { throw failure }
            // Some display reconfigurations invalidate the originating process's
            // AVService state. A new helper can confirm an already-applied write.
            // Never repeat the write or report success without matching readback.
            for _ in 0..<4 {
                Thread.sleep(forTimeInterval: 0.25)
                if let data = try? execute(["get", arguments[1], arguments[2]], timeout: 1.5),
                   let value = try? JSONDecoder().decode(DDCValue.self, from: data), value.current == expected {
                    return data
                }
            }
            throw failure
        }
    }
    private func execute(_ arguments: [String], timeout: TimeInterval = 8) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
            throw DDCFailure(message: L("显示器响应超时，请检查连接线后重试。"))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // Helper errors are Chinese localization keys; translate them here.
            throw DDCFailure(message: L(json?["error"] as? String ?? "无法连接显示器，请重新检测。"), // i18n-key
                             writeSent: json?["writeSent"] as? Bool == true)
        }
        return data
    }
}
