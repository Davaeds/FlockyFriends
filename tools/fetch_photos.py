"""Find and save a real photo for every bird.

Runs in GitHub Actions (see .github/workflows/photos.yml), which can reach the
sites the photos live on. For each bird in tools/photo-sources.json without a
photo yet, it tries, in order:
  1. Target's own product image (target.scene7.com)
  2. the bird's page on the Target Birds fan wiki (lead image)
  3. the bird's Target product page (og:image)
  4. a resale listing that names only this bird (og:image)
The image is resized to at most 800 px, saved as photos/<id>.jpg, and recorded
in photos/index.json with where it came from, so the app can credit it.

usage: python3 tools/fetch_photos.py [--only id,id]   (birds already in photos/index.json are skipped)
"""
import io, json, os, re, sys, time, hashlib, urllib.parse, urllib.request
from collections import Counter
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tools", "photo-sources.json")
OUT = os.path.join(ROOT, "photos")
INDEX = os.path.join(OUT, "index.json")
WIKI = "https://target-birds.fandom.com"
UA = "FlocksPhotoFetcher/1.0 (family collection app; https://github.com/Davaeds/FlockyFriends)"
BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
SKIP_FILE = re.compile(r"\.svg$|\.gif$|logo|wordmark|icon|site-community|favicon|placeholder|no.?image|badge", re.I)

def get(url, ua=UA, accept="*/*", tries=2):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": ua, "Accept": accept, "Accept-Language": "en-US,en;q=0.8"})
            with urllib.request.urlopen(req, timeout=25) as r:
                return r.read(), r.headers.get("Content-Type", ""), r.geturl()
        except Exception as e:
            err = e
            time.sleep(1.5 * (i + 1))
    raise err

def api(params):
    params = dict(params, format="json", formatversion="2")
    body, _, _ = get(WIKI + "/api.php?" + urllib.parse.urlencode(params))
    return json.loads(body)

def og_image(url):
    body, ctype, final = get(url, ua=BROWSER_UA, accept="text/html")
    html = body.decode("utf-8", "replace")
    m = re.search(r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)', html) or \
        re.search(r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']og:image', html)
    return m.group(1).replace("&amp;", "&") if m else ""

def wiki_lead_image(titles, name, year):
    """Return (image_url, page_url) for the first wiki page found among titles, else by search."""
    def from_titles(ts):
        r = api({"action": "query", "titles": "|".join(ts[:20]), "redirects": 1, "prop": "pageimages",
                 "piprop": "original|name", "pilicense": "any"})
        found = {}
        for p in r.get("query", {}).get("pages", []):
            if p.get("missing") or "original" not in p: continue
            src = p["original"]["source"]
            if not SKIP_FILE.search(p.get("pageimage", "") or src):
                found[p["title"]] = src
        norm = {n["to"]: n["from"] for n in r.get("query", {}).get("normalized", [])}
        redir = {n["to"]: n["from"] for n in r.get("query", {}).get("redirects", [])}
        for t in ts:   # keep the caller's priority order
            for title, src in found.items():
                if t in (title, norm.get(title), redir.get(title)):
                    return src, WIKI + "/wiki/" + urllib.parse.quote(title.replace(" ", "_"))
        return None
    hit = from_titles(titles)
    if hit: return hit
    # fall back to the wiki's own search, accepting only a page named after this bird
    r = api({"action": "query", "list": "search", "srsearch": name, "srlimit": 10, "srnamespace": 0})
    base = name.lower()
    cands = [s["title"] for s in r.get("query", {}).get("search", [])
             if re.sub(r"\s*\(.*\)$", "", s["title"]).lower() == base]
    if year:
        with_year = [t for t in cands if year in t]
        cands = with_year or ([t for t in cands if "(" not in t] if len(cands) > 1 else cands)
    return from_titles(cands) if cands else None

def save(bid, data):
    im = Image.open(io.BytesIO(data))
    if im.width < 120 or im.height < 120: raise ValueError("too small")
    im = im.convert("RGB")
    im.thumbnail((800, 800))
    buf = io.BytesIO(); im.save(buf, "JPEG", quality=82, optimize=True, progressive=True)
    blob = buf.getvalue()
    with open(os.path.join(OUT, bid + ".jpg"), "wb") as f: f.write(blob)
    return hashlib.sha1(blob).hexdigest()[:10]

def main():
    args = sys.argv[1:]
    only = set(args[args.index("--only") + 1].split(",")) if "--only" in args else None
    src = json.load(open(SRC))
    os.makedirs(OUT, exist_ok=True)
    index = json.load(open(INDEX)) if os.path.exists(INDEX) else {}
    missing_log = index.pop("_missing", {})
    shared = Counter(p for v in src.values() for p in v["pages"])   # a listing used by several birds shows several birds
    stats = Counter()
    for bid, s in src.items():
        if only and bid not in only: continue
        if bid in index and os.path.exists(os.path.join(OUT, bid + ".jpg")): stats["kept"] += 1; continue
        tried = []
        attempts = []
        if s.get("img"): attempts.append(("target", lambda s=s: (s["img"].split("?")[0] + "?wid=800&hei=800&fmt=pjpeg&qlt=90", "")))
        attempts.append(("wiki", lambda s=s: wiki_lead_image(s["wiki"], s["name"], s["year"])))
        for p in s["pages"]:
            if "target.com/p/" in p: attempts.append(("target", lambda p=p: (og_image(p), p)))
        for p in s["pages"]:
            if re.search(r"ebay|mercari|poshmark|amazon|etsy", p) and shared[p] == 1:
                attempts.append(("resale", lambda p=p: (og_image(p), p)))
        done = False
        for kind, fn in attempts:
            try:
                hit = fn()
                if not hit or not hit[0]: tried.append(kind + ": nothing"); continue
                img_url, page = hit
                if SKIP_FILE.search(img_url): tried.append(kind + ": logo"); continue
                data, ctype, _ = get(img_url, ua=BROWSER_UA, accept="image/*")
                if not ctype.startswith("image/"): tried.append(kind + ": not an image"); continue
                v = save(bid, data)
                index[bid] = {"v": v, "from": kind, "page": page or "", "image": img_url}
                stats[kind] += 1; done = True
                print(f"ok   {bid:40} {kind:7} {img_url[:90]}", flush=True)
                break
            except Exception as e:
                tried.append(f"{kind}: {type(e).__name__} {str(e)[:60]}")
            finally:
                time.sleep(0.4)
        if not done:
            stats["missing"] += 1; missing_log[bid] = tried
            print(f"MISS {bid:40} {' | '.join(tried)[:160]}", flush=True)
        else:
            missing_log.pop(bid, None)
    out = {k: index[k] for k in sorted(index)}
    out["_missing"] = {k: missing_log[k] for k in sorted(missing_log) if k not in index}
    with open(INDEX, "w") as f: json.dump(out, f, indent=1, ensure_ascii=False)
    print("\nsummary:", dict(stats), "| with photo:", len(index), "of", len(src))

if __name__ == "__main__":
    main()
