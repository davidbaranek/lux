# Roadmap

What is done, and what comes next in order. How things work lives in
[architecture.md](architecture.md) and [rust-core.md](rust-core.md).

## Done

### Accounts and security

- [x] Sign in with a password or on the server's page (OAuth, MAS), any homeserver
- [x] The session and the stores' keys in the Keychain; every store encrypted at rest
- [x] A session the server ends signs the app out
- [x] Device verification (emoji), recovery key, key backup
- [x] After sign-in: verify with another device or the recovery key; answer other devices' requests;
      verify the account's other devices; set up recovery for a new account
- [x] Sign another device out: on the server's account page (OAuth), else with the password
- [x] Messages from before the backup opened decrypted from it, in the list too

### Chat list

- [x] The last list drawn at launch from the encrypted store, before the server answers
- [x] Places: inbox, low priority, archive, saved, networks, spaces, labels, requests
- [x] Filters: unread, read, drafts, groups, direct messages
- [x] Pin, mute, archive, delete, low priority, mark unread; a pinned grid
- [x] Merged chats: one person on several networks as one conversation
- [x] Networks told by their bridges, with their logos; a group's two members' pictures
- [x] Requests (invites) answered from the list
- [x] Reminders and send later

### Chat

- [x] Formatted messages: bold, italic, code, quotes, lists, links
- [x] Replies, swipe to reply, reactions, edits, deletes, forwards
- [x] Read receipts, typing with the typists' pictures
- [x] Photos, albums, videos, files: sent, opened in Quick Look (Space on the Mac, the arrows through
      the chat's media), dragged and dropped, pasted; saved, copied and dragged out
- [x] The iPhone's + : a panel in the keyboard's place with the camera, the newest photos (a tap
      puts one in the composer, numbered; limited access too), all photos, files, and a scan to a PDF
- [x] Uploads that go on in the background (iPhone, with a live activity)
- [x] Videos sent as an optimized 1080p copy, made while they wait, or as they are; one over the
      server's limit offered smaller instead of refused
- [x] The composer's Markdown formatted as typed, with a format menu; it grows with its text,
      then scrolls
- [x] Markup on a photo or PDF waiting in the iPhone's composer, its edited copy sent in its place
- [x] Saved messages
- [x] Insert from iPhone on the Mac (Continuity Camera: a photo, a document scan, a sketch) from
      the + and the composer's context menu
- [x] The first unread message marked, the chat opening at it
- [x] Messages that failed to send retried or discarded
- [x] Shared posts (reels, posts) as cards: their media, title and caption, folded to four lines
- [x] Deleted messages one after another folded into one row ("6 deleted messages"), unfolded by a tap

### Search

- [x] Chats by name, without case or accents
- [x] Messages from an encrypted on-device index (FTS5), filled in the background, merged chats'
      rooms included; deleted and left chats forgotten
- [x] Photos, read on the device: by the words in them (Vision) and the messages sent near them;
      by how they look when turned on (SigLIP 2 on Core ML, an Apple-hosted asset pack)

### Platform

- [x] iPhone (UIKit) and Mac (AppKit) over one Rust core
- [x] Share extension on iPhone: photos, videos, files and links sent to a chat; the chats the
      user writes in suggested in the share sheet
- [x] A demo account for development and benchmarks (`-LuxDemo`)
- [x] Background refresh on iPhone
- [x] Settings: account, encryption, search index
- [x] The account's own name and picture, changed in Settings (iPhone and Mac)
- [x] Handoff: the open chat (and its open thread) continues on the account's other iPhone or Mac;
      its room and thread only, never a message's content, and nothing for Spotlight or Siri

## Next

### 1. Push notifications

- [x] iPhone: pusher, notification extension (sender, chat, pictures, merged chats), reply and mark read
- [x] Mac: notifications while the app runs
- [ ] Verify on a device
- [ ] After the first TestFlight build: ask Apple for the filtering entitlement
      (`com.apple.developer.usernotifications.filtering`) and turn on the two commented lines in
      `project.yml`
- [ ] Push to a Mac that is not running

### 2. Chat details and settings

- [x] Chat info and members: picture, name, topic, networks (a merged chat's rooms), encryption,
      notifications, members found by name, mark read, leave (from the chat's title)
- [x] Rename, picture, topic (who may, by power level)
- [ ] Invite, and a member's own card (message them, their role)
- [ ] Disappearing messages
- [x] Shared media, files and links, read back from the server across a merged chat's rooms
- [x] Search in them: a file's name, a link's address or text, a photo's caption, and photos by
      the words in them and their look (photo search's index)
- [ ] Spaces: create one, add chats
- [ ] Settings: appearance, notifications, sign out other sessions

### 3. Bridges in the app

- [ ] Sign in to WhatsApp, Signal and the other networks (QR code or pairing code, through the
      bridges' provisioning API); the flows in the core, the QR code and forms native
- [ ] List the bridges and sign out of them

### 4. 120 Hz on iPhone

- [ ] Add `CADisableMinimumFrameDurationOnPhone`
- [ ] Measure the scroll benchmarks against the 8.3 ms frame budget

### 5. Message effects

- [ ] The effect as a namespaced key in the message content; the body stays a plain-text fallback
- [ ] The core turns the key into a typed effect; native views draw it for new messages only
- [ ] Pick an effect by holding Send
- [ ] Check that bridges drop the key

### 6. Media

- [ ] Link previews
- [ ] Rich previews of posts (Instagram, X, Facebook, …) through oEmbed and Open Graph; a fetch
      reveals the device's address to the site, so it is a setting
- [ ] GIFs and stickers (KLIPY), animated GIFs
- [ ] Voice messages: record and play
- [ ] Voice messages transcribed on the device (SpeechAnalyzer), once voice messages exist: the
      text under the message, searchable; no permission needed for a file
- [ ] Speech to text on the device (SpeechAnalyzer, or whisper.cpp in the core for every
      platform): transcripts of voice messages and videos, kept and searchable; dictation in the
      composer
- [ ] Choose whether photo metadata (location, EXIF) is kept or stripped

### 7. Platform

- [ ] Mac: keyboard navigation, several windows, menus
- [ ] Share extension on the Mac

### 8. Every Matrix message

The aim: everything the Matrix specification defines shows and can be sent, so the app stays
compatible with any client and bridge.

- [ ] Threads: a thread's replies apart from the chat, its summary under the message it answers
- [ ] Polls: answered and closed, results as they come (MSC3381, `m.poll.*`)
- [ ] Location: a place or a live location on a map (`m.location`, MSC3488 and MSC3489)
- [ ] Stickers, emotes (`/me`), notices; spoilers; mentions of people and rooms
- [ ] Custom emoji and sticker packs (MSC2545)
- [ ] Rich replies across rooms, permalinks (`matrix.to`) opened in the app
- [ ] Room upgrades (tombstones) followed; server notices
- [ ] Every event the timeline does not draw yet shown as a line that says what it is

### 9. Quality

- [ ] Czech localization
- [ ] Largest Dynamic Type sizes, VoiceOver, reduced motion
- [ ] Snapshot and UI tests
- [ ] MetricKit crash and hang reports
- [ ] App icon and brand

### 10. Calls

- [ ] Voice and video calls through Element Call (MatrixRTC, MSC4143), embedded as Element X
      embeds it; CallKit on iPhone
- [ ] Group calls in rooms; joining a call from the chat list

## Later

Each platform has its own native UI over the same Rust core:

- [ ] **iPad:** UIKit, with the Mac's layout of rail, list and chat
- [ ] **Android:** Kotlin and Jetpack Compose, the core through UniFFI's Kotlin bindings
- [ ] **Linux:** GTK 4 and libadwaita (gtk4-rs), as Fractal does; it calls the core directly
- [ ] **Windows:** C# and WinUI 3, the core through bindings generated from UniFFI
      (uniffi-bindgen-cs)

## Known gaps

- [ ] Time zones on iOS (`jiff`) are untested on a device
- [ ] At most 8 timelines stay open
- [ ] A chat whose bridge brought no history shows only "You joined", dated by the join (a bridge
      cannot backfill into an existing room on a standard Matrix server)
- [ ] Upstream: report that a `SyncService::stop` right after `start` is lost (matrix-rust-sdk 14a0ada)
