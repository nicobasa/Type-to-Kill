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

That is the whole setup. It registers itself when PlayerGui populates.

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
