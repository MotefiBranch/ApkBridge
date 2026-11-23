import Foundation

public enum GitHubRepoError: LocalizedError {
    case invalidUrl
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUrl:
            return "Enter a valid GitHub repo URL (e.g. https://github.com/owner/repo)"
        case .requestFailed(let msg):
            return msg
        }
    }
}

public final class GitHubRepoService {
    public static let shared = GitHubRepoService()
    private init() {}

    public func parseOwnerRepo(from input: String) -> (owner: String, repo: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        var path = trimmed
        if let url = URL(string: trimmed), let host = url.host, host.lowercased().contains("github.com") {
            path = url.path
        } else if trimmed.lowercased().hasPrefix("github.com/") {
            path = String(trimmed.dropFirst("github.com/".count))
        }

        let parts = path.split(separator: "/").map { String($0) }.filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        var repo = parts[1]
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }
        return (owner, repo)
    }

    public func fetchAppMetadata(from input: String, hostIs32BitOnly: Bool = true) async throws -> GitHubAppItem {
        guard let (owner, repo) = parseOwnerRepo(from: input) else {
            throw GitHubRepoError.invalidUrl
        }

        let repoUrl = URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!
        var repoReq = URLRequest(url: repoUrl)
        repoReq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        repoReq.setValue("ApkBridgeHub/1.0", forHTTPHeaderField: "User-Agent")

        let (repoData, repoResp) = try await URLSession.shared.data(for: repoReq)
        guard let httpResp = repoResp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            throw GitHubRepoError.requestFailed("GitHub repository not found (\(owner)/\(repo))")
        }

        let repoJson = (try? JSONSerialization.jsonObject(with: repoData) as? [String: Any]) ?? [:]
        let displayName = (repoJson["name"] as? String) ?? repo
        let description = (repoJson["description"] as? String) ?? "Android application from GitHub"
        let ownerObj = repoJson["owner"] as? [String: Any]
        let avatarUrl = (ownerObj?["avatar_url"] as? String) ?? ""

        // Fetch latest release
        var version = "Source"
        var apkUrl: String? = nil
        var apkName: String? = nil
        var isArm64Only = false

        if let relUrl = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") {
            var relReq = URLRequest(url: relUrl)
            relReq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            relReq.setValue("ApkBridgeHub/1.0", forHTTPHeaderField: "User-Agent")

            if let (relData, relResp) = try? await URLSession.shared.data(for: relReq),
               let relHttp = relResp as? HTTPURLResponse, (200...299).contains(relHttp.statusCode),
               let relJson = try? JSONSerialization.jsonObject(with: relData) as? [String: Any] {
                version = (relJson["tag_name"] as? String) ?? (relJson["name"] as? String) ?? "Latest"
                let assets = (relJson["assets"] as? [[String: Any]]) ?? []
                let apkAssets = assets.filter {
                    (($0["name"] as? String) ?? "").lowercased().hasSuffix(".apk")
                }

                if let chosen = selectBestApk(from: apkAssets, prefer32Bit: hostIs32BitOnly) {
                    apkName = chosen.name
                    apkUrl = chosen.url
                    isArm64Only = chosen.isArm64Only
                }
            }
        }

        return GitHubAppItem(
            owner: owner,
            repo: repo,
            name: displayName,
            description: description,
            version: version,
            iconUrl: avatarUrl,
            apkDownloadUrl: apkUrl,
            apkAssetName: apkName,
            isArm64Only: isArm64Only
        )
    }

    private func selectBestApk(
        from assets: [[String: Any]],
        prefer32Bit: Bool
    ) -> (name: String, url: String, isArm64Only: Bool)? {
        guard !assets.isEmpty else { return nil }

        let parsed: [(name: String, url: String)] = assets.compactMap { a in
            guard let n = a["name"] as? String,
                  let u = a["browser_download_url"] as? String else { return nil }
            return (n, u)
        }
        guard !parsed.isEmpty else { return nil }

        if prefer32Bit {
            if let arm32 = parsed.first(where: {
                let low = $0.name.lowercased()
                return low.contains("armeabi-v7a") || low.contains("armeabi") || low.contains("arm32")
            }) {
                return (arm32.name, arm32.url, false)
            }
            if let universal = parsed.first(where: {
                let low = $0.name.lowercased()
                return low.contains("universal") || (!low.contains("arm64") && !low.contains("x86"))
            }) {
                return (universal.name, universal.url, false)
            }
            let first = parsed[0]
            let is64 = first.name.lowercased().contains("arm64")
            return (first.name, first.url, is64)
        }

        let first = parsed[0]
        return (first.name, first.url, false)
    }
}
