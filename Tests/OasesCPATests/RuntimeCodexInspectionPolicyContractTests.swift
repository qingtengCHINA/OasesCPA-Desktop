import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeCodexInspectionPolicyContractTests: XCTestCase {
    func testDefaultConfigMatchesCPAMPInspectionDefaults() {
        let config = RuntimeCodexInspectionPolicyDraft.defaultConfig()

        XCTAssertEqual(config.enabled, false)
        XCTAssertEqual(config.targetTypes, ["codex"])
        XCTAssertEqual(config.targetType, "codex")
        XCTAssertEqual(config.schedule.mode, "interval")
        XCTAssertEqual(config.schedule.timePoints, [])
        XCTAssertEqual(config.schedule.intervalMinutes, 60)
        XCTAssertEqual(config.schedule.timeZone, "")
        XCTAssertEqual(config.workers, 4)
        XCTAssertEqual(config.deleteWorkers, 4)
        XCTAssertEqual(config.timeout, 15_000)
        XCTAssertEqual(config.retries, 0)
        XCTAssertEqual(config.usedPercentThreshold, 100)
        XCTAssertEqual(config.sampleSize, 0)
        XCTAssertEqual(config.autoActionMode, "none")
        XCTAssertFalse(config.autoRecoverEnabled)
        XCTAssertFalse(config.xaiInferenceEnabled)
        XCTAssertEqual(config.xaiInferenceModel, "grok-4.5")
        XCTAssertEqual(config.xaiInferencePrompt, "Reply with exactly OK.")
    }

    func testDraftNormalizesTargetsAndDailyTimePoints() {
        let targetSelection = RuntimeCodexInspectionTargetSelection(
            targetTypes: [" XAI ", "codex", "xai", "unsupported"],
            legacyTargetType: "codex"
        )
        XCTAssertEqual(targetSelection, .codexAndXAI)

        var draft = RuntimeCodexInspectionPolicyDraft(
            config: RuntimeCodexInspectionPolicyDraft.defaultConfig()
        )
        draft.targetSelection = targetSelection
        draft.scheduleMode = .timePoints
        draft.timePoints = "9:5, 09:05; 18:30, 07:00，18:30"

        XCTAssertEqual(draft.parsedTimePoints, ["07:00", "09:05", "18:30"])

        let applied = draft.applying(to: RuntimeCodexInspectionPolicyDraft.defaultConfig())
        XCTAssertEqual(applied.targetTypes, ["codex", "xai"])
        XCTAssertEqual(applied.targetType, "codex")
        XCTAssertEqual(applied.schedule.mode, "time_points")
        XCTAssertEqual(applied.schedule.timePoints, ["07:00", "09:05", "18:30"])
    }

    func testDraftRejectsInvalidTimeZoneThresholdSampleAndTimePoint() {
        var draft = RuntimeCodexInspectionPolicyDraft(
            config: RuntimeCodexInspectionPolicyDraft.defaultConfig()
        )
        draft.scheduleMode = .timePoints
        draft.timePoints = "25:00"
        draft.timeZone = "Not/AnIANAZone"
        draft.usedPercentThreshold = "100.1"
        draft.sampleSize = "-1"

        XCTAssertNotNil(draft.validationMessage)
        XCTAssertNil(draft.parsedTimePoints)
        XCTAssertNil(draft.parsedUsedPercentThreshold)
        XCTAssertNil(draft.parsedSampleSize)

        draft.timePoints = "09:00"
        draft.timeZone = "Asia/Shanghai"
        draft.usedPercentThreshold = "100"
        draft.sampleSize = "0"
        XCTAssertNil(draft.validationMessage)
    }

    func testApplyingWritesCustomAdvancedPolicyAndPreservesUnrelatedSnapshotFields() {
        let existing = RuntimeCodexInspectionConfig(
            enabled: false,
            schedule: RuntimeCodexInspectionScheduleConfig(
                mode: "interval",
                timePoints: [],
                intervalMinutes: 60,
                timeZone: "UTC"
            ),
            targetTypes: ["codex"],
            targetType: "codex",
            workers: 7,
            deleteWorkers: 3,
            timeout: 22_000,
            retries: 2,
            userAgent: "custom-codex-agent",
            xaiInferenceUserAgent: "custom-xai-agent",
            xaiInferenceEnabled: true,
            xaiInferenceModel: "grok-custom",
            xaiInferencePrompt: "return OK",
            usedPercentThreshold: 100,
            sampleSize: 0,
            autoActionMode: "none",
            autoRecoverEnabled: false
        )
        var draft = RuntimeCodexInspectionPolicyDraft(config: existing)
        draft.workers = "11"
        draft.deleteWorkers = "5"
        draft.timeoutMilliseconds = "24000"
        draft.retries = "3"
        draft.userAgent = "custom-codex-agent-v2"
        draft.xaiInferenceUserAgent = "custom-xai-agent-v2"
        draft.xaiInferenceEnabled = true
        draft.xaiInferenceModel = "grok-new"
        draft.xaiInferencePrompt = "Reply with exactly READY."

        let applied = draft.applying(to: existing)

        XCTAssertEqual(applied.workers, 11)
        XCTAssertEqual(applied.deleteWorkers, 5)
        XCTAssertEqual(applied.timeout, 24_000)
        XCTAssertEqual(applied.retries, 3)
        XCTAssertEqual(applied.userAgent, "custom-codex-agent-v2")
        XCTAssertEqual(applied.xaiInferenceUserAgent, "custom-xai-agent-v2")
        XCTAssertTrue(applied.xaiInferenceEnabled)
        XCTAssertEqual(applied.xaiInferenceModel, "grok-new")
        XCTAssertEqual(applied.xaiInferencePrompt, "Reply with exactly READY.")

        XCTAssertEqual(applied.enabled, existing.enabled)
        XCTAssertEqual(applied.schedule, existing.schedule)
        XCTAssertEqual(applied.targetTypes, existing.targetTypes)
        XCTAssertEqual(applied.targetType, existing.targetType)
        XCTAssertEqual(applied.usedPercentThreshold, existing.usedPercentThreshold)
        XCTAssertEqual(applied.sampleSize, existing.sampleSize)
        XCTAssertEqual(applied.autoActionMode, existing.autoActionMode)
        XCTAssertEqual(applied.autoRecoverEnabled, existing.autoRecoverEnabled)
    }

    func testAdvancedIntegerFieldsRequireTheirAllowedRanges() {
        var draft = RuntimeCodexInspectionPolicyDraft(
            config: RuntimeCodexInspectionPolicyDraft.defaultConfig()
        )

        for invalidValue in ["0", "-1", "not-a-number"] {
            draft.workers = invalidValue
            XCTAssertNil(draft.parsedWorkers, "workers should reject \(invalidValue)")
            XCTAssertNotNil(draft.advancedValidationMessage)

            draft.deleteWorkers = invalidValue
            XCTAssertNil(draft.parsedDeleteWorkers, "deleteWorkers should reject \(invalidValue)")
            XCTAssertNotNil(draft.advancedValidationMessage)

            draft.timeoutMilliseconds = invalidValue
            XCTAssertNil(draft.parsedTimeoutMilliseconds, "timeout should reject \(invalidValue)")
            XCTAssertNotNil(draft.advancedValidationMessage)
        }

        draft.workers = "1"
        draft.deleteWorkers = "1"
        draft.timeoutMilliseconds = "1"
        for invalidValue in ["-1", "not-a-number"] {
            draft.retries = invalidValue
            XCTAssertNil(draft.parsedRetries, "retries should reject \(invalidValue)")
            XCTAssertNotNil(draft.advancedValidationMessage)
        }

        draft.retries = "0"
        XCTAssertNil(draft.advancedValidationMessage)
        XCTAssertEqual(draft.parsedWorkers, 1)
        XCTAssertEqual(draft.parsedDeleteWorkers, 1)
        XCTAssertEqual(draft.parsedTimeoutMilliseconds, 1)
        XCTAssertEqual(draft.parsedRetries, 0)
    }

    func testEmptyXAIModelAndPromptOnlyValidateForActiveXAIInference() {
        var draft = RuntimeCodexInspectionPolicyDraft(
            config: RuntimeCodexInspectionPolicyDraft.defaultConfig()
        )
        draft.xaiInferenceModel = ""
        draft.xaiInferencePrompt = ""

        draft.targetSelection = .codex
        draft.xaiInferenceEnabled = true
        XCTAssertNil(draft.validationMessage)

        draft.targetSelection = .xai
        draft.xaiInferenceEnabled = false
        XCTAssertNil(draft.validationMessage)

        draft.xaiInferenceEnabled = true
        draft.xaiInferenceModel = "grok-4.5"
        XCTAssertNotNil(draft.validationMessage)
        XCTAssertTrue(draft.validationMessage?.contains("提示词") == true)

        draft.xaiInferenceModel = ""
        draft.xaiInferencePrompt = "Reply with exactly OK."
        XCTAssertNotNil(draft.validationMessage)
        XCTAssertTrue(draft.validationMessage?.contains("模型名") == true)
    }

    func testLegacyZeroValuedAdvancedConfigFallsBackToCPAMPDefaults() {
        let legacy = RuntimeCodexInspectionConfig(
            enabled: true,
            targetTypes: ["xai"],
            targetType: "xai",
            workers: 0,
            deleteWorkers: 0,
            timeout: 0,
            retries: 0,
            userAgent: "",
            xaiInferenceUserAgent: "",
            xaiInferenceEnabled: true,
            xaiInferenceModel: "",
            xaiInferencePrompt: "",
            usedPercentThreshold: 100,
            sampleSize: 0,
            autoActionMode: "none",
            autoRecoverEnabled: false
        )

        let draft = RuntimeCodexInspectionPolicyDraft(config: legacy)
        let defaults = RuntimeCodexInspectionPolicyDraft.defaultConfig()

        XCTAssertEqual(draft.workers, String(defaults.workers))
        XCTAssertEqual(draft.deleteWorkers, String(defaults.deleteWorkers))
        XCTAssertEqual(draft.timeoutMilliseconds, String(defaults.timeout))
        XCTAssertEqual(draft.retries, "0")
        XCTAssertEqual(draft.userAgent, defaults.userAgent)
        XCTAssertEqual(draft.xaiInferenceUserAgent, defaults.xaiInferenceUserAgent)
        XCTAssertEqual(draft.xaiInferenceModel, defaults.xaiInferenceModel)
        XCTAssertEqual(draft.xaiInferencePrompt, defaults.xaiInferencePrompt)
        XCTAssertNil(draft.validationMessage)
    }

    func testManagerConfigPayloadEncodesCompleteCodexInspectionSnapshot() throws {
        let inspection = RuntimeCodexInspectionConfig(
            enabled: true,
            schedule: RuntimeCodexInspectionScheduleConfig(
                mode: "time_points",
                timePoints: ["08:00", "18:30"],
                intervalMinutes: 45,
                timeZone: "Asia/Shanghai"
            ),
            targetTypes: ["codex", "xai"],
            targetType: "codex",
            workers: 7,
            deleteWorkers: 3,
            timeout: 22_000,
            retries: 2,
            userAgent: "custom-codex-agent",
            xaiInferenceUserAgent: "custom-xai-agent",
            xaiInferenceEnabled: true,
            xaiInferenceModel: "grok-custom",
            xaiInferencePrompt: "return OK",
            usedPercentThreshold: 80,
            sampleSize: 4,
            autoActionMode: "disable",
            autoRecoverEnabled: true
        )
        let config = RuntimeManagerConfig(codexInspection: inspection)

        let data = try JSONEncoder().encode(RuntimeManagerConfigPayload(config: config))
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let submittedConfig = try XCTUnwrap(root["config"] as? [String: Any])
        let submittedInspection = try XCTUnwrap(
            submittedConfig["codexInspection"] as? [String: Any]
        )
        let submittedSchedule = try XCTUnwrap(
            submittedInspection["schedule"] as? [String: Any]
        )

        XCTAssertEqual(submittedInspection["enabled"] as? Bool, true)
        XCTAssertEqual(submittedInspection["targetTypes"] as? [String], ["codex", "xai"])
        XCTAssertEqual(submittedInspection["targetType"] as? String, "codex")
        XCTAssertEqual(submittedInspection["workers"] as? Int, 7)
        XCTAssertEqual(submittedInspection["deleteWorkers"] as? Int, 3)
        XCTAssertEqual(submittedInspection["timeout"] as? Int, 22_000)
        XCTAssertEqual(submittedInspection["retries"] as? Int, 2)
        XCTAssertEqual(submittedInspection["userAgent"] as? String, "custom-codex-agent")
        XCTAssertEqual(submittedInspection["xaiInferenceUserAgent"] as? String, "custom-xai-agent")
        XCTAssertEqual(submittedInspection["xaiInferenceEnabled"] as? Bool, true)
        XCTAssertEqual(submittedInspection["xaiInferenceModel"] as? String, "grok-custom")
        XCTAssertEqual(submittedInspection["xaiInferencePrompt"] as? String, "return OK")
        XCTAssertEqual(submittedInspection["usedPercentThreshold"] as? Double, 80)
        XCTAssertEqual(submittedInspection["sampleSize"] as? Int, 4)
        XCTAssertEqual(submittedInspection["autoActionMode"] as? String, "disable")
        XCTAssertEqual(submittedInspection["autoRecoverEnabled"] as? Bool, true)
        XCTAssertEqual(submittedSchedule["mode"] as? String, "time_points")
        XCTAssertEqual(submittedSchedule["timePoints"] as? [String], ["08:00", "18:30"])
        XCTAssertEqual(submittedSchedule["intervalMinutes"] as? Int, 45)
        XCTAssertEqual(submittedSchedule["timeZone"] as? String, "Asia/Shanghai")
    }
}
