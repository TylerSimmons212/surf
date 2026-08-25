# The Amazon site lens

Search field, results grid, product page, cart sidebar. `AmazonLens` owns the
phase and the tab's address; `AmazonSelectors` holds every piece of site
knowledge and crosses the bridge as a call argument.

## Driving it

```bash
SURF_FOCUS=1 .claude/skills/verify-surf/scripts/launch.sh amazon \
  "https://www.amazon.com/dp/B088NRLMPV"
```

Real amazon.com — there is no fixture and there cannot be a useful one, because
what is being tested is whether Amazon's markup still says what the selectors
expect. A frozen copy would pass forever and prove nothing.

**You can fill a cart signed out.** This is the single most useful fact for
working on this lens, and the reason the cart's selectors were measured rather
than guessed. Islands are always signed out and it still works there.

## What proves it

One `[surf] amazon:` line per read, and it is deliberately dense — it is the
canary for every selector at once. A field that silently stopped matching shows
up as a `?` or a missing clause, not as a blank patch on screen.

```
amazon: Anker USB C… — 7 pictures, 6 highlights, 5+0 specs, 13 reviews,
max qty 99, $9.99 ($5.00 per count), variations [Size=7 Color=3 …], Choice,
10K+ bought in past month, sold by AnkerDirect/ships Amazon, FREE Returns,
delivery conditionallyFree Sunday, August 30 FREE, swatch prices $9.99/…
```

| Check | Oracle |
|---|---|
| the lens engaged | `focus: Amazon lens` |
| the product read | the line above, with no `?` in it |
| delivery attributes | `delivery conditionallyFree …` — `unknown` means the attributes did not arrive |
| add to cart | `amazon: cart is <n>`, observed from the page and never assumed |
| the cart read | `amazon: cart <n> lines, <n> units, subtotal $…` |
| a cart write | `amazon: <action> landed — <n> units` |

Clicks are by coordinate — the window is one opaque `AXGroup` like every other
here. Measured on a 1512×949 window, in screen points:

| Control | Where |
|---|---|
| Add to Cart | (987, 803) |
| cart badge | (1434, 66) |
| first row's Remove | (1328, 175) |

Screenshots come back at Retina scale. A 2000px-wide capture of a 1512pt window
is ~1.32×, and forgetting that once led to "fixing" column widths that were
already right.

## Things that are true and are not obvious

**Add to Cart navigates.** It goes to `/cart/smart-wagon`, a confirmation screen
with recommendations and none of the cart's rows. It is not the cart, and
`AmazonPage` names the readable cart paths rather than matching a `/cart/`
prefix, because accepting it meant opening the sidebar right after adding
something and being told the cart was empty.

**Amazon's minus button is a delete at the quantity floor.** Not a disabled
minus — a delete, whose `aria-label` reads "Delete Anker USB C to USB C
Cable…". Two guards: `AmazonCartItem.canDecrement`, and a selector that asks for
the label Amazon gives a real decrease control, which does not exist there to be
matched. If both ever fail the log says `DECREMENT REMOVED <id> — the floor
guard did not hold`.

**A removed row stays in the page.** Amazon empties the element and shows "… was
removed from Shopping Cart" inside it, keeping every attribute:
`data-itemtype="active"`, the old quantity, the old price.

It is recognised by that message node becoming visible — a *positive* marker,
and the correction matters. The first version inferred a ghost from what the row
was missing, which is also exactly what a row looks like before the page has
finished rendering. On a slower signed-in cart every line matched that
description, the whole cart was dropped, and the sidebar reported it empty to
somebody who had just filled it. When testing this, check both directions: the
marker must match a removed row **and not match a live one.**

**"The cart changed" is not evidence a write landed.** Amazon re-renders rows on
its own, so each action has to show its own effect — a removal is that line
being gone, an increment is that line going up. Getting this wrong reported
`remove landed` while nothing had moved.

**A page the lens has no screen for is the search field, not a failure.** The
front page, a department, an order list. Entering Focus reads whatever is
already open with no expectation in hand, and that used to come back as
`notReady` — "wait and read again" — so the ladder ran out and told somebody who
had touched nothing that Amazon had not finished loading.

**Signed-in Amazon is a heavier page.** The read ladder runs to nine seconds,
not the three that were enough signed out.

## Not yet proven

Anything signed in. Every measurement here is a signed-out session, so Prime
delivery (`delivery-benefit-program-id="prime"`) has never been seen — only
`cfs` — and a signed-in cart may carry rows this has never met: subscriptions,
gift options, unavailable items.

The full cart page. Only the sidebar exists.

Nothing about how any of it looks. `screencapture` needs Screen Recording, and
without it every check here is a log line.
