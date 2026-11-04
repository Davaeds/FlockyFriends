"""Look for Featherly Friends birds that aren't on the list yet.

Runs every few days in GitHub Actions (.github/workflows/new-birds.yml), after
tools/wiki_dump.py and tools/wiki_birds.py have refreshed the fan wiki copy.
Two places are checked:
  1. the Target Birds fan wiki's release list (research/wiki-birds.json), and
  2. recent hip2save.com articles about Target's birds (found through the
     site's sitemaps, which it publishes for this), for birds the wiki hasn't
     listed yet. Names come from the article's shopping links, so these need a
     human look before they go on the list.
Anything new goes in new-birds.json as "waiting". The app keeps waiting birds
hidden from everyone until Ethan adds them on his phone. New birds also get an
entry in tools/photo-sources.json so the photo job can find a real photo.

usage: python3 tools/find_new_birds.py   (prints the ids that still need a photo
on the last line as "NEED_PHOTOS=id,id")
"""
import datetime as dt, html, json, os, re, sys, time, unicodedata, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = lambda *a: os.path.join(ROOT, *a)
UA = "FlocksBirdCheck/1.0 (family collection app; https://github.com/Davaeds/FlockyFriends)"
WIKI = "https://target-birds.fandom.com/wiki/"
NEWS_DAYS = 60
SEASON_WORDS = [("christmas", "christmas"), ("holiday", "christmas"), ("wondershop", "christmas"), ("hanukkah", "christmas"),
                ("halloween", "halloween"), ("hyde", "halloween"), ("muertos", "muertos"), ("harvest", "fall"), ("fall", "fall"),
                ("thanksgiving", "fall"), ("valentine", "valentine"), ("patrick", "stpatricks"), ("easter", "spring"),
                ("spring", "spring"), ("pride", "pride"), ("sun squad", "summer"), ("summer", "summer"), ("patriotic", "patriotic"),
                ("4th of july", "patriotic"), ("july 4", "patriotic")]
SEASON_LABEL = {"christmas": "Christmas", "halloween": "Halloween", "fall": "Harvest", "muertos": "Día de los Muertos", "valentine": "Valentine's Day",
                "spring": "Easter", "summer": "Summer", "patriotic": "Patriotic", "pride": "Pride", "stpatricks": "Saint Patrick's Day", "other": ""}
BODY = {"christmas": "#E0525B", "halloween": "#F2873A", "fall": "#C9A227", "muertos": "#8A5CC9", "valentine": "#F4A6C0", "spring": "#9C8BE0",
        "summer": "#3BA7D9", "patriotic": "#3E5BA9", "pride": "#F2795D", "stpatricks": "#2FA35B", "other": "#C9B8A6"}
NOT_A_BIRD = re.compile(r"\b(\d+\s*-?\s*(pk|pack|pc|piece)|pack|set|mini|minis|ornament|mug|tree|bundle|garland|stand|camper|house|sign|pillow|"
                        r"target|amazon|walmart|shop|here|deal|deals|sale|coupon|app|circle|redcard|gift card|featherly friends)\b", re.I)

def norm(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "", s)

def slug(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")

def get(url, tries=3):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,application/xml,*/*"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read().decode("utf-8", "replace")
        except Exception:
            if i == tries - 1: raise
            time.sleep(5 * (i + 1))

def season_of(*texts):
    for t in texts:
        low = (t or "").lower()
        for word, s in SEASON_WORDS:
            if word in low: return s
    return "other"

def load(path, default):
    try: return json.load(open(path))
    except FileNotFoundError: return default

def main():
    now = dt.datetime.now(dt.timezone.utc)
    birds = json.load(open(P("birds.json")))
    excluded = load(P("research", "excluded.json"), {})
    state = load(P("new-birds.json"), {"birds": []})
    seen = load(P("research", "news-seen.json"), {})
    sources = json.load(open(P("tools", "photo-sources.json")))
    listed = birds["birds"]
    have = {(norm(b["name"]), b["year"]) for b in listed}
    names_any = {norm(b["name"]) for b in listed}
    ids = {b["id"] for b in listed} | set(birds.get("merged", {}))
    skip_names = {norm(x) for x in excluded.get("names", []) + excluded.get("wiki_unnamed_left_out", [])}
    # Birds already on the list leave the waiting list; the rest stay as they were found.
    waiting = [w for w in state.get("birds", []) if w["id"] not in ids and (norm(w["name"]), w["year"]) not in have]
    wait_keys = {(norm(w["name"]), w["year"]): w for w in waiting}
    found = []

    def add(rec, photo):
        key = (norm(rec["name"]), rec["year"])
        if key in have or norm(rec["name"]) in skip_names: return
        if key in wait_keys:   # seen before: the wiki's latest details win over older ones and over a news mention
            old = wait_keys[key]
            if rec["source"] == "wiki":
                rec["id"], rec["found"] = old["id"], old["found"]
                waiting[waiting.index(old)] = rec; wait_keys[key] = rec; sources[rec["id"]] = photo
            return
        base = slug(rec["name"]) + "-" + rec["year"]
        rec["id"] = base if base not in ids else base + "-new"
        if rec["id"] in ids: return
        ids.add(rec["id"]); waiting.append(rec); wait_keys[key] = rec; found.append(rec)
        sources[rec["id"]] = photo

    # 1. the fan wiki's release list
    back, back_keys = [], set()
    for it in json.load(open(P("research", "wiki-birds.json")))["birds"]:
        if not it["named"] or it["rerelease"] or it["kind"] not in ("bird", "mini", "set") or not re.fullmatch(r"20\d\d", it["year"] or ""):
            continue
        season = it["season"] if it["season"] in BODY else "other"
        if it["kind"] == "mini" and not re.search(r"\bmini$", it["name"], re.I): it = dict(it, name=it["name"] + " Mini")   # same naming as earlier minis
        # A bird from an earlier year, listed again (Target re-releases favourites): the wiki shows its old photo.
        earlier = [b for b in listed if norm(b["name"]) == norm(it["name"]) and b["season"] == season and b["year"] != it["year"]]
        cb = re.search(r"cb=(20\d\d)", it.get("image") or "")
        if earlier and (not cb or cb.group(1) < it["year"]):
            back.append(f"{it['name']} {it['year']} (back from {earlier[0]['year']})"); back_keys.add((norm(it["name"]), it["year"])); continue
        page = WIKI + it["page"].replace(" ", "_") if it.get("page") else WIKI + "All_Releases"
        kind = {"mini": "Mini", "set": "Two-bird set"}.get(it["kind"], it.get("look") or "")
        if it["season"] == "hanukkah": kind = "Hanukkah"
        rec = {"name": it["name"], "season": season, "year": it["year"], "kind": kind[:80], "source": "wiki", "body": BODY[season],
               "url": page, "urlLabel": "Fan wiki", "about": f"Listed on the Target Birds fan wiki ({SEASON_LABEL[season]} {it['year']}).".replace(" )", ")").replace("( ", "("),
               "found": now.strftime("%Y-%m-%d")}
        titles = [f"{it['name']} ({SEASON_LABEL[season]} {it['year']})", f"{it['name']} ({it['year']})"] + ([it["name"]] if norm(it["name"]) not in names_any else [])
        add(rec, {"name": it["name"], "year": it["year"], "season": season, "img": "", "wimg": it.get("image", ""), "wpage": page,
                  "wiki": titles, "pages": [], "strict": norm(it["name"]) in names_any})

    # 2. recent hip2save articles about Target's birds
    cutoff = now - dt.timedelta(days=NEWS_DAYS)
    news_log = []
    try:
        index = get("https://hip2save.com/sitemap_index.xml")
        maps = re.findall(r"<loc>\s*(https://hip2save\.com/(?:deals|news|tips)-sitemap\d*\.xml)\s*</loc>\s*<lastmod>([^<]+)</lastmod>", index)
        urls = []
        for loc, lm in maps:
            if dt.datetime.fromisoformat(lm.strip().replace("Z", "+00:00")) < cutoff: continue
            time.sleep(1)
            try: smap = get(loc)
            except Exception as e: news_log.append(f"{loc}: {type(e).__name__}"); continue
            for u, ulm in re.findall(r"<loc>\s*([^<\s]+)\s*</loc>\s*<lastmod>([^<]+)</lastmod>", smap):
                if dt.datetime.fromisoformat(ulm.strip().replace("Z", "+00:00")) < cutoff: continue
                if re.search(r"featherly|(target|wondershop|spritz|hyde|eek)[a-z-]*-birds?\b|birds?-(at-)?target", u): urls.append((u, ulm.strip()))
        for u, ulm in urls:
            if seen.get(u) == ulm: continue
            time.sleep(1)
            try: page = get(u)
            except Exception as e: news_log.append(f"{u}: {type(e).__name__}"); continue
            seen[u] = ulm
            if "featherly" not in page.lower(): news_log.append(f"{u}: no Featherly Friends"); continue
            pub = re.search(r'article:published_time"\s+content="(\d{4})', page)
            year = pub.group(1) if pub else now.strftime("%Y")
            title = html.unescape((re.search(r"<title>([^<]+)", page) or [None, ""])[1])
            body = page.split("</article>")[0]
            names = []
            for href, text in re.findall(r'<a\s[^>]*href="([^"]+)"[^>]*>(.*?)</a>', body, re.S):
                if not re.search(r"ltk\.com|target\.com|rstyle\.me|go\.skimresources|howl\.me|shopstyle", href): continue
                text = html.unescape(re.sub(r"<[^>]+>", "", text)).strip()
                m = re.search(r"Featherly Friends?\S*\s*[–—-]\s*(.+)$", text)
                if m: cand, ctx = m.group(1).strip(), text
                elif re.fullmatch(r"[A-Z][A-Za-z'’.]+(?: [A-Z][A-Za-z'’.]+)?", text): cand, ctx = text, ""
                else: continue
                if NOT_A_BIRD.search(cand) or NOT_A_BIRD.search(ctx.replace("Featherly Friends", "")) or len(cand) > 30: continue
                names.append((cand.strip(" '’\""), season_of(ctx, title, u)))
            news_log.append(f"{u}: {', '.join(n for n, _ in names) or 'no names'}")
            for name, season in names:
                prev = str(int(year) - 1)
                if any(norm(b["name"]) == norm(name) and b["year"] == prev and b["season"] == season for b in listed): continue   # last year's bird, back in stock
                rec = {"name": name, "season": season, "year": year, "kind": "", "source": "news", "body": BODY[season], "url": u,
                       "urlLabel": "hip2save article", "about": f"Named in the hip2save.com article “{title.split(' | ')[0].strip()}”. Not on the fan wiki yet.",
                       "found": now.strftime("%Y-%m-%d")}
                add(rec, {"name": name, "year": year, "season": season, "img": "", "wimg": "", "wpage": "",
                          "wiki": [f"{name} ({SEASON_LABEL[season]} {year})", f"{name} ({year})"] + ([name] if norm(name) not in names_any else []),
                          "pages": [], "strict": True})
    except Exception as e:
        news_log.append(f"news check failed: {type(e).__name__} {str(e)[:120]}")

    waiting[:] = [w for w in waiting if (norm(w["name"]), w["year"]) not in back_keys]
    # Birds that left the waiting list without joining the main list (e.g. they turned out to be re-releases): drop their photos too.
    official = {b["id"] for b in listed}
    for gone in {w["id"] for w in state.get("birds", [])} - {w["id"] for w in waiting} - official:
        sources.pop(gone, None)
        for d, ext in (("photos", ".jpg"), ("cutouts", ".webp")):
            idx = load(P(d, "index.json"), None)
            if idx is not None and gone in idx:
                idx.pop(gone); open(P(d, "index.json"), "w").write(json.dumps(idx, indent=1 if d == "photos" else 0, ensure_ascii=False))
            if os.path.exists(P(d, gone + ext)): os.remove(P(d, gone + ext))
    state = {"note": "Birds the automatic check found that aren't on the list yet. The app hides them until Ethan adds them; see tools/find_new_birds.py.",
             "checked": now.strftime("%Y-%m-%d %H:%M UTC"), "birds": waiting, "rereleases": back, "news": news_log[-40:]}
    open(P("new-birds.json"), "w").write(json.dumps(state, indent=1, ensure_ascii=False) + "\n")
    open(P("research", "news-seen.json"), "w").write(json.dumps(dict(sorted(seen.items())), indent=1) + "\n")
    open(P("tools", "photo-sources.json"), "w").write(json.dumps(sources, indent=1, ensure_ascii=False))
    photos = load(P("photos", "index.json"), {})
    need = [w["id"] for w in waiting if w["id"] not in photos]
    print(f"waiting: {len(waiting)} ({len(found)} new this time): " + ", ".join(f"{w['name']} {w['season']} {w['year']} [{w['source']}]" for w in waiting))
    print("re-releases skipped: " + (", ".join(back) or "none"))
    print("\n".join(news_log))
    print("NEED_PHOTOS=" + ",".join(need))

if __name__ == "__main__":
    main()
