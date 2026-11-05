import Foundation
import Darwin

@main enum PrivilegedHelperMain {
    static func main() {
        guard geteuid() == 0 else { exit(EX_NOPERM) }
        umask(0o077)
        if CommandLine.arguments.count > 1 {
            do {
                let arguments = Array(CommandLine.arguments.dropFirst())
                if arguments.first == FSKitWriteProbe.mode {
                    try FileHandle.standardOutput.write(contentsOf: FSKitWriteProbe.execute(arguments))
                    exit(EX_OK)
                }
                try FSKitMountBridge.execute(arguments)
            }
            catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(EX_OSERR)
            }
        }
        let delegate = PrivilegedMountListener()
        let listener = NSXPCListener(machServiceName: PrivilegedMountConfiguration.machServiceName)
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime(delegate) { RunLoop.current.run() }
    }
}
