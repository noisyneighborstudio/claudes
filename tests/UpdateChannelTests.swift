import Foundation

@main struct UpdateChannelTests {
    static func main() {
        let suite = "Claudes.UpdateChannelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(UpdateChannel.selected(defaults: defaults) == .stable)
        precondition(UpdateChannel.selected(defaults: defaults).feedInfoKey == "ClaudesStableFeedURL")
        defaults.set(UpdateChannel.continuous.rawValue, forKey: UpdateChannel.preferenceKey)
        precondition(UpdateChannel.selected(defaults: defaults) == .continuous)
        precondition(UpdateChannel.selected(defaults: defaults).feedInfoKey == "ClaudesContinuousFeedURL")
        defaults.set("untrusted", forKey: UpdateChannel.preferenceKey)
        precondition(UpdateChannel.selected(defaults: defaults) == .stable)
    }
}
