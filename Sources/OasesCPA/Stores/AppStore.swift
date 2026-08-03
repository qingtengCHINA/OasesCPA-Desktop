import Foundation
import SwiftUI

enum ProviderEditorRoute: Equatable {
    case createOpenAICompatibility
    case editOpenAICompatibility(providerID: String)
}

final class AppStore: ObservableObject {
    @Published private(set) var selectedSection: AppSection = .dashboard
    @Published private(set) var pendingSection: AppSection?
    @Published var configurationHasUnsavedChanges = false
    @Published var lastRefreshed = Date()
    @Published private(set) var refreshCount = 0
    @Published var providerEditorRoute: ProviderEditorRoute?

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
