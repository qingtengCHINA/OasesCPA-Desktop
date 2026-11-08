import Foundation
import SwiftUI

enum ProviderEditorRoute: Equatable {
    case createOpenAICompatibility
    case editOpenAICompatibility(providerID: String)
}

final class AppStore: ObservableObject {
    @Published private(set) var selectedSection: AppSection = AppStore.initialSection
    @Published private(set) var pendingSection: AppSection?
    @Published var configurationHasUnsavedChanges = false
    @Published var lastRefreshed = Date()
    @Published private(set) var refreshCount = 0
    @Published var providerEditorRoute: ProviderEditorRoute?
    /// Help → 欢迎指南 asked for the welcome gate again (it keeps the onboarding completed).
    @Published var isWelcomeReopened = false

    /// DEBUG QA: `-OasesQASection monitoring` opens a section directly (screenshots, review).
    private static var initialSection: AppSection {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "OasesQASection"), let section = AppSection(rawValue: raw) {
            return section
        }
        #endif
        return .dashboard
    }

    var connectionLabel: String { OasesLocalization.localized("未连接") }

    var connectionDetail: String { OasesLocalization.localized("选择本机或 SSH / VPS") }

    func refresh() {
        lastRefreshed = Date()
        refreshCount += 1
    }

    func selectSection(_ section: AppSection) {
        guard section != selectedSection else { return }
        guard selectedSection == .config, configurationHasUnsavedChanges else {
            pendingSection = nil
            selectedSection = section
            return
        }
        pendingSection = section
    }

    /// Set by the welcome flow's "创建" step: the API key page opens its create-key editor as soon
    /// as its keys have loaded and then clears the request (it also clears it when it goes away),
    /// so the first key is one click from the welcome screen.
    @Published var createKeyRequested = false

    func cancelPendingNavigation() {
        pendingSection = nil
    }

    func discardConfigurationChangesAndContinue() {
        configurationHasUnsavedChanges = false
        guard let pendingSection else { return }
        self.pendingSection = nil
        selectedSection = pendingSection
    }

    func openProviderEditor(_ route: ProviderEditorRoute) {
        providerEditorRoute = route
    }

    func closeProviderEditor() {
        providerEditorRoute = nil
    }
}
