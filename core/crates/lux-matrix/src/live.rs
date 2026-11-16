//! The notifications of what the sync brings while the app runs: where no push wakes an
//! extension (the Mac), the app shows these itself.
//!
//! The SDK evaluates the account's push rules on each event a sync brings and hands the ones
//! that notify to a notification handler (registered once per client: it cannot be removed).
//! The handler only passes them on; one task makes each a [`Notification`] (the chat as the list
//! names it, the merged chat it is part of) while someone follows, and each follower keeps its own
//! [`LiveNotifications`] (what is new to it, each once).

use lux_core::gone::OtherEndGone;
use std::sync::Arc;
use std::time::SystemTime;

use futures_util::stream;
use lux_core::ids::{EventId, RoomId};
use lux_core::merge;
use lux_core::organizer::Organized;
use lux_core::ports::NotificationStream;
use lux_core::preview::PreviewKind;
use lux_core::push::{LiveNotifications, Notification, NotifiedChat, NotifiedSender, SyncedEvent};
use matrix_sdk::deserialized_responses::RawAnySyncOrStrippedTimelineEvent;
use matrix_sdk::ruma::OwnedUserId;
use matrix_sdk::ruma::push::{Action, Tweak};
use matrix_sdk::sync::Notification as SdkNotification;
use matrix_sdk::{Client, Room};
use tokio::sync::{broadcast, mpsc, watch};

use crate::convert::system_time;
use crate::mapping;

/// A notifying event the sync brought, with the facts that decide whether it shows.
#[derive(Clone, Debug)]
struct Candidate {
    notification: Notification,
    sent: SystemTime,
    is_own: bool,
    is_noisy: bool,
    is_read: bool,
}

/// The account's live notifications: the SDK's handler, the task that words its events, and
/// the channel its followers listen to.
pub(crate) struct LiveFeed {
    candidates: broadcast::Sender<Arc<Candidate>>,
    _task: crate::task::Owned,
}

impl LiveFeed {
    /// How many events a slow follower may fall behind before it misses some.
    const BACKLOG: usize = 64;

    /// Registers the handler on `client` and starts the task; `organized` names the merges.
    pub(crate) async fn start(client: &Client, own: OwnedUserId, organized: watch::Receiver<Arc<Organized>>) -> Self {
        let (synced, receiver) = mpsc::unbounded_channel();
        client
            .register_notification_handler(move |notification: SdkNotification, room: Room, _: Client| {
                // the task may have ended with the account: then nobody follows.
                synced
                    .send((notification, room))
                    .other_end_may_be_gone("the notifications' task");
                async {}
            })
            .await;
        let (candidates, _) = broadcast::channel(Self::BACKLOG);
        let task = crate::task::spawn(run(receiver, candidates.clone(), own, organized));
        Self {
            candidates,
            _task: task,
        }
    }

    /// The notifications of what the sync brings from now on.
    pub(crate) fn follow(&self) -> NotificationStream {
        let state = (self.candidates.subscribe(), LiveNotifications::new(SystemTime::now()));
        Box::pin(stream::unfold(state, |(mut candidates, mut live)| async move {
            loop {
                match candidates.recv().await {
                    Ok(candidate) => {
                        let synced = SyncedEvent {
                            event: &candidate.notification.event,
                            sent: candidate.sent,
                            is_own: candidate.is_own,
                            is_noisy: candidate.is_noisy,
                            is_read: candidate.is_read,
                        };
                        if live.admits(&synced) {
                            let notification = candidate.notification.clone();
                            return Some((notification, (candidates, live)));
                        }
                    }
                    // a burst while the app was slow: the ones missed stay in the chat list.
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return None,
                }
            }
        }))
    }
}

/// Words each event the handler passes on, while anyone follows.
async fn run(
    mut synced: mpsc::UnboundedReceiver<(SdkNotification, Room)>,
    candidates: broadcast::Sender<Arc<Candidate>>,
    own: OwnedUserId,
    organized: watch::Receiver<Arc<Organized>>,
) {
    while let Some((notification, room)) = synced.recv().await {
        if candidates.receiver_count() == 0 {
            continue;
        }
        let merges = Arc::clone(&organized.borrow());
        if let Some(candidate) = candidate(&notification, &room, &own, &merges).await {
            // nobody followed by now: nothing lost.
            candidates
                .send(Arc::new(candidate))
                .other_end_may_be_gone("the notifications' followers");
        }
    }
}

/// The candidate of one notifying event; none for one no follower shows (the account's own, a
/// silent one, one read elsewhere), an invite (no message to show), or one that cannot be read.
async fn candidate(
    notification: &SdkNotification,
    room: &Room,
    own: &OwnedUserId,
    organized: &Organized,
) -> Option<Candidate> {
    let RawAnySyncOrStrippedTimelineEvent::Sync(raw) = &notification.event else {
        return None;
    };
    let event = raw.deserialize().ok()?;
    let is_own = event.sender() == own;
    let is_noisy = notification
        .actions
        .iter()
        .any(|action| matches!(action, Action::SetTweak(Tweak::Sound(_))));
    // read on another device: both the server's count and the receipts' say nothing is left.
    let is_read = room.unread_notification_counts().notification_count == 0 && room.num_unread_notifications() == 0;
    let sent = system_time(event.origin_server_ts());
    // what no follower shows is not worded (the followers' filter says the same).
    if is_own || !is_noisy || is_read {
        return None;
    }
    let heroes = room.heroes().await;
    let mapping::Looks { is_group, picture, .. } = mapping::Looks::of(room, &heroes).await;
    let name = mapping::display_name(room);
    let picture = picture.map(|url| url.to_string());
    let room_id = RoomId::from(room.room_id().as_str());
    let member = room.get_member_no_sync(event.sender()).await.ok().flatten();
    let sender_picture = member
        .as_ref()
        .and_then(|member| member.avatar_url())
        .map(ToString::to_string);
    let notification = Notification::new(
        NotifiedChat {
            room: &room_id,
            name: &name,
            is_group,
            picture: picture.as_deref(),
            merge: merge::containing(&organized.merges, &room_id),
        },
        EventId::from(event.event_id().as_str()),
        NotifiedSender {
            id: event.sender().as_str(),
            name: member.as_ref().and_then(|member| member.display_name()),
            localpart: event.sender().localpart(),
            picture: sender_picture.as_deref(),
        },
        mapping::event_kind(&event).unwrap_or(PreviewKind::Other),
        is_noisy,
    )
    .in_thread(mapping::thread_root(&event));
    Some(Candidate {
        notification,
        sent,
        is_own,
        is_noisy,
        is_read,
    })
}
