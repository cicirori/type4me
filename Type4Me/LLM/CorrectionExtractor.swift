import Foundation

/// LLM-based ASR correction pair extraction.
/// Given original injected text and the user's edited version,
/// uses the configured LLM to identify which changes are ASR recognition errors.
actor CorrectionExtractor {

    struct Correction: Codable, Equatable, Hashable {
        let wrong: String
        let correct: String
    }

    enum ExtractionError: LocalizedError {
        case noLLMConfigured
        case llmFailed(String)
        case parseFailed
        case skipped

        var errorDescription: String? {
            switch self {
            case .noLLMConfigured:
                return "No LLM configured"
            case .llmFailed(let detail):
                return "LLM call failed: \(detail)"
            case .parseFailed:
                return "Failed to parse LLM response"
            case .skipped:
                return "Pre-filter skipped this pair"
            }
        }
    }

    // MARK: - Main entry

    func extract(original: String, edited: String) async throws -> [Correction] {
        // Pre-filter: avoid wasting LLM calls
        guard shouldProcess(original: original, edited: edited) else {
            throw ExtractionError.skipped
        }

        guard let config = KeychainService.loadLLMConfig() else {
            throw ExtractionError.noLLMConfigured
        }

        let provider = KeychainService.selectedLLMProvider
        let client: any LLMClient = provider == .claude
            ? ClaudeChatClient()
            : DoubaoChatClient(provider: provider)

        let prompt = buildPrompt(original: original, edited: edited)

        let response: String
        do {
            response = try await client.process(text: prompt, prompt: "{text}", config: config)
        } catch {
            throw ExtractionError.llmFailed(error.localizedDescription)
        }

        let cleaned = response.strippingThinkTags()
        guard let corrections = parseResponse(cleaned) else {
            throw ExtractionError.parseFailed
        }

        let result = deduplicate(corrections)
        DebugFileLogger.log("auto-correction: LLM returned \(corrections.count) corrections, \(result.count) after dedup")
        return result
    }

    // MARK: - Pre-filter

    private func shouldProcess(original: String, edited: String) -> Bool {
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = edited.trimmingCharacters(in: .whitespacesAndNewlines)

        if o.isEmpty || e.isEmpty { return false }
        if o == e { return false }

        // Check character overlap — skip full rewrites
        let oChars = Set(o)
        let eChars = Set(e)
        let intersection = oChars.intersection(eChars).count
        let union = oChars.union(eChars).count
        let jaccard = union > 0 ? Double(intersection) / Double(union) : 0
        if jaccard < 0.2 { return false }

        return true
    }

    // MARK: - Prompt

    private func buildPrompt(original: String, edited: String) -> String {
        """
        你是一个语音识别纠错分析工具。

        下面有两段文本：
        - 原文（语音识别输出，已注入到目标应用）
        - 修改后（用户手动修正后的版本）

        请分析用户的修改，提取出**语音识别错误的修正**。

        规则：
        1. 只提取"语音识别错误"的修正（同音字、近音词、漏字、多字等ASR典型错误）
        2. 忽略用户主动改写的内容（改变句意、重组句子、添加新内容）
        3. 忽略纯标点符号或空格的变化
        4. 如果没有识别错误的修正，返回空数组

        原文：\(original)

        修改后：\(edited)

        以JSON数组格式返回，每个元素包含 wrong（识别错误的词）和 correct（正确的词）：
        [{"wrong": "错误词", "correct": "正确词"}]

        只返回JSON，不要其他内容。
        """
    }

    // MARK: - Parse

    private func parseResponse(_ response: String) -> [Correction]? {
        // Find JSON array in response
        guard let match = response.range(of: #"\[[\s\S]*\]"#, options: .regularExpression),
              let data = response[match].data(using: .utf8)
        else { return [] }  // Empty array if no JSON found (LLM said "no corrections")

        return try? JSONDecoder().decode([Correction].self, from: data)
    }

    // MARK: - Deduplicate against existing snippets

    private func deduplicate(_ corrections: [Correction]) -> [Correction] {
        let existingTriggers = Set(
            (SnippetStorage.load() + SnippetStorage.loadBuiltin())
                .map { $0.trigger.filter { !$0.isWhitespace }.lowercased() }
        )

        return corrections.filter { correction in
            let norm = correction.wrong.filter { !$0.isWhitespace }.lowercased()
            return !norm.isEmpty
                && !correction.correct.isEmpty
                && correction.wrong != correction.correct
                && !existingTriggers.contains(norm)
        }
    }
}
