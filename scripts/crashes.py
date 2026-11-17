#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pyjwt[crypto]>=2.9", "httpx>=0.28"]
# ///
# SPDX-License-Identifier: GPL-3.0-only
"""TestFlight's crash submissions, newest first, each summed up: the build, the exception, the
termination reason and the first frame in the app's own code. From the App Store Connect API.

    scripts/crashes.py                      # the last 7 days
    scripts/crashes.py --since 2026-11-15   # since a day (or an ISO time)
    scripts/crashes.py --save build/crashes # also writes each full log there
    scripts/crashes.py --file some.ips      # sums up a crash report on disk instead

The API key comes from the environment, never from the repository (docs/releasing.md):
ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file App Store Connect gave).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

APP_ID = "6834817742"
API = "https://api.appstoreconnect.apple.com"
# the processes that are the app's own code (the app, its extensions); the core and LuxCore are
# linked into each.
OWN_IMAGES = {"Lux", "LuxNotifications", "LuxShare", "LuxAssets"}
# termination codes worth naming (FrontBoard / RunningBoard).
CODES = {
    0xDEAD10CC: "dead10cc: held a file lock or SQLite database in a shared container when suspended",
    0x8BADF00D: "8badf00d: the watchdog, the main thread too long unresponsive",
    0xC00010FF: "c00010ff: the device too hot",
    0xBAADCA11: "baadca11: a VoIP push not reported to CallKit",
    0xDEADFA11: "deadfa11: force quit by the user",
}


@dataclass
class Summary:
    build: str
    exception: str
    termination: str
    frame: str


def token() -> str:
    import jwt

    missing = [name for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH") if not os.environ.get(name)]
    if missing:
        sys.exit(f"error: set {', '.join(missing)} (the App Store Connect API key, docs/releasing.md)")
    key = Path(os.environ["ASC_KEY_PATH"]).expanduser().read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def parse_time(text: str) -> datetime:
    moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    return moment if moment.tzinfo else moment.replace(tzinfo=UTC)


def submissions(client, app: str, since: datetime):
    """The submissions newer than `since`, newest first, each with its build number."""
    url = f"{API}/v1/apps/{app}/betaFeedbackCrashSubmissions"
    params = {"sort": "-createdDate", "limit": "50", "include": "build", "fields[builds]": "version"}
    while url:
        response = client.get(url, params=params)
        if response.status_code >= 400:
            sys.exit(f"error: {response.status_code} {response.text}")
        page = response.json()
        builds = {item["id"]: item["attributes"].get("version", "?")
                  for item in page.get("included", []) if item["type"] == "builds"}
        for item in page["data"]:
            created = parse_time(item["attributes"]["createdDate"])
            if created < since:
                return
            build = (item.get("relationships", {}).get("build", {}).get("data") or {}).get("id")
            yield item, builds.get(build, "?")
        # the next link carries the parameters.
        url, params = page.get("links", {}).get("next"), None


def crash_log(client, submission: str) -> str | None:
    response = client.get(f"{API}/v1/betaFeedbackCrashSubmissions/{submission}/crashLog")
    if response.status_code == 404:
        return None
    response.raise_for_status()
    return response.json()["data"]["attributes"].get("logText")


def summarize(log: str, build: str = "?") -> Summary:
    """A crash log (.ips, JSON: a header line then the report; or the older text format)."""
    header, _, body = log.partition("\n")
    try:
        meta, report = json.loads(header), json.loads(body)
    except json.JSONDecodeError:
        return summarize_text(log, build)
    if build == "?":
        build = f"{meta.get('app_version', '?')} ({meta.get('build_version', '?')})"
    exception = report.get("exception", {})
    exception_text = " ".join(filter(None, [exception.get("type"), f"({exception['signal']})" if exception.get("signal") else None,
                                            exception.get("subtype")])) or "?"
    termination = report.get("termination", {})
    code = termination.get("code")
    termination_text = " ".join(filter(None, [termination.get("namespace"),
                                              CODES.get(code, hex(code) if isinstance(code, int) else None),
                                              termination.get("indicator")])) or "?"
    images = report.get("usedImages", [])
    own = OWN_IMAGES | {report.get("procName", "")}
    threads = report.get("threads", [])
    faulting = report.get("faultingThread", next((i for i, t in enumerate(threads) if t.get("triggered")), 0))
    order = [faulting] + [i for i in range(len(threads)) if i != faulting]
    frame = "none in the app's code"
    for index in order:
        for number, item in enumerate(threads[index].get("frames", []) if index < len(threads) else []):
            image = images[item["imageIndex"]] if item.get("imageIndex", -1) < len(images) else {}
            # a Debug build keeps the app's code in `Lux.debug.dylib`.
            if (image.get("name") or "").removesuffix(".debug.dylib") in own:
                symbol = item.get("symbol", f"+{item.get('imageOffset', '?')}")
                where = f" {Path(item['sourceFile']).name}:{item.get('sourceLine', '?')}" if item.get("sourceFile") else ""
                thread = "" if index == faulting else f" (thread {index}, not the crashed one)"
                frame = f"#{number} {image['name']} {symbol}{where}{thread}"
                break
        else:
            continue
        break
    return Summary(build, exception_text, termination_text, frame)


def summarize_text(log: str, build: str) -> Summary:
    def field(name: str) -> str:
        match = re.search(rf"^{name}:\s*(.+)$", log, re.MULTILINE)
        return match.group(1).strip() if match else "?"

    if build == "?":
        build = field("Version")
    termination = field("Termination Reason")
    for code, meaning in CODES.items():
        if f"{code:x}" in termination.lower():
            termination += f" ({meaning})"
    crashed = re.search(r"^Thread \d+ Crashed:.*?\n(.*?)(?:\n\n|\Z)", log, re.MULTILINE | re.DOTALL)
    frame = "none in the app's code"
    for line in (crashed.group(1).splitlines() if crashed else []):
        parts = line.split()
        if len(parts) >= 4 and parts[1].removesuffix(".debug.dylib") in OWN_IMAGES:
            frame = f"#{parts[0]} {parts[1]} {' '.join(parts[3:])}"
            break
    return Summary(build, field("Exception Type"), termination, frame)


def show(summary: Summary, title: str) -> None:
    print(title)
    print(f"  build        {summary.build}")
    print(f"  exception    {summary.exception}")
    print(f"  termination  {summary.termination}")
    print(f"  app frame    {summary.frame}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", help="a day or an ISO time (default: 7 days ago)")
    parser.add_argument("--app", default=APP_ID, help=f"the App Store Connect app id (default: {APP_ID})")
    parser.add_argument("--save", type=Path, help="a folder to write each full crash log into")
    parser.add_argument("--file", type=Path, help="sum up this crash report instead of asking the API")
    arguments = parser.parse_args()

    if arguments.file:
        show(summarize(arguments.file.read_text()), str(arguments.file))
        return

    import httpx

    since = parse_time(arguments.since) if arguments.since else datetime.now(UTC) - timedelta(days=7)
    count = 0
    with httpx.Client(headers={"Authorization": f"Bearer {token()}"}, timeout=60) as client:
        for item, build in submissions(client, arguments.app, since):
            count += 1
            attributes = item["attributes"]
            title = (f"{attributes['createdDate']}  {attributes.get('deviceModel', '?')}, "
                     f"iOS/macOS {attributes.get('osVersion', '?')}  ({item['id']})")
            log = crash_log(client, item["id"])
            if log is None:
                print(f"{title}\n  no crash log (yet)")
                continue
            if arguments.save:
                arguments.save.mkdir(parents=True, exist_ok=True)
                (arguments.save / f"{item['id']}.ips").write_text(log)
            show(summarize(log, build), title)
            if attributes.get("comment"):
                print(f"  comment      {attributes['comment']}")
    print(f"{count} crash submission(s) since {since.isoformat(timespec='minutes')}")


if __name__ == "__main__":
    main()
