import Foundation

/// Generates app-specific style instructions via LLM for first-time apps.
actor AppStyleGenerator {

    func generate(bundleID: String, appName: String) async throws -> String {
        guard let config = KeychainService.loadLLMConfig() else { return "" }

        let provider = KeychainService.selectedLLMProvider
        let client: any LLMClient = provider == .claude
            ? ClaudeChatClient()
            : DoubaoChatClient(provider: provider)

        let prompt = buildPrompt(bundleID: bundleID, appName: appName)

        let response = try await client.process(text: prompt, prompt: "{text}", config: config)
        return response.strippingThinkTags().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildPrompt(bundleID: String, appName: String) -> String {
        """
        你是一个语音输入风格顾问。用户使用语音输入工具，将语音识别的文字经过 LLM 润色后注入到不同的应用中。

        现在用户在使用「\(appName)」（bundle ID: \(bundleID)）。

        请为这个应用场景生成一段简短的风格指令（2-4句话），指导 LLM 在润色语音输入时调整风格。考虑：

        1. 这个应用的典型使用场景（聊天、写文档、写代码、发邮件等）
        2. 合适的语气（正式/随意/专业）
        3. 标点符号偏好（聊天场景通常省略句尾句号，正式场景保留）
        4. 语言偏好（如果是国际化工具如 Slack，可能倾向英文风格）
        5. 格式偏好（长短句、是否分段等）

        只返回风格指令文本本身，不要解释、不要 JSON、不要前缀。用中文回答（除非该应用明显偏向英文使用场景）。
        """
    }
}
