import Cocoa
import CoreML
import CryptoKit
import Darwin
import Foundation
import IOKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Hardware Region & Apple Intelligence Compatibility Probe

struct GatewayAIHardwareReport: Equatable {
    var regionInfoCode: String              // e.g. "CH/A", "LL/A", "ZP/A"
    var isMainlandChinaSKU: Bool            // true when regionInfoCode has prefix "CH/"
    var foundationModelsAvailable: Bool     // true ONLY when SystemLanguageModel.default.availability == .available
    var foundationModelsStateCode: String   // "available" | "modelNotReady" | "appleIntelligenceNotEnabled" | "deviceNotEligible" | "unsupportedSDK"
    var statusTitle: String
    var statusDetail: String

    static func probe() -> GatewayAIHardwareReport {
        let region = readIORegistryRegionInfo()
        let isCN = region.uppercased().hasPrefix("CH/")

        var fmReady = false
        var fmCode = "unsupportedSDK"

        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            fmReady = true
            fmCode = "available"
        case .unavailable(let reason):
            fmReady = false
            switch reason {
            case .deviceNotEligible:
                fmCode = "deviceNotEligible"
            case .appleIntelligenceNotEnabled:
                fmCode = "appleIntelligenceNotEnabled"
            case .modelNotReady:
                fmCode = "modelNotReady"
            @unknown default:
                fmCode = "unavailable"
            }
        }
        #endif

        let title: String
        let detail: String
        if fmReady {
            title = "Apple Intelligence (FoundationModels) 已就绪"
            detail = "硬件地区码 \(region.isEmpty ? "国际版" : region) · 系统端侧大模型可直接参与 L2 灰区语义复核。"
        } else if isCN {
            title = "国行硬件 (\(region)) · FoundationModels 未就绪 (\(fmCode))"
            detail = "Apple 通过 eligibilityd 对国行 (CH/A) 硬件限制了海外版端侧 FoundationModels 激活；但 Apple 神经网络引擎 (ANE) 与 CoreML 完全开放，推荐使用上方「独立 CoreML 增强小模型」与内置微型分类器。"
        } else {
            switch fmCode {
            case "appleIntelligenceNotEnabled":
                title = "系统未开启 Apple Intelligence (\(region.isEmpty ? "非国行" : region))"
                detail = "在「系统设置 → Apple Intelligence 与 Siri」开启并完成模型下载后可自动协同；当前由内置微型模型 / CoreML 增强模型守护。"
            case "modelNotReady":
                title = "FoundationModels 模型尚未就绪 (\(region.isEmpty ? "未知地区" : region))"
                detail = "系统返回 modelNotReady（模型未下载完成或受地区合规门控限制）；当前由内置微型模型 / CoreML 增强模型守护。"
            case "deviceNotEligible":
                title = "当前设备不支持 FoundationModels"
                detail = "硬件或系统未满足 Apple Intelligence 条件；内置微型模型与 CoreML 增强小模型仍可全速运行。"
            default:
                title = "FoundationModels 当前不可用 (\(fmCode))"
                detail = "内置微型分类器与独立 CoreML 增强小模型不受影响，可离线独立运行。"
            }
        }

        return GatewayAIHardwareReport(
            regionInfoCode: region,
            isMainlandChinaSKU: isCN,
            foundationModelsAvailable: fmReady,
            foundationModelsStateCode: fmCode,
            statusTitle: title,
            statusDetail: detail
        )
    }

    static func readIORegistryRegionInfo() -> String {
        let matching = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return "" }
        defer { IOObjectRelease(service) }

        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            "region-info" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return ""
        }
        let val = unmanaged.takeRetainedValue()
        if let data = val as? Data {
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 \t\r\n"))
        }
        if let str = val as? String {
            return str.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \t\r\n"))
        }
        return ""
    }
}

// MARK: - Byte-Window Encoder & CoreML Weight Assembler (`bardsai/password-detector` `large`, Apache-2.0)

enum GatewaySecretTypes {
    static let names = ["none", "password", "api_key", "token", "private_key", "generic"]
}

enum GatewaySpanEncoder {
    static let leftBytes = 64
    static let candBytes = 96
    static let rightBytes = 32
    static let seqLen = 194

    static func encodeUTF8Span(text: String, start: Int, end: Int) -> (ids: [Int32], seg: [Int32]) {
        let utf8 = Array(text.utf8)
        let s = max(0, min(start, utf8.count))
        let e = max(s, min(end, utf8.count))

        let lStart = max(0, s - leftBytes)
        let left = Array(utf8[lStart..<s])

        let candRaw = Array(utf8[s..<e])
        let cand: [UInt8]
        if candRaw.count > candBytes {
            let half = candBytes / 2
            cand = Array(candRaw.prefix(half)) + Array(candRaw.suffix(half))
        } else {
            cand = candRaw
        }

        let rEnd = min(utf8.count, e + rightBytes)
        let right = Array(utf8[e..<rEnd])

        var ids = [Int32](repeating: 0, count: seqLen)
        var seg = [Int32](repeating: 0, count: seqLen)

        let lOff = leftBytes - left.count
        for i in 0..<left.count {
            ids[lOff + i] = Int32(left[i]) + 3
            seg[lOff + i] = 1
        }
        ids[leftBytes] = 1 // SEP1
        seg[leftBytes] = 2
        var o = leftBytes + 1

        for b in cand {
            ids[o] = Int32(b) + 3
            seg[o] = 2
            o += 1
        }
        ids[o] = 2 // SEP2
        seg[o] = 2
        o += 1

        for b in right where o < seqLen {
            ids[o] = Int32(b) + 3
            seg[o] = 3
            o += 1
        }
        return (ids, seg)
    }
}

enum GatewayCoreMLWeightAssembler {
    static let expectedONNXSHA256 = "a9cc22b63ba8b3f0fdd536d18d0dd479835eb2950a29eff20b8257015121a3b3"
    static let expectedWeightBinSHA256 = "1260e5ac81ecb4d9b20b66a0ac17dfa12cf2755423130f8eec8da57e728ae4b4"
    static let weightBinByteCount = 644_224

    static let mirrorDownloadURLs: [URL] = [
        URL(string: "https://hf-mirror.com/bardsai/password-detector/resolve/main/onnx/large/model.onnx")!,
        URL(string: "https://huggingface.co/bardsai/password-detector/resolve/main/onnx/large/model.onnx")!
    ]

    private static let tensorSlices: [(dstOff: Int, fp16Bytes: Int, srcOff: Int)] = [
        (64,     16576,  13021),
        (16704,    256,  46203),
        (17024,  32768,  46746),
        (49856,    256, 112305),
        (50176,  98304, 313746),
        (148544,   256, 510381),
        (148864, 98304, 510927),
        (247232,   256, 707562),
        (247552, 98304, 708108),
        (345920,   256, 904743),
        (346240, 98304, 905289),
        (444608,   256, 1101924),
        (444928, 98304, 1102470),
        (543296,   256, 1299105),
        (543616, 98304, 112850),
        (641984,   256, 309484),
        (642304,   256, 310023),
        (642624,  1536, 310591)
    ]

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func buildWeightBin(fromONNX onnxData: Data) throws -> Data {
        let gotONNXHash = sha256Hex(onnxData)
        guard gotONNXHash == expectedONNXSHA256 else {
            throw NSError(
                domain: "GatewayAIEngine",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "CoreML 增强模型权重 SHA-256 校验失败（\(gotONNXHash.prefix(12))），已中止安装。"]
            )
        }

        for s in tensorSlices {
            if s.srcOff + s.fp16Bytes * 2 > onnxData.count {
                throw NSError(
                    domain: "GatewayAIEngine",
                    code: 102,
                    userInfo: [NSLocalizedDescriptionKey: "模型文件长度异常，无法装配 CoreML 权重。"]
                )
            }
        }

        var out = Data(count: weightBinByteCount)
        out.withUnsafeMutableBytes { outRaw in
            guard let base = outRaw.baseAddress else { return }
            base.storeBytes(of: UInt32(tensorSlices.count).littleEndian, toByteOffset: 0, as: UInt32.self)
            base.storeBytes(of: UInt32(2).littleEndian, toByteOffset: 4, as: UInt32.self)

            onnxData.withUnsafeBytes { srcRaw in
                guard let srcPtr = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for s in tensorSlices {
                    let dataOff = s.dstOff + 64
                    base.storeBytes(of: UInt32(0xDEADBEEF).littleEndian, toByteOffset: s.dstOff + 0, as: UInt32.self)
                    base.storeBytes(of: UInt32(1).littleEndian, toByteOffset: s.dstOff + 4, as: UInt32.self)
                    base.storeBytes(of: UInt32(s.fp16Bytes).littleEndian, toByteOffset: s.dstOff + 8, as: UInt32.self)
                    base.storeBytes(of: UInt32(0).littleEndian, toByteOffset: s.dstOff + 12, as: UInt32.self)
                    base.storeBytes(of: UInt32(dataOff).littleEndian, toByteOffset: s.dstOff + 16, as: UInt32.self)
                    base.storeBytes(of: UInt32(0).littleEndian, toByteOffset: s.dstOff + 20, as: UInt32.self)

                    let elemCount = s.fp16Bytes / 2
                    for i in 0..<elemCount {
                        let p = s.srcOff + i * 4
                        let b0 = UInt32(srcPtr[p])
                        let b1 = UInt32(srcPtr[p + 1]) << 8
                        let b2 = UInt32(srcPtr[p + 2]) << 16
                        let b3 = UInt32(srcPtr[p + 3]) << 24
                        let f32 = Float(bitPattern: b0 | b1 | b2 | b3)
                        let f16Bits = Float16(f32).bitPattern.littleEndian
                        base.storeBytes(of: f16Bits, toByteOffset: dataOff + i * 2, as: UInt16.self)
                    }
                }
            }
        }

        let gotWeightHash = sha256Hex(out)
        guard gotWeightHash == expectedWeightBinSHA256 else {
            throw NSError(
                domain: "GatewayAIEngine",
                code: 103,
                userInfo: [NSLocalizedDescriptionKey: "装配后的 CoreML weight.bin 指纹不匹配（\(gotWeightHash.prefix(12))）。"]
            )
        }
        return out
    }
}

// MARK: - Local Unix-Socket AI Coprocessor (`CoreML ANE` + `FoundationModels`)

struct GatewayAIScoreItem: Codable {
    var text: String
    var start: Int
    var end: Int
    var ruleName: String?
    var filePath: String?
    var channel: String?
}

struct GatewayAIScoreRequest: Codable {
    var items: [GatewayAIScoreItem]
}

struct GatewayAIPrediction: Codable, Equatable {
    var prob: Double
    var kind: String
    var model: String
    var reason: String?
}

struct GatewayAIScoreResponse: Codable {
    var results: [GatewayAIPrediction]
}

final class GatewayAIEngine {
    let modelsDirURL: URL
    let compiledModelURL: URL
    let guardStateDirURL: URL

    private let modelLock = NSLock()
    private var loadedCoreMLModel: MLModel? = nil
    private var allowCoreML: Bool = true
    private var allowFoundationModels: Bool = true
    private var hardwareReport: GatewayAIHardwareReport

    private var listenFD: Int32 = -1
    private var activeSocketPath: String? = nil
    private var acceptRunning: Bool = false
    private let serverQueue = DispatchQueue(label: "com.bofinder.deskside.ai-coproc", qos: .userInitiated, attributes: .concurrent)

    init(appSupportDirURL: URL, guardStateDirURL: URL) {
        self.modelsDirURL = appSupportDirURL.appendingPathComponent("models", isDirectory: true)
        self.compiledModelURL = modelsDirURL.appendingPathComponent("SecretGuardANE.mlmodelc", isDirectory: true)
        self.guardStateDirURL = guardStateDirURL
        self.hardwareReport = GatewayAIHardwareReport.probe()
        _ = reloadCoreMLIfPresent()
    }

    func refreshHardwareReport() -> GatewayAIHardwareReport {
        let rep = GatewayAIHardwareReport.probe()
        modelLock.lock()
        hardwareReport = rep
        modelLock.unlock()
        return rep
    }

    var isCoreMLModelInstalled: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: compiledModelURL.path, isDirectory: &isDir) && isDir.boolValue
    }

    @discardableResult
    func reloadCoreMLIfPresent() -> Bool {
        guard isCoreMLModelInstalled else {
            modelLock.lock()
            loadedCoreMLModel = nil
            modelLock.unlock()
            return false
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        if let model = try? MLModel(contentsOf: compiledModelURL, configuration: cfg) {
            modelLock.lock()
            loadedCoreMLModel = model
            modelLock.unlock()
            return true
        }
        return false
    }

    func setAllowCoreML(_ allow: Bool) {
        modelLock.lock()
        allowCoreML = allow
        modelLock.unlock()
    }

    func setAllowFoundationModels(_ allow: Bool) {
        modelLock.lock()
        allowFoundationModels = allow
        modelLock.unlock()
    }

    func coprocessorSocketPath() -> String {
        let direct = guardStateDirURL.appendingPathComponent("ai-coproc.sock").path
        if direct.utf8.count <= 96 {
            return direct
        }
        let clean = (guardStateDirURL.path as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(clean.utf8))
        let hexPrefix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "/tmp/dg-ai-\(getuid())-\(hexPrefix).sock"
    }

    func activeModelLabel() -> String {
        modelLock.lock()
        let hasCoreML = allowCoreML && (loadedCoreMLModel != nil)
        let fmActive = allowFoundationModels && hardwareReport.foundationModelsAvailable
        modelLock.unlock()

        switch (hasCoreML, fmActive) {
        case (true, true): return "coreml-ane+foundation-models"
        case (true, false): return "coreml-ane-large"
        case (false, true): return "foundation-models"
        case (false, false): return "builtin-tiny-cnn"
        }
    }

    // MARK: - Download, SHA-256 Verify & Compile CoreML ANE Model

    func downloadAndCompileCoreMLModel(
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let skeletonDir = resolveBundledSkeletonDir() else {
            completion(.failure(NSError(
                domain: "GatewayAIEngine",
                code: 104,
                userInfo: [NSLocalizedDescriptionKey: "未找到内置 CoreML 计算图骨架 SecretGuardGraph，请重新构建应用。"]
            )))
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                let onnxData = try await Self.downloadFromMirrors(
                    urls: GatewayCoreMLWeightAssembler.mirrorDownloadURLs,
                    progress: progress
                )

                await MainActor.run {
                    progress("正在校验 SHA-256 指纹并装配 FP16 神经网络权重…")
                }
                let weightBin = try GatewayCoreMLWeightAssembler.buildWeightBin(fromONNX: onnxData)

                let fm = FileManager.default
                try fm.createDirectory(at: self.modelsDirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

                let tempStage = fm.temporaryDirectory.appendingPathComponent("SecretGuardANE-\(UUID().uuidString).mlpackage", isDirectory: true)
                let weightsSubdir = tempStage.appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true)
                try fm.createDirectory(at: weightsSubdir, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tempStage) }

                try fm.copyItem(
                    at: skeletonDir.appendingPathComponent("Manifest.json"),
                    to: tempStage.appendingPathComponent("Manifest.json")
                )
                try fm.copyItem(
                    at: skeletonDir.appendingPathComponent("model.mlmodel"),
                    to: tempStage.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
                )
                try weightBin.write(to: weightsSubdir.appendingPathComponent("weight.bin"), options: .atomic)

                await MainActor.run {
                    progress("正在通过本机 CoreML 编译器针对 Apple 神经网络引擎 (ANE) 优化编译…")
                }
                let tempCompiled = try await MLModel.compileModel(at: tempStage)
                defer { try? fm.removeItem(at: tempCompiled) }

                if fm.fileExists(atPath: self.compiledModelURL.path) {
                    try fm.removeItem(at: self.compiledModelURL)
                }
                try fm.moveItem(at: tempCompiled, to: self.compiledModelURL)

                guard self.reloadCoreMLIfPresent() else {
                    throw NSError(
                        domain: "GatewayAIEngine",
                        code: 105,
                        userInfo: [NSLocalizedDescriptionKey: "编译完成但加载 SecretGuardANE.mlmodelc 失败。"]
                    )
                }

                await MainActor.run {
                    completion(.success(()))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func removeCoreMLModel() {
        modelLock.lock()
        loadedCoreMLModel = nil
        modelLock.unlock()
        try? FileManager.default.removeItem(at: compiledModelURL)
    }

    private func resolveBundledSkeletonDir() -> URL? {
        let fm = FileManager.default
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("SecretGuardGraph", isDirectory: true),
           fm.fileExists(atPath: resURL.appendingPathComponent("model.mlmodel").path) {
            return resURL
        }
        let appFallback = URL(fileURLWithPath: "/Applications/DeskSide.app/Contents/Resources/SecretGuardGraph", isDirectory: true)
        if fm.fileExists(atPath: appFallback.appendingPathComponent("model.mlmodel").path) {
            return appFallback
        }
        let cwdFallback = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("BoFinderApp/Resources/SecretGuardGraph", isDirectory: true)
        if fm.fileExists(atPath: cwdFallback.appendingPathComponent("model.mlmodel").path) {
            return cwdFallback
        }
        return nil
    }

    private static func downloadFromMirrors(
        urls: [URL],
        progress: @escaping (String) -> Void
    ) async throws -> Data {
        var lastError: Error?
        let sessionCfg = URLSessionConfiguration.ephemeral
        sessionCfg.timeoutIntervalForRequest = 25
        sessionCfg.timeoutIntervalForResource = 90
        let session = URLSession(configuration: sessionCfg)

        for (idx, url) in urls.enumerated() {
            let host = url.host ?? "mirror"
            await MainActor.run {
                progress("正在从镜像源 (\(host)) 下载独立 CoreML 增强权重 (~1.25 MB)…")
            }
            do {
                let (data, resp) = try await session.data(from: url)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 1_000_000 {
                    return data
                }
                lastError = NSError(
                    domain: "GatewayAIEngine",
                    code: 106 + idx,
                    userInfo: [NSLocalizedDescriptionKey: "镜像源 \(host) 返回异常状态或数据不完整。"]
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(
            domain: "GatewayAIEngine",
            code: 199,
            userInfo: [NSLocalizedDescriptionKey: "无法连接模型镜像源，请检查网络后重试（内置随包微型模型仍正常生效）。"]
        )
    }

    // MARK: - Inference (`CoreML ANE` + Optional `FoundationModels` Semantic Adjudication)

    func scoreItems(_ items: [GatewayAIScoreItem]) -> [GatewayAIPrediction] {
        modelLock.lock()
        let coreML = allowCoreML ? loadedCoreMLModel : nil
        let fmEnabled = allowFoundationModels && hardwareReport.foundationModelsAvailable
        modelLock.unlock()

        return items.map { item in
            if let coreML = coreML, let pred = Self.predictWithCoreML(model: coreML, item: item) {
                // On overseas Macs with FoundationModels ready, refine borderline L2 gray-zone scores semantically.
                if fmEnabled, item.channel != "llm", pred.prob > 0.12 && pred.prob < 0.55 {
                    if let fmVerdict = Self.adjudicateWithFoundationModelsSync(item: item) {
                        return fmVerdict
                    }
                }
                return pred
            }
            if fmEnabled, let fmVerdict = Self.adjudicateWithFoundationModelsSync(item: item) {
                return fmVerdict
            }
            return GatewayAIPrediction(prob: 0.5, kind: "generic", model: "coproc-unavailable", reason: nil)
        }
    }

    private static func predictWithCoreML(model: MLModel, item: GatewayAIScoreItem) -> GatewayAIPrediction? {
        let (ids, seg) = GatewaySpanEncoder.encodeUTF8Span(text: item.text, start: item.start, end: item.end)
        guard let idsArr = try? MLMultiArray(shape: [1, 194], dataType: .int32),
              let segArr = try? MLMultiArray(shape: [1, 194], dataType: .int32) else {
            return nil
        }

        let idsPtr = idsArr.dataPointer.assumingMemoryBound(to: Int32.self)
        let segPtr = segArr.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<194 {
            idsPtr[i] = ids[i]
            segPtr[i] = seg[i]
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
            "ids": MLFeatureValue(multiArray: idsArr),
            "seg": MLFeatureValue(multiArray: segArr)
        ]),
              let out = try? model.prediction(from: provider),
              let probArr = out.featureValue(for: "secret_prob")?.multiArrayValue else {
            return nil
        }

        let prob = max(0.0, min(1.0, probArr[0].doubleValue))
        var bestIdx = 0
        if let typeArr = out.featureValue(for: "type_probs")?.multiArrayValue, typeArr.count >= GatewaySecretTypes.names.count {
            var bestVal = -Double.infinity
            for t in 0..<GatewaySecretTypes.names.count {
                let v = typeArr[t].doubleValue
                if v > bestVal {
                    bestVal = v
                    bestIdx = t
                }
            }
        }
        return GatewayAIPrediction(
            prob: prob,
            kind: GatewaySecretTypes.names[bestIdx],
            model: "coreml-ane-large",
            reason: "ane_cnn"
        )
    }

    private static func adjudicateWithFoundationModelsSync(item: GatewayAIScoreItem) -> GatewayAIPrediction? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }
        let utf8 = Array(item.text.utf8)
        let s = max(0, min(item.start, utf8.count))
        let e = max(s, min(item.end, utf8.count))
        let lStart = max(0, s - 80)
        let rEnd = min(utf8.count, e + 40)
        let snippet = String(decoding: utf8[lStart..<rEnd], as: UTF8.self)
        let cand = String(decoding: utf8[s..<e], as: UTF8.self)

        let sema = DispatchSemaphore(value: 0)
        var outPred: GatewayAIPrediction? = nil

        Task.detached(priority: .userInitiated) {
            defer { sema.signal() }
            do {
                let session = LanguageModelSession(
                    instructions: "Classify whether the candidate value in this code/config snippet is a REAL credential or a HARMLESS mock/placeholder/identifier. Reply with ONLY one word: REAL or MOCK."
                )
                let prompt = "File: \(item.filePath ?? "unknown")\nRule: \(item.ruleName ?? "")\nSnippet: \(snippet)\nCandidate: \(cand)"
                let resp = try await session.respond(to: prompt)
                let upper = resp.content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if upper.contains("MOCK") && !upper.contains("REAL") {
                    outPred = GatewayAIPrediction(prob: 0.04, kind: "none", model: "foundation-models", reason: "afm_mock")
                } else if upper.contains("REAL") {
                    outPred = GatewayAIPrediction(prob: 0.96, kind: "generic", model: "foundation-models", reason: "afm_real")
                }
            } catch {
                outPred = nil
            }
        }
        _ = sema.wait(timeout: .now() + .milliseconds(650))
        return outPred
        #else
        return nil
        #endif
    }

    // MARK: - 0600 Unix Domain Socket Server

    func startCoprocessorIfEligible(explicitSocketPath: String? = nil) -> Bool {
        stopCoprocessor()

        modelLock.lock()
        let eligible = (allowCoreML && loadedCoreMLModel != nil) || (allowFoundationModels && hardwareReport.foundationModelsAvailable)
        modelLock.unlock()
        guard eligible else { return false }

        let sockPath = explicitSocketPath ?? coprocessorSocketPath()
        let fm = FileManager.default
        let parentDir = (sockPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(sockPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(sockPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for i in 0..<pathBytes.count {
                    dst[i] = pathBytes[i]
                }
            }
        }

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0 else {
            close(fd)
            return false
        }
        chmod(sockPath, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            close(fd)
            unlink(sockPath)
            return false
        }

        listenFD = fd
        activeSocketPath = sockPath
        acceptRunning = true
        let capturedPath = sockPath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let self = self, self.acceptRunning {
                var clientAddr = sockaddr_un()
                var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        Darwin.accept(fd, saPtr, &clientLen)
                    }
                }
                if clientFD < 0 {
                    if !self.acceptRunning { break }
                    continue
                }
                self.serverQueue.async { [weak self] in
                    self?.handleClientConnection(clientFD)
                }
            }
            unlink(capturedPath)
        }
        return true
    }

    func stopCoprocessor() {
        acceptRunning = false
        let fd = listenFD
        listenFD = -1
        let prevPath = activeSocketPath
        activeSocketPath = nil
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        if let prevPath = prevPath {
            unlink(prevPath)
        }
        unlink(coprocessorSocketPath())
    }

    private func handleClientConnection(_ fd: Int32) {
        defer { close(fd) }

        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var rawReq = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Int? = nil
        var expectedBodyBytes = 0

        while rawReq.count < 4 * 1024 * 1024 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            rawReq.append(buf, count: n)

            if headerEnd == nil, let sep = rawReq.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = sep.upperBound
                if let hdrStr = String(data: rawReq.subdata(in: 0..<sep.lowerBound), encoding: .utf8) {
                    for line in hdrStr.split(separator: "\r\n") {
                        if line.lowercased().hasPrefix("content-length:") {
                            let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                            expectedBodyBytes = Int(val) ?? 0
                        }
                    }
                }
            }
            if let hEnd = headerEnd, rawReq.count >= hEnd + expectedBodyBytes {
                break
            }
        }

        guard let hEnd = headerEnd,
              let hdrStr = String(data: rawReq.subdata(in: 0..<(hEnd - 4)), encoding: .utf8),
              let reqLine = hdrStr.split(separator: "\r\n").first else {
            return
        }

        let parts = reqLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1])
        let bodyData = rawReq.subdata(in: hEnd..<min(rawReq.count, hEnd + expectedBodyBytes))

        if method == "GET" && path == "/v1/info" {
            let infoJSON = (try? JSONSerialization.data(withJSONObject: ["model": activeModelLabel()])) ?? Data("{}".utf8)
            writeHTTPResponse(fd: fd, status: "200 OK", body: infoJSON)
            return
        }

        if method == "POST" && path == "/v1/score" {
            guard let decoded = try? JSONDecoder().decode(GatewayAIScoreRequest.self, from: bodyData) else {
                writeHTTPResponse(fd: fd, status: "400 Bad Request", body: Data(#"{"error":"invalid json"}"#.utf8))
                return
            }
            let preds = scoreItems(decoded.items)
            let outData = (try? JSONEncoder().encode(GatewayAIScoreResponse(results: preds))) ?? Data(#"{"results":[]}"#.utf8)
            writeHTTPResponse(fd: fd, status: "200 OK", body: outData)
            return
        }

        writeHTTPResponse(fd: fd, status: "404 Not Found", body: Data(#"{"error":"not found"}"#.utf8))
    }

    private func writeHTTPResponse(fd: Int32, status: String, body: Data) {
        let hdr = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var packet = Data(hdr.utf8)
        packet.append(body)
        packet.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < rawBuf.count {
                let n = Darwin.write(fd, base.advanced(by: sent), rawBuf.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
