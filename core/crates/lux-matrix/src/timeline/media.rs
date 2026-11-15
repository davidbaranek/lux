//! Media as files in the folder the app gives: pictures (rooms', people's, photos' thumbnails,
//! videos' posters) and originals. Loaded once each; the SDK decrypts encrypted media, and keeps
//! the pictures in its own cache besides (not the originals, which the files keep).

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use lux_core::ids::{EventId, MediaId, MessageId, RoomId};
use lux_core::ports::{BackendError, ChatMedia};
use lux_core::timeline::ImageSource;
use matrix_sdk::Room;
use matrix_sdk::media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings};
use matrix_sdk::ruma::UInt;
use matrix_sdk::ruma::events::room::MediaSource;
use matrix_sdk::ruma::events::room::message::MessageType;
use matrix_sdk::ruma::events::{AnySyncMessageLikeEvent, AnySyncTimelineEvent, SyncMessageLikeEvent};
use matrix_sdk::ruma::{OwnedEventId, OwnedMxcUri};
use sha2::{Digest, Sha256};
use tracing::debug;
use uuid::Uuid;

use super::MatrixTimelines;
use super::items::{media_key, media_of};
use crate::errors::from_sdk;

/// The side of a room's or a person's picture, in pixels.
const AVATAR_SIDE: u32 = 160;

/// The request of a room's or a person's picture at `url`, as the chat list loads it: the same
/// request finds what the SDK's media cache keeps of it (a notification's picture).
pub(crate) fn avatar(url: OwnedMxcUri) -> MediaRequestParameters {
    thumbnail(MediaSource::Plain(url), AVATAR_SIDE)
}

/// The picture at `media` as image file bytes: from the SDK's media cache, where the chat list put
/// it, else from the server within `within`; none when it cannot be had by then.
pub(crate) async fn avatar_bytes(
    client: &matrix_sdk::Client,
    media: Option<&MediaId>,
    within: std::time::Duration,
) -> Option<Vec<u8>> {
    let url = OwnedMxcUri::from(media?.as_str());
    if !url.is_valid() {
        return None;
    }
    let request = avatar(url);
    match tokio::time::timeout(within, picture_content(client, &request, true)).await {
        Ok(Ok(bytes)) => Some(bytes),
        Ok(Err(error)) => {
            tracing::warn!(%error, "a picture cannot be had");
            None
        }
        Err(_) => None,
    }
}

/// The side a photo's thumbnail is asked at, when the sender sent none.
const THUMBNAIL_SIDE: u32 = 800;

impl MatrixTimelines {
    /// A found photo's thumbnail, by its event: its file is named by the event, so a photo shown
    /// again (the same search typed on) does not ask the server for its event again.
    async fn found_thumbnail(
        &self,
        room: &RoomId,
        event: &EventId,
        folder: &Path,
    ) -> Result<Option<PathBuf>, BackendError> {
        let file = folder.join(found_file_name(event));
        if file.is_file() {
            return Ok(Some(file));
        }
        let Some(photo) = found_photo(&self.room(room)?, event).await? else {
            return Ok(None);
        };
        let request = photo.thumbnail.map_or_else(|| photo_thumbnail(photo.source), original);
        let data = picture_content(&self.client, &request, false).await.map_err(from_sdk)?;
        write(&file, data).await?;
        Ok(Some(file))
    }
}

impl ChatMedia for MatrixTimelines {
    async fn image_file(&self, source: &ImageSource, folder: &Path) -> Result<Option<PathBuf>, BackendError> {
        let request = match source {
            ImageSource::Room(room) => {
                let Some(url) = crate::mapping::room_picture(&self.room(room)?).await else {
                    return Ok(None);
                };
                avatar(url)
            }
            ImageSource::Person(media) => {
                let url = OwnedMxcUri::from(media.as_str());
                if !url.is_valid() {
                    return Ok(None);
                }
                avatar(url)
            }
            ImageSource::Photo { room, message } | ImageSource::Poster { room, message } => {
                let timeline = self.open(room).await?;
                let item = timeline.item(message).await.ok_or(BackendError::UnknownMessage)?;
                let Some(media) = media_of(&item) else {
                    return Ok(None);
                };
                match (media.thumbnail, source) {
                    (Some(thumbnail), _) => original(thumbnail),
                    (None, ImageSource::Poster { .. }) => return Ok(None),
                    (None, _) => photo_thumbnail(media.source),
                }
            }
            ImageSource::Found { room, event } => return self.found_thumbnail(room, event, folder).await,
        };
        let file = folder.join(file_name(&request));
        if file.is_file() {
            return Ok(Some(file));
        }
        // the file is the cache of an original.
        let data = picture_content(&self.client, &request, false).await.map_err(from_sdk)?;
        write(&file, data).await?;
        Ok(Some(file))
    }

    async fn media_file(&self, room: &RoomId, message: &MessageId, folder: &Path) -> Result<PathBuf, BackendError> {
        let timeline = self.open(room).await?;
        let item = timeline.item(message).await.ok_or(BackendError::UnknownMessage)?;
        let media = media_of(&item).ok_or(BackendError::NotAllowed)?;
        let request = original(media.source);
        // its own folder, so the file keeps the name it was sent with.
        let file = folder
            .join(file_name(&request))
            .join(safe_name(&media.filename, media.mimetype.as_deref()));
        if file.is_file() {
            return Ok(file);
        }
        // the file is the cache: a video is not kept twice.
        let data = self
            .client
            .media()
            .get_media_content(&request, false)
            .await
            .map_err(from_sdk)?;
        write(&file, data).await?;
        Ok(file)
    }

    async fn found_photo_file(
        &self,
        room: &RoomId,
        event: &EventId,
        folder: &Path,
    ) -> Result<Option<PathBuf>, BackendError> {
        let Some(photo) = found_photo(&self.room(room)?, event).await? else {
            return Ok(None);
        };
        let request = original(photo.source);
        let file = folder.join(file_name(&request));
        if !file.is_file() {
            // read once by the apps, then deleted: not kept in the SDK's cache.
            let data = self
                .client
                .media()
                .get_media_content(&request, false)
                .await
                .map_err(from_sdk)?;
            write(&file, data).await?;
        }
        Ok(Some(file))
    }

    async fn max_upload_size(&self) -> Result<u64, BackendError> {
        self.client
            .load_or_fetch_max_upload_size()
            .await
            .map(u64::from)
            .map_err(from_sdk)
    }
}

/// The bytes `request` asks for, from the SDK's media cache or the server. A server may make no
/// thumbnail of a picture (a small one, one a bridge serves itself, one it did not thumbnail
/// ahead and will not on demand): then the picture as it is, which the apps scale; kept in the
/// SDK's media cache when `cache_original`.
async fn picture_content(
    client: &matrix_sdk::Client,
    request: &MediaRequestParameters,
    cache_original: bool,
) -> matrix_sdk::Result<Vec<u8>> {
    let media = client.media();
    match media.get_media_content(request, true).await {
        Err(error) if matches!(request.format, MediaFormat::Thumbnail(_)) => {
            debug!(%error, "no thumbnail: the picture itself");
            media
                .get_media_content(&original(request.source.clone()), cache_original)
                .await
        }
        content => content,
    }
}

/// A photo's media, and its sender's thumbnail.
struct FoundPhoto {
    source: MediaSource,
    thumbnail: Option<MediaSource>,
}

/// The photo `event` sent, from the event cache or the server (decrypted); `None` when it is no
/// photo, or no longer one (deleted).
async fn found_photo(room: &Room, event: &EventId) -> Result<Option<FoundPhoto>, BackendError> {
    let event_id = OwnedEventId::try_from(event.as_str()).map_err(|_| BackendError::UnknownMessage)?;
    let event = room.load_or_fetch_event(&event_id, None).await.map_err(from_sdk)?;
    let Ok(AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(SyncMessageLikeEvent::Original(
        message,
    )))) = event.raw().deserialize()
    else {
        return Ok(None);
    };
    let MessageType::Image(image) = message.content.msgtype else {
        return Ok(None);
    };
    Ok(Some(FoundPhoto {
        thumbnail: image.info.and_then(|info| info.thumbnail_source),
        source: image.source,
    }))
}

/// A photo's thumbnail when its sender sent none: the server scales it, unless it is encrypted
/// (the server cannot read it), then the photo as it is, which the apps scale.
fn photo_thumbnail(source: MediaSource) -> MediaRequestParameters {
    match source {
        MediaSource::Plain(_) => thumbnail(source, THUMBNAIL_SIDE),
        MediaSource::Encrypted(_) => original(source),
    }
}

fn thumbnail(source: MediaSource, side: u32) -> MediaRequestParameters {
    MediaRequestParameters {
        source,
        format: MediaFormat::Thumbnail(MediaThumbnailSettings::new(UInt::from(side), UInt::from(side))),
    }
}

fn original(source: MediaSource) -> MediaRequestParameters {
    MediaRequestParameters {
        source,
        format: MediaFormat::File,
    }
}

/// A file name for a request: its media's URL, hashed (any URL, one name each), and its size.
fn file_name(request: &MediaRequestParameters) -> String {
    let key: MediaId = media_key(&request.source);
    let mut name = String::with_capacity(64 + 12);
    // writing to a string cannot fail.
    for byte in Sha256::digest(key.as_str()) {
        let _ = write!(name, "{byte:02x}");
    }
    if let MediaFormat::Thumbnail(settings) = &request.format {
        let _ = write!(name, "-{}x{}", settings.width, settings.height);
    }
    name
}

/// A found photo's thumbnail's file name: its event, hashed (any id, one name each).
fn found_file_name(event: &EventId) -> String {
    let mut name = String::with_capacity(64 + 6);
    name.push_str("found-");
    // writing to a string cannot fail.
    for byte in Sha256::digest(event.as_str()) {
        let _ = write!(name, "{byte:02x}");
    }
    name
}

/// A sent file's name as a file on the device: no folders, never empty, with an extension.
fn safe_name(name: &str, mimetype: Option<&str>) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or_default().trim();
    let base = if base.is_empty() || base == "." || base == ".." {
        "file"
    } else {
        base
    };
    if Path::new(base).extension().is_some() {
        return base.to_owned();
    }
    let extension = mimetype
        .and_then(|mimetype| mimetype.split('/').nth(1))
        .map(|subtype| subtype.split(['+', ';']).next().unwrap_or(subtype).trim())
        .filter(|subtype| !subtype.is_empty() && subtype.chars().all(|character| character.is_ascii_alphanumeric()));
    match extension {
        Some(extension) => format!("{base}.{extension}"),
        None => base.to_owned(),
    }
}

/// Writes a file whole (to a temporary name of its own, then renamed), off the async threads.
/// Two loads of the same media at once each write their own; the last rename wins, with the same
/// content.
async fn write(file: &Path, data: Vec<u8>) -> Result<(), BackendError> {
    let file = file.to_owned();
    tokio::task::spawn_blocking(move || {
        if let Some(folder) = file.parent() {
            std::fs::create_dir_all(folder)?;
        }
        let mut partial = file.clone().into_os_string();
        partial.push(format!(".{}.partial", Uuid::new_v4().simple()));
        std::fs::write(&partial, data)?;
        std::fs::rename(&partial, &file).or_else(|error| {
            let _ = std::fs::remove_file(&partial);
            if file.is_file() { Ok(()) } else { Err(error) }
        })
    })
    .await
    .map_err(BackendError::file)?
    .map_err(BackendError::file)
}

#[cfg(test)]
mod tests {
    use matrix_sdk::ruma::owned_mxc_uri;

    use super::*;

    #[test]
    fn file_names_are_one_per_url_and_tell_the_size() {
        let request = thumbnail(MediaSource::Plain(owned_mxc_uri!("mxc://example.org/abc-123")), 160);
        let name = file_name(&request);
        assert!(name.ends_with("-160x160"));
        assert!(
            name.chars()
                .all(|character| character.is_ascii_hexdigit() || "-x0123456789".contains(character))
        );
        // these two read alike once their punctuation is gone.
        let one = file_name(&original(MediaSource::Plain(owned_mxc_uri!("mxc://a-b.org/x"))));
        let other = file_name(&original(MediaSource::Plain(owned_mxc_uri!("mxc://a.b-org/x"))));
        assert_ne!(one, other);
        assert_eq!(one.len(), 64);
    }

    #[test]
    fn a_sent_name_keeps_its_name_and_gets_an_extension() {
        assert_eq!(safe_name("Trip plan.pdf", Some("application/pdf")), "Trip plan.pdf");
        assert_eq!(safe_name("../../etc/passwd", None), "passwd");
        assert_eq!(safe_name("", Some("image/svg+xml")), "file.svg");
        assert_eq!(safe_name("voice", Some("audio/ogg; codecs=opus")), "voice.ogg");
    }
}
