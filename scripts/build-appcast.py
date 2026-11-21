#!/usr/bin/env python3
"""Builds the Sparkle appcast from every release that has an appcast-item.json.

Called by .github/workflows/pages.yml with a folder holding one subfolder per
release: item.json (the asset the release workflow attaches) and notes.html
(the release notes, rendered from Markdown). The feed is written from scratch
each time, so deleted releases drop out and edited notes show up on the next
deploy.

Stable and beta releases share one feed. Beta items carry
<sparkle:channel>beta</sparkle:channel>, which hides them from everyone who has
not turned on beta updates in the app.
"""
import argparse
import email.utils
import json
import pathlib
import xml.etree.ElementTree as ET
from datetime import datetime

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def sparkle(tag):
    return f"{{{SPARKLE}}}{tag}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--releases", required=True, help="folder with one subfolder per release")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    releases = []
    for folder in pathlib.Path(args.releases).iterdir():
        item = json.loads((folder / "item.json").read_text(encoding="utf-8"))
        notes_file = folder / "notes.html"
        item["notes"] = notes_file.read_text(encoding="utf-8").strip() if notes_file.exists() else ""
        releases.append(item)
    # Newest first. Sparkle compares build numbers, not versions.
    releases.sort(key=lambda r: int(r["build"]), reverse=True)

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Memoir"
    for r in releases:
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = r["version"]
        published = datetime.fromisoformat(r["published"].replace("Z", "+00:00"))
        ET.SubElement(item, "pubDate").text = email.utils.format_datetime(published, usegmt=True)
        ET.SubElement(item, sparkle("version")).text = str(r["build"])
        ET.SubElement(item, sparkle("shortVersionString")).text = r["version"]
        ET.SubElement(item, sparkle("minimumSystemVersion")).text = r["minimumSystemVersion"]
        if r.get("channel"):
            ET.SubElement(item, sparkle("channel")).text = r["channel"]
        if r["notes"]:
            ET.SubElement(item, "description").text = r["notes"]
        ET.SubElement(item, "enclosure", {
            "url": r["url"],
            "length": str(r["length"]),
            "type": "application/octet-stream",
            sparkle("edSignature"): r["signature"],
        })

    tree = ET.ElementTree(rss)
    ET.indent(tree, space="  ")
    tree.write(args.output, encoding="utf-8", xml_declaration=True)
    print(f"Wrote {len(releases)} releases to {args.output}")


if __name__ == "__main__":
    main()
