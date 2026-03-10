import Foundation
import ArgumentParser

struct Arm64ToSim: ParsableCommand {
    
    static var configuration = CommandConfiguration(
        abstract: "A simple command-line tool for hacking native ARM64 binaries to run on the Apple Silicon iOS Simulator.",
        version: "1.2.0",
        subcommands: [Patch.self, Restore.self, Revert.self]
    )
    
}

extension Arm64ToSim {
    struct Patch: ParsableCommand {
        @Argument(help: "The path of the library to patch.")
        var path: String
        
        @Option()
        var minOS: UInt32 = 13
        
        @Option()
        var sdk: UInt32 = 13
        
        func run() throws {
            try Patcher.patch(atPath: path, minos: minOS, sdk: sdk)
        }
    }
    
    struct Restore: ParsableCommand {
        @Argument(help: "The path of the library to restore.")
        var path: String
        
        func run() throws {
            try Patcher.restore(atPath: path)
        }
    }
    
    struct Revert: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Revert a simulator arm64 static library back to device arm64 by changing platform from iOSSimulator to iOS."
        )
        
        @Argument(help: "The path of the simulator library to revert.")
        var path: String
        
        @Option(help: "Minimum OS version to set (default: keep existing).")
        var minOS: UInt32 = 0
        
        @Option(help: "SDK version to set (default: keep existing).")
        var sdk: UInt32 = 0
        
        func run() throws {
            try Patcher.revert(atPath: path, minos: minOS, sdk: sdk)
        }
    }
}

Arm64ToSim.main()
