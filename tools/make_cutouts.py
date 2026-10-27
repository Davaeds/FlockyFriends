"""Cut each bird out of its photo for the shelf.

Reads photos/<id>.jpg, removes the background (rembg, isnet-general-use model),
trims to the bird, and saves cutouts/<id>.webp with a transparent background.
cutouts/index.json maps id -> the photo version ("v" in photos/index.json) it
was made from, so only new or changed photos are redone.

Birds in SKIP keep their framed photo on the shelf, because the cut-out
didn't come out cleanly (checked by eye).

usage: pip install "rembg[cpu]"; python3 tools/make_cutouts.py
       python3 tools/make_cutouts.py --tidy   (re-trim existing cutouts only)
"""
import json, os, sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHOTOS, OUT = os.path.join(ROOT, "photos"), os.path.join(ROOT, "cutouts")
MAX = 360   # longest side in pixels; the shelf shows birds about 110px tall
SKIP = set(json.load(open(os.path.join(ROOT, "tools", "cutout-skip.json")))) if os.path.exists(os.path.join(ROOT, "tools", "cutout-skip.json")) else set()

def tidy(im):
    """Drop the faint haze the model leaves around fur and legs, then trim to the bird."""
    a = im.getchannel("A").point(lambda v: 0 if v < 28 else v)
    im.putalpha(a)
    box = a.point(lambda v: 255 if v > 24 else 0).getbbox()
    return im.crop(box) if box else None

def main():
    if "--tidy" in sys.argv:
        for f in sorted(os.listdir(OUT)):
            if f.endswith(".webp"):
                im = tidy(Image.open(os.path.join(OUT, f)).convert("RGBA"))
                if im: im.save(os.path.join(OUT, f), "WEBP", quality=82, method=6)
        return print("tidied")
    from rembg import new_session, remove
    photos = {k: v for k, v in json.load(open(os.path.join(PHOTOS, "index.json"))).items() if not k.startswith("_")}
    os.makedirs(OUT, exist_ok=True)
    idx_path = os.path.join(OUT, "index.json")
    done = json.load(open(idx_path)) if os.path.exists(idx_path) else {}
    for bid in [b for b in done if b not in photos or b in SKIP]:   # photo removed, or cut-out not clean
        done.pop(bid)
        if os.path.exists(os.path.join(OUT, bid + ".webp")): os.remove(os.path.join(OUT, bid + ".webp"))
    todo = [b for b, p in photos.items() if done.get(b) != p["v"] and b not in SKIP]
    session = new_session("isnet-general-use")
    for n, bid in enumerate(todo, 1):
        im = remove(Image.open(os.path.join(PHOTOS, bid + ".jpg")).convert("RGB"), session=session)
        im = tidy(im)
        if im is None: print("nothing left:", bid); continue
        im.thumbnail((MAX, MAX), Image.LANCZOS)
        im.save(os.path.join(OUT, bid + ".webp"), "WEBP", quality=82, method=6)
        done[bid] = photos[bid]["v"]
        if n % 25 == 0: print(f"{n}/{len(todo)}", flush=True); json.dump(done, open(idx_path, "w"), indent=0, sort_keys=True)
    json.dump(done, open(idx_path, "w"), indent=0, sort_keys=True)
    print(f"done: {len(todo)} made, {len(done)} cutouts")

if __name__ == "__main__":
    sys.exit(main())
