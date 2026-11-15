import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Downloads photo search's model (an Apple-hosted asset pack, `PhotoSearchAssets`) when the
/// system schedules it, and keeps it up to date while the app is not running. The pack is
/// on-demand: the system never downloads it on its own, only once the app asks (photo search
/// turned on); the system's own downloader does the rest.
@main
struct DownloaderExtension: StoreDownloaderExtension {}
