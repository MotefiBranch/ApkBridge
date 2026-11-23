import SwiftUI

public struct AddGitHubAppSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let hostIs32BitOnly: Bool
    public let onAdd: (GitHubAppItem) -> Void

    @State private var repoUrl: String = ""
    @State private var packageNameOverride: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMsg: String? = nil
    @State private var previewItem: GitHubAppItem? = nil

    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("GitHub Repository")) {
                    TextField("https://github.com/owner/repo", text: $repoUrl)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)

                    Button(action: fetchRepo) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(isLoading ? "Fetching from GitHub..." : "Fetch App Info & Release APK")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(repoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }

                if let err = errorMsg {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }

                if let item = previewItem {
                    Section(header: Text("Preview")) {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: item.iconUrl)) { img in
                                img.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.3))
                            }
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.headline)
                                Text("Version: \(item.version)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let asset = item.apkAssetName {
                                    Text(asset)
                                        .font(.caption2)
                                        .foregroundColor(item.isArm64Only ? .orange : .green)
                                } else {
                                    Text("No .apk release asset found")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        }

                        Text(item.description)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if item.isArm64Only && hostIs32BitOnly {
                            Text("Warning: This release only provides arm64-v8a, which will not install on your 32-bit SkyDevices X63.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }

                        TextField("Optional Android Package ID (e.g. org.schabi.newpipe)", text: $packageNameOverride)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
            }
            .navigationTitle("Add GitHub App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if var item = previewItem {
                            let cleanPkg = packageNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !cleanPkg.isEmpty {
                                item.packageName = cleanPkg
                            }
                            onAdd(item)
                            dismiss()
                        }
                    }
                    .disabled(previewItem == nil)
                }
            }
        }
    }

    private func fetchRepo() {
        isLoading = true
        errorMsg = nil
        previewItem = nil
        Task {
            do {
                let item = try await GitHubRepoService.shared.fetchAppMetadata(
                    from: repoUrl,
                    hostIs32BitOnly: hostIs32BitOnly
                )
                await MainActor.run {
                    self.previewItem = item
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMsg = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}
