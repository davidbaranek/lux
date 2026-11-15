//! A room as the chat list shows it: [`Chat`] for a joined room, [`Request`] for an invite.

use std::collections::{HashMap, HashSet};

use crate::bridge_state::bridge_states;
use lux_core::chat::{Chat, Folder, Request};
use lux_core::ids::{ChatId, MediaId, RoomId};
use lux_core::network::Network;
use lux_core::preview::{Membership, Preview, PreviewKind, PreviewSource, Sender};
use matrix_sdk::Room;
use matrix_sdk::latest_events::LatestEventValue;
use matrix_sdk::ruma::events::room::member::MembershipChange;
use matrix_sdk::ruma::events::room::message::{MessageType, Relation};
use matrix_sdk::ruma::events::{
    AnyMessageLikeEventContent, AnySyncMessageLikeEvent, AnySyncStateEvent, AnySyncTimelineEvent,
    MessageLikeEventContent as _, SyncStateEvent,
};
use matrix_sdk::ruma::{OwnedDirectUserIdentifier, OwnedMxcUri, OwnedRoomId, OwnedUserId, UserId};
use matrix_sdk_base::RoomHeroWithProfile;
use tracing::debug;

/// Maps rooms to rows. Owned by one list's task, it remembers the network a room's bridge
/// state events name, so a room's next update (each new message) reads it not again. One the
/// store does not hold yet (a fresh store has none until a chat loads its state) is read again
/// next time. [`Mapper::forget`] starts again. A preview sender's name is read each time: a
/// member may rename.
#[derive(Debug, Default)]
pub(crate) struct Mapper {
    bridges: HashMap<OwnedRoomId, Network>,
}

impl Mapper {
    /// Forgets what it remembered (the whole list comes again).
    pub(crate) fn forget(&mut self) {
        self.bridges.clear();
    }

    /// A joined room as a chat-list row.
    pub(crate) async fn chat(&mut self, room: &Room, own: &UserId) -> Chat {
        let heroes = room.heroes().await;
        let Looks {
            is_group,
            picture,
            member_pictures,
            members,
        } = Looks::of(room, &heroes).await;
        let latest = crate::latest::row_event(room, own).await;
        let date = crate::latest::row_time(room, &latest)
            .await
            .map(crate::convert::system_time);
        let preview = self.preview_line(room, &latest, own, is_group).await;
        let network = self.network(room, own, &members).await;
        let avatar = picture.map(|url| MediaId::from(url.as_str()));
        let member_avatars = member_pictures.iter().map(|url| MediaId::from(url.as_str())).collect();
        let pinned = if room.is_favourite() {
            // a pin without an order goes last.
            Some(crate::actions::favourite_order(room).await.unwrap_or(1.0))
        } else {
            None
        };
        Chat {
            id: ChatId::Room(RoomId::from(room.room_id().as_str())),
            name: display_name(room),
            preview,
            date,
            unread_count: u32::try_from(room.num_unread_messages()).unwrap_or(u32::MAX),
            unread_mentions: u32::try_from(room.num_unread_mentions()).unwrap_or(u32::MAX),
            is_marked_unread: room.is_marked_unread(),
            // the room list's push rules decide it (`ChatRows`): muted or mentions only.
            is_muted: false,
            network,
            avatar,
            member_avatars,
            // reminders, folders other than low priority, and merges are the account data's.
            reminder: None,
            is_group,
            folder: if room.is_low_priority() {
                Folder::LowPriority
            } else {
                Folder::Inbox
            },
            pinned,
            rooms: Vec::new(),
            default_room: None,
        }
    }

    /// An invited room as a request.
    pub(crate) async fn request(room: &Room) -> Request {
        let inviter_name = match room.invite_details().await {
            Ok(invite) => match invite.inviter.as_ref().and_then(|inviter| inviter.display_name()) {
                Some(name) => name.to_owned(),
                None => invite.inviter_id.localpart().to_owned(),
            },
            Err(_) => String::new(),
        };
        Request {
            id: RoomId::from(room.room_id().as_str()),
            name: display_name(room),
            avatar: room.avatar_url().map(|url| MediaId::from(url.as_str())),
            inviter_name,
            is_direct: room.is_direct().await.unwrap_or(false),
        }
    }

    /// The room's network: its bridge's state event, else its bridge's users (`known`, the
    /// people and bots this device knows of in the room), looked at again on each update.
    async fn network(&mut self, room: &Room, own: &UserId, known: &[OwnedUserId]) -> Network {
        let bridged = if let Some(network) = self.bridges.get(room.room_id()) {
            Some(network.clone())
        } else {
            let bridged = bridged_network(room).await;
            if let Some(network) = &bridged {
                self.bridges.insert(room.room_id().to_owned(), network.clone());
            }
            bridged
        };
        bridged.unwrap_or_else(|| network_of_members(room, own, known))
    }

    /// The latest event's one-line preview; `None` for a chat with none, or whose latest event
    /// is nothing a line can say.
    async fn preview_line(
        &mut self,
        room: &Room,
        latest: &LatestEventValue,
        own: &UserId,
        is_group: bool,
    ) -> Option<Preview> {
        match latest {
            LatestEventValue::None | LatestEventValue::RemoteInvite { .. } => None,
            LatestEventValue::Remote(event) => {
                let event = match event.raw().deserialize() {
                    Ok(event) => event,
                    Err(error) => {
                        debug!(%error, "the latest event cannot be read");
                        return None;
                    }
                };
                let sender_id = event.sender();
                if sender_id == own {
                    return remote_line(&event, Sender::Own, is_group);
                }
                let name = sender_name(room, sender_id).await;
                remote_line(&event, Sender::Other(&name), is_group)
            }
            LatestEventValue::LocalIsSending(local)
            | LatestEventValue::LocalCannotBeSent(local)
            | LatestEventValue::LocalHasBeenSent { value: local, .. } => match local.content.deserialize() {
                Ok(content) => content_line(&content, Sender::Own, is_group),
                Err(error) => {
                    debug!(%error, "the latest local event cannot be read");
                    None
                }
            },
        }
    }
}

/// The network a room's bridge state event names; none while the store holds none (a room's
/// bridge events come with its full state: the room list asks for none).
pub(crate) async fn bridged_network(room: &Room) -> Option<Network> {
    bridge_states(room)
        .await
        .iter()
        .find_map(|state| state.protocol.as_deref())
        .map(Network::from_protocol)
}

/// The network of a room's bridge users (`known`, the people and bots this device knows of in
/// it, first), Matrix when none is a bridge's.
pub(crate) fn network_of_members(room: &Room, own: &UserId, known: &[OwnedUserId]) -> Network {
    let members = members_to_look_at(room, own, known);
    Network::detect([], members.iter().map(|id| id.as_str()))
}

/// Whether the sender of the room's latest message (not the account) is a member the store does
/// not hold yet: its preview names them by their id until the room's members load.
pub(crate) async fn latest_sender_unknown(room: &Room, own: &UserId) -> bool {
    let LatestEventValue::Remote(event) = crate::latest::row_event(room, own).await else {
        return false;
    };
    let Ok(Some(sender)) = event.raw().get_field::<OwnedUserId>("sender") else {
        return false;
    };
    sender != own && matches!(room.get_member_no_sync(&sender).await, Ok(None))
}

/// A preview sender's name in the room, as the store holds the member now; their id's localpart
/// until it holds them.
async fn sender_name(room: &Room, sender: &UserId) -> String {
    match room.get_member_no_sync(sender).await {
        Ok(Some(member)) => member.display_name().unwrap_or(sender.localpart()).to_owned(),
        _ => sender.localpart().to_owned(),
    }
}

/// The members whose ids may tell a bridge: the direct chat's other person, the people and bots
/// known (heroes first, then the members the store holds), the service members (bridge bots set
/// them, MSC4171), never the account itself.
fn members_to_look_at(room: &Room, own: &UserId, known: &[OwnedUserId]) -> Vec<OwnedUserId> {
    let mut members: Vec<OwnedUserId> = room
        .direct_targets()
        .into_iter()
        .filter_map(OwnedDirectUserIdentifier::into_user_id)
        .chain(known.iter().cloned())
        .chain(room.service_members().into_iter().flatten())
        .filter(|id| id != own)
        .collect();
    // each once, in the order found.
    let mut seen = HashSet::new();
    members.retain(|id| seen.insert(id.clone()));
    members
}

/// How many of a group's people a row looks at, at most, for the two pictures of its collage.
const PEOPLE_FOR_PICTURES: usize = 8;

/// How a room looks in the chat list: a group or a conversation of two, and its pictures.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct Looks {
    /// More than two people besides the bridges' bots; a direct chat with one person never is.
    pub(crate) is_group: bool,
    /// The room's own picture, else, in a conversation of two, the other person's.
    pub(crate) picture: Option<OwnedMxcUri>,
    /// A group without a picture of its own: two of its people's pictures, else none.
    pub(crate) member_pictures: Vec<OwnedMxcUri>,
    /// The people and bots this device knows of in the room, the account aside: whose ids may
    /// tell its bridge.
    pub(crate) members: Vec<OwnedUserId>,
}

impl Looks {
    /// How `room` looks, from its heroes and the members the store holds.
    ///
    /// A sliding sync names a room's heroes only for a room without a name: a named room (any
    /// bridged chat) has none, and its people are the members the store holds (the senders of
    /// its latest messages, from the start; everyone once the chat loaded its members).
    pub(crate) async fn of(room: &Room, heroes: &[RoomHeroWithProfile]) -> Self {
        let people = People::of(room, heroes).await;
        let is_group = people.is_group(room);
        let (picture, member_pictures) = match room.avatar_url() {
            Some(own) => (Some(own), Vec::new()),
            None if is_group => (None, people.two_pictures(room).await),
            None => (people.other_persons_picture(room).await, Vec::new()),
        };
        Self {
            is_group,
            picture,
            member_pictures,
            members: people.others.into_iter().chain(people.bots).collect(),
        }
    }
}

/// A room's people as far as this device knows them: its heroes, then the members the store
/// holds, never the account itself, the room's service members or the bridges' bots.
#[derive(Debug)]
struct People<'a> {
    heroes: &'a [RoomHeroWithProfile],
    /// The people other than the account, heroes first, each once.
    others: Vec<OwnedUserId>,
    /// The bridges' bots among the members (not the service members, counted apart).
    bots: Vec<OwnedUserId>,
}

impl<'a> People<'a> {
    async fn of(room: &Room, heroes: &'a [RoomHeroWithProfile]) -> Self {
        let own = room.own_user_id();
        let services = room.service_members().unwrap_or_default();
        let stored = match room.joined_user_ids().await {
            Ok(stored) => stored,
            Err(error) => {
                debug!(%error, "the room's members cannot be read");
                Vec::new()
            }
        };
        let mut seen = HashSet::new();
        let mut others = Vec::new();
        let mut bots = Vec::new();
        for id in heroes.iter().map(|hero| hero.user_id.clone()).chain(stored) {
            if id == own || services.contains(&id) || !seen.insert(id.clone()) {
                continue;
            }
            if Network::from_bridge_bot(id.as_str()).is_some() {
                bots.push(id);
            } else {
                others.push(id);
            }
        }
        Self { heroes, others, bots }
    }

    /// More than two people besides the bridges' bots (the room's service members, MSC4171, and
    /// the bots among its members); a direct chat with one person never is.
    fn is_group(&self, room: &Room) -> bool {
        if room.direct_targets_length() == 1 {
            return false;
        }
        let services = room.service_members().map_or(0, |members| members.len());
        let people = room
            .active_members_count()
            .saturating_sub(u64::try_from(services + self.bots.len()).unwrap_or(u64::MAX));
        people > 2
    }

    /// The other person's picture in a conversation of two: the direct chat's person, else the
    /// one other person known; none when that is not sure (no picture rather than someone
    /// else's).
    async fn other_persons_picture(&self, room: &Room) -> Option<OwnedMxcUri> {
        let own = room.own_user_id();
        let targets: Vec<OwnedUserId> = room
            .direct_targets()
            .into_iter()
            .filter_map(OwnedDirectUserIdentifier::into_user_id)
            .filter(|id| id != own && Network::from_bridge_bot(id.as_str()).is_none())
            .collect();
        let person = match (targets.as_slice(), self.others.as_slice()) {
            ([target], _) => target,
            ([], [other]) => other,
            _ => return None,
        };
        self.picture_of(room, person).await
    }

    /// Two of the group's people's pictures (heroes first), or none.
    async fn two_pictures(&self, room: &Room) -> Vec<OwnedMxcUri> {
        let mut pictures: Vec<OwnedMxcUri> = Vec::with_capacity(2);
        for person in self.others.iter().take(PEOPLE_FOR_PICTURES) {
            if let Some(picture) = self.picture_of(room, person).await
                && !pictures.contains(&picture)
            {
                pictures.push(picture);
                if pictures.len() == 2 {
                    return pictures;
                }
            }
        }
        Vec::new()
    }

    /// A person's picture: as a hero, else as a member the store holds.
    async fn picture_of(&self, room: &Room, person: &UserId) -> Option<OwnedMxcUri> {
        if let Some(picture) = self
            .heroes
            .iter()
            .find(|hero| hero.user_id == person)
            .and_then(|hero| hero.avatar_url.clone())
        {
            return Some(picture);
        }
        match room.get_member_no_sync(person).await {
            Ok(member) => member.and_then(|member| member.avatar_url().map(ToOwned::to_owned)),
            Err(error) => {
                debug!(%error, "a member cannot be read");
                None
            }
        }
    }
}

/// The picture a room shows, as the chat list shows it: what a room's image loads.
pub(crate) async fn room_picture(room: &Room) -> Option<OwnedMxcUri> {
    let heroes = room.heroes().await;
    Looks::of(room, &heroes).await.picture
}

pub(crate) fn display_name(room: &Room) -> String {
    room.cached_display_name()
        .map_or_else(|| room.room_id().to_string(), |name| name.to_string())
}

/// What a timeline event is, as a preview words it (a notification's message); `None` for an
/// event no line says.
pub(crate) fn event_kind(event: &AnySyncTimelineEvent) -> Option<PreviewKind> {
    // the sender only decides who a line names, never what the event is.
    remote_line(event, Sender::Own, false).map(|preview| preview.kind)
}

fn remote_line(event: &AnySyncTimelineEvent, sender: Sender<'_>, is_group: bool) -> Option<Preview> {
    match event {
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomEncrypted(_)) => {
            Some(Preview::new(PreviewSource::Encrypted, sender, is_group))
        }
        AnySyncTimelineEvent::MessageLike(event) => match event.original_content() {
            Some(content) => content_line(&content, sender, is_group),
            None => Some(Preview::new(PreviewSource::Deleted, sender, is_group)),
        },
        AnySyncTimelineEvent::State(event) => state_line(event, sender, is_group),
    }
}

/// The state events the SDK takes as a chat's latest: the account joining or invited, someone
/// asking to join, a live location.
fn state_line(event: &AnySyncStateEvent, sender: Sender<'_>, is_group: bool) -> Option<Preview> {
    let kind = match event {
        AnySyncStateEvent::RoomMember(SyncStateEvent::Original(member)) => match member.membership_change() {
            MembershipChange::Joined | MembershipChange::InvitationAccepted => {
                PreviewSource::Membership(Membership::Joined)
            }
            MembershipChange::Invited | MembershipChange::KnockAccepted => {
                PreviewSource::Membership(Membership::Invited)
            }
            MembershipChange::Knocked => PreviewSource::Membership(Membership::Knocked),
            change => {
                debug!(?change, "no preview for the latest membership change");
                return None;
            }
        },
        AnySyncStateEvent::BeaconInfo(_) => PreviewSource::Location,
        event => {
            debug!(event_type = %event.event_type(), "no preview for the latest event");
            return None;
        }
    };
    Some(Preview::new(kind, sender, is_group))
}

fn content_line(content: &AnyMessageLikeEventContent, sender: Sender<'_>, is_group: bool) -> Option<Preview> {
    let kind = match content {
        AnyMessageLikeEventContent::RoomMessage(message) => match &message.relates_to {
            // an edit: what the message says now.
            Some(Relation::Replacement(replacement)) => message_kind(&replacement.new_content.msgtype),
            _ => message_kind(&message.msgtype),
        },
        AnyMessageLikeEventContent::Sticker(_) => PreviewSource::Sticker,
        AnyMessageLikeEventContent::UnstablePollStart(poll) => {
            PreviewSource::Poll(poll.poll_start().question.text.as_str())
        }
        AnyMessageLikeEventContent::RoomEncrypted(_) => PreviewSource::Encrypted,
        AnyMessageLikeEventContent::CallInvite(_) | AnyMessageLikeEventContent::RtcNotification(_) => {
            PreviewSource::Call
        }
        AnyMessageLikeEventContent::Reaction(reaction) => PreviewSource::Reaction(&reaction.relates_to.key),
        AnyMessageLikeEventContent::RoomRedaction(_) => PreviewSource::Deleted,
        content => {
            debug!(event_type = %content.event_type(), "no preview for the latest event");
            return None;
        }
    };
    Some(Preview::new(kind, sender, is_group))
}

fn message_kind(message: &MessageType) -> PreviewSource<'_> {
    match message {
        MessageType::Text(text) => PreviewSource::Text(&text.body),
        MessageType::Notice(notice) => PreviewSource::Text(&notice.body),
        MessageType::Emote(emote) => PreviewSource::Text(&emote.body),
        MessageType::Image(_) => PreviewSource::Image,
        MessageType::Video(_) => PreviewSource::Video,
        MessageType::Audio(audio) if audio.voice.is_some() => PreviewSource::Voice,
        MessageType::Audio(_) => PreviewSource::Audio,
        MessageType::File(file) => PreviewSource::File(Some(file.filename())),
        MessageType::Location(_) => PreviewSource::Location,
        other => PreviewSource::Text(other.body()),
    }
}
