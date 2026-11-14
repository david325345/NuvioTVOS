import Foundation

/// The fork's test build: the app's own symbol table, read from its executable (the test build
/// keeps it), to name the app functions the main thread is sampled in. `dladdr` sees exported
/// symbols only, so most of the app's functions came out as "?", and some under the exported
/// symbol before them.
final class AppSymbolTable: @unchecked Sendable {
    static let shared = AppSymbolTable()

    private let lock = NSLock()
    private var isLoaded = false
    private var addresses: [UInt64] = []
    private var nameOffsets: [UInt32] = []
    private var strings: [UInt8] = []
    private var textVMAddress: UInt64 = 0

    private init() {}

    /// The executable's own name: frames in it, not in the app's embedded frameworks, are the
    /// ones this table can name.
    private let executableSuffix = ".app/" + ((Bundle.main.executablePath as NSString?)?.lastPathComponent ?? "")

    /// The symbol `address` is in, given the image it is in (`imagePath`, loaded at
    /// `imageBase`), or nil when that isn't the app's executable or the table can't say.
    func name(for address: UInt, imageBase: UnsafeRawPointer, imagePath: String) -> String? {
        guard imagePath.hasSuffix(executableSuffix) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if !isLoaded {
            isLoaded = true
            load()
        }
        guard let first = addresses.first else { return nil }
        let unslid = UInt64(address) &- UInt64(UInt(bitPattern: imageBase)) &+ textVMAddress
        guard unslid >= first else { return nil }
        var low = 0
        var high = addresses.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if addresses[mid] <= unslid { low = mid } else { high = mid - 1 }
        }
        let start = Int(nameOffsets[low])
        guard start < strings.count else { return nil }
        var end = start
        while end < strings.count, strings[end] != 0 { end += 1 }
        var name = String(decoding: strings[start..<end], as: UTF8.self)
        if name.hasPrefix("_") { name.removeFirst() }
        return name.isEmpty ? nil : name
    }

    private func load() {
        guard let path = Bundle.main.executablePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            func u32(_ offset: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            func u64(_ offset: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            guard raw.count > 32, u32(0) == 0xFEED_FACF else { return }  // MH_MAGIC_64
            let commandCount = Int(u32(16))
            var offset = 32  // sizeof(mach_header_64)
            var symbolsAt = 0, symbolCount = 0, stringsAt = 0, stringsSize = 0
            for _ in 0..<commandCount {
                guard offset + 8 <= raw.count else { return }
                let command = u32(offset)
                let size = Int(u32(offset + 4))
                if command == 0x2 {  // LC_SYMTAB
                    symbolsAt = Int(u32(offset + 8))
                    symbolCount = Int(u32(offset + 12))
                    stringsAt = Int(u32(offset + 16))
                    stringsSize = Int(u32(offset + 20))
                } else if command == 0x19 {  // LC_SEGMENT_64
                    let name = raw[(offset + 8)..<(offset + 24)].prefix { $0 != 0 }
                    if String(decoding: name, as: UTF8.self) == "__TEXT" {
                        textVMAddress = u64(offset + 24)
                    }
                }
                guard size > 0 else { return }
                offset += size
            }
            guard symbolCount > 0, symbolsAt + symbolCount * 16 <= raw.count,
                  stringsAt + stringsSize <= raw.count else { return }
            var entries: [(address: UInt64, name: UInt32)] = []
            entries.reserveCapacity(symbolCount / 2)
            for index in 0..<symbolCount {
                let entry = symbolsAt + index * 16  // nlist_64
                let type = raw[entry + 4]
                // Not a debugging entry, and defined in a section (N_SECT).
                guard type & 0xE0 == 0, type & 0x0E == 0x0E else { continue }
                entries.append((u64(entry + 8), u32(entry)))
            }
            entries.sort { $0.address < $1.address }
            addresses = entries.map(\.address)
            nameOffsets = entries.map(\.name)
            strings = Array(raw[stringsAt..<(stringsAt + stringsSize)])
        }
    }
}
