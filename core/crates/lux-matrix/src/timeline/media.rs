//! Media as files in the folder the app gives: pictures (rooms', people's, photos' thumbnails,
//! videos' posters) and originals. Loaded once each; the SDK decrypts encrypted media, and keeps
//! the pictures in its own cache besides (not the originals, which the files keep).

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use lux_core::ids::{EventId, MediaId, MessageId, RoomId};
use lux_core::ports::{BackendError, ChatMedia};
use lux_core::timeline::ImageSource;
use matrix_sdk::media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings};
use matrix_sdk::ruma::OwnedMxcUri;
use matrix_sdk::ruma::UInt;
use matrix_sdk::ruma::events::room::MediaSource;
use sha2::{Digest, Sha256};
use tracing::debug;
use uuid::Uuid;

use super::MatrixTimelines;
use super::items::{MediaOf, media_key, media_of};
use super::shared::event_media;
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

impl ChatMedia for MatrixTimelines {
    async fn image_file(&self, source: &ImageSource, folder: &Path) -> Result<Option<PathBuf>, BackendError> {
        // a picture by its event is kept by its event: shown again (a search typed on, the chat's
        // details opened again), no server is asked for the event again.
        let by_event = match source {
            ImageSource::Shared { event, .. } => Some(folder.join(event_file_name(event))),
            _ => None,
        };
        if let Some(file) = &by_event
            && file.is_file()
        {
            return Ok(Some(file.clone()));
        }
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
            ImageSource::Photo { .. } | ImageSource::Poster { .. } | ImageSource::Shared { .. } => {
                let media = match source {
                    ImageSource::Photo { room, message } | ImageSource::Poster { room, message } => {
                        let timeline = self.open(room).await?;
                        let item = timeline.item(message).await.ok_or(BackendError::UnknownMessage)?;
                        media_of(&item)
                    }
                    ImageSource::Shared { room, event } => event_media(&self.room(room)?, event).await?,
                    ImageSource::Room(_) | ImageSource::Person(_) => None,
                };
                let Some(media) = media else {
                    return Ok(None);
                };
                match (media.thumbnail, source) {
                    // the sender's thumbnail or poster, as it is.
                    (Some(thumbnail), _) => original(thumbnail),
                    (None, ImageSource::Poster { .. }) => return Ok(None),
                    (None, ImageSource::Shared { .. }) if is_video(media.mimetype.as_deref()) => return Ok(None),
                    // a photo without one: the server scales it, unless it is encrypted.
                    (None, _) => match media.source {
                        MediaSource::Plain(_) => thumbnail(media.source, THUMBNAIL_SIDE),
                        MediaSource::Encrypted(_) => original(media.source),
                    },
                }
            }
        };
        let file = by_event.unwrap_or_else(|| folder.join(file_name(&request)));
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
        self.original_file(media, folder).await
    }

    async fn shared_file(&self, room: &RoomId, event: &EventId, folder: &Path) -> Result<PathBuf, BackendError> {
        let media = event_media(&self.room(room)?, event)
            .await?
            .ok_or(BackendError::NotAllowed)?;
        self.original_file(media, folder).await
    }

    async fn max_upload_size(&self) -> Result<u64, BackendError> {
        self.client
            .load_or_fetch_max_upload_size()
            .await
            .map(u64::from)
            .map_err(from_sdk)
    }
}

impl MatrixTimelines {
    /// The media's original, loaded once into `folder`.
    async fn original_file(&self, media: MediaOf, folder: &Path) -> Result<PathBuf, BackendError> {
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
}

fn is_video(mimetype: Option<&str>) -> bool {
    mimetype.is_some_and(|mimetype| mimetype.starts_with("video/"))
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

/// The file name of a picture by its event: the event, hashed (any id, one name each).
fn event_file_name(event: &EventId) -> String {
    let mut name = String::with_capacity(6 + 64);
    name.push_str("event-");
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
