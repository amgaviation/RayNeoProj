import AppKit
import CoreServices
import Foundation

/// Sends messages through the Messages app with its public AppleScript interface.
///
/// Each send runs `/usr/bin/osascript` in a child process with the handle and text
/// passed as arguments (never spliced into the script, so message text cannot
/// inject AppleScript), and with a timeout so a stuck Messages can't hang the relay.
enum MessagesSender {
    enum Service: String {
        case iMessage = "iMessage"
        case sms = "SMS"
    }

    enum Outcome: Equatable {
        /// Messages accepted the message.
        case sent
        /// Messages refused it; the text says why.
        case failed(String)
        /// No answer in time. It may or may not have gone out, so never retry blindly.
        case timedOut
    }

    static let messagesBundleID = "com.apple.MobileSMS"

    /// Lines of the AppleScript run by `send`. Internal so tests can compile it.
    static let sendScript = [
        "on run argv",
        "  set targetHandle to item 1 of argv",
        "  set messageText to item 2 of argv",
        "  set serviceName to item 3 of argv",
        "  tell application \"Messages\"",
        "    if serviceName is \"SMS\" then",
        "      set targetAccount to 1st account whose service type = SMS",
        "    else",
        "      set targetAccount to 1st account whose service type = iMessage",
        "    end if",
        "    set targetParticipant to participant targetHandle of targetAccount",
        "    send messageText to targetParticipant",
        "  end tell",
        "  return \"ok\"",
        "end run",
    ]

    static func send(_ text: String, to handle: String, service: Service, timeout: TimeInterval = 45) async -> Outcome {
        let result = await runOSAScript(lines: sendScript, arguments: [handle, text, service.rawValue], timeout: timeout)
        if result.timedOut { return .timedOut }
        if result.status == 0 { return .sent }
        return .failed(describe(result.errorOutput))
    }

    /// A harmless query whose only purpose is to trigger the permission prompt.
    static let permissionProbeScript = ["tell application \"Messages\" to get name"]

    /// Makes macOS ask for permission to control Messages (a harmless query).
    static func requestAutomationAccess() async -> Outcome {
        let result = await runOSAScript(lines: permissionProbeScript, arguments: [], timeout: 120)
        if result.timedOut { return .timedOut }
        return result.status == 0 ? .sent : .failed(describe(result.errorOutput))
    }

    // MARK: Permission check

    enum AutomationStatus: Equatable {
        case granted
        case denied
        case notDetermined
        case messagesNotRunning
        case unknown(Int32)

        var summary: String {
            switch self {
            case .granted: return "Allowed"
            case .denied: return "Denied"
            case .notDetermined: return "Not granted yet"
            case .messagesNotRunning: return "Messages isn't running"
            case .unknown(let code): return "Unknown (\(code))"
            }
        }
    }

    /// Whether this app may send Apple Events to Messages. With `ask`, shows the
    /// system prompt if the user hasn't decided yet. Blocking, so runs off-main.
    static func automationStatus(ask: Bool) async -> AutomationStatus {
        if NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).isEmpty {
            await launchMessagesHidden()
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: messagesBundleID)
                let status = AEDeterminePermissionToAutomateTarget(
                    target.aeDesc,
                    AEEventClass(typeWildCard),
                    AEEventID(typeWildCard),
                    ask
                )
                let result: AutomationStatus
                switch status {
                case 0: result = .granted
                case -1743: result = .denied
                case -1744: result = .notDetermined
                case -600: result = .messagesNotRunning
                default: result = .unknown(status)
                }
                continuation.resume(returning: result)
            }
        }
    }

    @MainActor
    static func launchMessagesHidden() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        // Give Messages a moment to finish launching before it is scripted.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    @MainActor
    static func openMessages() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Process plumbing

    private struct ScriptResult {
        let status: Int32
        let output: String
        let errorOutput: String
        let timedOut: Bool
    }

    private static func runOSAScript(lines: [String], arguments: [String], timeout: TimeInterval) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                var processArguments: [String] = []
                for line in lines {
                    processArguments.append("-e")
                    processArguments.append(line)
                }
                processArguments.append(contentsOf: arguments)
                process.arguments = processArguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ScriptResult(status: -1, output: "", errorOutput: error.localizedDescription, timedOut: false))
                    return
                }

                let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
                if timedOut {
                    process.terminate()
                    _ = finished.wait(timeout: .now() + 5)
                }

                let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: ScriptResult(
                    status: timedOut ? -2 : process.terminationStatus,
                    output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                    errorOutput: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                    timedOut: timedOut
                ))
            }
        }
    }

    /// Turns osascript's error text into something a person can act on.
    private static func describe(_ error: String) -> String {
        if error.contains("-1743") || error.localizedCaseInsensitiveContains("not allowed to send") || error.localizedCaseInsensitiveContains("Not authorized") {
            return "macOS blocked control of Messages. Allow it in System Settings › Privacy & Security › Automation."
        }
        if error.contains("-1728") || error.localizedCaseInsensitiveContains("Can’t get account") || error.localizedCaseInsensitiveContains("Can't get account") {
            return "Messages has no account for this service. Sign in to iMessage, or set up Text Message Forwarding for SMS."
        }
        if error.contains("-600") {
            return "Messages isn't running and couldn't be started."
        }
        return error.isEmpty ? "Messages reported an unknown error." : error
    }
}
