//
//  ArArchive.swift
//
//  Parses and rebuilds BSD-style ar archives, correctly preserving duplicate members.
//

import Foundation

struct ArMember {
    let name: String
    var data: Data
    let modificationTime: Int
    let ownerId: Int
    let groupId: Int
    let mode: Int
    
    init(name: String, data: Data, modificationTime: Int = 0, ownerId: Int = 0, groupId: Int = 0, mode: Int = 0o644) {
        self.name = name
        self.data = data
        self.modificationTime = modificationTime
        self.ownerId = ownerId
        self.groupId = groupId
        self.mode = mode
    }
}

enum ArArchiveError: Error, CustomStringConvertible {
    case cannotReadFile(String)
    case invalidArchive(String)
    case cannotWriteFile(String)
    
    var description: String {
        switch self {
        case .cannotReadFile(let path): return "Cannot read file: \(path)"
        case .invalidArchive(let msg): return "Invalid archive: \(msg)"
        case .cannotWriteFile(let path): return "Cannot write file: \(path)"
        }
    }
}

struct ArArchive {
    private static let arMagic = "!<arch>\n"
    private static let headerSize = 60
    
    static func parse(url: URL) throws -> [ArMember] {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ArArchiveError.cannotReadFile(url.path)
        }
        return try parse(data: data)
    }
    
    static func parse(data: Data) throws -> [ArMember] {
        guard data.count >= 8 else {
            throw ArArchiveError.invalidArchive("File too small")
        }
        
        let magic = String(data: Data(data[0..<8]), encoding: .ascii)
        guard magic == arMagic else {
            throw ArArchiveError.invalidArchive("Invalid ar magic: \(magic ?? "nil")")
        }
        
        var members: [ArMember] = []
        var offset = 8
        
        while offset + headerSize <= data.count {
            let header = Data(data[offset..<(offset + headerSize)])
            
            let rawName = String(data: header[0..<16], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
            let modTimeStr = String(data: header[16..<28], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "0"
            let ownerIdStr = String(data: header[28..<34], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "0"
            let groupIdStr = String(data: header[34..<40], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "0"
            let modeStr = String(data: header[40..<48], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "0"
            let sizeStr = String(data: header[48..<58], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
            
            guard let size = Int(sizeStr) else { break }
            
            offset += headerSize
            
            var name = rawName
            var contentOffset = offset
            var contentSize = size
            
            // Handle BSD long filename format: #1/N
            if rawName.hasPrefix("#1/") {
                let nameLengthStr = String(rawName.dropFirst(3))
                if let nameLength = Int(nameLengthStr) {
                    let nameData = Data(data[offset..<(offset + nameLength)])
                    name = String(data: nameData, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? rawName
                    contentOffset = offset + nameLength
                    contentSize = size - nameLength
                }
            }
            
            // Remove trailing slash (GNU ar format)
            if name.hasSuffix("/") {
                name = String(name.dropLast())
            }
            
            // Skip symbol table
            if name.hasPrefix("__.SYMDEF") || name == "" || name == "/" || name == "//" {
                offset += size
                if size % 2 == 1 { offset += 1 }
                continue
            }
            
            let content = Data(data[contentOffset..<(contentOffset + contentSize)])
            
            let member = ArMember(
                name: name,
                data: content,
                modificationTime: Int(modTimeStr) ?? 0,
                ownerId: Int(ownerIdStr) ?? 0,
                groupId: Int(groupIdStr) ?? 0,
                mode: Int(modeStr, radix: 8) ?? 0o644
            )
            members.append(member)
            
            offset += size
            if size % 2 == 1 { offset += 1 }
        }
        
        return members
    }
    
    static func write(members: [ArMember], to url: URL) throws {
        let data = try serialize(members: members)
        try data.write(to: url)
    }
    
    static func serialize(members: [ArMember]) throws -> Data {
        var output = Data()
        output.append(arMagic.data(using: .ascii)!)
        
        for member in members {
            let nameData = member.name.data(using: .utf8)!
            let nameLength = nameData.count
            let contentSize = member.data.count
            
            var header = Data(count: headerSize)
            
            // Use BSD long filename format for names > 16 chars or containing spaces
            let needsLongName = nameLength > 16 || member.name.contains(" ")
            let headerName: String
            let totalSize: Int
            
            if needsLongName {
                let paddedNameLength = (nameLength + 3) & ~3
                headerName = "#1/\(paddedNameLength)"
                totalSize = paddedNameLength + contentSize
            } else {
                headerName = member.name
                totalSize = contentSize
            }
            
            writeString(headerName, to: &header, at: 0, length: 16)
            writeString(String(member.modificationTime), to: &header, at: 16, length: 12)
            writeString(String(member.ownerId), to: &header, at: 28, length: 6)
            writeString(String(member.groupId), to: &header, at: 34, length: 6)
            writeString(String(member.mode, radix: 8), to: &header, at: 40, length: 8)
            writeString(String(totalSize), to: &header, at: 48, length: 10)
            
            header[58] = 0x60 // `
            header[59] = 0x0A // \n
            
            output.append(header)
            
            if needsLongName {
                let paddedNameLength = (nameLength + 3) & ~3
                var paddedName = nameData
                while paddedName.count < paddedNameLength {
                    paddedName.append(0)
                }
                output.append(paddedName)
            }
            
            output.append(member.data)
            
            if totalSize % 2 == 1 {
                output.append(0x0A)
            }
        }
        
        return output
    }
    
    private static func writeString(_ string: String, to data: inout Data, at offset: Int, length: Int) {
        let bytes = Array(string.utf8)
        for i in 0..<length {
            if i < bytes.count {
                data[offset + i] = bytes[i]
            } else {
                data[offset + i] = 0x20
            }
        }
    }
}
