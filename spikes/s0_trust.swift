import ApplicationServices
import Foundation

let trusted = AXIsProcessTrusted()
print("AXIsProcessTrusted: \(trusted)")
print("pid: \(getpid()), ppid: \(getppid())")
