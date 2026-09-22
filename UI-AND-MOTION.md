# UI and Motion

## The idea

**Studio owns the GUIs. Code owns which one is on screen.**

Rojo does not mount GUIs (see [ARCHITECTURE.md](ARCHITECTURE.md)), so there is no
registry to populate and no list to keep in sync with a tree you edit in another
program. Put a ScreenGui under `StarterGui.Screens` and it is a screen, addressed
by its name:

```lua
local UIController = require(script.Parent.UIController)

UIController.open("Shop")     -- closes whatever else was open. That IS the swap.
UIController.close("Shop")
UIController.toggle("Shop")
```

Same trade the Loader makes with its `Service`/`Controller` suffix, for the same
reason: the convention *is* the registration.

---

## Making a screen

```
StarterGui
└── Screens              (Folder -- create this once)
    ├── HUD              (ScreenGui)
    │   └── Root         (Frame -- one root GuiObject, the thing that moves)
    ├── Shop             (ScreenGui)
    │   └── Root
    └── Menus            (Folder -- organise freely, it does not affect the name)
        └── Inventory    (ScreenGui -- still just "Inventory")
            └── Root
```

That is the whole setup. It registers itself once the folder reaches PlayerGui.

### How it reaches PlayerGui, and why that is not automatic here

Normally the engine copies StarterGui into PlayerGui **when a character spawns**. This
game never spawns one on join — `ParticipantService` sets `Players.CharacterAutoLoads =
false` so a player lands in the main menu, not in the world. No character, no copy, no UI.

So `UIController.Init` clones `StarterGui.Screens` into PlayerGui itself. Two things make
that safe rather than a race:

- `StarterGui.ResetPlayerGuiOnSpawn` is **off**, and with it off the engine does not do
  the copy on a later spawn either — so there is never a second `Screens` folder. This was
  verified in a Studio session, not assumed: with a folder already present,
  `LoadCharacter()` left the count at one.
- Screens are addressed by name and register themselves, so even if a copy did arrive
  later, `register()` rebinds rather than breaking.

**If you ever turn `ResetPlayerGuiOnSpawn` back on**, the engine will wipe PlayerGui and
re-clone on every respawn — including over this clone. It recovers, but every screen also
reverts to its authored `Enabled` state on each death, which reads to a player as "the
menu closed itself". Leave it off.

### Properties, on the ScreenGui

| | | |
|---|---|---|
| `Enabled` | *property* | **The starting state.** Leave it ticked and the player spawns into it. Studio previews the spawn; there is no `OpenOnStart` to set and none to forget. |
| `Transition` | *attribute* | `Scale` (default), `Fade`, `SlideUp`, `SlideDown`, `SlideLeft`, `SlideRight`, `None`. Misspell it and you get a warn plus the default, not silence. |
| `Exclusive` | *attribute* | Default `true` — opening it closes the other exclusive screens. Set `false` for a HUD, a toast, or a dialog that should stack on top. |

Slides are named for the direction the screen **enters**: `SlideUp` comes up from
below. Every transition except `None` fades as well — a panel that slides without
fading reads as a jump cut.

### One root, and why

The handler animates the ScreenGui's **first GuiObject child**. A ScreenGui has no
position and no transparency of its own, so there has to be something inside to
move. Two top-level frames earns a warn, because only the first would animate and
the second would sit there perfectly still.

---

## Buttons

Opt-in. Tag a `GuiButton` **`UIButton`** and it grows on hover and dips on press.

The tag is an include list rather than a `NoMotion` exclude list on purpose: a
toggle that swaps its own image, a slider handle, or a card that already animates
will fight this. Opting in is one click in the Studio tag editor and it is visible
there; opting out of something automatic is neither.

| attribute | default | |
|---|---|---|
| `HoverScale` | `1.05` | Read live — retune it in the property panel mid-playtest. |
| `PressScale` | `0.94` | |

---

## Reacting to a screen opening

```lua
UIController.onOpen("Shop", function()
    refreshItems()
end)
```

Fires when the transition **starts**, not when it ends — you want the list
populated as it arrives, not a quarter second after the player is already looking
at it. `onClose` is the mirror.

Handy for an Escape key, since only one exclusive screen can be open:

```lua
local open = UIController.getOpen()
if open ~= nil then
    UIController.close(open)
end
```

---

## The files

| | |
|---|---|
| `Controllers/UIController.luau` | Which screen is open. Discovery, open/close/swap, the tag listener. The only one you call. |
| `UI/Transitions.luau` | What a transition *is*. Poses, not animations. |
| `UI/Motion.luau` | TweenService plus a cancel handle. |
| `UI/Buttons.luau` | The `UIButton` tag. |
| `UI/Scaling.luau` | The UIScale on each screen root. Transitions drive it; it does not read the viewport. |

### Poses, not animations

`Transitions` maps one number onto properties — `alpha 0` is fully shown, `alpha 1`
is fully hidden — and `UIController` tweens that number.

That inversion is the load-bearing choice. Reopening a half-closed menu is just
"tween alpha the other way from where it is": there is no in-flight animation to
reverse and no state that can disagree with the screen. The alternative — a
`show()` animation and a `hide()` animation that each own the property — is where
menus get stuck half-faded, because the two have to negotiate and they only ever
meet during a bug.

### Nobody writes `UIScale.Scale` except Scaling

`Scaling` owns that property; a transition asks for it through
`Scaling.setMultiplier` rather than assigning `.Scale` directly, so there is always
exactly one writer and never two disagreeing about the current value.

---

## Gotchas worth knowing up front

- **`StarterGui.ResetPlayerGuiOnSpawn` is on by default**, which wipes and re-clones
  the whole of PlayerGui on every respawn — so every screen reverts to its authored
  `Enabled` state when the player dies. Screens rebind themselves either way (they
  are addressed by name, not by a held instance), but "my menu closed itself when I
  died" is rarely what anyone wants. Turn it off.

- **A busy screen should have a `CanvasGroup` root.** A ScreenGui cannot fade, so
  `Fade` walks the tree and moves every transparency property proportionally — an
  element authored at 0.5 fades 0.5 → 1 rather than popping to opaque first. A
  CanvasGroup collapses that whole walk into one `GroupTransparency`, and it is the
  only way an element added *during* a transition fades with everything else.

- **Elements cloned in between transitions are handled**; ones cloned in *during*
  one are not. The snapshot is rebuilt per transition, so a shop row added while the
  screen sits open fades correctly on the next close. A row added in the 0.26s the
  transition is actually running will sit at full opacity until it finishes. Use a
  CanvasGroup root if that matters.

- **Screens register when PlayerGui populates**, which is after every `Init()` has
  run. `open()` before that warns and does nothing — but you should not need it,
  because the authored `Enabled` state already covers "open at start".

- **Names address screens, so they must be unique.** Two `Shop`s earns a warn and
  the newer wins.

- **A grid of fixed-shape cards** (Shop catalog, Inventory, the case preview) is a
  `UIGridLayout` with a `UIAspectRatioConstraint` parented to the *layout*, and a
  `CellSize` whose width is a scale and whose height is a **large offset**
  (`UDim2.new(0.235, 0, 0, 4000)`). The constraint shrinks each cell to fit the
  aspect inside `CellSize`, so a height of 0 collapses every card to nothing.
  Give the grid's ScrollingFrame a `UIPadding` of a few pixels on every side: a
  ScrollingFrame clips, so a card's `UIStroke` (drawn outside the card) and the
  hover scale are cut off at the edges without it.

- **Anything cloned into a list must be sized in offset, not scale.** A template's
  scale is relative to wherever it is authored; its clone lands in a different,
  usually smaller, list and comes out tiny. The same goes for a multi-row
  `UIGridLayout` cell height and a `UIListLayout` padding. An offset-to-scale
  conversion pass over a screen breaks exactly these and nothing else, which is
  why it looks fine in Studio and wrong at runtime. It happened once to
  `Screens.Admin` (2026-09-22).

- **An overlay inside a panel replaces the panel's content** (`UI/PanelOverlay.luau`),
  it does not sit on top of it. Drawn on top, the panel's padding left its edges
  showing and the buttons underneath still took clicks. `PanelOverlay.show(overlay)`
  hides the visible siblings and returns the function that restores them. The Shop's
  case preview and the Inventory's case reveal use it.

- **A screen used during a round needs `Modal = true` on one visible button.**
  First person locks the mouse to the centre, and switching the camera to Classic
  does not free it while the camera is still zoomed in. A visible `Modal` button is
  the engine's own way to free the cursor, only while that screen is enabled.
  `Screens.Admin` has it on its CloseButton.
