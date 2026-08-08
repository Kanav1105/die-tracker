# Die Tracker

Shop floor production tracking for press stamping dies. Three installable apps, one Supabase
backend, live across every device.

**Landing page:** https://kanav1105.github.io/die-tracker/
**Operator terminal:** https://kanav1105.github.io/die-tracker/floor.html
**Manager view:** https://kanav1105.github.io/die-tracker/manager.html
**Dashboard:** https://kanav1105.github.io/die-tracker/dashboard.html

The landing page is a plain chooser with three cards. It carries no manifest and belongs to none
of the three apps — that is required. Two PWAs cannot share a scope, or Android Chrome treats the
second as a page inside the first and refuses to install it. Each app below has its own manifest
and its own scope, so all three install side by side as genuinely separate apps.

---

## Files

| File | Purpose |
|---|---|
| `index.html` | Landing page. Three cards, no manifest, belongs to no app |
| `floor.html` | **Operator terminal.** This is what goes on the tablets |
| `manager.html` | **Manager view**, behind a password. Machines, dies, event log, setup |
| `dashboard.html` | **Analytics dashboard**, behind a separate password. Read-only, no data entry |
| `core.js` | Shared logic: config, database connection, domain rules. Edited once, used by all three |
| `manifest.json` | Install metadata for the operator app |
| `manager-manifest.json` | Install metadata for the manager app |
| `dashboard-manifest.json` | Install metadata for the dashboard app |
| `sw.js` | Service worker. Offline shell, caching, one file shared by all three apps |
| `logo.png` / `favicon.png` | Header logo and browser tab icon |
| `icon-*.png` | Home-screen icons — a distinct set per app so they never look alike |
| `labels.html` | Printable Code 128 labels for machines |
| `dashboard_views.sql` | Views and functions the dashboard reads. Run once in Supabase |

---

## Deploy

1. Copy every file above into the repo root of `Kanav1105/die-tracker`.
2. Commit and push to `main`.
3. Settings → Pages → Source: **Deploy from a branch**, branch `main`, folder `/ (root)`. Save.
4. Wait about a minute, then open the landing page.

---

## Before it will work

**1. Row-level security must be on.** In the Supabase SQL Editor:

```sql
select tablename, rowsecurity from pg_tables where schemaname='public';
```

All tables should show `true`. Without this, the publishable key in `core.js` grants full write
and delete access to anyone who has it.

**2. Realtime must be enabled**, or tablets will not see each other's scans live:

```sql
select tablename from pg_publication_tables where pubname='supabase_realtime';
```

`events` must appear.

**3. Run `dashboard_views.sql`** before opening the Dashboard app. Paste the whole file into the
SQL Editor and run it in one go — the functions near the bottom depend on the views above them.
Every statement is `create or replace`, so re-running it is always safe. Verify it worked:

```sql
select f_hold_summary(30);
```

If that errors with "function does not exist," the SQL did not fully complete — scroll up in the
editor output for the first error.

---

## The three access points

Each app is fully separated. `floor.html` has no manager or dashboard code in it and cannot reach
either. `manager.html` has no scanner. `dashboard.html` has no data-entry controls anywhere —
it only reads.

Put only the operator URL on the tablets. Give the manager and dashboard URLs out separately,
to the people who should have them.

### Operator keypad password

Typing a die code by hand bypasses the scanner, so it is gated. The supervisor gives the code out
when a label is damaged. Set at the top of `floor.html`:

```js
const KEYPAD_PASSWORD  = "2580";   // CHANGE THIS
const KEYPAD_GRACE_MIN = 3;        // minutes before it asks again
```

Use only characters that exist on the pad: digits and U, L, P. After a correct entry the keypad
stays open for the grace period so one mistyped code does not mean re-entering the password twice.

Machines are chosen by tapping a tile, never scanned, so this keypad is only ever needed for dies.

### Manager password

Set at the top of `manager.html`:

```js
const MANAGER_PASSWORD = "toolroom2026";   // CHANGE THIS
const SESSION_HOURS = 12;                  // re-ask after this long
```

### Dashboard password

Separate password, separate session, at the top of `dashboard.html`:

```js
const DASH_PASSWORD  = "boardroom2026";   // CHANGE THIS
const SESSION_HOURS  = 24;
```

### What these passwords are and are not

All three are a convenience gate, not security. Each sits in JavaScript that anyone can read with
View Source. They stop casual wandering between apps and keep the keypad from becoming the default
way to log dies. They will not stop anyone determined, and making the GitHub repository private
does not change this — GitHub Pages serves the deployed files publicly either way, private repo or
not. Real protection means Supabase Auth with actual accounts, which is future work.

Your data is protected by the row-level security policies on the database, not by any of these
three pages. That is why the RLS checks above matter more than any password does.

---

## Install

All three apps install independently, with different names and different icons, so they are never
confused on a device.

**Operator terminal** — on each tablet:
1. Open `floor.html` in Chrome.
2. Menu → **Add to Home Screen** → Install.
3. Launch from the icon. There should be no address bar.
Icon: dark ground, yellow die block. Name: *Die Tracker*.

**Manager** — on the manager's laptop or phone:
1. Open `manager.html` in Chrome or Edge.
2. Click the **INSTALL** chip in the header, or use the install icon in the address bar, or menu →
   Install app.
3. On iPhone or iPad: Safari → Share → Add to Home Screen. Safari does not show the chip.
Icon: pale paper ground, dark bar chart. Name: *DT Manager*.

**Dashboard** — same as manager, from `dashboard.html`.
Icon: navy ground, gold ascending line in a ring. Name: *DT Dashboard*.

If a tablet already has an old install from before the three-app split, uninstall it first, then
clear site data for the domain (Chrome → Settings → Site settings → All sites → your domain →
Delete data), before installing the new version. Chrome caches manifests and remembers installed
scopes, and the old state will otherwise persist.

---

## Machine rules

Set once, at the top of `core.js`:

```js
const NA_MACHINE = "100";                       // auto-assigned, never chosen
const NO_MACHINE_STAGES = [1,3,5,8];             // Raw Casting, Fitting, Heat Treatment, Assembly
const MULTI_DIE_MACHINES = ["100","114"];        // NA and OS can each hold several dies at once
```

Stages in `NO_MACHINE_STAGES` skip the machine step entirely — the operator picks the operation and
the app assigns machine 100 (NA) automatically. Every other real machine holds exactly one die at a
time; NA and OS are the two exceptions, since several dies can genuinely be at Assembly or at a
vendor simultaneously. If you add a machine that should behave the same way, add its code to
`MULTI_DIE_MACHINES`.

`IDEAL_MACHINES` in the same block lists which machines are expected for each operation. Off-list
choices are allowed but show a warning on the confirm screen before the operator can start.

---

## Updating the app

Edit, commit, push. Then **bump the cache version in `sw.js`**:

```js
const CACHE = "die-tracker-v16";   // increment on every deploy, no exceptions
```

Skip this and every device, tablets, manager, dashboard, keeps serving the old build from cache.
This is the single most common cause of "I deployed but nothing changed." If you hit it on a
device you're testing on, the fast fix is: F12 → Application → Service Workers → Unregister, then
Application → Storage → Clear site data, then hard refresh.

---

## Adding dies and machines

Both live in the database, not in the code, so no deploy is needed for new entries.

Supabase → Table Editor → `dies` or `machines` → Insert row.

Machine codes are freeform text but the app expects the ones referenced in `core.js`
(`NA_MACHINE`, `MULTI_DIE_MACHINES`, `IDEAL_MACHINES`) to exist. Adding a new real machine needs no
code change at all — it will simply not be "ideal" for anything until you add it to that list.

---

## Data model

`events` is append-only. Nothing is ever edited or deleted; a correction is a new row that
references the original. Machine status and die stage are **derived** by replaying events, never
stored, so no status column can drift out of step with what actually happened. This is also what
the dashboard views build on — they sessionise the same event stream rather than reading any
separate "current state" table.

| Column | Note |
|---|---|
| `ts` | Server time. Authoritative |
| `device_ts` | Device clock, kept for audit of offline scans |
| `type` | START, END, PAUSE, RESUME, CORRECTION |
| `stage_no` | What the operator chose |
| `suggested_stage_no` | What the system expected. Compare the two to measure route adherence |
| `client_event_id` | Unique. Makes retries idempotent so an offline replay cannot double-post |

---

## Dashboard notes

The dashboard reads pre-aggregated SQL functions (`f_hold_summary`, `f_machine_occupancy`,
`f_die_leadtime`, `f_queue_by_stage`), not the raw event table, so the browser never has to
replay thousands of events to draw a chart.

**Touch % includes NA.** Time spent at Assembly, Fitting, Heat Treatment, or Raw Casting counts as
touch time, since it is real work happening without a dedicated machine. Time at an outside vendor
(OS) also sits inside a session, so it is broken out separately as "outsourced days" and an
"at vendor" column — subtract it from touch time if you want a figure that excludes vendor time.

**The 7 / 30 / 90 / 365 day buttons genuinely filter.** They call the SQL functions with a `days`
argument rather than re-slicing data already loaded in the browser, so each range reflects only
activity within that window. The KPI cards at the top are the exception by design — they always
describe the current moment, not the selected range.

**All seven views plus four functions were tested against a local Postgres 16 instance** (matching
Supabase's engine) with synthetic data covering a clean multi-stage route, a customer hold, a
press-busy hold, back-to-back holds, two dies parked at NA simultaneously, a die out at an
outsource vendor, and a die still on an open hold. Every number was checked by hand against the
known inputs before being handed over. See the comment block at the end of `dashboard_views.sql`
for details.

---

## Known limits of this build

These are deliberate scope decisions, not oversights.

- **No real login.** All three passwords are static and readable in the source. Anyone with a URL
  and its password has full access to that app's functions.
- **No supervisor role distinct from manager.** Force-finish and corrections are available to
  anyone who has the manager password.
- **No trial loop capture**, no bay location, no outsourced heat treatment gate in/out beyond the
  OS machine code.
- **Route adherence is captured but not yet reported.** The data is in `suggested_stage_no` versus
  `stage_no` on every event; nothing currently summarises the gap between them.
