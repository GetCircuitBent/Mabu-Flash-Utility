# Branded Edition — spec (for review, not yet built)

Goal: a **branded** variant of the flash utility that, as part of flashing a
Mabu (RK3288 H7R), writes the **GCB boot screen** (static power-on logo) *and*
the **GCB loading animation** so a freshly-flashed unit boots fully branded with
no extra manual steps. **No root required** — both are Loader-side writes on a
liberated unit (dm-verity off), the mechanism we already use.

Status: DESIGN. Nothing here is built or hardware-tested.

**SCOPE DECISION (locked 2026-07-07):** brand the loading animation **and** the
static boot screen entirely inside one `bootanimation.zip`, deployed via the
proven Loader `/system` write. The pre-Android **u-boot power-on splash is OUT OF
SCOPE** (would need a `resource` dump + repack tooling we don't have; deferred as
an optional future spike). So this build touches **only `/system`** — no
`resource` partition, no root, no new device dump.

## Source of truth — the style guide (read-only)
`D:\Claude Projects\GitHub-Style-Guide\assets\` (per Motion.md, which explicitly
says device-specific exports "live with the device project that consumes them,
generated from this same composition" — i.e. here):
- `boot-animation.gif` — 700×438 landscape, looping (wordmark + cat + brand
  sparkles on Bluewood `#1A242D`). → the **loading animation**.
- `boot-logo.png` — 700×438, static logo, no sparkles. → the **boot screen**.

The style guide stays the upstream reference; we never edit it. The branded
tooling *generates* device exports from these and commits the exports into
Mabu-Flash-Guide (per repo-scope rule).

## Device facts (confirmed from the existing dump — unit ...476 `system-clean.tar`)
- **Panel / framebuffer: `1024×600`, animation `30 fps`** (stock `desc.txt`:
  `1024 600 30`).
- Stock `bootanimation.zip`: single infinite-loop part (`p 0 0 mabu_v2_boot`),
  frames are PNGs, archive is **Stored (no deflate)** — Android requires stored.
  Stock size **1,870,133 B**, sha `a2c144b1…`.
- Style-guide GIF is 700×438 → scale to 1024×600 (pad on Bluewood `#1A242D`;
  aspect 1.71 vs 1.60, so minor letterbox). No rotation — stock frames are authored
  at 1024×600 upright.

## Two on-device targets
| Asset | Lands at | Mechanism | Confidence |
|---|---|---|---|
| Loading animation | `/system/media/bootanimation.zip` | Loader `/system` sector write (verity off) + i_size patch | HIGH — proven path + fully sourced (1024×600@30) |
| Boot screen (RECOMMENDED) | static leading **part** inside the same `bootanimation.zip` | same `/system` write — no extra target | HIGH — zero resource-partition risk |
| Boot screen (true power-on splash) | **`resource` partition** (`0x8000`, 16 MB) — RK `resource.img` = DTB + `logo.bmp` | dump → unpack → swap logo.bmp → repack → write | LOW/UNPROVEN + **not sourceable from any existing dump** |

**Key finding:** there is **no `resource`/`logo` image in any Mabu-repo dump or
git branch** (checked `firmware/`, all dump dirs, `system-clean.tar`, and full
git history). So the *true* u-boot power-on logo can't be verified or sourced
without a fresh `resource` dump. **Recommended path avoids it entirely:** render
`boot-logo.png` as a held static "part 0" (e.g. `p 1 30 logo`) followed by the
sparkle loop (`p 0 0 sparkle`) in one `bootanimation.zip`. Branded static screen →
animation, all within the proven `/system` write. The only thing this does NOT
brand is the ~1–2s u-boot splash before Android starts the animation — that alone
needs the `resource` partition (a separate, optional, higher-risk phase).

## Build-time asset pipeline (host, run when the brand assets change)
Produces committed, hash-pinned device exports; the flash flow only *writes* them.

1. **GIF → `bootanimation.zip`**: extract GIF frames → scale + **rotate to the
   panel's framebuffer orientation** → `desc.txt` (`<w> <h> <fps>` + `p 0 0 part0`
   loop) → zip **stored (no deflate)** (Android requires stored). Reuse/port
   `make_bootanim.py` (referenced by DEPLOY.md; confirm it's present and what
   resolution/rotation it targets — that did not surface in this worktree).
2. **PNG → `logo.bmp`**: scale + rotate to panel res → convert to the BMP format
   RK's resource loader expects (bit depth / bottom-up row order — TBD from a real
   resource.img). Then repack into `resource.img`.
3. Record SHA-256 of every export; store under `assets/branding/`.

**Blocker for both: the panel's real resolution + orientation.** The style-guide
reference is 700×438 landscape; the H7R panel/framebuffer size and rotation are
not yet pinned here. Derive from the device (existing `bootanimation.zip`
`desc.txt`, and the stock `logo.bmp` dimensions once dumped) before exporting.

## Deploy flow — the `-Branded` switch
Add `-Branded` to `flash-mabu.ps1` (a switch, not a separate script — reuses all
the Loader/WinUSB/adb plumbing). Runs as a new **Phase 9 "Branding"**, after
liberation + provisioning + SELinux, and only when liberation is confirmed
(verity disabled). Sequencing note: like SELinux, it needs its own Loader
re-catch; keep it a distinct phase so a hiccup here never risks the earlier work.

Per deploy:
1. **Preconditions**: `ro.boot.veritymode=disabled`; Loader reachable; WinUSB
   bound (reuse `Confirm-LoaderWinUsb`).
2. **Loading animation** (reuse DEPLOY.md logic, automated):
   - Live-derive `/system` start LBA: `cat /sys/class/block/mmcblk1p11/start`
     (per-unit — never hardcode; staged `0x18C000` was unit ...476).
   - `find_system_file.py` → locate `media/bootanimation.zip` extents + inode.
   - **Back up** the original extents (read them out) before any write.
   - If inode `metadata_csum` is ON → i_size hand-edit is unsafe → **fall back to
     full-image reflash path**, don't hand-patch. (Documented fork.)
   - Else patch inode `i_size` to the new size, write only the needed content
     blocks, read-verify.
3. **Boot screen** (new, gated on the R&D below):
   - **Back up** the whole `resource` partition first (`rl 0x8000 0x8000 …`).
   - Unpack `resource.img`, replace `logo.bmp` (keep original DTB), repack,
     write partition, read-verify.
4. `rd`; visually confirm the static GCB logo, then the sparkle animation.

## Safety / recovery (must-haves)
- **Back up before every write**: original bootanimation extents + full original
  `resource` partition, saved to `assets/branding/scratch/` with hashes. Recovery
  is a straight `wl` of the backup.
- Nothing destructive until the locate/verify steps pass (same discipline as the
  SELinux Tier-2 and DEPLOY.md flows).
- The animation half is reversible per DEPLOY.md. The resource/logo half: keep the
  untouched original `resource` dump as the one-shot restore.

## Open decisions / R&D
Resolved from the existing dump:
- ✅ **Panel resolution / fps**: 1024×600 @ 30, upright, stored zip (see Device facts).

Still open for the RECOMMENDED (no-resource) path:
- **`make_bootanim.py`**: locate/port it (referenced by DEPLOY.md; didn't surface
  in this worktree) and confirm it targets 1024×600 stored. Otherwise write the
  GIF→zip builder fresh (extract frames → scale/pad to 1024×600 → held logo part0
  + sparkle loop part1 → stored zip).
- **`metadata_csum` status** on the fleet's `/system` inodes (decides whether the
  animation write is same-size-simple or needs the full-reflash fork per unit) —
  `find_system_file.py` reports this.

Only if we ALSO want the true u-boot power-on splash (optional, higher risk):
- **A `resource` partition dump does not exist in any repo/dump** — would need one
  fresh from a unit (contradicts "no new dump"), then confirm the logo is a
  `logo.bmp` in `resource.img` and source the RK repack tool (`resource_tool` /
  `rkImageMaker`) — not present today. Recommend deferring this unless the pre-
  Android splash is a hard requirement.

## Proposed build order
1. **Boot-logo-as-static-part**: build the combined `bootanimation.zip` (static
   `boot-logo.png` hold → sparkle loop, 1024×600 stored) from the style-guide
   assets. Pure host-side, no hardware.
2. Automate the `/system` deploy into a `-Branded` Phase 9 (reuse DEPLOY.md +
   `find_system_file.py`; per-unit LBA; metadata_csum fork).
3. Validate end-to-end on a unit (verity off), visually confirm.
4. (Optional, later) true u-boot splash via `resource` — its own R&D spike first.
5. Document + (optionally) port worktree→main.

## Scope
All new code/assets live in **Mabu-Flash-Guide** (this worktree). The style-guide
repo is read-only upstream. `-Branded` is opt-in; the default flash is unchanged.
