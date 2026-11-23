import SwiftUI

@main
public struct ApkBridgeHubApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            HubLibraryView()
                .preferredColorScheme(.dark)
        }
    }
}
