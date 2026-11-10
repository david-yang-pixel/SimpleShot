import Foundation
import Security

/// AI 接口类型
enum AIProviderKind: String, CaseIterable {
    case openAICompatible = "openai"
    case anthropic = "anthropic"

    var title: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容接口"
        case .anthropic: return "Anthropic Claude"
        }
    }
}

/// 常见服务的预设：选一下自动填好接口类型、地址和模型
struct AIPreset {
    let name: String
    let kind: AIProviderKind
    let baseURL: String
    let model: String
    let needsKey: Bool

    static let all: [AIPreset] = [
        AIPreset(name: "DeepSeek", kind: .openAICompatible,
                 baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", needsKey: true),
        AIPreset(name: "通义千问", kind: .openAICompatible,
                 baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus", needsKey: true),
        AIPreset(name: "Kimi（月之暗面）", kind: .openAICompatible,
                 baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k", needsKey: true),
        AIPreset(name: "智谱 GLM", kind: .openAICompatible,
                 baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash", needsKey: true),
        AIPreset(name: "OpenAI", kind: .openAICompatible,
                 baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini", needsKey: true),
        AIPreset(name: "Ollama（本机）", kind: .openAICompatible,
                 baseURL: "http://localhost:11434/v1", model: "qwen2.5", needsKey: false),
        AIPreset(name: "Claude", kind: .anthropic,
                 baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", needsKey: true),
    ]

    static let deepSeek = all[0]
}

struct AIConfig {
    var kind: AIProviderKind
    var baseURL: String
    var model: String
    var apiKey: String

    /// 用于状态提示，例如“DeepSeek（deepseek-chat）”
    var displayName: String {
        let host = URL(string: baseURL)?.host ?? baseURL
        let provider = AIPreset.all.first { URL(string: $0.baseURL)?.host == host }?.name ?? host
        return "\(provider)（\(model)）"
    }
}

enum AITranslateError: LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case badResponse
    case refused

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return s
        case .http(let code, let message): return "HTTP \(code)：\(message)"
        case .badResponse: return "无法解析模型返回的内容"
        case .refused: return "模型拒绝翻译这段内容"
        }
    }
}

/// 调用用户配置的 AI 模型翻译（只发送识别出的文字，不上传截图）
enum AITranslator {
    private static let anthropicVersion = "2026-10-21"

    static func translate(_ text: String, to targetLanguageName: String, config: AIConfig) async throws -> String {
        guard !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !config.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AITranslateError.notConfigured("请先在设置里填写 AI 接口地址和模型")
        }
        let system = """
            你是专业的翻译。请把用户发来的文本翻译成\(targetLanguageName)。
            要求：只输出译文本身，不要解释、不要加引号或前后缀；保留原文的换行和段落结构；\
            专有名词、代码、网址保持原样。文本来自截图的文字识别，可能有个别识别错误或断行，请结合上下文理解后自然地翻译。
            """
        switch config.kind {
        case .openAICompatible:
            return try await openAI(text, system: system, config: config)
        case .anthropic:
            return try await anthropic(text, system: system, config: config)
        }
    }

    // MARK: OpenAI 兼容（DeepSeek、通义千问、Kimi、智谱、OpenAI、Ollama…）

    private static func openAI(_ text: String, system: String, config: AIConfig) async throws -> String {
        var base = config.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        let endpoint = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: endpoint) else { throw AITranslateError.notConfigured("接口地址格式不正确") }

        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
            "temperature": 0.3,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw AITranslateError.badResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Anthropic Claude（Messages API）

    private static func anthropic(_ text: String, system: String, config: AIConfig) async throws -> String {
        var base = config.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        let endpoint: String
        if base.hasSuffix("/v1/messages") {
            endpoint = base
        } else if base.hasSuffix("/v1") {
            endpoint = base + "/messages"
        } else {
            endpoint = base + "/v1/messages"
        }
        guard let url = URL(string: endpoint) else { throw AITranslateError.notConfigured("接口地址格式不正确") }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": text]],
        ]
        let model = config.model
        // 翻译是简单任务：支持 effort 的模型用 low，响应更快、更省
        let effortModels = ["claude-opus-5", "claude-fable-5", "claude-mythos-5", "claude-sonnet-5",
                            "claude-haiku-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
                            "claude-sonnet-4-6"]
        if effortModels.contains(where: { model.hasPrefix($0) }) {
            body["output_config"] = ["effort": "low"]
        }
        // 官方接口上，较新的模型被安全分类器拒绝时自动改用其他模型重试
        let fallbackModels: Set<String> = ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5",
                                           "claude-opus-5", "claude-sonnet-5-5"]
        if url.host == "api.anthropic.com", fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        if json["stop_reason"] as? String == "refusal" { throw AITranslateError.refused }
        guard let content = json["content"] as? [[String: Any]] else { throw AITranslateError.badResponse }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw AITranslateError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTTP

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(code) else {
            // OpenAI 兼容与 Anthropic 都把错误放在 error.message
            let message = (json?["error"] as? [String: Any])?["message"] as? String
                ?? (json?["error"] as? String)
                ?? String(data: data, encoding: .utf8)?.prefix(200).description
                ?? "请求失败"
            throw AITranslateError.http(code, message)
        }
        guard let json else { throw AITranslateError.badResponse }
        return json
    }
}

/// API Key 存在 macOS 钥匙串里，按接口地址的主机名分别保存（切换服务时各自保留）
enum KeychainStore {
    private static let service = "io.github.simpleshot.SimpleShot.ai"

    static func apiKey(forBaseURL baseURL: String) -> String {
        get(account(for: baseURL)) ?? ""
    }

    static func setAPIKey(_ key: String, forBaseURL baseURL: String) {
        set(key, account: account(for: baseURL))
    }

    private static func account(for baseURL: String) -> String {
        "apiKey:" + (URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? baseURL)
    }

    private static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "SimpleShot AI 翻译 API Key"
        SecItemAdd(item as CFDictionary, nil)
    }
}
