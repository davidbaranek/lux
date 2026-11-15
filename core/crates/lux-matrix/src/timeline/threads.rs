//! A room's Matrix threads, a page at a time from the server's list (`/threads`), the latest
//! active first: each root with its bundled summary, who took part and how much is unread as
//! the device knows it.

use lux_core::ids::{EventId, MediaId, UserId};
use lux_core::ports::{BackendError, ListedThread, ThreadPage};
use lux_core::preview::PreviewKind;
use lux_core::timeline::{Participant, ThreadReply, ThreadSummary};
use matrix_sdk::Room;
use matrix_sdk::deserialized_responses::TimelineEvent;
use matrix_sdk::room::ListThreadsOptions;
use matrix_sdk::ruma::events::AnySyncTimelineEvent;
use matrix_sdk::ruma::{OwnedUserId, UInt, UserId as SdkUserId};

use super::items::thread_activity;
use crate::convert::{member_name, system_time};
use crate::errors::from_sdk;
use crate::mapping::event_kind;

/// How many threads a page asks the server for.
const PAGE: u32 = 20;

/// The page of the room's threads from `from` (the latest active first when `None`).
pub(crate) async fn page(room: &Room, from: Option<&str>) -> Result<ThreadPage, BackendError> {
    let roots = room
        .list_threads(ListThreadsOptions {
            from: from.map(ToOwned::to_owned),
            limit: Some(UInt::from(PAGE)),
            ..ListThreadsOptions::default()
        })
        .await
        .map_err(from_sdk)?;
    let mut threads = Vec::with_capacity(roots.chunk.len());
    for root in &roots.chunk {
        if let Some(thread) = listed(room, root).await {
            threads.push(thread);
        }
    }
    Ok(ThreadPage {
        threads,
        next: roots.prev_batch_token,
    })
}

/// A thread as the list shows it, from its root as the server sent it.
async fn listed(room: &Room, started_by: &TimelineEvent) -> Option<ListedThread> {
    let root_id = started_by.event_id()?;
    let event = started_by.raw().deserialize().ok()?;
    let (bundled, latest) = match started_by.thread_summary_with_latest_event() {
        Some((summary, latest)) => (summary.num_replies, latest.raw().deserialize().ok()),
        None => (0, None),
    };
    let latest = match latest {
        Some(latest) => Some(reply(room, &latest).await),
        None => None,
    };
    let (repliers, unread) = thread_activity(room, root_id).await;
    let mut participants: Vec<Participant> = latest.iter().map(|latest| latest.sender.clone()).collect();
    for sender in repliers {
        if participants.iter().all(|known| known.user.as_str() != sender.as_str()) {
            participants.push(participant(room, &sender).await);
        }
    }
    Some(ListedThread {
        root: EventId::from(root_id.as_str()),
        sender: participant(room, event.sender()).await,
        kind: event_kind(&event).unwrap_or(PreviewKind::Other),
        date: system_time(event.origin_server_ts()),
        summary: ThreadSummary {
            replies: bundled,
            latest,
            participants,
            unread,
        },
    })
}

/// A thread's last reply.
async fn reply(room: &Room, event: &AnySyncTimelineEvent) -> ThreadReply {
    ThreadReply {
        sender: participant(room, event.sender()).await,
        kind: event_kind(event).unwrap_or(PreviewKind::Other),
        date: system_time(event.origin_server_ts()),
    }
}

/// A member, by their name and picture in the room.
async fn participant(room: &Room, user: &SdkUserId) -> Participant {
    let avatar = match room.get_member_no_sync(user).await {
        Ok(Some(member)) => member.avatar_url().map(|url| MediaId::from(url.as_str())),
        _ => None,
    };
    let user: OwnedUserId = user.to_owned();
    Participant {
        name: member_name(room, &user).await,
        user: UserId::from(user.as_str()),
        avatar,
    }
}
