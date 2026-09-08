import Foundation
import WeftCore
import WeftIPC
import WeftPlatform

func usage() -> Never {
    fputs(
        """
        usage:
          weftctl query <displays|spaces|windows|world|state|tree|capability>
          weftctl <command>            # focus/move/resize/split/balance/sync/retile/...
          weftctl space <focus|move-window|label|layout>  # native spaces (M4+)
          weftctl sticky [wid] [on|off]             # toggle sticky window
          weftctl focus display <next|prev|N>
          weftctl app toggle <bundle-id>            # launch/focus/hide
          weftctl subscribe [--all]    # live event stream (Ctrl-C to exit)
          weftctl doctor               # diagnostic health check
          weftctl bench <cmd> [-n N]   # latency benchmark & histogram
          weftctl migrate [--write]    # migrate yabai/skhd configuration
          weftctl service <install|uninstall|start|stop|restart|status>
        """,
        stderr
    )
    exit(2)
}

/// M1 local fallback: answer topology queries without a daemon.
func localQuery(_ kind: String) -> Never {
    let world = WorldReader.snapshot()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data: Data?
    switch kind {
    case "displays": data = try? encoder.encode(world.displays)
    case "spaces": data = try? encoder.encode(world.spaces)
    case "windows": data = try? encoder.encode(world.windows)
    case "world": data = try? encoder.encode(world)
    case "capability": data = try? encoder.encode(PlatformCapability.current)
    default: data = nil
    }
    guard let data, let str = String(data: data, encoding: .utf8) else { usage() }
    print(str)
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty, !["help", "--help", "-h"].contains(args[0]) else { usage() }

ignoreSIGPIPE()

// 1. Doctor command
if args[0] == "doctor" {
    Doctor.run()
    exit(0)
}

// 2. Service command
if args[0] == "service" {
    guard args.count >= 2 else {
        fputs("usage: weftctl service <install|uninstall|start|stop|restart|status>\n", stderr)
        exit(2)
    }
    switch args[1] {
    case "install": ServiceManager.install()
    case "uninstall": ServiceManager.uninstall()
    case "start": ServiceManager.start()
    case "stop": ServiceManager.stop()
    case "restart": ServiceManager.restart()
    case "status": ServiceManager.status()
    default:
        fputs("unknown service command '\(args[1])'\n", stderr)
        exit(2)
    }
    exit(0)
}

// 3. Migrate command
if args[0] == "migrate" {
    let write = args.contains("--write")
    Migrate.run(writeOutput: write)
    exit(0)
}

// 4. Bench command
if args[0] == "bench" {
    guard args.count >= 2 else {
        fputs("usage: weftctl bench <command> [-n count]\n", stderr)
        exit(2)
    }
    var iter = 100
    var cmdWords: [String] = []
    var skip = false
    for (i, a) in args.dropFirst().enumerated() {
        if skip { skip = false; continue }
        if a == "-n", i + 1 < args.count - 1 {
            iter = Int(args[i + 2]) ?? 100
            skip = true
        } else {
            cmdWords.append(a)
        }
    }
    Bench.run(command: cmdWords.joined(separator: " "), iterations: iter)
    exit(0)
}

let text = args.joined(separator: " ")
let path = IPCPaths.socketPath()

// Streaming mode: hold the connection open, print each event line.
if args[0] == "subscribe" {
    // Line-buffered: downstream pipes (bars, logs) must see events instantly,
    // and output must survive SIGTERM without losing buffered lines.
    setlinebuf(stdout)
    let ok = IPCClient.subscribe(path: path, command: text) { print($0) }
    if !ok {
        fputs("weftctl: no daemon at \(path) — is weftd running?\n", stderr)
        exit(1)
    }
    exit(0)
}

// Try the daemon first — it owns live tiling state.
if let response = IPCClient.sendCommand(path: path, command: text) {
    if let out = response.output { print(out) }
    if !response.ok {
        fputs("weftctl: \(response.error ?? "failed")\n", stderr)
        exit(1)
    }
    exit(0)
}

// No daemon: read-only queries still work locally (M1 behaviour;
// capability is static probe evidence, so it never needs the daemon).
if args.count == 2, args[0] == "query",
   ["displays", "spaces", "windows", "world", "capability"].contains(args[1])
{
    localQuery(args[1])
}

fputs("weftctl: no daemon at \(path) — is weftd running?\n", stderr)
exit(1)
