import Foundation
import Testing
@testable import Triage

struct ScrollBarVisibilityTests {
    @Test func savesAppKitsPerAppDefault() throws {
        let name = "ScrollBarVisibilityTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        ScrollBarVisibility.whenScrolling.save(defaults)
        #expect(defaults.string(forKey: ScrollBarVisibility.key) == "WhenScrolling")
        ScrollBarVisibility.always.save(defaults)
        #expect(defaults.string(forKey: ScrollBarVisibility.key) == "Always")
        ScrollBarVisibility.system.save(defaults)
        #expect(defaults.object(forKey: ScrollBarVisibility.key) == nil)
    }
}
