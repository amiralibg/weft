import Foundation
import WeftCore
import WeftIPC
import WeftPlatform

func usage() -> Never {
    fputs(
        """
        usage:
          weftctl query <displays|spaces|windows|world|state|tree|trace|capability>
          weftctl <command>            # focus/move/resize/split/balance/sync/retile/...
          weftctl space <focus|move-window|label|layout>  # native spaces (M4+)
          weftctl sticky [wid] [on|off]             # toggle sticky window
          weftctl focus display <next|prev|N>
          weftctl app toggle <bundle-id>            # launch/focus/hide
          weftctl exec '<shell command>'            # run it through /bin/sh
          weftctl subscribe [--all]    # live event stream (Ctrl-C to exit)
          weftctl doctor               # diagnostic health check
          weftctl logs [-n N] [-f]     # the daemon's log, for a bug report
          weftctl rescue               # bring back windows stranded off every display
          weftctl bench <cmd> [-n N]   # latency benchmark, histogram, daemon phases
          weftctl trace reset          # clear the daemon's phase samples
          weftctl migrate [--write]    # migrate yabai/skhd configuration
          weftctl service <install|uninstall|start|stop|restart|status>
          weftctl --version
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

if ["--version", "-v", "version"].contains(args[0]) {
    print(WeftVersion.full)
    exit(0)
}

ignoreSIGPIPE()

// 1. Doctor command
if args[0] == "doctor" {
    Doctor.run()
    exit(0)
}

// 1b. Logs. The point is that reporting a problem is one command, not a path
// to remember plus a guess at which of two files moved in some release.
if args[0] == "logs" {
    let follow = args.contains("-f") || args.contains("--follow")
    let lines = args.firstIndex(of: "-n").flatMap { i in
        i + 1 < args.count ? Int(args[i + 1]) : nil
    } ?? 200
    Logs.run(follow: follow, lines: lines)
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

// Every other verb is a fixed set of words, so rejoining what the shell split
// reconstructs it exactly. `exec` is the one whose argument is arbitrary text:
// `weftctl exec 'sed s/a  b/c/'` arrives as one argument that the shell has
// already unquoted, and joining it back with single spaces would rewrite it.
// One argument is passed through untouched; several are joined, which is what
// `weftctl exec echo hi` means anyway.
let text: String = {
    guard args[0] == "exec", args.count == 2 else { return args.joined(separator: " ") }
    return "exec " + args[1]
}()
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
