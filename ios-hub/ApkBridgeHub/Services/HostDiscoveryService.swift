import Foundation
import Network

@MainActor
public final class HostDiscoveryService: ObservableObject {
    public static let shared = HostDiscoveryService()

    @Published public var discoveredHosts: [DiscoveredHost] = []
    @Published public var activeHost: DiscoveredHost? = nil
    @Published public var isSearching: Bool = false
    @Published public var connectionError: String? = nil

    private var browser: NWBrowser?
    private let savedIpKey = "apkbridge_manual_host_ip"

    private init() {
        if let savedIp = UserDefaults.standard.string(forKey: savedIpKey), !savedIp.isEmpty {
            Task {
                await connectManualHost(ip: savedIp, port: 5566)
            }
        }
    }

    public func startDiscovery() {
        stopDiscovery()
        isSearching = true
        connectionError = nil

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let newBrowser = NWBrowser(for: .bonjour(type: "_apkbridge._tcp", domain: nil), using: params)

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    Task { @MainActor [weak self] in
                        self?.resolveEndpoint(result.endpoint, serviceName: name)
                    }
                }
            }
        }

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let err) = state {
                    self?.connectionError = err.localizedDescription
                    self?.isSearching = false
                }
            }
        }

        newBrowser.start(queue: .main)
        browser = newBrowser
    }

    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint, serviceName: String) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                if let remoteEndpoint = conn.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remoteEndpoint {
                    let ipString: String
                    switch host {
                    case .ipv4(let addr):
                        ipString = "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
                    case .ipv6(let addr):
                        ipString = "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
                    case .name(let hostname, _):
                        ipString = hostname
                    @unknown default:
                        ipString = "\(host)"
                    }
                    let portInt = Int(port.rawValue)
                    conn.cancel()
                    Task { @MainActor in
                        await self.connectManualHost(ip: ipString, port: portInt, customName: serviceName)
                    }
                } else {
                    conn.cancel()
                }
            } else if case .failed(_) = state {
                conn.cancel()
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    public func connectManualHost(ip: String, port: Int = 5566, customName: String? = nil) async {
        let cleanIp = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIp.isEmpty else { return }

        guard let url = URL(string: "http://\(cleanIp):\(port)/status") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                self.connectionError = "Host returned HTTP error"
                return
            }
            let status = try JSONDecoder().decode(AndroidHostStatus.self, from: data)
            let hostObj = DiscoveredHost(
                name: customName ?? "\(status.manufacturer) \(status.model)",
                ip: cleanIp,
                port: port,
                status: status
            )

            UserDefaults.standard.set(cleanIp, forKey: savedIpKey)
            self.activeHost = hostObj
            if let idx = self.discoveredHosts.firstIndex(where: { $0.ip == cleanIp }) {
                self.discoveredHosts[idx] = hostObj
            } else {
                self.discoveredHosts.append(hostObj)
            }
            self.connectionError = nil
        } catch {
            self.connectionError = "Could not reach \(cleanIp):\(port) — \(error.localizedDescription)"
        }
    }

    public func refreshActiveStatus() async {
        guard let host = activeHost else { return }
        await connectManualHost(ip: host.ip, port: host.port, customName: host.name)
    }

    public func installApk(apkUrl: String, packageName: String?) async throws {
        guard let host = activeHost else { throw URLError(.cannotFindHost) }
        guard let url = URL(string: "http://\(host.ip):\(host.port)/install") else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["apkUrl": apkUrl]
        if let pkg = packageName { payload["packageName"] = pkg }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    public func launchApp(packageName: String) async throws -> Bool {
        guard let host = activeHost else { throw URLError(.cannotFindHost) }
        guard let url = URL(string: "http://\(host.ip):\(host.port)/launch") else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["packageName": packageName])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return false
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (json["ok"] as? Bool) == true
    }
}
