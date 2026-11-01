"""Follow shop links to the Target product page they point at.

Runs in GitHub Actions (.github/workflows/resolve.yml), which can reach the
link shortener and Target. Reads research/to-resolve.json and writes
research/resolved.json with, for each name: the final Target product URL, its
item number (TCIN), the page title and Target's product image, when found.
"""
import json, os, re, sys, time, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IN = os.path.join(ROOT, "research", "to-resolve.json")
OUT = os.path.join(ROOT, "research", "resolved.json")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
TGT = re.compile(r"https?://(?:www\.)?target\.com/p/[^\"'\s<>?#]+/-/A-(\d+)")

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,*/*", "Accept-Language": "en-US,en;q=0.8"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.read().decode("utf-8", "replace"), r.geturl()

def meta(html, prop):
    m = re.search(r'<meta[^>]+(?:property|name)=["\']%s["\'][^>]+content=["\']([^"\']+)' % re.escape(prop), html) or \
        re.search(r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']%s["\']' % re.escape(prop), html)
    return m.group(1).replace("&amp;", "&") if m else ""

def find_target(url, depth=0):
    """Return the target.com product URL a link leads to (through redirects, meta refresh or links in the page)."""
    html, final = get(url)
    m = TGT.search(urllib.parse.unquote(final))
    if m: return m.group(0), m.group(1), html if "target.com" in final else None
    text = urllib.parse.unquote(html.replace("\\u002F", "/").replace("\\/", "/"))
    m = TGT.search(text)
    if m: return m.group(0), m.group(1), None
    if depth < 2:
        for nxt in re.findall(r'https?://(?:goto\.target\.com|click\.linksynergy\.com|[a-z0-9.-]*ltk\.com|rstyle\.me)[^"\'\s<>]+', text)[:3]:
            try:
                r = find_target(nxt.replace("&amp;", "&"), depth + 1)
                if r[0]: return r
            except Exception:
                pass
    return "", "", None

def main():
    links = json.load(open(IN))["links"]
    out = {}
    for name, url in links.items():
        rec = {"from": url}
        try:
            turl, tcin, html = find_target(url)
            rec.update(url=turl, tcin=tcin)
            if turl and html is None:
                try: html, _ = get(turl)
                except Exception as e: rec["page_error"] = str(e)[:200]
            if html:
                rec["title"] = meta(html, "og:title") or (re.search(r"<title>([^<]+)", html) or [None, ""])[1]
                rec["img"] = meta(html, "og:image")
                rec["desc"] = meta(html, "og:description") or meta(html, "description")
                hl = re.findall(r'(?:Height|Dimensions \(Overall\))[^0-9<]{0,40}([0-9.]+ ?(?:Inches|inches|in))', html)
                if hl: rec["height"] = hl[0]
                bl = re.findall(r'"bullet_descriptions?"\s*:\s*\[([^\]]{0,3000})\]', html)
                if bl: rec["bullets"] = re.sub(r"<[^>]+>", "", bl[0])[:1500]
                dl = re.findall(r'"downstream_description"\s*:\s*"([^"]{0,2000})"', html)
                if dl: rec["long"] = re.sub(r"<[^>]+>", " ", dl[0])[:1500]
                if not rec["img"]:
                    m = re.search(r'https://target\.scene7\.com/is/image/Target/(GUEST_[0-9a-f-]{36})', html)
                    if m: rec["img"] = "https://target.scene7.com/is/image/Target/" + m.group(1)
        except Exception as e:
            rec["error"] = str(e)[:200]
        out[name] = rec
        print(name, json.dumps(rec), flush=True)
        time.sleep(1.5)
    json.dump(out, open(OUT, "w"), indent=1, ensure_ascii=False)

if __name__ == "__main__":
    main()
