import Foundation
import Network
import AVFoundation
import CoreMedia

public final class H264StreamClient: ObservableObject {
    @Published public var isConnected: Bool = false
    @Published public var streamError: String? = nil

    private var videoConn: NWConnection?
    private var inputConn: NWConnection?
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    private var formatDesc: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var receiveBuffer = Data()

    private let decodeQueue = DispatchQueue(label: "com.apkbridge.h264.decode", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "com.apkbridge.input.send", qos: .userInteractive)

    public init() {}

    public func attach(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    public func connect(hostIp: String, videoPort: UInt16 = 5567, inputPort: UInt16 = 5568) {
        disconnect()

        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOpts)

        let vConn = NWConnection(
            host: NWEndpoint.Host(hostIp),
            port: NWEndpoint.Port(rawValue: videoPort)!,
            using: params
        )
        vConn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.streamError = nil
                case .failed(let err):
                    self?.isConnected = false
                    self?.streamError = err.localizedDescription
                case .cancelled:
                    self?.isConnected = false
                default:
                    break
                }
            }
        }
        videoConn = vConn
        vConn.start(queue: decodeQueue)
        readNextVideoChunk(on: vConn)

        let iConn = NWConnection(
            host: NWEndpoint.Host(hostIp),
            port: NWEndpoint.Port(rawValue: inputPort)!,
            using: params
        )
        inputConn = iConn
        iConn.start(queue: inputQueue)
    }

    public func disconnect() {
        videoConn?.cancel()
        videoConn = nil
        inputConn?.cancel()
        inputConn = nil
        decodeQueue.async { [weak self] in
            self?.receiveBuffer.removeAll(keepingCapacity: false)
            self?.formatDesc = nil
            self?.spsData = nil
            self?.ppsData = nil
        }
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }

    // MARK: - Touch & Key Input

    public func sendTouch(type: String, normX: CGFloat, normY: CGFloat) {
        let clampedX = min(max(normX, 0), 1)
        let clampedY = min(max(normY, 0), 1)
        let line = String(format: "{\"t\":\"%@\",\"x\":%.4f,\"y\":%.4f}\n", type, clampedX, clampedY)
        sendInputLine(line)
    }

    public func sendNav(_ action: String) {
        sendInputLine("{\"t\":\"k\",\"action\":\"\(action)\"}\n")
    }

    public func sendText(_ text: String) {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        sendInputLine("{\"t\":\"txt\",\"v\":\"\(escaped)\"}\n")
    }

    public func sendBackspace() {
        sendInputLine("{\"t\":\"bs\"}\n")
    }

    private func sendInputLine(_ line: String) {
        guard let conn = inputConn, let data = line.data(using: .utf8) else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Wire Framing & VideoToolbox Decode

    private func readNextVideoChunk(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainPackets()
            }
            if error == nil && !isComplete {
                self.readNextVideoChunk(on: conn)
            } else if let error = error {
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.streamError = error.localizedDescription
                }
            }
        }
    }

    private func drainPackets() {
        // Header: [4B UInt32 length][1B flags][8B Int64 ptsUs] = 13 bytes
        while receiveBuffer.count >= 13 {
            let length = receiveBuffer.withUnsafeBytes { ptr -> Int in
                let raw = ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                return Int(UInt32(bigEndian: raw))
            }
            guard length > 0 && length < 8_000_000 else {
                receiveBuffer.removeAll()
                return
            }
            guard receiveBuffer.count >= 13 + length else { return }

            let ptsUs = receiveBuffer.withUnsafeBytes { ptr -> Int64 in
                let raw = ptr.loadUnaligned(fromByteOffset: 5, as: Int64.self)
                return Int64(bigEndian: raw)
            }
            let payload = receiveBuffer.subdata(in: 13..<(13 + length))
            receiveBuffer.removeSubrange(0..<(13 + length))

            processAnnexBFrame(payload, ptsUs: ptsUs)
        }
    }

    private func processAnnexBFrame(_ data: Data, ptsUs: Int64) {
        let nalus = splitAnnexBNALUs(data)
        var frameNalus: [Data] = []

        for nalu in nalus {
            guard let firstByte = nalu.first else { continue }
            let naluType = firstByte & 0x1F
            if naluType == 7 {
                spsData = nalu
                tryCreateFormatDescription()
            } else if naluType == 8 {
                ppsData = nalu
                tryCreateFormatDescription()
            } else if naluType == 5 || naluType == 1 {
                frameNalus.append(nalu)
            }
        }

        guard !frameNalus.isEmpty, let fmt = formatDesc else { return }
        enqueueSampleBuffer(nalus: frameNalus, formatDesc: fmt, ptsUs: ptsUs)
    }

    private func splitAnnexBNALUs(_ data: Data) -> [Data] {
        var result: [Data] = []
        let bytes = [UInt8](data)
        let count = bytes.count
        var i = 0
        var naluStart = -1

        while i < count {
            var scLen = 0
            if i + 3 < count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                scLen = 4
            } else if i + 2 < count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                scLen = 3
            }

            if scLen > 0 {
                if naluStart >= 0 && i > naluStart {
                    result.append(Data(bytes[naluStart..<i]))
                }
                i += scLen
                naluStart = i
            } else {
                i += 1
            }
        }
        if naluStart >= 0 && count > naluStart {
            result.append(Data(bytes[naluStart..<count]))
        }
        return result
    }

    private func tryCreateFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }
        var newDesc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                guard let spsBase = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                let paramPointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let paramSizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: paramPointers,
                    parameterSetSizes: paramSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newDesc
                )
            }
        }
        if status == noErr, let desc = newDesc {
            self.formatDesc = desc
        }
    }

    private func enqueueSampleBuffer(nalus: [Data], formatDesc: CMVideoFormatDescription, ptsUs: Int64) {
        var avccData = Data()
        for nalu in nalus {
            var lenBE = CFSwapInt32HostToBig(UInt32(nalu.count))
            withUnsafeBytes(of: &lenBE) { avccData.append(contentsOf: $0) }
            avccData.append(nalu)
        }

        let totalLen = avccData.count
        var blockBuffer: CMBlockBuffer?
        let status1 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLen,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLen,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status1 == kCMBlockBufferNoErr, let block = blockBuffer else { return }

        let status2 = avccData.withUnsafeBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: totalLen
            )
        }
        guard status2 == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            decodeTimeStamp: CMTime.invalid
        )
        var sampleSize = totalLen
        let status3 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status3 == noErr, let sbuf = sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.displayLayer else { return }
            if layer.status == .failed {
                layer.flush()
            }
            layer.enqueue(sbuf)
        }
    }
}
