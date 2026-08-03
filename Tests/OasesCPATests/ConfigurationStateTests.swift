import XCTest
@testable import OasesCPA

final class ConfigurationStateTests: XCTestCase {
    func testFailedSaveKeepsConfigurationDraftDirty() {
        var state = ConfigurationEditState()
        state.markChanged()
        let revision = state.beginSave()

        state.finishSave(revision: revision, succeeded: false)

        XCTAssertTrue(state.isDirty)
    }

    func testSuccessfulSaveDoesNotClearNewerEdits() {
        var state = ConfigurationEditState()
        state.markChanged()
        let submittedRevision = state.beginSave()
        state.markChanged()

        state.finishSave(revision: submittedRevision, succeeded: true)

        XCTAssertTrue(state.isDirty)
    }

    @MainActor
    func testUnsavedConfigurationBlocksNavigationUntilDiscardIsConfirmed() {
        let store = AppStore()
        store.selectSection(.config)
        store.configurationHasUnsavedChanges = true

        store.selectSection(.dashboard)

        XCTAssertEqual(store.selectedSection, .config)
        XCTAssertEqual(store.pendingSection, .dashboard)

        store.discardConfigurationChangesAndContinue()

        XCTAssertEqual(store.selectedSection, .dashboard)
        XCTAssertNil(store.pendingSection)
        XCTAssertFalse(store.configurationHasUnsavedChanges)
    }

    func testDirtyProviderEditorRequiresDiscardConfirmationBeforeClosing() {
        var state = UnsavedWindowState()
        state.setDirty(true)

        XCTAssertFalse(state.requestClose())
        XCTAssertTrue(state.isConfirmationPresented)

        XCTAssertTrue(state.confirmDiscardAndClose())
        XCTAssertFalse(state.isDirty)
        XCTAssertFalse(state.isConfirmationPresented)
    }
}
