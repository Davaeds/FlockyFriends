"""Save a copy of the Target Birds fan wiki's bird pages, so the bird list can be
checked against it.

Runs in GitHub Actions (see .github/workflows/wiki.yml), which can reach the
wiki. Writes research/wiki-pages.json:
  pages:      one entry per article: title, categories, lead image, wikitext
              (the infobox has year and collection; release pages list every bird)
  redirects:  other names that lead to an article ({"from": ..., "to": ...})
  categories: every category with how many pages it has
  files:      the full-size address of every image shown in a gallery

usage: python3 tools/wiki_dump.py
"""
import json, os, re, time, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "research", "wiki-pages.json")
WIKI = "https://target-birds.fandom.com"
UA = "FlocksPhotoFetcher/1.0 (family collection app; https://github.com/Davaeds/FlockyFriends)"

def api(params):
    params = dict(params, action="query", format="json", formatversion="2")
    url = WIKI + "/api.php?" + urllib.parse.urlencode(params)
    for i in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except Exception as e:
            err = e
            time.sleep(2 * (i + 1))
    raise err

def run(params):
    """Follow MediaWiki continuation, yielding each response."""
    cont = {}
    while True:
        r = api(dict(params, **cont))
        yield r
        if "continue" not in r: return
        cont = r["continue"]
        time.sleep(0.3)

def main():
    pages = {}
    q = {"generator": "allpages", "gapnamespace": 0, "gapfilterredir": "nonredirects", "gaplimit": 50,
         "prop": "revisions|categories|pageimages", "rvprop": "content", "rvslots": "main",
         "cllimit": "max", "clshow": "!hidden", "piprop": "original|name", "pilicense": "any"}
    for r in run(q):
        for p in r.get("query", {}).get("pages", []):
            e = pages.setdefault(p["pageid"], {"title": p["title"], "categories": [], "image": "", "file": "", "text": ""})
            for c in p.get("categories", []):
                name = c["title"].split(":", 1)[-1]
                if name not in e["categories"]: e["categories"].append(name)
            if p.get("original"): e["image"] = p["original"]["source"]
            if p.get("pageimage"): e["file"] = p["pageimage"]
            revs = p.get("revisions") or []
            if revs and not e["text"]:
                slot = revs[0].get("slots", {}).get("main", {})
                e["text"] = slot.get("content") or revs[0].get("content") or ""
        print("pages so far:", len(pages), flush=True)
    redirects = []
    for r in run({"generator": "allpages", "gapnamespace": 0, "gapfilterredir": "redirects", "gaplimit": 500, "redirects": 1}):
        for d in r.get("query", {}).get("redirects", []):
            redirects.append({"from": d["from"], "to": d["to"]})
    cats = []
    for r in run({"list": "allcategories", "aclimit": 500, "acprop": "size"}):
        for c in r.get("query", {}).get("allcategories", []):
            cats.append({"name": c.get("category") or c.get("title") or c.get("*", ""), "pages": c.get("pages", c.get("size", 0))})
    # Release pages show birds that have no page of their own in galleries; look up those images.
    names = set()
    for e in pages.values():
        for block in re.findall(r"<gallery[^>]*>(.*?)</gallery>", e["text"], re.S | re.I):
            for line in block.splitlines():
                f = re.sub(r"^\s*(File|Image):", "", line.split("|", 1)[0].strip(), flags=re.I).strip()
                if re.search(r"\.(jpe?g|png|webp|gif)$", f, re.I): names.add(f)
        names.update(m.strip() for m in re.findall(r"\[\[(?:File|Image):([^|\]]+)", e["text"], re.I))
    files = {}
    names = sorted(names)
    for i in range(0, len(names), 50):
        r = api({"titles": "|".join("File:" + n for n in names[i:i + 50]), "prop": "imageinfo", "iiprop": "url"})
        norm = {n["to"]: n["from"] for n in r.get("query", {}).get("normalized", [])}
        for p in r.get("query", {}).get("pages", []):
            info = p.get("imageinfo") or []
            if info:
                t = norm.get(p["title"], p["title"])
                files[t.split(":", 1)[1]] = info[0]["url"]
        time.sleep(0.3)
    out = {"source": WIKI, "fetched": time.strftime("%Y-%m-%d"),
           "pages": sorted(pages.values(), key=lambda e: e["title"]),
           "redirects": sorted(redirects, key=lambda d: d["from"]),
           "categories": sorted(cats, key=lambda c: c["name"]),
           "files": dict(sorted(files.items()))}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f: json.dump(out, f, indent=1, ensure_ascii=False)
    print(f"saved {len(pages)} pages, {len(redirects)} redirects, {len(cats)} categories, {len(files)} of {len(names)} images")

if __name__ == "__main__":
    main()
