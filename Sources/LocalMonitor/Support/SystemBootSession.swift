import Darwin
import Foundation

struct SystemBootSession {
    let id: UUID?
    let startedAt: Date?

    static let current: Self = {
        var uuid = [UInt8](repeating: 0, count: MemoryLayout<uuid_string_t>.size)
        var uuidSize = uuid.count
        let id: UUID? = uuid.withUnsafeMutableBytes { bytes in
            guard sysctlbyname("kern.bootsessionuuid", bytes.baseAddress, &uuidSize, nil, 0) == 0,
                  uuidSize == bytes.count, bytes.last == 0 else { return nil }
            return UUID(uuidString: String(decoding: bytes.dropLast(), as: UTF8.self))
        }

        var bootTime = timeval()
        var timeSize = MemoryLayout.size(ofValue: bootTime)
        guard sysctlbyname("kern.boottime", &bootTime, &timeSize, nil, 0) == 0 else {
            return Self(id: id, startedAt: nil)
        }
        let seconds = Double(bootTime.tv_sec) + Double(bootTime.tv_usec) / 1_000_000
        return Self(id: id, startedAt: Date(timeIntervalSince1970: seconds))
    }()
}
