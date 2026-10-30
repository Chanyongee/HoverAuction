# HoverAuction

With the Auction House open, **hover a bag item and tap Space** to load it into the sell slot.
**Tap again while still hovering the same item** to post it. No mouse clicks needed.

- World of Warcraft Retail (Midnight, Interface `120105` / `120100`)
- When the cursor is not over a bag item, Space still **jumps** as usual
- The addon shuts itself off completely while you are in combat

## Install

Drop the `HoverAuction` folder into:

```
World of Warcraft/_retail_/Interface/AddOns/
```

Then `/reload` in game.

## Usage

| Situation | Pressing Space |
|---|---|
| Hovering a bag item | Loads it into the sell slot |
| Pressing again on the same item | Posts it |
| Moved onto a different item | Swaps that item in instead |
| Cursor not over an item | Jumps — the addon stays out of the way |
| Blizzard's post warning is up | Accepts it |

Posting is held back until the price lookup returns (1.5 seconds at most). That guard stops an
item from going up at the vendor-price-based default when you tap twice quickly; turn it off
with `/ha guard off`.

## Settings

```
/ha                  show current settings
/ha on | /ha off     enable or disable
/ha key SPACE        change the key (e.g. /ha key E)
/ha qty one | all    quantity mode
/ha guard off        drop the price-lookup guard
```

`/ha qty all` works by pressing Blizzard's own "Max" button for you, so it costs one extra press
(load → max → post). Items whose quantity box never appears skip that step entirely.

## Design note: avoiding taint

This addon never **writes** to the Auction House UI. It only reads from it.

When an addon — which runs insecurely — calls `AuctionHouseFrame:SetPostItem()` or `:Click()` on
the post button directly, the Auction House UI state becomes tainted. Right-clicking a bag item
afterwards makes
[`ContainerFrame.lua`](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua)
read that tainted state and then call the protected function `UseContainerItem()`, which the game
blocks:

```
[ADDON_ACTION_FORBIDDEN] 'HoverAuction' ... 'UseContainerItem()'
```

So instead of acting on the UI, HoverAuction only declares **what should be clicked**, through a
`SecureActionButtonTemplate` with `type="click"`. Blizzard's own code performs the click, in a
secure execution context:

- Bag button ← right-click delegate, so Blizzard calls `SetPostItem` itself
- Post button / "Max" button / warning-dialog accept button ← left-click delegate

Key binding is handled entirely by a secure handler snippet, because addon code cannot call the
binding APIs while in combat. That also means the snippet can drop the binding the moment combat
starts, handing the key straight back to jumping.

One detail worth knowing if you build on this: `SecureHandlerStateTemplate` runs a snippet only
when an attribute whose name starts with `state-` changes, and the snippet it runs is
`_onstate-<name>`. The general-purpose `_onattributechanged` hook belongs to
`SecureHandlerAttributeTemplate` and does nothing under this template.

## License

[MIT](LICENSE)
