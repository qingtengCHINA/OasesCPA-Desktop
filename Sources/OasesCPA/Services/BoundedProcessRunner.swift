import Darwin
import Foundation

struct BoundedProcessResult: Equatable, Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

enum BoundedProcessError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case cancelled
    case outputLimitExceeded
    case inputLimitExceeded
    case nonZero(status: Int32, standardOutput: String, standardError: String)
}

struct BoundedProcessRunner {
    static let defaultMaximumOutputBytes = 8 * 1024 * 1024
    static let defaultMaximumInputBytes = 8 * 1024 * 1024

    static func run(
        executable: String,
        arguments: [String],
        standardInput: String? = nil,
        timeout: TimeInterval,
        maximumOutputBytes: Int = defaultMaximumOutputBytes,
        maximumInputBytes: Int = defaultMaximumInputBytes
    ) async throws -> BoundedProcessResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            if Task.isCancelled {
                control.request(.cancelled)
            }
            return try await Task.detached(priority: .userInitiated) {
                try runBlocking(
                    executable: executable,
                    arguments: arguments,
                    standardInput: standardInput,
                    timeout: timeout,
                    maximumOutputBytes: maximumOutputBytes,
                    maximumInputBytes: maximumInputBytes,
                    control: control
                )
            }.value
        }, onCancel: {
            control.request(.cancelled)
        })
    }

    static func userFacingMessage(for error: Error, fallback: String) -> String {
        guard let processError = error as? BoundedProcessError else {
            return fallback
        }
        switch processError {
        case .launchFailed:
            return fallback
        case .timedOut:
            return OasesLocalization.localized("命令执行超时，已停止。")
        case .cancelled:
            return OasesLocalization.localized("命令已取消。")
        case .outputLimitExceeded:
            return OasesLocalization.localized("命令输出超出安全限制，已停止。")
        case .inputLimitExceeded:
            return OasesLocalization.localized("命令输入超出安全限制，已停止。")
        case .nonZero(_, _, let standardError):
            return SSHConnectionService.userFacingError(standardError, fallback: fallback)
        }
    }

    private enum TerminationReason: Sendable {
        case cancelled
        case timedOut
        case outputLimitExceeded
    }

    private final class ProcessControl: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var processGroupConfigured = false
        private var terminationReason: TerminationReason?

        func install(process: Process, processGroupConfigured: Bool) {
            var shouldTerminate = false
            self.lock.lock()
            self.process = process
            self.processGroupConfigured = processGroupConfigured
            shouldTerminate = terminationReason != nil
            self.lock.unlock()
            if shouldTerminate {
                BoundedProcessRunner.terminate(
                    process,
                    processGroupConfigured: processGroupConfigured
                )
            }
        }

        func request(_ reason: TerminationReason) {
            let process: Process?
            let groupConfigured: Bool
            let shouldTerminate: Bool
            lock.lock()
            if terminationReason == nil {
                terminationReason = reason
                shouldTerminate = true
            } else {
                shouldTerminate = false
            }
            process = self.process
            groupConfigured = processGroupConfigured
            lock.unlock()

            guard shouldTerminate, let process else { return }
            BoundedProcessRunner.terminate(
                process,
                processGroupConfigured: groupConfigured
            )
        }

        var reason: TerminationReason? {
            lock.lock()
            defer { lock.unlock() }
            return terminationReason
        }

        var isProcessRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return process?.isRunning == true
        }
    }

    private final class OutputBudget: @unchecked Sendable {
        private let maximumBytes: Int
        private let lock = NSLock()
        private var consumedBytes = 0
        private var exceeded = false

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        func reserve(_ requestedBytes: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            guard !exceeded else { return 0 }
            let remaining = maximumBytes - consumedBytes
            let accepted = min(requestedBytes, remaining)
            consumedBytes += accepted
            if accepted < requestedBytes {
                exceeded = true
            }
            return accepted
        }

        var didExceed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return exceeded
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let budget: OutputBudget
        private let lock = NSLock()
        private var data = Data()

        init(budget: OutputBudget) {
            self.budget = budget
        }

        func append(_ chunk: Data) -> Bool {
            let accepted = budget.reserve(chunk.count)
            if accepted > 0 {
                lock.lock()
                data.append(chunk.prefix(accepted))
                lock.unlock()
            }
            return accepted < chunk.count
        }

        var result: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private final class DrainEndpoint: @unchecked Sendable {
        private let fileHandle: FileHandle
        private let descriptor: Int32
        private let lock = NSLock()
        private var closed = false

        init(fileHandle: FileHandle) {
            self.fileHandle = fileHandle
            self.descriptor = fileHandle.fileDescriptor
        }

        func readData(ofLength length: Int) -> Data {
            var bytes = [UInt8](repeating: 0, count: length)
            let count = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, rawBuffer.count)
            }
            guard count > 0 else { return Data() }
            return Data(bytes: bytes, count: count)
        }

        func close() {
            lock.lock()
            guard !closed else {
                lock.unlock()
                return
            }
            closed = true
            lock.unlock()
            fileHandle.closeFile()
        }
    }

    private static func runBlocking(
        executable: String,
        arguments: [String],
        standardInput: String?,
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        maximumInputBytes: Int,
        control: ProcessControl
    ) throws -> BoundedProcessResult {
        guard timeout > 0,
              maximumOutputBytes > 0,
              maximumInputBytes > 0 else {
            throw BoundedProcessError.timedOut
        }
        let inputData: Data?
        if let standardInput {
            guard standardInput.utf8.count <= maximumInputBytes else {
                throw BoundedProcessError.inputLimitExceeded
            }
            inputData = Data(standardInput.utf8)
        } else {
            inputData = nil
        }

        if control.reason == .cancelled {
            throw BoundedProcessError.cancelled
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = inputData == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw BoundedProcessError.launchFailed
        }

        let processID = process.processIdentifier
        let processGroupConfigured: Bool
        if processID > 0 {
            let setGroupStatus = Darwin.setpgid(processID, processID)
            processGroupConfigured = setGroupStatus == 0 || Darwin.getpgid(processID) == processID
        } else {
            processGroupConfigured = false
        }
        control.install(process: process, processGroupConfigured: processGroupConfigured)

        let outputBudget = OutputBudget(maximumBytes: maximumOutputBytes)
        let outputCollector = OutputCollector(budget: outputBudget)
        let errorCollector = OutputCollector(budget: outputBudget)
        let outputEndpoint = DrainEndpoint(fileHandle: outputPipe.fileHandleForReading)
        let errorEndpoint = DrainEndpoint(fileHandle: errorPipe.fileHandleForReading)
        let drainGroup = DispatchGroup()
        startDrain(
            endpoint: outputEndpoint,
            collector: outputCollector,
            control: control,
            group: drainGroup
        )
        startDrain(
            endpoint: errorEndpoint,
            collector: errorCollector,
            control: control,
            group: drainGroup
        )

        let deadline = Date().addingTimeInterval(timeout)
        let inputGroup = DispatchGroup()
        if let inputPipe, let inputData {
            inputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    inputPipe.fileHandleForWriting.closeFile()
                    inputGroup.leave()
                }
                let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
                let flags = Darwin.fcntl(descriptor, F_GETFL)
                guard flags >= 0,
                      Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    return
                }
                // A script that exits before it has read all of its input (an early guard of a
                // large install script) closes the pipe: the write must fail with EPIPE, not
                // raise SIGPIPE, which would end this app.
                guard Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
                    return
                }

                var offset = 0
                while offset < inputData.count,
                      control.reason == nil,
                      control.isProcessRunning,
                      Date() < deadline {
                    let written = inputData.withUnsafeBytes { rawBuffer -> Int in
                        guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                        return Darwin.write(
                            descriptor,
                            baseAddress.advanced(by: offset),
                            inputData.count - offset
                        )
                    }
                    if written > 0 {
                        offset += written
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        usleep(5_000)
                    } else {
                        break
                    }
                }
            }
        }

        while process.isRunning {
            if Task.isCancelled {
                control.request(.cancelled)
            } else if Date() >= deadline {
                control.request(.timedOut)
            }
            if control.reason != nil {
                break
            }
            usleep(10_000)
        }
        process.waitUntilExit()

        if inputGroup.wait(timeout: .now() + 1) == .timedOut {
            control.request(.timedOut)
            _ = inputGroup.wait(timeout: .now() + 1)
        }
        var drainTimedOut = false
        if drainGroup.wait(timeout: .now() + 1) == .timedOut {
            drainTimedOut = true
            control.request(.outputLimitExceeded)
            outputEndpoint.close()
            errorEndpoint.close()
            _ = drainGroup.wait(timeout: .now() + 1)
        }

        switch control.reason {
        case .cancelled:
            throw BoundedProcessError.cancelled
        case .timedOut:
            throw BoundedProcessError.timedOut
        case .outputLimitExceeded:
            throw BoundedProcessError.outputLimitExceeded
        case nil:
            break
        }

        if outputBudget.didExceed || drainTimedOut {
            throw BoundedProcessError.outputLimitExceeded
        }
        let output = outputCollector.result
        let errorOutput = errorCollector.result
        let result = BoundedProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: output, as: UTF8.self),
            standardError: String(decoding: errorOutput, as: UTF8.self)
        )
        guard result.status == 0 else {
            throw BoundedProcessError.nonZero(
                status: result.status,
                standardOutput: result.standardOutput,
                standardError: result.standardError
            )
        }
        return result
    }

    private static func startDrain(
        endpoint: DrainEndpoint,
        collector: OutputCollector,
        control: ProcessControl,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                endpoint.close()
                group.leave()
            }
            while true {
                let data = endpoint.readData(ofLength: 64 * 1024)
                if data.isEmpty { return }
                if collector.append(data) {
                    control.request(.outputLimitExceeded)
                    return
                }
            }
        }
    }

    private static func terminate(_ process: Process, processGroupConfigured: Bool) {
        let processID = process.processIdentifier
        if processGroupConfigured, processID > 0 {
            _ = Darwin.kill(-processID, SIGTERM)
        }
        if process.isRunning {
            process.terminate()
        }
        let softDeadline = Date().addingTimeInterval(0.25)
        while process.isRunning, Date() < softDeadline {
            usleep(10_000)
        }
        if processGroupConfigured, processID > 0 {
            _ = Darwin.kill(-processID, SIGKILL)
        }
        if process.isRunning, processID > 0 {
            _ = Darwin.kill(processID, SIGKILL)
            process.terminate()
        }
    }
}
