import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// 自动判断翻译方向：中文 → 英文，其他语言 → 简体中文
enum TranslationDirection {
    static func decide(for text: String) -> (source: Locale.Language?, target: Locale.Language) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let chinese = Locale.Language(identifier: "zh-Hans")
        let english = Locale.Language(identifier: "en")
        guard let detected = recognizer.dominantLanguage, detected != .undetermined else {
            return (nil, chinese) // 识别不出来就让系统自动检测，翻成中文
        }
        if detected == .simplifiedChinese || detected == .traditionalChinese {
            return (Locale.Language(identifier: detected.rawValue), english)
        }
        return (Locale.Language(identifier: detected.rawValue), chinese)
    }

    /// 语言的中文名，例如“英语”“简体中文”
    static func displayName(_ language: Locale.Language?) -> String {
        guard let language else { return "自动检测" }
        let zh = Locale(identifier: "zh-Hans")
        if let script = language.script?.identifier, language.languageCode?.identifier == "zh" {
            return script == "Hant" ? "繁体中文" : "简体中文"
        }
        if let code = language.languageCode?.identifier, let name = zh.localizedString(forLanguageCode: code) {
            return name
        }
        return language.maximalIdentifier
    }
}

// MARK: - 系统翻译（Translation 框架只能通过 SwiftUI 的 translationTask 获取会话）

@available(macOS 15.0, *)
@MainActor
final class TranslationModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    private var pendingTexts: [String] = []
    private var completion: ((Result<[String], Error>) -> Void)?

    /// 批量翻译，结果与输入一一对应
    func translate(_ texts: [String], from source: Locale.Language?, to target: Locale.Language,
                   completion: @escaping (Result<[String], Error>) -> Void) {
        pendingTexts = texts
        self.completion = completion
        if var config = configuration, config.source == source, config.target == target {
            config.invalidate() // 同样的语言对：让 translationTask 再执行一次
            configuration = config
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    func run(with session: TranslationSession) async {
        guard let completion, !pendingTexts.isEmpty else { return }
        self.completion = nil
        let texts = pendingTexts
        do {
            if texts.count == 1 {
                completion(.success([try await session.translate(texts[0]).targetText]))
                return
            }
            let requests = texts.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            let responses = try await session.translations(from: requests)
            var results = texts
            for response in responses {
                if let id = response.clientIdentifier, let index = Int(id), results.indices.contains(index) {
                    results[index] = response.targetText
                }
            }
            completion(.success(results))
        } catch {
            completion(.failure(error))
        }
    }
}

@available(macOS 15.0, *)
struct TranslationHost: View {
    @ObservedObject var model: TranslationModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                await model.run(with: session)
            }
    }
}

// MARK: - 翻译执行（截图翻译和划词翻译共用）

enum TranslationRunnerError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let s): return s }
    }
}

/// 按设置选择翻译引擎（系统翻译 / AI 大模型）并执行翻译。
/// 系统翻译需要把一个隐藏的 SwiftUI 视图挂到窗口上，所以要传入 hostView。
@MainActor
final class TranslationRunner {
    struct Plan {
        let direction: String // 例如“英语 → 简体中文，DeepSeek（deepseek-chat）”
        let busyText: String
    }

    private weak var hostView: NSView?
    private var model: AnyObject? // macOS 15+ 时为 TranslationModel

    init(hostView: NSView) {
        self.hostView = hostView
    }

    func translate(_ text: String, onStart: (Plan) -> Void,
                   completion: @escaping (Result<String, Error>) -> Void) {
        translateBatch([text], onStart: onStart) { result in
            completion(result.map { $0.first ?? "" })
        }
    }

    /// 批量翻译（截图原位翻译用）；方向按全部文字判断，结果与输入一一对应
    func translateBatch(_ texts: [String], onStart: (Plan) -> Void,
                        completion: @escaping (Result<[String], Error>) -> Void) {
        let direction = TranslationDirection.decide(for: texts.joined(separator: "\n"))
        let sourceName = TranslationDirection.displayName(direction.source)
        let targetName = TranslationDirection.displayName(direction.target)

        if Settings.shared.translationEngine == .ai {
            let config = Settings.shared.aiConfig
            let host = URL(string: config.baseURL)?.host ?? ""
            let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
            if config.apiKey.isEmpty && !isLocal {
                completion(.failure(TranslationRunnerError.message("请先在 设置 › 翻译引擎 里填写 API Key")))
                return
            }
            onStart(Plan(direction: "\(sourceName) → \(targetName)，\(config.displayName)",
                         busyText: "正在用 \(config.displayName) 翻译…"))
            Task { @MainActor in
                do {
                    completion(.success(try await AITranslator.translateBatch(texts, to: targetName, config: config)))
                } catch {
                    completion(.failure(error))
                }
            }
            return
        }

        guard #available(macOS 15.0, *) else {
            completion(.failure(TranslationRunnerError.message("系统翻译需要 macOS 15 或更高版本，可在设置中改用 AI 大模型")))
            return
        }
        onStart(Plan(direction: "\(sourceName) → \(targetName)",
                     busyText: "正在翻译…（某种语言首次使用时，系统会提示下载语言包）"))
        Task { @MainActor in
            if let source = direction.source {
                let status = await LanguageAvailability().status(from: source, to: direction.target)
                if status == .unsupported {
                    completion(.failure(TranslationRunnerError.message("系统翻译暂不支持\(sourceName)→\(targetName)")))
                    return
                }
            }
            self.translationModel().translate(texts, from: direction.source, to: direction.target,
                                              completion: completion)
        }
    }

    @available(macOS 15.0, *)
    private func translationModel() -> TranslationModel {
        if let existing = model as? TranslationModel { return existing }
        let created = TranslationModel()
        model = created
        let host = NSHostingView(rootView: TranslationHost(model: created))
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        hostView?.addSubview(host)
        return created
    }
}
