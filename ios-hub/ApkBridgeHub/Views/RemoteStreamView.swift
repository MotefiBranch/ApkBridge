import SwiftUI
import AVFoundation

struct StreamCanvasRepresentable: UIViewRepresentable {
    @ObservedObject var client: H264StreamClient
    let videoAspectRatio: CGFloat

    func makeUIView(context: Context) -> StreamHostUIView {
        let view = StreamHostUIView()
        view.client = client
        view.videoAspectRatio = videoAspectRatio
        client.attach(displayLayer: view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: StreamHostUIView, context: Context) {
        uiView.videoAspectRatio = videoAspectRatio
        uiView.setNeedsLayout()
    }
}

final class StreamHostUIView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    weak var client: H264StreamClient?
    var videoAspectRatio: CGFloat = 720.0 / 1520.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = false
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = videoContentRect()
    }

    private func videoContentRect() -> CGRect {
        let b = bounds
        guard b.width > 0, b.height > 0, videoAspectRatio > 0 else { return b }
        let viewAspect = b.width / b.height
        if viewAspect > videoAspectRatio {
            let h = b.height
            let w = h * videoAspectRatio
            return CGRect(x: (b.width - w) * 0.5, y: 0, width: w, height: h)
        } else {
            let w = b.width
            let h = w / videoAspectRatio
            return CGRect(x: 0, y: (b.height - h) * 0.5, width: w, height: h)
        }
    }

    private func normalizedPoint(for touch: UITouch) -> CGPoint {
        let rect = videoContentRect()
        let pt = touch.location(in: self)
        let nx = (pt.x - rect.minX) / max(rect.width, 1)
        let ny = (pt.y - rect.minY) / max(rect.height, 1)
        return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let n = normalizedPoint(for: t)
        client?.sendTouch(type: "d", normX: n.x, normY: n.y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let n = normalizedPoint(for: t)
        client?.sendTouch(type: "m", normX: n.x, normY: n.y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let n = normalizedPoint(for: t)
        client?.sendTouch(type: "u", normX: n.x, normY: n.y)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let n = normalizedPoint(for: t)
        client?.sendTouch(type: "u", normX: n.x, normY: n.y)
    }
}

public struct RemoteStreamView: View {
    public let host: DiscoveredHost
    public let title: String
    public let onDismiss: () -> Void

    @StateObject private var client = H264StreamClient()
    @State private var showControls: Bool = false
    @State private var showKeyboardBar: Bool = false
    @State private var textInput: String = ""
    @FocusState private var isKeyboardFocused: Bool

    private var aspectRatio: CGFloat {
        guard let s = host.status, s.screenHeight > 0 else { return 720.0 / 1520.0 }
        return CGFloat(s.screenWidth) / CGFloat(s.screenHeight)
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StreamCanvasRepresentable(client: client, videoAspectRatio: aspectRatio)
                .ignoresSafeArea()

            if !client.isConnected {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.blue)
                        .scaleEffect(1.2)
                    Text(client.streamError ?? "Connecting to \(host.name)...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Close", action: closeStream)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            VStack {
                HStack {
                    Spacer()
                    if showControls {
                        HStack(spacing: 12) {
                            Button(action: { client.sendNav("back") }) {
                                Image(systemName: "chevron.backward")
                            }
                            Button(action: { client.sendNav("home") }) {
                                Image(systemName: "circle")
                            }
                            Button(action: { client.sendNav("recents") }) {
                                Image(systemName: "square.on.square")
                            }
                            Button(action: {
                                showKeyboardBar.toggle()
                                isKeyboardFocused = showKeyboardBar
                            }) {
                                Image(systemName: "keyboard")
                            }
                            Button(action: closeStream) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                            Button(action: { withAnimation { showControls = false } }) {
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    } else {
                        Button(action: { withAnimation { showControls = true } }) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(10)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 14)

                Spacer()

                if showKeyboardBar {
                    HStack(spacing: 8) {
                        TextField("Type text to send to Android...", text: $textInput)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.12))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .focused($isKeyboardFocused)
                            .onSubmit {
                                if !textInput.isEmpty {
                                    client.sendText(textInput)
                                    textInput = ""
                                }
                            }

                        Button(action: { client.sendBackspace() }) {
                            Image(systemName: "delete.left")
                                .foregroundColor(.white)
                                .padding(9)
                                .background(Color.white.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        Button("Send") {
                            if !textInput.isEmpty {
                                client.sendText(textInput)
                                textInput = ""
                            }
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(10)
                    .background(Color(red: 0.08, green: 0.09, blue: 0.12))
                }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            client.connect(hostIp: host.ip, videoPort: 5567, inputPort: 5568)
        }
        .onDisappear {
            client.disconnect()
        }
    }

    private func closeStream() {
        client.disconnect()
        onDismiss()
    }
}
