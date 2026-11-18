# Jump to a message with the SDK's event-focused timeline

Status: accepted 2026-11-17 (architect review: 100 context events, the seam, merged chats,
memory, delivery order). No code yet. Audit package 14. Implementation starts after package 2
(timeline catch-up, same `room.rs`) merges.

## Context

A chat reaches an old message (a search result, a saved message, a quote's original) through
`RoomTimeline::show_event` (`core/crates/lux-matrix/src/timeline/room.rs`): it pages the **live**
timeline backwards until the event appears, up to `PAGES_TO_AN_EVENT = 20` pages, or
`PAGES_TO_A_TIME = 400` pages (~20,000 events) when `load_or_fetch_event` told it the event's time.
After every page it waits up to `PAGE_CATCH_UP` (1 s) for the mapped list to grow. Everything
between now and the target is fetched, decrypted, mapped and kept in the open timeline. Measured
on dev (package 2's note): three pages of state events before the target cost 2.01 s. A photo
found a year back costs hundreds of `/messages` requests.

matrix-rust-sdk has the canonical tool for this: a timeline focused on an event, built from one
`/context` request, paginated in both directions. Element X uses it for every permalink and
search result.

## What the pinned SDK offers (rev `14a0ada`, read in source)

Paths are under `~/.cargo/git/checkouts/matrix-rust-sdk-*/14a0ada/crates/`.

**API.** `matrix_sdk_ui::timeline::TimelineFocus::Event { target, num_context_events,
thread_mode: TimelineEventFocusThreadMode }` (`matrix-sdk-ui/src/timeline/mod.rs:158`), passed to
`room.timeline_builder().with_focus(..)` like Lux's `Live`/`Thread` focuses today. `thread_mode`
is `ForceThread` or `Automatic { hide_threaded_events }` (`mod.rs:176`).

**Opening.** `TimelineController::new` asks the event cache for an `EventFocusedCache`
(`matrix-sdk/src/event_cache/caches/mod.rs:257`), whose `start_from` calls
`Paginator::start_from` → `room.event_with_context` (`/context`, `num_context_events` around the
target). The backward and forward tokens become gaps at the front and back of an **in-memory**
linked chunk (`event_focused/mod.rs` module docs, `add_initial_events_with_gaps`). `init_focus`
then puts those events in the timeline with `replace_with_initial_remote_events` **before
`build()` returns** (`controller/mod.rs:1554-1590`). So once the timeline is built, its first
`subscribe()` already holds the target: the jump itself needs no catch-up wait at all.

**Errors.** A missing event is `PaginatorError::EventNotFound`; a server 404/403
(`M_NOT_FOUND`, `M_FORBIDDEN`: redacted-and-purged, history visibility, left room) comes as
`PaginatorError::SdkError` wrapping the HTTP error. Both surface from `build()`.

**Pagination.** `Timeline::paginate_backwards` / `paginate_forwards` route to
`EventFocusedCache::paginate_backwards/forwards` for this focus (`timeline/pagination.rs:56,78`),
returning `hit_end_of_timeline` (start or end reached: no gap left). The Thread focus, by
contrast, cannot paginate forwards (`NotSupported`). The live-only lazy "skip count" does not apply
(`state_transaction.rs:1120`). As with the live timeline, the page reaches the timeline items
through a spawned task (`event_focused_task`, `timeline/tasks.rs:104`) after the call returns:
the same two-hop shape package 2 deals with, but only for paging, never for the jump.

**Threads.** With `Automatic`, if the target has an `m.thread` relation the cache switches to
thread pagination (`/relations`), keeps only that thread's events, and stops paging back once the
root is in (`reload_impl`, `event_focused/mod.rs` ~l.180-250); `Timeline::is_threaded()` and the
receipt thread follow (`controller/mod.rs:186-220`). If the target is not threaded,
`hide_threaded_events: true` filters threaded events out of the context and every page, exactly
like Lux's live focus. `ForceThread` treats a non-threaded target as a thread root.

**An event the live timeline already holds.** The SDK does nothing special: a focused timeline
is always a separate `/context` fetch. Element X checks its live items first (below); Lux does
the same.

**Caching.** Focused caches are memoised per room by `(event, thread_mode)` and reused without a
new `/context` if the same event is focused again (`caches/mod.rs:268-295`). Nothing evicts them:
the map is only ever inserted into, in 14a0ada and on upstream `main` today. The only public calls
that drop them, `EventCache::forget_room` and `clear_all_rooms` (`event_cache/mod.rs:531,538`),
also clear the room's stored events, so Lux cannot use them for this. Two consequences, both
handled in "Memory and reloads" below:
- each distinct target keeps its window (100 context events plus what was paged) in memory until
  the `Client` drops;
- when the event cache's cross-process store lock comes back dirty, the event cache reloads every
  state, and an event-focused cache's `reload` calls `reload_impl` again. That is one new
  `/context` per memoised cache, and its window is reset to the initial context
  (`states/mod.rs:553-565`, `event_focused/mod.rs` `reload`). In Lux this does not happen: the
  notification and share extensions build their clients `with_event_cache(false)`
  (`lux-matrix/src/store/mod.rs`). Outside the event cache, only `Client::optimize_stores` and
  `Client::get_store_sizes` take that lock (`matrix-sdk/src/client/mod.rs:4102,4128`), and Lux
  calls neither. Measured in PR (1), see below.

**Live data on a focused timeline.**
- *New events from sync:* never added (`state_transaction.rs:~605`: "Never add any item to a
  focused timeline when the item comes from sync"). Only aggregations of sync events are applied
  (`tasks.rs:270-276`, `handle_remote_aggregations`): reactions, edits.
- *Thread summaries:* not updated on a focused timeline (`UpdateThreadSummary` is live-only,
  `tasks.rs:284`).
- *Read receipts:* receipt events are applied to its items (`AddReadReceiptEvent`, all focuses).
  `mark_as_read` would pick the focused window's latest event (`timeline/mod.rs:1083`) — Lux must
  never send receipts from a focused timeline.
- *Local echoes:* a message sent while focused does **not** appear in it
  (`state.rs:175-187`, `should_add_new_items = false` for `Event`; SDK test
  `test_focused_timeline_doesnt_show_local_echoes`). Local reactions and edits to items it holds do
  (`test_focused_timeline_local_echoes`).
- *Decryption:* the redecryptor replaces resolved UTDs in every event-focused cache
  (`event_cache/redecryptor.rs:592`), and the builder installs the same UTD hook. Late keys fix
  focused rows as they fix live ones.

**Tests to copy.** `matrix-sdk-ui/tests/integration/timeline/focus_event.rs` drives all of the
above with `MatrixMockServer::mock_room_event_context()` and `RoomContextResponseTemplate`.

## How Element X does it (element-x-ios `develop`)

- `TimelineController` holds a `liveTimeline` and an `activeTimeline`. `focusOnEvent(_:timelineSize:)`
  builds a focused timeline and makes it active; `focusLive()` makes the live one active again.
  There is no separate "detached" flag: detached means active ≠ live, sent to the view as
  `.isLive(Bool)`.
- `TimelineViewModel.focusOnEvent(eventID:)`: if `timelineState.hasLoadedItem(with:)`, it just
  scrolls; otherwise `focusOnEvent(eventID, timelineSize: 100)`. Failure → toast
  "message not found" (`.eventNotFound`) or "failed".
- Opening a room at an event: skip the focused timeline when the live one already contains it.
- Both pagination directions go to the active timeline. When forward pagination reports
  `endReached`, it calls `focusLive()`.
- Scroll-to-bottom while detached calls `focusLive()`; sending a message ends with
  `scrollToBottom()`, so sending returns to live. On becoming live the focus highlight clears.

## Decision

Lux jumps by **opening an event-focused timeline** of the target's room whenever the target is not
already in the loaded live messages, and **deletes the back-paging search**. The focused timeline
is one more kind of timeline behind the same port, not a second stack. The thread view model shows
either its live rooms or one focused timeline ("detached"), and returns to live on the user's
"jump to bottom", on sending, or when paging forward reaches the present.

### Entry points

| Entry point | Today | Then |
|---|---|---|
| Search result (photo, file, link's message) | `SearchTarget.chat(row, focusEvent:)` → open chat, then `jump_to_event` back-pages | Open chat **at** the event: live if loaded, else focused |
| Saved message (`Later`, inbox `destination(of:)` `.message`) | same | same |
| Quote tap (`jump(toRepliedMessageOf:)`) | `jump_to_replied` back-pages (≤20 pages) | scroll if loaded, else focused in the quote's room |
| First unread ("New messages" above the fold) | `first_unread` pages back ≤10 pages | unchanged in this work; a follow-up can focus on the receipt's event when it is not loaded |
| Notification tap | opens the chat (or its thread) at the bottom: the message is new, live has it | unchanged |
| Pins | Lux pins *chats*, not messages; no entry point | none now; pinned messages later reuse the same jump |
| Links to messages (`matrix.to/#/!room/$event`, `matrix:` URIs) | not handled (only mentions are parsed, `timeline/html.rs:279`) | last PR: parsed in lux-core with ruma's `MatrixToUri`/`MatrixUri` into the same "open chat at event" |
| A message in a Matrix thread | — | see "Threads" below |

Every entry point that names an event also names its **room** (a merged chat has several):
`FoundPhoto`, `FoundFile`, saved messages already carry `roomId`; `FoundLink` gains one; a quote
is in a known room. So `jump_to_event(event)` becomes `jump_to_event(room, event)` and the
merged-chat loop that tried `show_event` room after room (`thread/task.rs:742-780`) goes.

### Live scroll vs focused timeline

1. The thread task looks for the event in the room's loaded live messages
   (`RoomMessages::find_event`, as `jump` does today). Found → reveal and scroll, as now.
2. Not found → open the focused timeline. No partial back-paging first, no time heuristics.

Opening a chat *at* an event does step 1 on the live list as the device has it (event cache), and
opens the focused timeline in parallel with the live first-screen fill otherwise, so the first rows
are the target's neighbourhood rather than the bottom of the chat.

`num_context_events`: 100, as Element X: one request either way, and 50 a side fills a tall Mac
window of short messages where 25 a side may not.

### Returning to live, and what the screen does meanwhile

- **State.** `ThreadState` gains `is_live: bool` (false while detached) and `can_load_newer: bool`.
  `is_loading`, `can_load_older`, `is_at_start` describe the timeline shown.
- **Jump to bottom.** The button shows whenever `!is_live` (also at the window's bottom). Tapping
  it sends `ReturnToLive`: the rows switch back to the live rooms and the screen lands at the
  bottom. Element X behaviour.
- **Paging.** Near the top: `load_older`, routed to the timeline shown. Near the bottom while
  detached: `load_newer` (focused `paginate_forwards`). When it reports the end, the task switches
  back to live through the seam below.
- **Unread marker.** "New messages" belongs to the live rows; it shows while detached only if the
  first unread message falls inside the focused window (it is the same `MessageId` space, see
  below). `needs_read_receipt` and `did_read_latest` are ignored while detached: no receipt is
  ever sent from a focused timeline; receipts keep going through the live `TimelineId`.
- **Composer.** Stays usable; draft, typing notices, reply and edit modes are unchanged (they name
  rooms and event ids, not timelines). **Sending returns to live first** (the SDK would not show
  the local echo in the focused rows). Replying to a detached message works: the quote carries
  the event id.
- **Message actions on detached rows** (react, edit, delete, retry, save, forward) keep working:
  they name the room and message, and the adapter finds the open timeline that shows the message
  (`Opened::of_room` includes focused timelines). Reactions and edits from others update the rows
  (SDK aggregations); thread summaries on detached roots stay as loaded.
- **Highlight.** The target flashes as today (`ThreadPresenter.jumpIfShown` → `screen.flash`).

### The seam back to live

The switch from the focused rows to the live rows happens only when both hold the same message,
so that no row is duplicated or lost and the scroll position does not move.

- **Anchor.** The presenter reports the topmost fully visible row as it scrolls
  (`ThreadViewModel::set_anchor(MessageId)`, a cheap intent coalesced per frame). Its **event id**
  is the anchor, because message ids differ between timelines (see the id prefixes below).
- **When.** The task tries the switch when `load_newer` reports the end, and on `ReturnToLive`.
- **Overlap.** The switch happens in the first live batch whose room messages contain the anchor's
  event (`RoomMessages::find_event`). It is driven by events, with no timer and no wait in the
  adapter: the live followers already deliver every batch to the task.
- **Live not holding it yet.** This happens when live holds only its latest events, or when a
  limited sync left a gap behind them. The task pages the **live** timeline back (`load_older`),
  bounded by a known number: the count of focused messages from the anchor to the focused end,
  plus one page. The anchor's event is at most that many messages before the present. The event
  cache's back-pagination fills a limited-sync gap from its gap token, so a gap is paged like any
  other history. Meanwhile the rows stay the focused ones, and `is_live` stays false.
- **Live never showing it** (bound used up: the event is hidden in live, or the mapping drops it).
  The view stays detached at the end. The jump-to-bottom button carries live's unread count, since
  the focused timeline gets no new messages from sync. `ReturnToLive` then switches without an
  anchor and lands at the bottom: an explicit move by the user, never an automatic jump.
- **The switch itself.** It is one `ThreadUpdate`: the row diff from the focused rows to the live
  rows, plus `anchor: Some(Anchor { from: MessageId, to: MessageId, offset })`. The presenter applies
  the snapshot without animation. It then sets the content offset so that `to`'s top sits where
  `from`'s top was (the same mechanism that keeps the position when older rows land above).
  Rows above the anchor in live replace those above it in focused; rows below come from live,
  which holds everything up to the present. So no row is missing and no event appears twice.
- **`ReturnToLive` from deep history** (jump to bottom) needs no overlap: it switches without an
  anchor and scrolls to the bottom, as Element X does.
- **A reload resetting the focused window** (dirty store lock, above). The focused rows get a
  `Reset` back to the initial context. If the anchor's event survives, the anchor keeps the
  position. If not, the task opens a new focused timeline at the anchor's event (one `/context`)
  and swaps to it through the same anchored switch.

### Merged chats

One rule: **a detached view shows the target's room alone.** The user sees this through the
merged chat's existing room filter. While detached, `ThreadState.shown_room` is the target's room,
so the header shows the same "only this room" state (name and network) that choosing one room
shows today. The user's own filter is remembered and restored on the way back to live. Choosing
"all rooms" while detached means `ReturnToLive`. Sending while detached returns to live first and
sends to the send room the restored filter gives.

### Memory and reloads

Nothing public in 14a0ada drops a focused cache (see "Caching"), so Lux bounds the cost in two ways:
- **The number of caches is the number of distinct targets the user opened in this run.** Each one
  is a tap, and opening the same target again reuses its cache. A cache holds about 100 events plus
  the pages read from it, a few hundred KB at most. All of them are freed when the `Client` drops:
  sign-out, account close, or the process ending (iOS ends suspended apps routinely; on the Mac
  the account's restart does it).
- **Reload cost, measured** (`lux-matrix/src/store/tests.rs`, the app and the notification
  extension's clients on one store). After 1, 10 and 50 jumps, the extension's sync followed by the
  app's next sync costs **0** `/context` requests each time. The control test lets another client
  take the event-cache lock (`get_store_sizes`). The app then fetches all 10 of its jumps again, so
  the cost is real but only reachable through a call Lux does not make. The test fails if an
  extension ever starts taking the lock.
- **What closes it.** Lux does not patch the SDK. The memory part (each distinct jump kept until
  the `Client` drops) remains. An upstream proposal to drop an event-focused cache once no timeline
  uses it is drafted in the shared notes. Posting it is the user's decision.

### Threads

The SDK's `Automatic { hide_threaded_events: true }` decides by itself whether the target is in a
Matrix thread. The adapter reports it (`Timeline::is_threaded()` plus the root the SDK found):

- **Room view, target outside threads** → detached room rows, as above.
- **Room view, target is a thread reply** → the jump answers `InThread { root, message }`; the app
  opens the thread (iOS pushes it, Mac shows it in the inspector) **at** that message. The room
  view stays where it was.
- **Thread view opened at a reply** → `TimelineId { room, thread: Some(root), at: Some(event) }`,
  built with the same `Automatic` mode, so the SDK reuses the memoised cache from the room view's
  attempt (same `(event, thread_mode)` key: no second `/context`). The thread focus cannot page
  forwards, the event focus can; returning to live = the thread's ordinary `Thread` focus.
- A thread **root** as target in the room view is not threaded for the SDK (`Automatic`): plain
  room jump, and the root's summary still opens the thread.

### Core model: one port, a timeline with a focus

**lux-core domain** (`ids.rs`, `ports/timeline.rs`, `thread/`):

```rust
pub struct TimelineId {
    pub room: RoomId,
    pub thread: Option<EventId>,
    /// The message the timeline is opened around; `None`: the live end.
    pub at: Option<EventId>,
}
```

- `ChatTimelines` keeps its methods; each works on any `TimelineId`. Changes:
  - `messages(&id)` for an `at` timeline opens it (one `/context`) and fails with
    `BackendError::UnknownMessage` (not found) or `BackendError::NotAllowed` (no permission; existing variants);
  - new `load_newer(&id, count) -> Result<bool /* reached the present */>`;
  - new `focused(&id) -> Result<Focused { message: MessageId, thread: Option<EventId> }>`: the
    target's id in that timeline and the thread the SDK put it in;
  - `show_event` is **removed**.
- `thread::task`: `rooms: Vec<RoomMessages>` stays the live state, untouched while detached (its
  followers and holds keep running, so unread state, typing and receipts stay correct and
  returning is instant). A new `detached: Option<Detached { room: usize, id: TimelineId,
  messages: RoomMessages, hold: TimelineHold, at_end: bool }>`. `rows::present` takes the source
  shown (the live rooms, or the detached one) — one presenter of rows, one `Window`, one diff to
  the listener. Switching source is one rows batch (the rows that go and come), plus the anchor
  (see "The seam back to live").
- Intents: `JumpToEvent { room, event }`, `JumpToReplied` (unchanged signature), `LoadNewer`,
  `ReturnToLive`. Answers become `Result<Jumped, JumpFailure>` with
  `Jumped::{ Here(MessageId), InThread { root, message } }` and
  `JumpFailure::{ NotFound, Forbidden, Failed }` instead of `Option<MessageId>`.
- Message ids: the adapter's internal-id prefix for a focused timeline is
  `"{room}/@{event}/"` (thread `"{room}/{root}/@{event}/"`), so its ids never collide with the live
  ones (the port's "no two messages share an id" holds). The row diff on switching is therefore a
  real remove/insert, and the presenter's layout cache keys stay valid.

**lux-matrix adapter** (`timeline/opened.rs`, `room.rs`, `mod.rs`):
- `Key` gains `at: Option<OwnedEventId>` (the audit's "third kind of key"). Focused keys never
  count toward `KEPT`: they close as soon as their last hold goes.
- `RoomTimeline::open` maps `(thread, at)` to the SDK focus: `(None, None)` → `Live { hide: true }`;
  `(Some, None)` → `Thread`; `(_, Some)` → `Event { target, 100, Automatic { hide: true } }`. The
  follower, mapper, cut and previews are the same code; the opening fill task is not started for a
  focused timeline (the context is its first screen); `at_start` comes from `paginate_backwards`'
  result as today, `at_end` from `paginate_forwards`'.
- `load_newer` = `paginate_forwards`, and whatever package 2 settles for waiting on a page applies
  to both directions alike (no new timeout is introduced here).

**lux-ffi** (`thread.rs`): `jump_to_event(room_id, event_id)`, `jump_to_replied`, `load_newer`,
`return_to_live`, `set_anchor` exported; the jump returns a uniffi enum (`Here`/`InThread`) or a typed error;
`ThreadState` carries `is_live`, `can_load_newer`. `ThreadSpec` (and its FFI record) gains
`focus: Option<EventId>` so a chat can open at an event.

### Swift: one presenter, both platforms

- `ThreadPort`/`RustThread`/`ThreadModel` mirror the FFI: `jumpToEvent(room:event:)`,
  `loadNewer()`, `returnToLive()`, `isLive`, `canLoadNewer`, and the `ThreadPresenter(focusEvent:)`
  init becomes `focus: MessageLink?` (room + event) handed to the core's `ThreadSpec` instead of a
  jump after `start()`.
- `ThreadPresenter` keeps all of it: `scrolled(_:)` asks `loadOlder` near the top and, when
  `!isLive`, `loadNewer` near the bottom; `jumpToBottom()` is `returnToLive()` when detached, a
  scroll otherwise; `send` returns to live through the core. A source switch arrives as an ordinary
  update with an anchor; the presenter keeps the anchor row's offset (or goes to the bottom on
  `ReturnToLive`). `InThread` calls a new `ThreadScreen.openThread(_:at:)`.
- The screens stay views only: iOS `ThreadViewController` pushes the thread for `openThread`; Mac
  `ThreadController` shows it in the inspector. The jump-to-bottom button binds to
  `isLive`/existing bottom state. A switch is items going and coming, so it is a diffable snapshot
  applied without animation (AGENTS.md), never `reloadData`.
- Failures: the presenter shows the existing error banner with "Message not found" /
  "You can't see this message" / generic.

## What gets deleted

- `RoomTimeline::show_event`, `PAGES_TO_AN_EVENT`, `PAGES_TO_A_TIME`, its `load_or_fetch_event`
  time lookup and its per-page `until(PAGE_CATCH_UP, ..)` waits (`room.rs:39-42, 225-266`).
- `ChatTimelines::show_event` (port), its adapter (`timeline/mod.rs:190`) and demo
  (`demo/timeline.rs:437`) implementations.
- In `thread/task.rs`: the room-by-room `show_event` loop in `jump`, `Event::Found`, and the
  `reveals` wait for "the room's list has not caught up yet" for jumps (the focused timeline's
  first list already holds the target).
- `ThreadPresenter.start()`'s jump after `model.start()` (`ThreadPresenter.swift:91`).

## Edge cases

- **Not found / redacted and purged / forbidden** (history visibility, left room, banned): `build()`
  fails → `JumpFailure::NotFound` / `Forbidden`; the thread stays where it was, the app says so.
  A **redacted** event the server still returns opens normally and shows as a deleted message.
- **Target filtered by Lux** (a state event the thread hides, or older than the chat's "cleared"
  cut): the focused list does not contain it → `NotFound`, nothing switches.
- **Focused timeline reaching live**: see "The seam back to live": anchored switch on overlap,
  bounded live back-paging, stay detached if the bound runs out.
- **Jumping while detached**: a second jump replaces the detached timeline (the old hold goes);
  a jump to a message in the current detached window scrolls.
- **Merged chats**: see "Merged chats": the target's room alone, shown through `shown_room`.
- **Event in a thread**: above. A thread whose root is unknown (`/context` without root) pages
  back with `/relations` until the root, as the SDK does.
- **Bridged rooms with gaps** (bridge backfill, missing history): `/context` and forward paging
  follow the server's DAG order; holes show as they do in live today. A bridged message whose
  event is not on this server (`M_NOT_FOUND`) is `NotFound`, never a paging search.
- **Encrypted rooms without keys**: rows show as undecryptable and resolve when keys arrive.
- **The chat is closed** while a jump is pending: the task ends, the hold and the SDK timeline go.
- **Demo mode**: no server; the demo backend implements `at` timelines from its seeded lists.

## Tests

- **lux-matrix (mock server, `tests/timeline.rs`)**, `mock_room_event_context`:
  open at an event → its id is in the first list, no `/messages` request; not found (404) and
  forbidden (403) → the right `BackendError`; `load_older`/`load_newer` with tokens;
  `load_newer` to the end → `true`; a threaded target → `focused().thread == Some(root)` and only
  thread events; the same event twice → one `/context`; a reaction from sync updates a focused row;
  a sent message never appears in the focused list; no receipt request while only a focused
  timeline is held; message ids of a focused timeline never equal live ones; `/context` is asked
  for `limit=100`. **Seam:** the room's live sync holds only its latest 10 events with
  `limited: true` and a `prev_batch` gap. A focused timeline is opened 40 events back and paged
  forward to the end. The test checks that the live timeline is paged back (through the gap) until
  it holds the anchor event, within the bound, and that the anchor's event is in both lists at the
  switch. A variant where the anchor's event is hidden in live checks that the bound stops paging.
  **Reload cost:** N jumps, then a forced reload, expects N `/context` requests (measured, recorded
  in PR 1).
- **lux-core (`thread/tests.rs`, the fake backend)**: loaded target → scroll, no `messages(at)`
  call; unloaded → detached rows, `is_live == false`; `ReturnToLive` → live rows, the live
  followers never stopped; `LoadNewer` reaching the end → live with the anchor; send while
  detached → live first; receipts suppressed while detached; `InThread` answer; failures leave the
  rows unchanged. **Seam:** at the switch, the rows' event ids are the focused ones above the anchor
  and the live ones from it on, with no duplicate and no gap, and the update carries
  `Anchor { from, to }` for the same event. When live lacks the anchor, the rows stay focused and
  `is_live` stays false until a live batch brings it. A focused `Reset` that drops the anchor
  re-focuses on it. **Merged chat:** a jump in room B of a two-room chat shows only B's rows with
  `shown_room == Some(B)`. `ReturnToLive` restores the user's previous filter (`None` or A).
  Choosing all rooms while detached returns to live.
- **Swift (`swift test`, presenter tests with a fake `ThreadPort`)**: jump to bottom while detached
  calls `returnToLive`; near-bottom scroll while detached calls `loadNewer` and not `loadOlder`;
  the topmost visible row is reported as the anchor; an anchored switch leaves the anchor row's
  `minY` on screen unchanged (fake screen geometry); `InThread` calls `openThread`; opening with a focus hands it to
  the spec and does not jump after `start()`.
- **Demo (`-LuxDemo`)**: a demo chat with a saved message several hundred messages back and a
  quote of one; the simulator smoke test opens the saved message and checks the flashed row and the
  jump-to-bottom button; `-LuxBenchmark` measures the jump (target: one request, no hitch).

## Delivery plan (stacked PRs, after package 2 merges)

1. **core: focused timelines in the adapter** — `TimelineId.at`, `Key.at`, the SDK focus mapping,
   `load_newer`, `focused()`, errors; demo backend support. `show_event` still in place. Mock
   server tests. No behaviour change.
   **Gate before (3):** PR (1) measures the `/context` requests one cross-process reload sends
   after 1, 10 and 50 distinct jumps, and reports the numbers to the architect. If the count grows
   with the number of jumps, (3) does not switch the jumps over until there is an option that
   needs no SDK patch, and the upstream proposal is drafted in the shared notes. Posting it upstream
   is the user's decision.
2. **core: the thread can show a detached timeline** — `thread/task.rs` detached source, the seam,
   merged-chat rule, new intents (`JumpToEvent { room, event }`, `LoadNewer`, `ReturnToLive`,
   `SetAnchor`), `ThreadState.is_live/can_load_newer`, typed answers, `ThreadSpec.focus`. Core
   tests. **The existing jump path is untouched:** `jump_to_event(event)`, `jump_to_replied` and
   `show_event` keep working as on `dev`, and the FFI surface does not change. Nothing reaches the
   detached state yet.
3. **ffi + swift: switch the jumps over** — FFI exports, `ThreadPort`/`ThreadModel`,
   `ThreadPresenter` paths, iOS and Mac screens (bottom button, anchor reporting, open at event,
   `openThread`), search and saved targets carry the room (`FoundLink.roomId`). In the **same PR**,
   the old jumps route to the new path and `show_event` (port, adapter, demo) and its paging loop
   are deleted. Presenter tests.

   So `dev` never has a broken jump: until (3) merges, `dev` jumps the old way. From (3) on, the core
   and both apps jump the new way in one squash commit.
4. **demo + smoke**: the demo chat case and the smoke test; benchmark before/after in the PR.
5. **links to messages** (optional): parse `matrix.to`/`matrix:` message links in lux-core and open
   them through the same path.

Follow-up, separate: "first unread" beyond the loaded window via the same focus.
