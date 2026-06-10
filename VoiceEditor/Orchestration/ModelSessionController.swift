import Foundation
import FluidAudio
import HitokuInference
import os

/// Owns the model session: the live STT/LLM service instances, load/switch tasks,
/// deferred-switch flags, and service construction (system prompt + tool wiring).
///
/// Extracted from ConversationCoordinator (audit batch 4). The coordinator forwards
/// its model API here, so views, pipelines, and FileTranscriptionModel are unchanged.
/// AppState stays single-source in the coordinator — this controller drives it only
/// through the injected `getState`/`setState` closures (same pattern as
/// ActionCoordinator), wired in the coordinator's init.
@MainActor
final class ModelSessionController {
    static let log = Logger(subsystem: "com.hitokudraft.coordinator", category: "models")

    // MARK: - Owned State

    var stt: (any STTService)?
    var llm: (any LLMService)?
    /// Tool executor for web search/fetch during LLM generation. Rebuilt with the service.
    var toolExecutor: ToolExecutor?

    /// Cancellable model-loading tasks so a new switch can abort an in-flight download.
    var llmLoadTask: Task<Void, Never>?
    var sttLoadTask: Task<Void, Never>?

    /// Pending model switches that couldn't run because state wasn't idle.
    var pendingLLMSwitch = false
    var pendingSTTSwitch = false

    // MARK: - Dependencies

    private let modelManager: ModelManager
    private let preferences: PreferencesStore

    /// AppState bridge — the coordinator owns pipeline state (single source of truth).
    var getState: () -> AppState = { .idle }
    var setState: (AppState) -> Void = { _ in }
    var getContextAwareMode: () -> ContextAwareMode = { .off }
    /// Coordinator's resetErrorAfterDelay (returns to idle + drains pending switches).
    var scheduleErrorReset: () -> Void = {}

    init(modelManager: ModelManager, preferences: PreferencesStore) {
        self.modelManager = modelManager
        self.preferences = preferences

        // When memory offload clears models, drop the service objects we hold.
        ObservationLoop.track(
            isActive: { [weak self] in self != nil },
            reading: { [weak self] in
                guard let self else { return }
                _ = self.modelManager.sttReady
                _ = self.modelManager.llmReady
            },
            onChange: { [weak self] in
                guard let self else { return }
                if !self.modelManager.sttReady { self.stt = nil }
                if !self.modelManager.llmReady { self.llm = nil }
            }
        )
    }

    // MARK: - LLM Activation (shared loading pattern)

    /// Loads, initializes, and warms up an LLM. Updates state throughout.
    ///
    /// - Parameters:
    ///   - model: The model to load.
    ///   - drainAfter: Whether to call `drainPendingSwitches()` after completion.
    ///   - afterLoad: Optional work performed after load succeeds but before service creation
    ///                (used by `downloadAndAddCustomModel` to register the model).
    func activateLLM(
        _ model: ModelOption,
        drainAfter: Bool = false,
        afterLoad: (() async -> Void)? = nil
    ) async {
        // None sentinel: release any loaded model weights, clear service
        guard !model.isNone else {
            try? await modelManager.loadModel(model)  // clears modelContainer + llmReady + GPU cache
            llm = nil
            setState(.idle)
            llmLoadTask = nil
            if drainAfter { await drainPendingSwitches() }
            return
        }

        do {
            try await modelManager.loadModel(model)
            try Task.checkCancellation()
            await afterLoad?()
            if modelManager.inferenceRouter.isLoaded {
                llm = makeLLMService()
            }
            setState(.warmingUp)
            try await llm?.warmup()
            try Task.checkCancellation()
            modelManager.keepAlive()
            setState(.idle)
            SoundPlayer.shared.play(.glass)
        } catch is CancellationError {
            setState(.idle)
        } catch let error as URLError where error.code == .cancelled {
            setState(.idle)
        } catch {
            revertToLastLoadedModel()
            setState(.error(error.localizedDescription))
            scheduleErrorReset()
        }
        llmLoadTask = nil
        if drainAfter { await drainPendingSwitches() }
    }

    // MARK: - Model Switching

    /// Reverts the model picker to the last successfully-loaded model.
    /// No-op if no model has been loaded yet (e.g. first launch failure).
    func revertToLastLoadedModel() {
        if let path = modelManager.loadedModelPath,
           let model = ModelRegistry.availableModels.first(where: { $0.path == path }) {
            modelManager.selectedModel = model
        }
    }

    func switchModel() async {
        // Cancel any in-flight LLM download/load
        if let existing = llmLoadTask {
            existing.cancel()
            await existing.value
            llmLoadTask = nil
        }

        guard getState() == .idle else {
            Self.log.warning("switchModel deferred — state is \(String(describing: self.getState()))")
            pendingLLMSwitch = true
            return
        }

        pendingLLMSwitch = false
        setState(.downloading(progress: 0))

        llmLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.activateLLM(self.modelManager.selectedModel, drainAfter: true)
        }
    }

    func switchSTTModel() async {
        // Cancel any in-flight STT download/load
        if let existing = sttLoadTask {
            existing.cancel()
            await existing.value
            sttLoadTask = nil
        }

        guard getState() == .idle else {
            Self.log.warning("switchSTTModel deferred — state is \(String(describing: self.getState()))")
            pendingSTTSwitch = true
            return
        }

        pendingSTTSwitch = false
        setState(.downloading(progress: 0))

        sttLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.modelManager.reloadSTT()
                try Task.checkCancellation()

                self.modelManager.statusMessage = L("download.loading_stt")
                self.stt = try await self.makeSttService()
                self.modelManager.sttReady = (self.stt != nil)
                try Task.checkCancellation()

                self.setState(.idle)
                SoundPlayer.shared.play(.glass)
            } catch is CancellationError {
                self.setState(.idle)
            } catch let error as URLError where error.code == .cancelled {
                self.setState(.idle)
            } catch {
                self.setState(.error(error.localizedDescription))
                self.scheduleErrorReset()
            }
            self.sttLoadTask = nil
            await self.drainPendingSwitches()
        }
    }

    /// Process any model switches that were deferred because state wasn't idle.
    func drainPendingSwitches() async {
        if pendingLLMSwitch && getState() == .idle {
            await switchModel()
        }
        if pendingSTTSwitch && getState() == .idle {
            await switchSTTModel()
        }
    }

    // MARK: - Custom Model Download + Add

    /// Downloads a HuggingFace model, then adds it to the registry only on success.
    /// If cancelled (e.g. user switches models mid-download), the model is never registered.
    func downloadAndAddCustomModel(_ model: ModelOption) async {
        // Cancel any in-flight LLM download/load
        if let existing = llmLoadTask {
            existing.cancel()
            await existing.value
            llmLoadTask = nil
        }

        // LiteRT-LM repos (e.g. litert-community/…) need the specific `.litertlm`
        // filename, which the custom path field doesn't capture. Resolve it from
        // the HuggingFace API before loading.
        var model = model
        if model.backendType == .liteRT, model.liteRTFilename == nil {
            setState(.downloading(progress: 0))
            modelManager.statusMessage = "Looking up \(model.path)…"
            guard let filename = await ModelManager.resolveLiteRTFilename(repo: model.path) else {
                setState(.error("No .litertlm file found in \(model.path). Make sure it's a LiteRT-LM repo (e.g. litert-community/…)."))
                scheduleErrorReset()
                return
            }
            model.liteRTFilename = filename
        }

        setState(.downloading(progress: 0))

        llmLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.activateLLM(model, drainAfter: true) {
                // Download succeeded — register the model with its measured on-disk size.
                // Set as selected model — triggers onChange → switchModel(), which early-returns
                // because loadedModelPath already matches, then redoes service creation + warmup.
                var finalModel = model
                let measured = ModelRegistry.measureModelOnDisk(model)
                if measured > 0 { finalModel.estimatedMemoryGB = measured }
                ModelRegistry.addModel(finalModel)
                self.modelManager.selectedModel = finalModel
                UserDefaults.standard.set(finalModel.path, forKey: "selectedModelPath")
            }
        }
    }

    // MARK: - On-Demand Model Reload (post-offload)

    /// Reloads STT from disk if it was offloaded. No-op if already loaded.
    func ensureSTTReady() async throws {
        // LiteRT models handle audio natively — no separate STT needed
        if modelManager.selectedModel.backendType == .liteRT {
            modelManager.sttReady = true
            return
        }
        guard stt == nil else { return }
        modelManager.sttLoading = true
        defer { modelManager.sttLoading = false }
        try await modelManager.reloadSTT()
        stt = try await makeSttService()
        modelManager.sttReady = (stt != nil)
    }

    /// Reloads LLM from disk if it was offloaded. No-op for None sentinel or already-loaded.
    /// Reuses the activateLLM path so warmup runs, but skips the glass sound.
    func ensureLLMReady() async throws {
        guard !modelManager.selectedModel.isNone else { return }
        guard llm == nil else { return }
        // Use loadModel directly to avoid duplicate sounds from activateLLM
        setState(.warmingUp)
        let model = modelManager.selectedModel
        try await modelManager.loadModel(model)
        if modelManager.inferenceRouter.isLoaded {
            llm = makeLLMService()
        }
        try await llm?.warmup()
        modelManager.keepAlive()
        setState(.idle)
        guard llm != nil else { throw VoiceEditorError.modelsNotLoaded }
    }

    // MARK: - Service Factories

    var modelCacheDirectory: URL { ModelManager.modelsCacheRoot }

    func makeSttService() async throws -> (any STTService)? {
        switch modelManager.selectedSTTModel.backend {
        case .fluidAudio:
            guard let models = modelManager.asrModels else { return nil }
            return try await FluidAudioSTT(models: models)
        case .mlxAudio:
            let path = modelManager.selectedSTTModel.path
            guard !path.isEmpty else { return nil }
            return try await MLXAudioSTTService(modelPath: path, cacheDirectory: modelCacheDirectory)
        case .whisperKit:
            let modelName = modelManager.selectedSTTModel.path
            return try await WhisperKitSTTService(modelName: modelName)
        }
    }

    /// Like `makeSttService()`, but loads the ASR models from disk first if they
    /// were offloaded. Used by file transcription, which can run even when the
    /// selected *LLM* is LiteRT/Gemma (which otherwise handles audio itself and
    /// leaves no standalone STT loaded). Returns nil only if STT is set to None.
    func makeSttServiceForFile() async throws -> (any STTService)? {
        if modelManager.selectedSTTModel.backend == .fluidAudio, modelManager.asrModels == nil {
            try await modelManager.reloadSTT()
        }
        return try await makeSttService()
    }

    /// Returns an LLM-backed transcriber (Gemma) for file transcription, loading
    /// the model from cache if it was offloaded. Returns nil if the loaded model
    /// can't actually accept audio.
    func makeLLMTranscriptionSTT() async throws -> (any STTService)? {
        if llm == nil, !modelManager.selectedModel.isNone {
            try await modelManager.loadModel(modelManager.selectedModel)
            if modelManager.inferenceRouter.isLoaded { llm = makeLLMService() }
            modelManager.keepAlive()
        }
        guard let routed = llm as? RoutedLLMService, routed.supportsAudioInput else { return nil }
        return LLMTranscriptionSTT(llm: routed)
    }

    /// Rebuilds the LLM service wrapper when context mode toggles (updates system prompt).
    /// Cheap operation — no model reload, just creates a new RoutedLLMService with the right prompt.
    func rebuildLLMServiceIfNeeded() {
        guard getState() == .idle, modelManager.inferenceRouter.isLoaded else { return }
        llm = makeLLMService()
    }

    func makeLLMService() -> RoutedLLMService {
        let family = modelManager.selectedModel.family
        let isScreenAware = getContextAwareMode() != .off
        var systemPrompt = family.systemPrompt(screenAware: isScreenAware)

        // Inject tool definitions — calendar tools always available, internet tools gated by preference
        if family.supportsToolUse {
            let executor = makeToolExecutor()
            toolExecutor = executor
            let toolPrompt = buildToolDefinitionsPrompt()
            systemPrompt += "\n\n" + toolPrompt
        } else {
            toolExecutor = nil
        }

        return RoutedLLMService(
            router: modelManager.inferenceRouter,
            family: family,
            systemPrompt: systemPrompt
        )
    }

    /// Creates a ToolExecutor. Calendar tools are always included;
    /// internet tools (web search, URL fetch) only when internet access is enabled.
    func makeToolExecutor() -> ToolExecutor {
        var tools: [any Tool] = [
            ListEventsTool(),
            FindFreeTimeTool(),
            CheckAvailabilityTool(),
        ]
        if preferences.internetAccessEnabled {
            let searchService = DuckDuckGoSearchService()
            let fetchService = ReadabilityWebFetcher()
            tools.insert(WebSearchTool(searchService: searchService), at: 0)
            tools.insert(FetchURLTool(fetchService: fetchService), at: 1)
        }
        return ToolExecutor(tools: tools)
    }

    /// Shared formatter — ISO8601DateFormatter construction is expensive and this
    /// runs at the start of every tool-enabled generation.
    static let isoDateTimeFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    /// Builds the tool definitions prompt string synchronously (avoids actor hop).
    /// Mirrors ToolExecutor.toolDefinitionsPrompt but without requiring an actor hop.
    func buildToolDefinitionsPrompt() -> String {
        let nowISO = Self.isoDateTimeFormatter.string(from: Date())
        let weekday = Calendar.current.weekdaySymbols[
            Calendar.current.component(.weekday, from: Date()) - 1
        ]

        let internetEnabled = preferences.internetAccessEnabled
        var toolDefs = """
        - **list_events**: List calendar events for a date range.
          Parameters: {"start_date": "YYYY-MM-DD", "end_date": "YYYY-MM-DD"}
        - **find_free_time**: Find free time slots on a given date.
          Parameters: {"date": "YYYY-MM-DD", "start_hour": "9", "end_hour": "18"}
        - **check_availability**: Check if a specific time is free.
          Parameters: {"datetime": "YYYY-MM-DDTHH:mm", "duration_minutes": "60"}
        """
        if internetEnabled {
            toolDefs = """
            - **web_search**: Search the web for current information.
              Parameters: {"query": "your search query"}
            - **fetch_url**: Fetch and read a web page.
              Parameters: {"url": "https://example.com/page"}
            """ + "\n" + toolDefs
        }

        var useRules = """
        - The user asks about their calendar, schedule, availability, or free time
        """
        if internetEnabled {
            useRules = """
            - The user asks about current events, news, or time-sensitive information
            - The user mentions or asks about a specific URL
            - The user explicitly asks you to search or look something up
            """ + "\n" + useRules
        }

        return """
        Current date and time: \(nowISO) (\(weekday))

        You have access to the following tools to help answer questions:

        \(toolDefs)

        When you need to use a tool, output EXACTLY this format (no other text around it):
        <tool_call>
        {"name": "TOOL_NAME", "arguments": {"param": "value"}}
        </tool_call>

        Use tools when:
        \(useRules)

        Do NOT use tools for:
        - Text editing, rewriting, or grammar fixes
        - Creative writing or drafting
        - Questions you can confidently answer from your training data
        - Opening or launching applications

        After receiving tool results, incorporate the information naturally into your response. \
        Output ONLY the final answer text -- no tool call tags in the final response.
        """
    }
}
