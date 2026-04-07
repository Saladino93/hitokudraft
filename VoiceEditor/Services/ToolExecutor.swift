import Foundation
import os

// MARK: - Tool Protocol

/// A tool the LLM can invoke during generation.
protocol Tool: Sendable {
    var name: String { get }
    var parameterDescription: String { get }
    var toolDescription: String { get }
    func execute(arguments: [String: String]) async throws -> String
}

// ToolCall is defined in ChatMessage.swift (shared with chat history).

// MARK: - Tool Executor

/// Manages tool registration, detection, and execution.
/// Thread-safe via actor isolation.
actor ToolExecutor {
    private static let log = Logger(subsystem: "com.hitokudraft.tools", category: "executor")

    private let tools: [String: any Tool]

    /// Maximum number of tool-use re-generation passes to prevent infinite loops.
    static let maxIterations = 3

    init(tools: [any Tool]) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    // MARK: - System Prompt Injection

    /// Tool definition block for injection into system prompts.
    /// Uses Qwen3.5 native tool call format.
    var toolDefinitionsPrompt: String {
        let toolDefs = tools.values.map { tool in
            """
            - **\(tool.name)**: \(tool.toolDescription)
              Parameters: \(tool.parameterDescription)
            """
        }.joined(separator: "\n")

        return """
        You have access to the following tools to help answer questions:

        \(toolDefs)

        When you need to use a tool, output EXACTLY this format (no other text around it):
        <tool_call>
        {"name": "TOOL_NAME", "arguments": {"param": "value"}}
        </tool_call>

        Use tools when:
        - The user asks about current events, recent news, or time-sensitive information
        - The user asks a factual question you are unsure about
        - The user mentions or asks about a specific URL
        - The user explicitly asks you to search or look something up

        Do NOT use tools for:
        - Text editing, rewriting, or grammar fixes
        - Creative writing or drafting
        - Questions you can confidently answer from your training data

        After receiving tool results, incorporate the information naturally into your response. \
        Output ONLY the final answer text -- no tool call tags in the final response.
        """
    }

    // MARK: - Detection

    /// Detects a tool call pattern in the LLM output buffer.
    /// Looks for: `<tool_call>\n{"name":"...","arguments":{...}}\n</tool_call>`
    func detectToolCall(in buffer: String) -> ToolCall? {
        guard let startRange = buffer.range(of: "<tool_call>"),
              let endRange = buffer.range(of: "</tool_call>") else {
            return nil
        }

        let jsonStart = buffer.index(after: startRange.upperBound) < endRange.lowerBound
            ? startRange.upperBound
            : startRange.upperBound
        let jsonString = buffer[jsonStart..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonString.data(using: .utf8) else {
            Self.log.warning("Tool call detected but JSON is not valid UTF-8")
            return nil
        }

        // Parse the JSON structure
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            Self.log.warning("Tool call detected but JSON parsing failed: \(jsonString)")
            return nil
        }

        // Extract arguments -- support both String values and nested objects
        var arguments: [String: String] = [:]
        if let args = json["arguments"] as? [String: Any] {
            for (key, value) in args {
                if let str = value as? String {
                    arguments[key] = str
                } else {
                    arguments[key] = "\(value)"
                }
            }
        }

        // Verify the tool exists
        guard tools[name] != nil else {
            Self.log.warning("LLM called unknown tool: \(name)")
            return nil
        }

        Self.log.info("Detected tool call: \(name) with \(arguments.count) argument(s)")
        return ToolCall(name: name, arguments: arguments)
    }

    // MARK: - Execution

    /// Executes a detected tool call and returns the formatted result.
    func execute(_ call: ToolCall) async throws -> String {
        guard let tool = tools[call.name] else {
            return "Error: Unknown tool '\(call.name)'"
        }

        Self.log.info("Executing tool: \(call.name)")
        let startTime = ContinuousClock.now

        let result: String
        do {
            result = try await tool.execute(arguments: call.arguments)
        } catch {
            Self.log.error("Tool \(call.name) failed: \(error.localizedDescription)")
            return "Error: Tool '\(call.name)' failed -- \(error.localizedDescription)"
        }

        let elapsed = ContinuousClock.now - startTime
        Self.log.info("Tool \(call.name) completed in \(elapsed)")

        return result
    }

    /// Strips tool call tags from the final output text so they are not pasted.
    func stripToolCallTags(from text: String) -> String {
        var result = text
        // Remove <tool_call>...</tool_call> blocks
        while let startRange = result.range(of: "<tool_call>"),
              let endRange = result.range(of: "</tool_call>") {
            let fullRange = startRange.lowerBound..<endRange.upperBound
            result.removeSubrange(fullRange)
        }
        // Also remove orphaned opening/closing tags
        result = result.replacingOccurrences(of: "<tool_call>", with: "")
        result = result.replacingOccurrences(of: "</tool_call>", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
