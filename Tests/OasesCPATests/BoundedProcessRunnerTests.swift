import Foundation
import Darwin
import XCTest
@testable import OasesCPA

final class BoundedProcessRunnerTests: XCTestCase {
    func testDrainsBothPipesWhenOutputExceedsPipeBuffer() async throws {
        let result = try await BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "dd if=/dev/zero bs=1048576 count=1 2>/dev/null; dd if=/dev/zero bs=1048576 count=1 >&2"
            ],
            timeout: 5
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertGreaterThanOrEqual(result.standardOutput.utf8.count, 1_048_576)
        XCTAssertGreaterThanOrEqual(result.standardError.utf8.count, 1_048_576)
    }

    func testTimeoutTerminatesAndReapsProcessGroup() async throws {
        let startedAt = Date()
        do {
            _ = try await BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep 30"],
                timeout: 0.2
            )
            XCTFail("expected timeout")
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testTaskCancellationTerminatesProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-cpa-runner-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "echo $$ > '\(marker.path)'; trap '' TERM; sleep 30"],
                timeout: 30
            )
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pidText = try String(contentsOf: marker, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(waitForExit(pid), "cancelled process still exists")
    }

    func testOutputLimitTerminatesProcessAndFailsClosed() async throws {
        do {
            _ = try await BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "dd if=/dev/zero bs=1048576 count=1 2>/dev/null"],
                timeout: 5,
                maximumOutputBytes: 1024
            )
            XCTFail("expected output limit")
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
    }

    func testOutputLimitCoversCombinedStdoutAndStderr() async throws {
        do {
            _ = try await BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%*s' 700 ''; printf '%*s' 700 '' >&2"],
                timeout: 5,
                maximumOutputBytes: 1024
            )
            XCTFail("expected combined output limit")
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
    }

    func testEscapedPipeDescendantDoesNotMakeRunnerWaitForever() async throws {
        let startedAt = Date()
        do {
            _ = try await BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 30 & printf descendant-ready"],
                timeout: 2
            )
            XCTFail("expected a fail-closed drain result")
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 4)
    }

    func testBoundedStdinIsWrittenAndClosed() async throws {
        let result = try await BoundedProcessRunner.run(
            executable: "/bin/cat",
            arguments: [],
            standardInput: "bounded-input\n",
            timeout: 2
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput, "bounded-input\n")
        XCTAssertTrue(result.standardError.isEmpty)
    }

    func testScriptThatExitsBeforeReadingAllInputDoesNotKillTheApp() async throws {
        // A native install script carries the gateway package (about 160 KB) and exits early on
        // its guards (lock, existing install). The unread rest of stdin must not raise SIGPIPE in
        // this process; the script's own exit status is the answer.
        let input = "exit 12\n" + String(repeating: "# padding line for the unread rest of the script\n", count: 80_000)
        for _ in 0..<5 {
            do {
                _ = try await BoundedProcessRunner.run(
                    executable: "/bin/bash",
                    arguments: ["-s"],
                    standardInput: input,
                    timeout: 10
                )
                XCTFail("expected non-zero status")
            } catch let error as BoundedProcessError {
                guard case .nonZero(let status, _, _) = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(status, 12)
            }
        }
    }

    func testNonZeroStatusPreservesBoundedOutputForMapping() async throws {
        do {
            _ = try await BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf out; printf err >&2; exit 7"],
                timeout: 2
            )
            XCTFail("expected non-zero status")
        } catch let error as BoundedProcessError {
            guard case .nonZero(let status, let output, let errorOutput) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(status, 7)
            XCTAssertEqual(output, "out")
            XCTAssertEqual(errorOutput, "err")
        }
    }

    func testInputLimitRejectsBeforeLaunchingProcess() async throws {
        do {
            _ = try await BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "exit 99"],
                standardInput: String(repeating: "x", count: 1025),
                timeout: 2,
                maximumInputBytes: 1024
            )
            XCTFail("expected input limit")
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .inputLimitExceeded)
        }
    }

    private func waitForExit(_ pid: Int32) -> Bool {
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            usleep(10_000)
        }
        return false
    }
}
