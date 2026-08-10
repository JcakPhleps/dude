# DMG installer artwork

The download is a `.dmg` that opens to a styled Finder window: **Dude.app** on the
left, a **shortcut to Applications** on the right, and a background image with an
arrow telling people to drag one onto the other.

**The background image is the entire design.** Make it here.

## Artboard spec

Design against a **640 × 400** window. The build script places the icons at fixed
spots, so line your art up with them:

```
  ┌─────────────────────────────────────────┐  640 wide
  │                (title up here?)          │
  │                                          │
  │     ┌───┐                     ┌───┐      │
  │     │ 🯅 │  ── drag me →  ──►  │ A │      │   icons are 128px,
  │     └───┘                     └───┘      │   centered at these
  │   Dude.app                 Applications  │   points ↓
  │      (160,185)                (480,185)  │
  │                                          │
  │            (instructions here?)          │
  └─────────────────────────────────────────┘  400 tall
```

- **Dude.app** icon center: **(160, 185)**
- **Applications** shortcut center: **(480, 185)**
- Icons render *on top* of the background, so keep those two ~128px squares fairly
  clear. Draw the arrow in the gap (roughly x 250→390 at y 185).
- Coordinates are from the **top-left** of the window (same as Figma).

## Export

Drop two PNGs in this folder:

- `background.png` — **640 × 400**
- `background@2x.png` — **1280 × 800** (Retina; `make-dmg.sh` fuses them into a
  crisp `.tiff`)

## Build it

```sh
brew install create-dmg          # once
# build a Release app first, then:
./scripts/make-dmg.sh            # → Dude.dmg in the repo root
```
