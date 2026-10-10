"""Save a copy of the Target Birds fan wiki's bird pages, so the bird list can be
checked against it.

Runs in GitHub Actions (see .github/workflows/wiki.yml), which can reach the
wiki. Writes research/wiki-pages.json:
  pages:      one entry per article: title, categories, lead image, the start of
              its wikitext (where the infobox with year and collection lives)
  redirects:  other names that lead to an article ({"from": ..., "to": ...})
  categories: every category with how many pages it has

usage: python3 tools/wiki_dump.py
"""
import json, os, time, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "research", "wiki-pages.json")
WIKI = "https://target-birds.fandom.com"
UA = "FlocksPhotoFetcher/1.0 (family collection app; https://github.com/Davaeds/FlockyFriends)"
HEAD = 3000   # characters of wikitext kept per page

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
                e["text"] = (slot.get("content") or revs[0].get("content") or "")[:HEAD]
        print("pages so far:", len(pages), flush=True)
    redirects = []
    for r in run({"generator": "allpages", "gapnamespace": 0, "gapfilterredir": "redirects", "gaplimit": 500, "redirects": 1}):
        for d in r.get("query", {}).get("redirects", []):
            redirects.append({"from": d["from"], "to": d["to"]})
    cats = []
    for r in run({"list": "allcategories", "aclimit": 500, "acprop": "size"}):
        for c in r.get("query", {}).get("allcategories", []):
            cats.append({"name": c.get("category") or c.get("title") or c.get("*", ""), "pages": c.get("pages", c.get("size", 0))})
    out = {"source": WIKI, "fetched": time.strftime("%Y-%m-%d"),
           "pages": sorted(pages.values(), key=lambda e: e["title"]),
           "redirects": sorted(redirects, key=lambda d: d["from"]),
           "categories": sorted(cats, key=lambda c: c["name"])}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f: json.dump(out, f, indent=1, ensure_ascii=False)
    print(f"saved {len(pages)} pages, {len(redirects)} redirects, {len(cats)} categories")

if __name__ == "__main__":
    main()
