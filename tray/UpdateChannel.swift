import Foundation

enum UpdateChannel: String, CaseIterable {
    case stable
    case continuous

    static let preferenceKey = "updateChannel"
    var feedInfoKey: String { self == .stable ? "ClaudesStableFeedURL" : "ClaudesContinuousFeedURL" }

    static func selected(defaults: UserDefaults = .standard) -> UpdateChannel {
        defaults.string(forKey: preferenceKey).flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }
}
