"""Turn the fan wiki copy (research/wiki-pages.json) into a plain list of birds.

The wiki's "All Releases" page lists every release by year and season. This
keeps the named birds (and named minis and two-bird sets), with the photo shown
for each in that section's gallery and, when the bird has its own page, what
its infobox says. Writes research/wiki-birds.json.

usage: python3 tools/wiki_birds.py
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "research", "wiki-pages.json")
OUT = os.path.join(ROOT, "research", "wiki-birds.json")
SEASONS = {"valentine's day": "valentine", "saint patrick's day": "stpatricks", "easter": "spring", "sun squad": "summer",
           "pride": "pride", "halloween": "halloween", "dia de los muertos": "muertos", "harvest": "fall", "christmas": "christmas"}
KEEP = {"birds": "bird", "mini birds": "mini", "minis": "mini", "sets": "set"}
# Descriptions rather than names: the early unnamed birds and the colour-named minis.
UNNAMED = re.compile(r"\b(with|hat|bird|plaid|chocolate|unnamed|featherly|set|\d+pk)\b|^(red|orange|yellow|green|blue|pink|purple|gray|grey|white|tan|"
                     r"brown|ivory|neutral|dark|light|teal|all white|santa hat|top hat|heart|owl|harvest owl)\b|\b(19|20)\d\d\b", re.I)

def strip_links(s):
    s = re.sub(r"\[\[(?:[^|\]]*\|)?([^\]]*)\]\]", r"\1", s)
    s = re.sub(r"\[https?://\S+ ([^\]]*)\]", r"\1", s)
    return re.sub(r"'''?", "", s).strip()

def infobox(text):
    m = re.search(r"\{\{Target Bird(.*?)\}\}(?!\})", text, re.S)
    if not m: return {}
    out = {}
    for part in re.split(r"\|(?![^\[]*\]\])", m.group(1)):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip().lower()] = strip_links(v.strip())
    return out

def main():
    w = json.load(open(SRC))
    pages = {p["title"]: p for p in w["pages"]}
    files = w.get("files", {})
    text = pages["All Releases"]["text"]
    year = season = sub = ""
    items, gallery = [], []
    def flush_gallery():
        # match each gallery picture to an item of the same section by its caption or link
        for g in gallery:
            parts = [x.strip() for x in g.split("|")]
            f = re.sub(r"^(File|Image):", "", parts[0], flags=re.I).strip()
            caps = [strip_links(re.sub(r"^link=", "", x)) for x in parts[1:]] + re.findall(r"\[\[([^|\]]+)", g)
            for it in items:
                if it["year"] == year and it["season"] == season and not it.get("file"):
                    keys = {it["display"], it["page"], it["display"].split(" (")[0]}
                    if any(c in keys for c in caps if c):
                        it["file"] = f
    in_gal = False
    for line in text.splitlines():
        if re.match(r"\s*<gallery", line, re.I): in_gal = True; gallery = []; line = re.sub(r".*?<gallery[^>]*>", "", line, flags=re.I)
        if in_gal:
            end = re.search(r"</gallery>", line, re.I)
            body = line[:end.start()] if end else line
            if body.strip(): gallery.append(body.strip())
            if end: in_gal = False; flush_gallery()
            continue
        if "<gallery" in line:   # gallery started mid-line ("Mug[gallery]")
            in_gal = True; gallery = []; continue
        h = re.match(r"^(=+)\s*(.*?)\s*\1\s*$", line.strip())
        if h:
            lvl, title = len(h.group(1)), strip_links(h.group(2))
            if lvl == 2: year, season, sub = re.sub(r"\D", "", title), "", ""
            elif lvl == 3: season, sub = SEASONS.get(title.lower(), title.lower()), ""
            else: sub = title.lower()
            continue
        if not line.strip().startswith("*") or sub not in KEEP: continue
        raw = line.strip().lstrip("*").strip()
        link = re.match(r"\[\[([^|\]]+)(?:\|([^\]]+))?\]\]", raw)
        ext = re.match(r"\[https?://\S+/wiki/(\S+) ([^\]]+)\]", raw)
        if link: page, display = link.group(1).strip(), (link.group(2) or link.group(1)).strip()
        elif ext: page, display = ext.group(1).replace("_", " "), ext.group(2).strip()
        else: page, display = "", re.sub(r"\[.*$", "", raw).strip()
        if not display or "canceled" in display.lower(): continue
        quals = re.findall(r"\(([^)]*)\)", display)
        name = re.sub(r"\s*\(.*$", "", display).strip()
        name = re.sub(r"\s+20\d\d$", "", name)   # "Lindoro 2025"
        rerelease = bool(re.search(r"rerelease", display, re.I))
        orig_year = next((re.search(r"(20\d\d)", q).group(1) for q in quals if re.fullmatch(r"20\d\d", q.strip())), "")
        look = next((q for q in quals if not re.search(r"\d|rerelease|duplicate", q, re.I)), "")
        if page in pages and "Anniversary Collection" in page and not rerelease: page = ""   # Aurum: listed under the set's page
        kind = KEEP[sub]
        named = not UNNAMED.search(name) or (kind == "mini" and not UNNAMED.search(re.sub(r"\s+Mini$", "", name)))
        items.append({"name": name, "display": display, "page": page if page in pages else "", "year": year, "season": season,
                      "kind": kind, "look": look, "rerelease": rerelease, "first_year": orig_year, "named": bool(named)})
    for it in items:
        p = pages.get(it["page"])
        box = infobox(p["text"]) if p else {}
        it["infobox"] = {k: box[k] for k in ("year", "collection", "holiday/season", "target.com_title", "color", "caption-image1", "release_date") if box.get(k)}
        it["page_image"] = p["image"] if p else ""
        it["image"] = files.get(it.get("file", ""), "") or (it["page_image"] if not it["rerelease"] else "")
    # bird pages that "All Releases" never mentions
    listed = {it["page"] for it in items}
    orphans = sorted(t for t, p in pages.items() if t not in listed and "{{Target Bird" in p["text"] and "Releases" not in t)
    json.dump({"note": "Built from the fan wiki's All Releases page; see tools/wiki_birds.py", "birds": items, "unlisted_pages": orphans},
              open(OUT, "w"), indent=1, ensure_ascii=False)
    named = [i for i in items if i["named"]]
    print(f"{len(items)} items, {len(named)} named ({sum(i['kind']=='bird' for i in named)} birds, {sum(i['kind']=='mini' for i in named)} minis, "
          f"{sum(i['kind']=='set' for i in named)} sets, {sum(i['rerelease'] for i in named)} rereleases); "
          f"{sum(1 for i in named if i['image'])} with a photo; unlisted pages: {len(orphans)}")

if __name__ == "__main__":
    main()
