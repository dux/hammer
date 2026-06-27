import Foundation

// Shells out to the `hammer` binary. The spec is fetched once per reload;
// a task run streams stdout+stderr line-by-line back to the caller.
//
// Both run in `projectDir` and inherit the launching environment (the GUI
// is spawned directly, not via `open`, so PATH still finds the right ruby).
final class HammerService {
  let hammerBin: String
  let projectDir: String

  init(hammerBin: String, projectDir: String) {
    self.hammerBin = hammerBin
    self.projectDir = projectDir
  }

  func loadSpec() throws -> Spec {
    let data = try capture([hammerBin, "h:json", "--compact"])
    return try JSONDecoder().decode(Spec.self, from: data)
  }

  private func capture(_ argv: [String]) throws -> Data {
    let p = makeProcess(argv, quiet: true)
    let out = Pipe()
    p.standardOutput = out
    p.standardError  = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
  }

  // Run a task. `onLine` fires on the process's queue with each chunk;
  // `onExit` fires once with the status. Callers marshal to the main queue.
  func runTask(_ argv: [String],
               onLine: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) {
    let p = makeProcess([hammerBin] + argv, quiet: false)
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError  = pipe

    pipe.fileHandleForReading.readabilityHandler = { h in
      let d = h.availableData
      guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
      onLine(s)
    }
    p.terminationHandler = { proc in
      pipe.fileHandleForReading.readabilityHandler = nil
      let rest = pipe.fileHandleForReading.readDataToEndOfFile()
      if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) { onLine(s) }
      onExit(proc.terminationStatus)
    }

    do {
      try p.run()
    } catch {
      onLine("failed to launch \(hammerBin): \(error)\n")
      onExit(127)
    }
  }

  private func makeProcess(_ argv: [String], quiet: Bool) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    p.currentDirectoryURL = URL(fileURLWithPath: projectDir)
    var env = ProcessInfo.processInfo.environment
    env["NO_COLOR"] = "1"                 // plain text until the event protocol lands
    if quiet { env["HAMMER_QUIET"] = "1" } // suppress the gray run banner for h:json
    p.environment = env
    return p
  }
}
