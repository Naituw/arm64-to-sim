//
//  File.swift
//  
//
//  Created by Luo Sheng on 2021/12/3.
//

import Foundation
import ShellOut

struct Patcher {
    
    private static let ORIGINAL_EXTENSION = "original"
    private static let PATCH_EXTENSION = "patched"
    
    private static func getArchitectures(atUrl url: URL) throws -> [String] {
        let output = try shellOut(to: "file", arguments: [url.path])
        let pattern = #"for architecture (?<arch>\w*)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsrange = NSRange(output.startIndex..<output.endIndex,
                              in: output)
        let matches = regex.matches(in: output, options: [], range: nsrange)
        return matches.map { match in
            guard let range = Range(match.range(withName: "arch"), in: output) else {
                return nil
            }
            return String(output[range])
        }.compactMap { $0 }
    }
    
    private static func extract(inputFileAtUrl url: URL, withArch arch: String, toURL: URL) throws {
        try shellOut(to: "lipo", arguments: [
            "-thin",
            arch,
            url.path,
            "-output",
            "lib.\(arch)"
        ], at: toURL.path)
    }
    
    static func patch(atPath path: String, minos: UInt32, sdk: UInt32) throws {
        let url = URL(fileURLWithPath: path).absoluteURL
        let patchedUrl = url.appendingPathExtension(PATCH_EXTENSION)
        if FileManager.default.fileExists(atPath: patchedUrl.path) {
            try link(url, withDestinationUrl: patchedUrl)
            return
        }
        
        let extractionUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: extractionUrl, withIntermediateDirectories: true, attributes: nil)
        let archs = try getArchitectures(atUrl: url)
        if archs.count == 0 {
            try FileManager.default.copyItem(at: url, to: extractionUrl.appendingPathComponent("lib.arm64"))
        } else {
            try archs.forEach { arch in
                try extract(inputFileAtUrl: url, withArch: arch, toURL: extractionUrl)
            }
        }
        
        // Use ArArchive to properly handle duplicate members
        let arm64LibUrl = extractionUrl.appendingPathComponent("lib.arm64")
        try processStaticLibrary(at: arm64LibUrl, minos: minos, sdk: sdk)
        
        FileManager.default.changeCurrentDirectoryPath(extractionUrl.path)
        try shellOut(to: "lipo", arguments: ["-create", "-output", url.lastPathComponent, "lib.*"])
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension(ORIGINAL_EXTENSION))
        try FileManager.default.moveItem(at: extractionUrl.appendingPathComponent(url.lastPathComponent), to: patchedUrl)
        try link(url, withDestinationUrl: patchedUrl)
    }
    
    /// Process static library using ArArchive to preserve duplicate members
    private static func processStaticLibrary(at url: URL, minos: UInt32, sdk: UInt32) throws {
        // Parse the archive, preserving all members including duplicates
        var members = try ArArchive.parse(url: url)
        
        // Process each .o member in memory
        for i in 0..<members.count {
            guard members[i].name.hasSuffix(".o") else { continue }
            
            do {
                members[i].data = try Transmogrifier.processData(members[i].data, minos: minos, sdk: sdk)
            } catch {
                // Skip files that can't be processed (e.g., already processed)
                continue
            }
        }
        
        // Write back the archive with all members preserved
        try ArArchive.write(members: members, to: url)
        
        // Regenerate symbol table
        _ = try? shellOut(to: "ranlib", arguments: [url.path])
    }
    
    private static func link(_ url: URL, withDestinationUrl destUrl: URL) throws {
        guard FileManager.default.fileExists(atPath: destUrl.path) else {
            fatalError("Can not find file at \(destUrl.path)")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destUrl)
    }
    
    static func restore(atPath path: String) throws {
        let url = URL(fileURLWithPath: path).absoluteURL
        try link(url, withDestinationUrl: url.appendingPathExtension(ORIGINAL_EXTENSION))
    }
    
    /// Revert a patched simulator arm64 static library back to device arm64
    static func revert(atPath path: String, minos: UInt32, sdk: UInt32) throws {
        let url = URL(fileURLWithPath: path).absoluteURL
        let revertedUrl = url.appendingPathExtension("reverted")
        if FileManager.default.fileExists(atPath: revertedUrl.path) {
            try link(url, withDestinationUrl: revertedUrl)
            return
        }
        
        let extractionUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: extractionUrl, withIntermediateDirectories: true, attributes: nil)
        let archs = try getArchitectures(atUrl: url)
        if archs.count == 0 {
            try FileManager.default.copyItem(at: url, to: extractionUrl.appendingPathComponent("lib.arm64"))
        } else {
            try archs.forEach { arch in
                try extract(inputFileAtUrl: url, withArch: arch, toURL: extractionUrl)
            }
        }
        
        let arm64LibUrl = extractionUrl.appendingPathComponent("lib.arm64")
        try revertStaticLibrary(at: arm64LibUrl, minos: minos, sdk: sdk)
        
        FileManager.default.changeCurrentDirectoryPath(extractionUrl.path)
        try shellOut(to: "lipo", arguments: ["-create", "-output", url.lastPathComponent, "lib.*"])
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("sim"))
        try FileManager.default.moveItem(at: extractionUrl.appendingPathComponent(url.lastPathComponent), to: revertedUrl)
        try link(url, withDestinationUrl: revertedUrl)
    }
    
    private static func revertStaticLibrary(at url: URL, minos: UInt32, sdk: UInt32) throws {
        var members = try ArArchive.parse(url: url)
        
        for i in 0..<members.count {
            guard members[i].name.hasSuffix(".o") else { continue }
            do {
                members[i].data = try Transmogrifier.revertData(members[i].data, minos: minos, sdk: sdk)
            } catch {
                continue
            }
        }
        
        try ArArchive.write(members: members, to: url)
        _ = try? shellOut(to: "ranlib", arguments: [url.path])
    }
}
