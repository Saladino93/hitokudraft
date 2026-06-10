import Foundation

// MARK: - Model Lifecycle (forwarders — logic lives in ModelSessionController)
//
// Extracted in audit batch 4. These keep the coordinator's public API stable for
// SettingsView (switch/download), setup(), and the pipelines (ensure*Ready).

extension ConversationCoordinator {

    func activateLLM(
        _ model: ModelOption,
        drainAfter: Bool = false,
        afterLoad: (() async -> Void)? = nil
    ) async {
        await models.activateLLM(model, drainAfter: drainAfter, afterLoad: afterLoad)
    }

    func switchModel() async { await models.switchModel() }

    func switchSTTModel() async { await models.switchSTTModel() }

    func drainPendingSwitches() async { await models.drainPendingSwitches() }

    func downloadAndAddCustomModel(_ model: ModelOption) async {
        await models.downloadAndAddCustomModel(model)
    }

    func ensureSTTReady() async throws { try await models.ensureSTTReady() }

    func ensureLLMReady() async throws { try await models.ensureLLMReady() }
}
