import Foundation
import Testing
@testable import LuxCore

struct AlbumTests {
    @Test func theGridHasTwoColumnsForTwoOrFourAndThreeOtherwise() {
        #expect(MessageLayout.albumGrid(count: 4, width: 242).tiles.map { $0.width } == Array(repeating: 120, count: 4))
        let five = MessageLayout.albumGrid(count: 5, width: 242)
        #expect(five.tiles.count == 5 && five.tiles[3].minY > 0 && five.size.width <= 242)
    }
}
