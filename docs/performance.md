# Performance

What the apps measure, today's numbers, and how to take them again. A change to a hot path (the
chat list, the thread, launch, images) says in its pull request what these numbers did.

## Today's numbers

| What | Number |
|---|---|
| The Rust library (`LuxFFI`, whole-program LTO) | 55 MB per slice |
| The apps' binaries | 39 MB on the Mac, 39 MB on the iPhone |
| Warm Mac launch: the kept chats shown | 0.34 s |
| Warm Mac launch: the account open | 0.35 s |
| Warm Mac launch: the chats up to date | 1.1–1.2 s |

## How to measure

- **Launch to first chats.** The app logs `launch-to-first-chats` with its footprint under the
  `metrics` category of its log subsystem (its bundle id). `scripts/measure-launch.sh mac|ios
  [runs] [-LuxDemo]` launches it `runs` times and prints each line (iOS: `SIMULATOR=<udid>`;
  `BUNDLE_ID`, `DERIVED_DATA` and `CONFIG` override the defaults). The steps in between
  (`launch: restore starts`, `keychain read`, `account open`) are logged beside it.
- **Scrolling.** `-LuxBenchmark` scrolls the chat list down and back, then a chat, one step per
  display frame, and logs the late frames (`FrameMeter`). Before the chat's scroll it measures the
  chat's first two seconds from its first rows (`chat open`), and the frames in which its list
  moved by itself: none, as a chat opens in place while its opening rows go in. In the chat it then jumps to a message
  far back while its pages load (`chat jump`, 3 s) and sends twelve messages at the newest
  (`chat new messages`), each span measured the same way.
- **XCTest.** The `Lux-iOS` scheme's tests (`Lux-iOS-UITests`, `PerformanceTests`) measure launch,
  the scroll hitch ratio and memory, in Release, on the demo. `TEST_RUNNER_LUX_REAL=1` uses the
  signed-in account instead (read only); use a test account, never a personal one.
- **Instruments.** The signposts `list`, `thread` and `images` mark the expensive intervals.
- **Memory.** `heap <pid>` sorts the live allocations; `MallocStackLogging=lite` at launch lets
  `malloc_history <pid> -allBySize` name the call stack of each. Most of the core's memory is
  the SDK's: each room's newest events (its event cache keeps every room it has seen), and the
  stores' SQLite connections, each with a page cache of up to 2 MB (about 4 KB a block) and
  100 KB of parsed schema. `lsof -p <pid>` counts the connections: the app keeps at most eight
  to each store (`APP_STORE_CONNECTIONS`); the SDK's default, four per core, opened 72 to the
  crypto store on an 18-core Mac.

Measure on the demo (`-LuxDemo`) for numbers anyone can reproduce, in Release, with the library
built by `scripts/setup-sdk.sh` (not `--profile release`, which skips the LTO).
