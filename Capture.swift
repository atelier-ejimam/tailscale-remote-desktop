import Foundation
import Darwin
import ScreenCaptureKit
import VideoToolbox

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Capture: " + message + "\n").utf8))
    exit(1)
}
func check(_ status: OSStatus, _ operation: String) {
    if status != noErr { fail("\(operation): \(status)") }
}
func connectLocal() -> FileHandle {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(8422).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else { fail("localhost:8422 に接続できません") }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "capture.frames")
    let socket = connectLocal()
    var encoder: VTCompressionSession?
    var latest: CVPixelBuffer?
    var lastCapture = CMTime.zero
    var lastEncoded = CMTime.invalid
    var stream: SCStream?
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let d = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { fail("メイン画面を取得できません") }
        let filter = SCContentFilter(display: d, excludingWindows: [])
        let config = SCStreamConfiguration()
        let requested = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1600
        config.width = max(2, min(1600, requested, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))) / 2 * 2
        config.height = max(2, Int((CGFloat(config.width) * filter.contentRect.height / filter.contentRect.width / 2).rounded()) * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.capturesAudio = false
        config.showsCursor = true
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        check(VTCompressionSessionCreate(allocator: nil, width: Int32(config.width), height: Int32(config.height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: { ctx, _, status, _, sample in
                check(status, "encode callback")
                if let ctx, let sample { Unmanaged<Capture>.fromOpaque(ctx).takeUnretainedValue().send(sample) }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder), "encoder")
        guard let encoder else { fail("encoder") }
        let properties: [String: Any] = [
            kVTCompressionPropertyKey_RealTime as String: true,
            kVTCompressionPropertyKey_AllowFrameReordering as String: false,
            kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate as String: 3_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate as String: 30,
            kVTCompressionPropertyKey_MaxKeyFrameInterval as String: 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String: 2]
        check(VTSessionSetProperties(encoder, propertyDictionary: properties as CFDictionary), "properties")
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        stream = s
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              info[.status] as? Int == SCFrameStatus.complete.rawValue,
              let image = sample.imageBuffer else { return }
        latest = image
        lastCapture = sample.presentationTimeStamp
        encode(force: false)
    }
    func encode(force: Bool) {
        guard let latest, let encoder else { return }
        let pts = lastEncoded.isValid && CMTimeCompare(lastCapture, lastEncoded) <= 0
            ? CMTimeAdd(lastEncoded, CMTime(value: 1, timescale: 1000)) : lastCapture
        lastEncoded = pts
        let options = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        check(VTCompressionSessionEncodeFrame(encoder, imageBuffer: latest, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: options, sourceFrameRefcon: nil, infoFlagsOut: nil), "encode")
    }
    func send(_ sample: CMSampleBuffer) {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { return }
        let start: [UInt8] = [0,0,0,1]
        var bytes = Data()
        var count = 0, lengthSize: Int32 = 0
        check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &lengthSize), "H264 format")
        let flags = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]])?.first
        if flags?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true {
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?, n = 0
                check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i,
                    parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil), "parameter set")
                if let p { bytes.append(contentsOf: start); bytes.append(p, count: n) }
            }
        }
        var raw = Data(count: CMBlockBufferGetDataLength(block))
        let size = raw.count
        guard size > 0, (1...4).contains(lengthSize) else { return }
        check(raw.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }, "block copy")
        var i = 0
        while i < size {
            guard i + Int(lengthSize) <= size else { fail("NAL header") }
            var n = 0
            for _ in 0..<lengthSize { n = n * 256 + Int(raw[i]); i += 1 }
            guard n > 0, i+n <= size else { fail("NAL length") }
            bytes.append(contentsOf: start)
            bytes.append(raw[i..<i+n])
            i += n
        }
        var length = UInt32(bytes.count + 8).bigEndian
        var ms = UInt64(CMTimeConvertScale(sample.presentationTimeStamp, timescale: 1000, method: .roundTowardZero).value).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        withUnsafeBytes(of: &ms) { packet.append(contentsOf: $0) }
        packet.append(bytes)
        do { try socket.write(contentsOf: packet) } catch { fail(error.localizedDescription) }
    }
}

@main struct Main {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let capture = Capture()
        do { try await capture.start() } catch { fail("画面収録の許可を確認してください。\(error)") }
        await Task.detached {
            while let command = readLine() {
                if command == "keyframe" { capture.queue.async { capture.encode(force: true) } }
            }
        }.value
    }
}
