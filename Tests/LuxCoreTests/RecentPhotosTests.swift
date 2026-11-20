import Photos
import Testing
@testable import LuxCore

/// The newest photos under the composer's +: what the library's permission opens, which photos
/// are picked and in what order, and which of a photo's files goes.
struct RecentPhotosTests {
    @Test func fullAccessShowsTheLibraryLimitedShowsWhatWasSharedAndNoAccessFallsBackToThePicker() {
        #expect(RecentPhotos.Access(.authorized) == .grid(limited: false))
        #expect(RecentPhotos.Access(.limited) == .grid(limited: true))
        #expect(RecentPhotos.Access(.denied) == .picker)
        #expect(RecentPhotos.Access(.restricted) == .picker)
        #expect(RecentPhotos.Access(.notDetermined) == .picker)
    }

    @Test func photosGoInTheOrderTheyWerePickedAndATapAgainPutsOneBack() {
        var selection = RecentPhotoSelection()
        selection.toggle("c")
        selection.toggle("a")
        selection.toggle("b")
        #expect(selection.ids == ["c", "a", "b"])
        selection.toggle("a")
        #expect(selection.ids == ["c", "b"])
    }

    @Test func aFullSelectionTakesNoMoreThanThePickerDoes() {
        var selection = RecentPhotoSelection()
        for index in 0..<RecentPhotos.selectionLimit {
            let taken = selection.toggle("\(index)")
            #expect(taken)
        }
        #expect(selection.isFull)
        let refused = !selection.toggle("one more")
        #expect(refused)
        #expect(selection.ids.count == RecentPhotos.selectionLimit)
        // one put back makes room again.
        selection.toggle("0")
        selection.toggle("one more")
        #expect(selection.ids.last == "one more")
    }

    @Test func aPhotoGoneFromTheLibraryIsNoLongerPicked() {
        var selection = RecentPhotoSelection()
        selection.toggle("kept")
        selection.toggle("deleted")
        selection.keep(only: ["kept", "new"])
        #expect(selection.ids == ["kept"])
    }

    @Test func aPhotoGoesAsTheLibraryShowsItEditedNotItsMotionOrItsAdjustments() {
        // an edited Live Photo: the original, the edit, its motion and the edit's data.
        let types: [PHAssetResourceType] = [.photo, .pairedVideo, .adjustmentData, .fullSizePhoto, .fullSizePairedVideo]
        #expect(RecentPhotos.original(among: types) == 3)
        #expect(RecentPhotos.original(among: [.pairedVideo, .photo]) == 1)
        #expect(RecentPhotos.original(among: [.video, .fullSizeVideo, .adjustmentData]) == 1)
        #expect(RecentPhotos.original(among: [.video]) == 0)
        #expect(RecentPhotos.original(among: [.adjustmentData]) == nil)
    }
}
