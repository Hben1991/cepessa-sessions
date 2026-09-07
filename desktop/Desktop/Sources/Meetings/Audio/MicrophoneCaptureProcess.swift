import Darwin
import Foundation

protocol MicrophoneCaptureChild: AnyObject {
  var processIdentifier: Int32 { get }
  var isRunning: Bool { get }
  var terminationStatus: Int32 { get }
  var onStdout: ((Data) -> Void)? { get set }
  var onTermination: (() -> Void)? { get set }
  func launch() throws
  func requestStop()
  func terminate()
  func kill()
  func drainOutput()
}

protocol MicrophoneCaptureChildLaunching {
  func makeChild(overrideDeviceID: UInt32?) throws -> MicrophoneCaptureChild
}

final class MicrophoneCaptureProcess: @unchecked Sendable {
  typealias ChunkHandler = (Data) -> Void
  typealias LevelHandler = (Float) -> Void

  private let launcher: MicrophoneCaptureChildLaunching
  private let handshakeTimeout: TimeInterval
  private let firstAudioTimeout: TimeInterval
  private let shutdownStageTimeout: TimeInterval
  private let queue = DispatchQueue(label: "me.cepessa.microphone-helper-parent")
  private let lock = NSLock()
  private var child: MicrophoneCaptureChild?
  private var decoder = MicrophoneCaptureFrameDecoder()
  private var startContinuation: CheckedContinuation<Void, Error>?
  private var helloReceived = false
  private var healthy = false
  private var generation: UInt = 0
  private var stoppingGeneration: UInt?
  private var onChunk: ChunkHandler?
  private var onLevel: LevelHandler?
  private var onFailure: ((Error) -> Void)?

  init(
    launcher: MicrophoneCaptureChildLaunching = FoundationMicrophoneCaptureLauncher(),
    handshakeTimeout: TimeInterval = 3,
    firstAudioTimeout: TimeInterval = 5,
    shutdownStageTimeout: TimeInterval = 1
  ) {
    self.launcher = launcher
    self.handshakeTimeout = handshakeTimeout
    self.firstAudioTimeout = firstAudioTimeout
    self.shutdownStageTimeout = shutdownStageTimeout
  }

  var isHealthy: Bool { lock.withLock { healthy } }
  var processIdentifier: Int32? { lock.withLock { child?.processIdentifier } }

  func start(
    overrideDeviceID: UInt32?,
    onChunk: @escaping ChunkHandler,
    onLevel: LevelHandler?,
    onFailure: @escaping (Error) -> Void
  ) async throws {
    await stopAndWait()
    let newChild = try launcher.makeChild(overrideDeviceID: overrideDeviceID)
    let token = lock.withLock { () -> UInt in
      generation &+= 1
      child = newChild
      decoder = .init()
      helloReceived = false
      healthy = false
      stoppingGeneration = nil
      self.onChunk = onChunk
      self.onLevel = onLevel
      self.onFailure = onFailure
      return generation
    }
    newChild.onStdout = { [weak self] data in self?.consume(data, token: token) }
    newChild.onTermination = { [weak self] in self?.terminated(token: token) }

    try await withCheckedThrowingContinuation { continuation in
      lock.withLock { startContinuation = continuation }
      do {
        try newChild.launch()
      } catch {
        let launchError = MicrophoneCaptureProcessError.launchFailed(error.localizedDescription)
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
          let value = startContinuation
          startContinuation = nil
          if child === newChild { child = nil }
          return value
        }
        pending?.resume(throwing: launchError)
        return
      }
      scheduleTimeout(
        .handshakeTimedOut, after: handshakeTimeout, token: token, requiresHello: false)
    }
  }

  func stopAndWait() async {
    let stop = lock.withLock { () -> (MicrophoneCaptureChild, UInt, Bool)? in
      guard let target = child else { return nil }
      let token = generation
      let shouldDrain = healthy
      stoppingGeneration = token
      if !shouldDrain {
        generation &+= 1
        child = nil
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        onChunk = nil
        onLevel = nil
        onFailure = nil
      }
      return (target, token, shouldDrain)
    }
    guard let (target, token, shouldDrain) = stop else { return }
    target.requestStop()
    await waitUntilExit(target, timeout: shutdownStageTimeout)
    if target.isRunning {
      target.terminate()
      await waitUntilExit(target, timeout: shutdownStageTimeout)
    }
    if target.isRunning {
      target.kill()
      await waitUntilExit(target, timeout: shutdownStageTimeout)
    }
    guard shouldDrain else {
      lock.withLock {
        if stoppingGeneration == token { stoppingGeneration = nil }
      }
      return
    }

    if !target.isRunning { target.drainOutput() }
    // Consume every stdout callback queued before helper exit before invalidating handlers.
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
    lock.withLock {
      guard generation == token, child === target else { return }
      generation &+= 1
      child = nil
      healthy = false
      stoppingGeneration = nil
      onChunk = nil
      onLevel = nil
      onFailure = nil
    }
  }

  private func consume(_ data: Data, token: UInt) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let frames = try self.lock.withLock { try self.decoder.append(data) }
        for frame in frames { self.consume(frame, token: token) }
      } catch {
        self.fail(error, token: token)
      }
    }
  }

  private func consume(_ frame: MicrophoneCaptureFrame, token: UInt) {
    guard lock.withLock({ token == generation && child != nil }) else { return }
    switch frame.type {
    case .hello:
      let shouldStartAudioTimer = lock.withLock { () -> Bool in
        guard !helloReceived else { return false }
        helloReceived = true
        return true
      }
      if shouldStartAudioTimer {
        scheduleTimeout(
          .firstAudioTimedOut,
          after: firstAudioTimeout,
          token: token,
          requiresHello: true
        )
      }
    case .pcm:
      guard !frame.payload.isEmpty, frame.payload.count.isMultiple(of: 2) else {
        fail(MicrophoneCaptureProcessError.invalidProtocol("invalid PCM payload"), token: token)
        return
      }
      guard lock.withLock({ helloReceived }) else {
        fail(
          MicrophoneCaptureProcessError.invalidProtocol("PCM received before HELLO"),
          token: token
        )
        return
      }
      let completion = lock.withLock { () -> CheckedContinuation<Void, Error>? in
        healthy = true
        let value = startContinuation
        startContinuation = nil
        return value
      }
      completion?.resume()
      // Preserve silence after startup. Removing zero-valued frames would compress the
      // microphone timeline relative to screen and system audio.
      onChunk?(frame.payload)
    case .level:
      guard frame.payload.count == 4 else { return }
      let bits = frame.payload.withUnsafeBytes {
        $0.loadUnaligned(as: UInt32.self)
      }.littleEndian
      onLevel?(Float(bitPattern: bits))
    case .failure:
      let detail = String(data: frame.payload, encoding: .utf8) ?? "Microphone capture failed."
      fail(MicrophoneCaptureProcessError.helperFailed(detail), token: token)
    case .status:
      break
    }
  }

  private func scheduleTimeout(
    _ error: MicrophoneCaptureProcessError,
    after seconds: TimeInterval,
    token: UInt,
    requiresHello: Bool
  ) {
    queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self else { return }
      let shouldFail = self.lock.withLock {
        token == self.generation
          && !self.healthy
          && (requiresHello ? self.helloReceived : !self.helloReceived)
      }
      if shouldFail { self.fail(error, token: token) }
    }
  }

  private func fail(_ error: Error, token: UInt) {
    let values = lock.withLock {
      () -> (CheckedContinuation<Void, Error>?, ((Error) -> Void)?, Bool) in
      guard token == generation else { return (nil, nil, false) }
      generation &+= 1
      let values = (startContinuation, healthy ? onFailure : nil, child != nil)
      startContinuation = nil
      healthy = false
      return values
    }
    values.0?.resume(throwing: error)
    values.1?(error)
    if values.2 { Task { await self.stopAndWait() } }
  }

  private func terminated(token: UInt) {
    let result = lock.withLock { () -> (expected: Bool, status: Int32) in
      (stoppingGeneration == token, child?.terminationStatus ?? -1)
    }
    guard !result.expected else { return }
    fail(MicrophoneCaptureProcessError.helperExited(result.status), token: token)
  }

  private func waitUntilExit(_ child: MicrophoneCaptureChild, timeout: TimeInterval) async {
    let deadline = Date().addingTimeInterval(timeout)
    while child.isRunning && Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}

final class FoundationMicrophoneCaptureLauncher: MicrophoneCaptureChildLaunching {
  func makeChild(overrideDeviceID: UInt32?) throws -> MicrophoneCaptureChild {
    guard let executable = Self.helperURL() else {
      throw MicrophoneCaptureProcessError.helperNotFound
    }
    return FoundationMicrophoneCaptureChild(
      executable: executable,
      arguments: Self.arguments(for: overrideDeviceID)
    )
  }

  static func arguments(for overrideDeviceID: UInt32?) -> [String] {
    overrideDeviceID.map { ["--device-id", String($0)] } ?? []
  }

  static func helperURL(bundle: Bundle = .main) -> URL? {
    let candidates = [
      bundle.bundleURL.appendingPathComponent("Contents/Helpers/CepessaMicrophoneCaptureHelper"),
      bundle.executableURL?.deletingLastPathComponent()
        .appendingPathComponent("CepessaMicrophoneCaptureHelper"),
    ].compactMap { $0 }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }
}

final class FoundationMicrophoneCaptureChild: MicrophoneCaptureChild {
  private let process = Process()
  private let output = Pipe()
  private let input = Pipe()
  private let outputLock = NSLock()
  private var isDrainingOutput = false
  var onStdout: ((Data) -> Void)?
  var onTermination: (() -> Void)?
  var processIdentifier: Int32 { process.processIdentifier }
  var isRunning: Bool { process.isRunning }
  var terminationStatus: Int32 { process.terminationStatus }

  init(executable: URL, arguments: [String]) {
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardInput = input
    process.standardError = FileHandle.nullDevice
  }

  func launch() throws {
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      guard let self else { return }
      self.outputLock.withLock {
        guard !self.isDrainingOutput else { return }
        let data = handle.availableData
        if !data.isEmpty { self.onStdout?(data) }
      }
    }
    process.terminationHandler = { [weak self] _ in self?.onTermination?() }
    try process.run()
  }

  func requestStop() {
    try? input.fileHandleForWriting.write(contentsOf: Data("STOP\n".utf8))
    try? input.fileHandleForWriting.close()
  }

  func terminate() {
    if process.isRunning { process.terminate() }
  }

  func kill() {
    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
  }

  func drainOutput() {
    let handle = output.fileHandleForReading
    handle.readabilityHandler = nil
    outputLock.withLock {
      isDrainingOutput = true
      do {
        if let data = try handle.readToEnd(), !data.isEmpty { onStdout?(data) }
      } catch {}
    }
  }
}
