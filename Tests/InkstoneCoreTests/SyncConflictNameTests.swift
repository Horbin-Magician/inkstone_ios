import Foundation
import Testing
@testable import InkstoneCore

struct SyncConflictNameTests {
    @Test(arguments: [String(repeating: "中", count: 84) + ".md", String(repeating: "😀", count: 63) + ".md"])
    func longNamesReserveUTF8SuffixSpace(path: String) throws {
        let old = digest(Data("old".utf8)), local = digest(Data("local".utf8)), remote = digest(Data("remote".utf8))
        let (merged, _) = try SyncManifest.merge(base: [path: old], local: [path: local], remote: SyncManifest(files: [path: remote]))
        let copy = try #require(merged.files.keys.first { $0 != path })
        #expect(copy.utf8.count <= 255)
        #expect(copy.hasSuffix(".md"))
        #expect(merged.files[copy] == remote)
        let repeated = try SyncManifest.merge(base: merged.files, local: merged.files, remote: merged).0
        #expect(repeated == merged)
    }

    @Test func occupiedConflictNameGetsDeterministicAlternative() throws {
        let old = digest(Data("old".utf8)), local = digest(Data("local".utf8)), remote = digest(Data("remote".utf8))
        let occupied = "note (云端冲突 \(remote)).md"
        let base = ["note.md": old, occupied: old]
        let current = ["note.md": local, occupied: old]
        let server = SyncManifest(files: ["note.md": remote, occupied: old])
        let result = try SyncManifest.merge(base: base, local: current, remote: server).0
        #expect(result.files[occupied] == old)
        #expect(result.files["note (云端冲突 \(remote) 2).md"] == remote)
        #expect(try SyncManifest.merge(base: base, local: current, remote: server).0 == result)
    }
}
