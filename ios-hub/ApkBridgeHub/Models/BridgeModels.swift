import Foundation

public struct GitHubAppItem: Identifiable, Codable, Equatable {
    public let id: String
    public let owner: String
    public let repo: String
    public let name: String
    public let description: String
    public let version: String
    public let iconUrl: String
    public let apkDownloadUrl: String?
    public let apkAssetName: String?
    public let isArm64Only: Bool
    public var packageName: String?

    public init(
        id: String = UUID().uuidString,
        owner: String,
        repo: String,
        name: String,
        description: String,
        version: String,
        iconUrl: String,
        apkDownloadUrl: String?,
        apkAssetName: String?,
        isArm64Only: Bool,
        packageName: String? = nil
    ) {
        self.id = id
        self.owner = owner
        self.repo = repo
        self.name = name
        self.description = description
        self.version = version
        self.iconUrl = iconUrl
        self.apkDownloadUrl = apkDownloadUrl
        self.apkAssetName = apkAssetName
        self.isArm64Only = isArm64Only
        self.packageName = packageName
    }
}

public struct InstalledAndroidApp: Identifiable, Codable, Equatable {
    public var id: String { packageName }
    public let packageName: String
    public let label: String
}

public struct AndroidHostStatus: Codable, Equatable {
    public let model: String
    public let manufacturer: String
    public let abis: [String]
    public let freeRamMb: Int
    public let totalRamMb: Int
    public let screenWidth: Int
    public let screenHeight: Int
    public let streaming: Bool
    public let accessibilityReady: Bool
    public let installedApps: [InstalledAndroidApp]

    public var is32BitOnly: Bool {
        !abis.contains("arm64-v8a")
    }
}

public struct DiscoveredHost: Identifiable, Equatable {
    public var id: String { "\(ip):\(port)" }
    public let name: String
    public let ip: String
    public let port: Int
    public var status: AndroidHostStatus?
}
