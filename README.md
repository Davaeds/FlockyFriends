# Flocks

A home-screen web app where Norma and Ashton keep track of their Featherly Friends birds.
Every bird is on one shared list. Each person has their own flock, wish list, notes and photos,
and can see what the other has and wants, so gift shopping is easy.

## What's in this folder

| File | What it is |
| --- | --- |
| `index.html` | The whole app (no build step) |
| `config.js` | Your Supabase project URL and public key. Until it's filled in, the app runs in preview mode and saves only on that phone |
| `setup.sql` | One-time database setup: locked tables, passcode-checked functions, and the starting bird list. Contains no passcode |
| `birds.json` | The same starting bird list, used by preview mode |
| `sw.js`, `manifest.webmanifest`, `icons/` | What makes it install like an app on the Home Screen and open without a connection |
| `.github/workflows/keep-awake.yml` | Pings the database twice a week so Supabase's free tier doesn't pause it |

## Setup (about 10 minutes)

1. **Database.** Create a free project at supabase.com. Open **SQL Editor > New query**, paste all of `setup.sql`, and press **Run**.
2. **Passcode.** Open a second **New query** (don't save it) and run one line with a passcode of your choice, at least 10 characters. Four random words work well:

   ```sql
   select flocks_set_passcode('four random words here');
   ```

   Never put the passcode in this repo. Share it with the family by text or in person.
3. **Keys.** In the project, open **Connect** (or **Project Settings > API Keys**), copy the **Project URL** and the **publishable** (or legacy **anon**) key, and put them in `config.js`. That key is meant to be public. The passcode is what keeps strangers out. Never use the **secret** or **service_role** key here.
4. **Hosting.** This repo is already set up. In the repo, go to **Settings > Pages**, set **Source: Deploy from a branch**, branch `main`, folder `/ (root)`, then **Save**. The app appears at `https://davaeds.github.io/FlockyFriends/` after a minute or two.
5. **On each iPhone.** Open the link in **Safari**, tap **Share > Add to Home Screen**, then open Flocks from the new icon, enter the family passcode once, and pick your name.

## How it stays private

- The tables are locked. The public key can only call database functions, and every function checks the family passcode first.
- The passcode is stored as a bcrypt hash, never in plain text and never in this repo.
- After 30 wrong passcodes in 15 minutes, Flocks refuses everyone (family included) until the 15 minutes pass. This protects against guessing, at the cost that a stranger who finds the link could pause it for a while.
- Every write is checked on the server: names and notes have length limits, colours must be hex codes, photos must be small JPEG, PNG or WebP images.
- Anyone who knows the passcode can change any flock. That's by design for one family.
- "I'm getting this" gift plans are hidden in the app from the person they're for. They are stored in the shared database, so they're private from that person's screen, not from someone who goes digging in the database.

## Photos

Every bird shows a real photo when one could be found. The **Fetch bird photos** workflow (`.github/workflows/photos.yml`, script `tools/fetch_photos.py`) uses Target's own product photo for birds Target lists, and otherwise the photo the Target Birds fan wiki shows for that bird's release, so two birds with the same name from different years each get their own picture. It saves the photos in `photos/` and lists where each one came from in `photos/index.json`; the app credits the source under each photo. Birds still without a photo say "No photo yet", and anyone can tap the bird and choose **Add my photo**, which is shrunk on the phone and saved for everyone to see.

To look again for missing photos, open **Actions > Fetch bird photos > Run workflow**.

## Where the bird list comes from

`birds.json` follows the fan wiki's [All Releases](https://target-birds.fandom.com/wiki/All_Releases) page: every named bird from 2016 to 2026 (including named minis and the two-bird sets), in the year and season the wiki gives, plus Target's newest birds that aren't on the wiki yet. Re-releases (the 2024 Reunion Collection, the 2025 Anniversary Collection) are noted on the original bird rather than listed twice, and Target's product names are kept as notes (searching "Bonjour" finds Chérie). Early unnamed birds (2013 to 2016), colour-named minis, ornaments, multi-packs and accessories are left out; `research/excluded.json` lists them.

How it's built: the **Copy fan wiki pages** workflow (`tools/wiki_dump.py`) saves the wiki to `research/wiki-pages.json`, and `tools/wiki_birds.py` turns that into `research/wiki-birds.json`. When two records turn out to be the same bird, `birds.json` has a `merged` entry, and both the app and `setup.sql` move anyone's flock, wish list, notes, gift plans and family photo to the record that stays. The family can add any missing bird from **All birds > Add a missing bird**.

## Changing things later

- **New passcode:** run `select flocks_set_passcode('new words');` again. Everyone re-enters it once.
- **Updated bird list:** run the new `setup.sql` again. It keeps every flock, wish list, note, gift plan, photo and family-added bird.
