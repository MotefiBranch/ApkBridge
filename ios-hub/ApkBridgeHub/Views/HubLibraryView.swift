import SwiftUI

private struct ActiveStreamSession: Identifiable {
    let id = UUID()
    let host: DiscoveredHost
    let title: String
}

public struct HubLibraryView: View {
    @StateObject private var discovery = HostDiscoveryService.shared

    @State private var githubApps: [GitHubAppItem] = []
    @State private var showAddSheet: Bool = false
    @State private var showIpPrompt: Bool = false
    @State private var manualIpInput: String = ""
    @State private var activeStream: ActiveStreamSession? = nil
    @State private var alertMessage: String? = nil

    private let appsStorageKey = "apkbridge_saved_github_apps"
    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    public init() {}

    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hostStatusCard

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("GitHub Apps")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                            Button(action: { showAddSheet = true }) {
                                Label("Add Repo", systemImage: "plus.circle.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.blue)
                            }
                        }

                        if githubApps.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "shippingbox.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white.opacity(0.25))
                                Text("No GitHub Apps Added")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white.opacity(0.75))
                                Text("Paste a GitHub repo URL to pull its icon, version, and APK for your Android host.")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.45))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(24)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(githubApps) { app in
                                    Button(action: { handleTapGitHubApp(app) }) {
                                        VStack(spacing: 7) {
                                            AsyncImage(url: URL(string: app.iconUrl)) { img in
                                                img.resizable().aspectRatio(contentMode: .fill)
                                            } placeholder: {
                                                RoundedRectangle(cornerRadius: 16)
                                                    .fill(Color.white.opacity(0.08))
                                            }
                                            .frame(width: 60, height: 60)
                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 16)
                                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                            )

                                            Text(app.name)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.white)
                                                .lineLimit(1)

                                            Text(app.version)
                                                .font(.system(size: 10))
                                                .foregroundColor(.blue)
                                                .lineLimit(1)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity)
                                        .background(Color(red: 0.1, green: 0.11, blue: 0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                    }
                                    .contextMenu {
                                        if let pkg = app.packageName, !pkg.isEmpty {
                                            Button("Launch & Stream") { launchAndStream(packageName: pkg, title: app.name) }
                                        }
                                        if let apkUrl = app.apkDownloadUrl {
                                            Button("Install APK on Android") { installOnHost(apkUrl: apkUrl, pkg: app.packageName) }
                                        }
                                        Button("Remove", role: .destructive) { removeApp(app) }
                                    }
                                }
                            }
                        }
                    }

                    if let status = discovery.activeHost?.status, !status.installedApps.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Installed on \(status.model)")
                                .font(.headline)
                                .foregroundColor(.white)

                            ForEach(status.installedApps) { app in
                                Button(action: {
                                    launchAndStream(packageName: app.packageName, title: app.label)
                                }) {
                                    HStack {
                                        Image(systemName: "app.badge.checkmark.fill")
                                            .foregroundColor(.green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.label)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundColor(.white)
                                            Text(app.packageName)
                                                .font(.system(size: 11))
                                                .foregroundColor(.white.opacity(0.45))
                                        }
                                        Spacer()
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.blue)
                                    }
                                    .padding(12)
                                    .background(Color(red: 0.1, green: 0.11, blue: 0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea())
            .navigationTitle("ApkBridge Hub")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        if let host = discovery.activeHost {
                            activeStream = ActiveStreamSession(host: host, title: host.name)
                        } else {
                            showIpPrompt = true
                        }
                    }) {
                        Image(systemName: "rectangle.connected.to.line.below")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddGitHubAppSheet(
                    hostIs32BitOnly: discovery.activeHost?.status?.is32BitOnly ?? true
                ) { newItem in
                    githubApps.append(newItem)
                    saveApps()
                }
            }
            .alert("Connect Android Host IP", isPresented: $showIpPrompt) {
                TextField("e.g. 192.168.1.50", text: $manualIpInput)
                    .keyboardType(.decimalPad)
                Button("Connect") {
                    Task {
                        await discovery.connectManualHost(ip: manualIpInput)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter your Android device's local Wi-Fi IP address shown in ApkBridge Host.")
            }
            .alert("Notice", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .fullScreenCover(item: $activeStream) { session in
                RemoteStreamView(host: session.host, title: session.title) {
                    activeStream = nil
                }
            }
            .onAppear {
                loadApps()
                discovery.startDiscovery()
            }
        }
    }

    private var hostStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(discovery.activeHost != nil ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(discovery.activeHost?.name ?? "Searching for Android Host...")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button("Set IP") { showIpPrompt = true }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.blue)
            }

            if let host = discovery.activeHost, let st = host.status {
                Text("\(host.ip) · \(st.freeRamMb) MB free · \(st.abis.first ?? "arm") · \(st.screenWidth)x\(st.screenHeight)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))

                if !st.accessibilityReady {
                    Text("Touch Accessibility is disabled on Android Host — enable it for iOS touch control.")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            } else if let err = discovery.connectionError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func handleTapGitHubApp(_ app: GitHubAppItem) {
        guard let host = discovery.activeHost else {
            showIpPrompt = true
            return
        }

        // Try matching installed app by packageName or fuzzy repo name
        if let explicitPkg = app.packageName, !explicitPkg.isEmpty {
            launchAndStream(packageName: explicitPkg, title: app.name)
            return
        }
        if let matched = host.status?.installedApps.first(where: {
            $0.label.localizedCaseInsensitiveContains(app.repo) ||
            $0.packageName.localizedCaseInsensitiveContains(app.repo)
        }) {
            launchAndStream(packageName: matched.packageName, title: app.name)
            return
        }

        if let apkUrl = app.apkDownloadUrl {
            installOnHost(apkUrl: apkUrl, pkg: app.packageName)
            activeStream = ActiveStreamSession(host: host, title: app.name)
        } else {
            alertMessage = "No .apk asset found in latest release for \(app.name)."
        }
    }

    private func launchAndStream(packageName: String, title: String) {
        guard let host = discovery.activeHost else {
            showIpPrompt = true
            return
        }
        Task {
            let ok = (try? await discovery.launchApp(packageName: packageName)) ?? false
            await MainActor.run {
                if ok {
                    activeStream = ActiveStreamSession(host: host, title: title)
                } else {
                    alertMessage = "Could not launch \(packageName) on \(host.name)."
                }
            }
        }
    }

    private func installOnHost(apkUrl: String, pkg: String?) {
        Task {
            do {
                try await discovery.installApk(apkUrl: apkUrl, packageName: pkg)
            } catch {
                await MainActor.run {
                    alertMessage = "Install request failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func removeApp(_ app: GitHubAppItem) {
        githubApps.removeAll { $0.id == app.id }
        saveApps()
    }

    private func loadApps() {
        guard let data = UserDefaults.standard.data(forKey: appsStorageKey),
              let decoded = try? JSONDecoder().decode([GitHubAppItem].self, from: data) else { return }
        githubApps = decoded
    }

    private func saveApps() {
        if let data = try? JSONEncoder().encode(githubApps) {
            UserDefaults.standard.set(data, forKey: appsStorageKey)
        }
    }
}
