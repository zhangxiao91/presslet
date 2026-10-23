import Foundation

/// The app's configured action catalog. Presentation never filters by input availability.
final class ActionProvider {
    let store: ActionConfigurationStore
    var configuration: ActionConfiguration { store.configuration }

    init(store: ActionConfigurationStore = ActionConfigurationStore()) {
        self.store = store
    }

    func profile(for bundleID: String) -> AppProfile? {
        configuration.profile(for: bundleID)
    }

    func actions(for bundleID: String) -> [MenuAction] {
        guard let profile = profile(for: bundleID), profile.isEnabled else { return [] }
        return Array(profile.actions.filter(\.isEnabled).prefix(9))
    }

    func hasActions(bundleID: String) -> Bool {
        !actions(for: bundleID).isEmpty
    }

    func shouldIntercept(bundleID: String) -> Bool {
        guard let profile = profile(for: bundleID) else { return false }
        return profile.isEnabled && profile.interceptForceClick && hasActions(bundleID: bundleID)
    }

    func observesSelection(bundleID: String) -> Bool {
        actions(for: bundleID).contains { $0.inputRequirement != .none }
    }

    func save(_ configuration: ActionConfiguration) throws {
        try store.save(configuration)
    }
}
