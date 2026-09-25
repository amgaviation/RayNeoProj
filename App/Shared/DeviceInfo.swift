import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum DeviceInfo {
    /// Shown in the delivery log ("Sent by Office Mac").
    @MainActor
    static var name: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
