#!/usr/bin/env python3
"""Writes the AltStore / SideStore source for the iPhone and iPad app.

    scripts/altstore-source.py RELEASES.json OWNER/REPO TAG IPA OUT.json

RELEASES.json is `gh api repos/OWNER/REPO/releases --paginate` (a list, or lists one after another).
The source lists every published release from v0.2.10 on that has AIOStreams.ipa, newest first:
earlier IPAs all said 0.2.0 inside, which AltStore would refuse as not the version it was told.
TAG's IPA is the file at IPA, whose size and SHA-256 are read from it. The workflow uploads OUT to
each release, so https://github.com/OWNER/REPO/releases/latest/download/altstore.json always names
the newest. Apple TV isn't listed: AltStore and SideStore install on iPhone and iPad only.
"""

import hashlib
import json
import re
import sys

ASSET = "AIOStreams.ipa"
FIRST = (0, 2, 10)
BUNDLE = "io.github.aiostreams-ios.app"
MIN_OS = "18.0"
TINT = "6152DF"


def releases_from(path):
    """`gh api --paginate` writes one JSON list per page, back to back."""
    text = open(path, encoding="utf-8").read()
    decoder = json.JSONDecoder()
    found, at = [], 0
    while at < len(text):
        while at < len(text) and text[at].isspace():
            at += 1
        if at >= len(text):
            break
        page, at = decoder.raw_decode(text, at)
        found.extend(page if isinstance(page, list) else [page])
    return found


def version_of(tag):
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", tag or "")
    return tuple(int(part) for part in match.groups()) if match else None


def plain(notes):
    """Release notes as AltStore shows them: plain text, without Markdown's marks."""
    text = notes or ""
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"^#+\s*", "", text, flags=re.M)
    text = text.replace("**", "").replace("`", "")
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def main():
    releases_path, repo, tag, ipa, out = sys.argv[1:6]
    raw = f"https://raw.githubusercontent.com/{repo}/main"

    data = open(ipa, "rb").read()
    current = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    versions = []
    for release in releases_from(releases_path):
        number = version_of(release.get("tag_name"))
        if release.get("draft") or release.get("prerelease") or not number or number < FIRST:
            continue
        asset = next((a for a in release.get("assets", []) if a.get("name") == ASSET), None)
        is_current = release["tag_name"] == tag
        if not asset and not is_current:
            continue
        entry = {
            "version": ".".join(map(str, number)),
            "date": release.get("published_at") or release.get("created_at"),
            "localizedDescription": plain(release.get("body")),
            "downloadURL": f"https://github.com/{repo}/releases/download/{release['tag_name']}/{ASSET}",
            "size": current["size"] if is_current else asset["size"],
            "minOSVersion": MIN_OS,
        }
        if is_current:
            entry["sha256"] = current["sha256"]
        versions.append((number, entry))
    versions.sort(key=lambda pair: pair[0], reverse=True)

    source = {
        "name": "AIOStreams for iOS",
        "identifier": "io.github.aiostreams-ios",
        "subtitle": "An unofficial iPhone and iPad port of AIOStreams.",
        "website": f"https://github.com/{repo}",
        "iconURL": f"{raw}/AIOStreams/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
        "tintColor": TINT,
        "apps": [
            {
                "name": "AIOStreams",
                "bundleIdentifier": BUNDLE,
                "developerName": "aiostreams-ios",
                "subtitle": "Your AIOStreams server, played through AetherEngine.",
                "localizedDescription": (
                    "An unofficial iPhone and iPad port of the AIOStreams app. It runs AIOStreams' own "
                    "web app over AetherEngine, with HDR10, HDR10+, Dolby Vision and Atmos, trailers, "
                    "Picture in Picture and downloads. Not affiliated with AIOStreams or AetherEngine."
                ),
                "iconURL": f"{raw}/AIOStreams/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
                "tintColor": TINT,
                "category": "entertainment",
                "screenshots": [
                    f"{raw}/docs/screenshots/{name}.jpg"
                    for name in ("iphone-home", "iphone-show", "iphone-movie", "iphone-versions")
                ],
                "versions": [entry for _, entry in versions],
                "appPermissions": {
                    "entitlements": [],
                    "privacy": {
                        "NSLocalNetworkUsageDescription": "AIOStreams connects to your server and streams on your local network.",
                        "NSMicrophoneUsageDescription": "Voice search in the page's search field uses the microphone.",
                    },
                },
            }
        ],
        "news": [],
    }
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(source, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"{out}: {len(versions)} versions, newest {versions[0][1]['version'] if versions else 'none'}")


if __name__ == "__main__":
    main()
