# Agents

[CONTRIBUTING.md](CONTRIBUTING.md) holds the build, layering and code style. These rules are for
the UI code in `Apps/` and the UI-facing Swift in `Sources/LuxCore`.

## UIKit and AppKit

- Use Apple's canonical API over hand-rolled logic. Before building UI plumbing (lists, sizing,
  observation, images, keyboard, formatting), check [developer.apple.com](https://developer.apple.com/documentation/)
  for the API that already does it. Its JSON form reads as text:
  `https://developer.apple.com/tutorials/data/documentation/uikit/<symbol>.json`.
- A diffable snapshot says only which items exist and in what order. Apply one when items come,
  go or move, never for a content-only change, and never `reconfigureItems(snapshot.itemIdentifiers)`.
- A visible cell's content changes through its `configurationUpdateHandler` and
  `setNeedsUpdateConfiguration()`; a list cell resizes itself (`UICollectionView.selfSizingInvalidation`).
  On the Mac, a visible row is shown again in place and `noteHeightOfRows(withIndexesChanged:)`
  says which heights changed.
- No `reloadData` for an update: `NSTableViewDiffableDataSource`, `NSCollectionViewDiffableDataSource`
  and `UICollectionViewDiffableDataSource` keep the rows that stay.
- No work on the main thread per model tick. A model that changes many times a second (indexing,
  catching up, typing) must not rebuild a list, decode an image or measure text on each change.
- Images decode off the main thread at their display size (`ImagePipeline`,
  `CGImageSourceCreateThumbnailAtIndex`, `UIImage.byPreparingThumbnail(ofSize:)`).
- Paging starts from the list's own display callbacks (`willDisplay`, `tableView(_:didAdd:forRow:)`),
  not from scroll-bounds notifications.
- Measure hitches: wrap the work in `Signposts` intervals and check it with the Animation Hitches
  instrument or `-LuxBenchmark` before and after a change to a list.
