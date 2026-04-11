import Foundation
import HitokuInference
import os

// MARK: - Model Lifecycle (LLM & STT loading, switching, reload)

extension ConversationCoordinator {

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
            state = .idle
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
            state = .warmingUp
            try await llm?.warmup()
            try Task.checkCancellation()
            modelManager.keepAlive()
            state = .idle
            SoundPlayer.shared.play(.glass)
        } catch is CancellationError {
            state = .idle
        } catch let error as URLError where error.code == .cancelled {
            state = .idle
        } catch {
            revertToLastLoadedModel()
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
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

        guard state == .idle else {
            Self.log.warning("switchModel deferred — state is \(String(describing: self.state))")
            pendingLLMSwitch = true
            return
        }

        pendingLLMSwitch = false
        state = .downloading(progress: 0)

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

        guard state == .idle else {
            Self.log.warning("switchSTTModel deferred — state is \(String(describing: self.state))")
            pendingSTTSwitch = true
            return
        }

        pendingSTTSwitch = false
        state = .downloading(progress: 0)

        sttLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.modelManager.reloadSTT()
                try Task.checkCancellation()

                self.modelManager.statusMessage = L("download.loading_stt")
                self.stt = try await self.makeSttService()
                self.modelManager.sttReady = (self.stt != nil)
                try Task.checkCancellation()

                self.state = .idle
                SoundPlayer.shared.play(.glass)
            } catch is CancellationError {
                self.state = .idle
            } catch let error as URLError where error.code == .cancelled {
                self.state = .idle
            } catch {
                self.state = .error(error.localizedDescription)
                self.resetErrorAfterDelay()
            }
            self.sttLoadTask = nil
            await self.drainPendingSwitches()
        }
    }

    /// Process any model switches that were deferred because state wasn't idle.
    func drainPendingSwitches() async {
        if pendingLLMSwitch && state == .idle {
            await switchModel()
        }
        if pendingSTTSwitch && state == .idle {
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

        state = .downloading(progress: 0)

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
        state = .warmingUp
        let model = modelManager.selectedModel
        try await modelManager.loadModel(model)
        if modelManager.inferenceRouter.isLoaded {
            llm = makeLLMService()
        }
        try await llm?.warmup()
        modelManager.keepAlive()
        state = .idle
        guard llm != nil else { throw VoiceEditorError.modelsNotLoaded }
    }
}
