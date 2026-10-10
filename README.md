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

Every bird shows a real photo when one could be found. The **Fetch bird photos** workflow (`.github/workflows/photos.yml`, script `tools/fetch_photos.py`) looks for each bird's photo on Target's listing, its page on the Target Birds fan wiki, or a resale listing that shows only that bird. It saves the photos in `photos/` and lists where each one came from in `photos/index.json`. The app credits the source under each photo. Birds still without a photo say "No photo yet", and anyone can tap the bird and choose **Add my photo**, which is shrunk on the phone and saved for everyone to see.

To look again for missing photos, open **Actions > Fetch bird photos > Run workflow**.

## Where the bird list comes from

`birds.json` lists named Featherly Friends characters (like Crawsly and Bonjour), combined from Target.com listings (October 2026), the Target Birds fan wiki (page titles), news and deal coverage, and resale listings. Ornaments, multi-packs, accessories and other decor are left out; `research/excluded.json` lists what was left out. Each bird records which kind of source it came from, and birds seen only in resale listings are marked "Unconfirmed" in the app. The family can add any missing bird from **All birds > Add a missing bird**.

## Changing things later

- **New passcode:** run `select flocks_set_passcode('new words');` again. Everyone re-enters it once.
- **Updated bird list:** run the new `setup.sql` again. It keeps every flock, wish list, note, gift plan, photo and family-added bird.
