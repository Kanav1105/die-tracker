# Die Tracker

Shop floor production tracking for press stamping dies. Installable PWA, backed by Supabase,
live across every tablet.

**Operator terminal:** https://kanav1105.github.io/die-tracker/
**Manager view:** https://kanav1105.github.io/die-tracker/manager.html

---

## Files

| File | Purpose |
|---|---|
| `index.html` | **Operator terminal.** This is what goes on the tablets |
| `manager.html` | **Manager view**, behind a password. Not linked from the operator page |
| `core.js` | Shared logic: config, database, domain rules. Edited once, used by both |
| `manifest.json` / `manager-manifest.json` | Install metadata. One per app, so they install separately |
| `manifest.json` | Makes it installable to the home screen |
| `sw.js` | Service worker. Offline shell and caching |
| `icon-192.png` `icon-512.png` `icon-maskable-512.png` | App icons |
| `labels.html` | Printable Code 128 labels for machines and dies |
| `seed_dies.sql` | Die register seed |

---

## Deploy

1. Copy every file above into the repo root of `Kanav1105/die-tracker`.
2. Commit and push to `main`.
3. Settings → Pages → Source: **Deploy from a branch**, branch `main`, folder `/ (root)`. Save.
4. Wait about a minute, then open https://kanav1105.github.io/die-tracker/

Everything uses relative paths (`./`), so the `/die-tracker/` subpath works without changes.

---

## Before it will work

**1. Confirm row-level security is on.** Run in the Supabase SQL Editor:

```sql
select tablename, rowsecurity from pg_tables where schemaname='public';
```

All four tables must show `true`. Without this, the publishable key in `index.html` grants
anyone full delete access to your history.

**2. Confirm the policies.**

```sql
select tablename, policyname, cmd from pg_policies where schemaname='public';
```

Expect five policies. There must be **no UPDATE or DELETE policy on `events`** — that is what
makes the log append-only at the database level rather than by convention.

**3. Seed the dies.** Run `seed_dies.sql`.

**4. Confirm Realtime is on.** Without this, tablets will not see each other's scans live.

```sql
select tablename from pg_publication_tables where pubname='supabase_realtime';
```

`events` must appear. If not:

```sql
alter publication supabase_realtime add table events;
```

---

## Install

Both pages install independently, with different names and different icons, so they are never
confused on a device.

**Operator terminal** — on each tablet:
1. Open https://kanav1105.github.io/die-tracker/ in Chrome.
2. Menu → **Add to Home Screen** → Install.
3. Launch from the icon. There should be no address bar.
Icon: dark, yellow die block. Name: *Die Tracker*.

**Manager** — on the manager's laptop or phone:
1. Open https://kanav1105.github.io/die-tracker/manager.html in Chrome or Edge.
2. Either click the **INSTALL** chip in the header, or use the install icon in the address bar,
   or menu → Install app.
3. On iPhone or iPad use Safari → Share → Add to Home Screen. Safari does not show the chip.
Icon: pale, dark bar chart. Name: *DT Manager*.

The INSTALL chip only appears when the browser judges the app installable and it is not already
installed. If you never see it, it is usually already installed, or you are on a browser that does
not support prompting.

Then lock the tablet down: install **Fully Kiosk Browser**, set the URL as the start page,
enable auto-start on boot and keep-screen-on. That gives you a terminal that survives a power cut.

---

## Checking it is really live

Open the app on two devices. Start a job on one. Within a second or two it should appear in
"Running now" on the other without a refresh. If it does not, Realtime is not enabled — see step 4.

The status chip at the top right tells you where you are:

| Chip | Meaning |
|---|---|
| `LIVE` | Connected, everything written |
| `QUEUE 3` | Three scans held locally, will send when the connection returns |
| `OFFLINE` | No network. Scanning still works, nothing is lost |
| `DB ERROR` | Reached the network but the database refused. Usually RLS |

---

## Scanning

The app tries the browser's native `BarcodeDetector` first, then falls back to **ZXing**.
That covers Android, ChromeOS, macOS, Windows, Linux and iOS.

If the camera will not start, work through these in order:

1. **Not HTTPS.** Camera is blocked on `file://` and plain `http://`. GitHub Pages is HTTPS, so
   this only bites during local testing. Use `python3 -m http.server` and `localhost`.
2. **Permission denied.** Chrome → site settings → Camera → Allow, then reload.
3. **Label does not match the database.** A perfect scan of the wrong code still fails. Machine
   codes are `101`–`113`, die codes are as printed in `labels.html`. Older labels reading
   `MC-01` or `D-2601` will not resolve.
4. **No camera at all.** Use the keypad. Machine codes are three digits; die codes include U, L
   and P keys.

A handheld USB or Bluetooth scanner is faster and more reliable than the camera and needs no
configuration — it behaves as a keyboard. Recommended as the primary method, camera as backup.

Print `labels.html` at **100% scale**. "Fit to page" distorts the bars and they stop scanning.

---

## Two access points

The two pages are fully separated. `index.html` has no manager button and does not contain the
manager code at all. `manager.html` has no scanner and cannot log shop floor events.

Put only the operator URL on the tablets. Give the manager URL to the office.

### Operator keypad password

Typing a die code by hand bypasses the scanner, so it is gated. The supervisor gives the code out
when a label is damaged. Set at the top of `index.html`:

```js
const KEYPAD_PASSWORD  = "2580";   // CHANGE THIS
const KEYPAD_GRACE_MIN = 3;        // minutes before it asks again
```

Use only characters that exist on the pad: digits and U, L, P. After a correct entry the keypad
stays open for the grace period so a mistyped code does not mean re-entering the password.

Machines are chosen by tapping a tile, never scanned, so the keypad is only ever needed for dies.

### Manager password

Set at the top of `manager.html`:

```js
const MANAGER_PASSWORD = "toolroom2026";   // CHANGE THIS
const SESSION_HOURS = 12;                   // re-ask after this long
```

Change it, commit, push. A successful login is remembered on that device for 12 hours.

### What this password is and is not

It is a convenience gate. It stops an operator wandering into the manager view by accident and
keeps casual eyes out.

It is **not security**. The password sits in JavaScript that anyone can read with View Source.
Making the repository private does not change this: GitHub Pages serves the file publicly either
way, so anyone with the URL can read it. Real protection means Supabase Auth with real accounts,
which is Phase 2 work.

Your data is protected by the row-level security policies on the database, not by this page.
That is why the RLS checks above matter more than the password does.

## Updating the app

Edit, commit, push. Then **bump the cache version in `sw.js`**:

```js
const CACHE = "die-tracker-v2";   // was v1
```

Skip this and tablets will keep serving the old build from cache. It is the single most common
cause of "I deployed but nothing changed".

---

## Adding dies and machines

Both live in the database, not in the code, so no deploy is needed.

Supabase → Table Editor → `dies` or `machines` → Insert row.

To let the app's Setup tab add dies directly instead:

```sql
create policy insert_dies on dies for insert with check (true);
```

---

## Data model

`events` is append-only. Nothing is ever edited or deleted; a correction is a new row that
references the original. Machine status and die stage are **derived** by replaying events, never
stored, so no status column can drift out of step with what actually happened.

| Column | Note |
|---|---|
| `ts` | Server time. Authoritative |
| `device_ts` | Device clock, kept for audit of offline scans |
| `type` | START, END, PAUSE, RESUME, CORRECTION |
| `stage_no` | What the operator chose |
| `suggested_stage_no` | What the system expected. Compare the two to measure route adherence |
| `client_event_id` | Unique. Makes retries idempotent so an offline replay cannot double-post |

---

## Known limits of this build

These are deliberate, not oversights. See the design document for the full list.

- **No login.** Anyone with the URL can log events. Operator is a picker, not an identity.
  Phase 2 adds device registration and office accounts.
- **No supervisor role.** Force-finish is available to anyone on the manager tab.
- **Manager view is basic.** Dashboards are Phase 2 by design, once six weeks of real data exist.
- **No trial loop capture**, no bay location, no outsourced heat treatment gate in or out.
- **Route adherence is captured but not reported.** The data is in `suggested_stage_no`.
