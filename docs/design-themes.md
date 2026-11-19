# Design note: themes, alternate accents and dark venues

Status: note only. Nothing here is implemented.

## The question

Some people dislike orange, and some venues are very dark. Should the app offer themes?

## Recommendation

**Don't add free themes. Offer, at most, a small set of approved accents, and treat stage clarity as a separate mode.**

- In Trillium, orange isn't decoration. It means "this is live" (`brand/BRAND.md` §4, §6). If any colour can be chosen, that meaning is lost and every screen has to be checked in every theme.
- One accent setting would keep the meaning while changing the hue. Candidates must meet the same contrast rules as Signal on Black (at least 4.5:1 for short text, 3:1 for shapes), and none of them may be a brand colour for something else:
  - **Signal** (default)
  - **Amber**: already a token, but it's used for levels and the last hit, so those would need another colour
  - a **cool accent** (for example the Connected green, or a new blue): needs a brand decision, since the kit has no blue
- The mark, app icon and wordmark stay Signal in every case. Only the in-app active state changes.

## Dark venues

These matter more than hue:

- **Stage mode:**
  - lower overall luminance (warm white at about 70%),
  - no large light areas,
  - the active state as a filled shape, not a thin line,
  - larger values (one size up),
  - no white flashes, and no animation except the live push.
- **Keep the screen dark first.** The black ground already keeps the screen from lighting the performer's face. Avoid graphite panels larger than they need to be.
- **Red-shifted option:** some performers want an amber or red-only display to keep night vision. That could be a variant of Stage mode with warm white replaced by Ash light.
- **Read at a distance:**
  - Note names and the active sector must be readable at 2 m on an iPad. They're the large monospaced labels in the instrument view.
  - Settings can stay small, since they're adjusted up close.
- **Tufte rules:**
  - Every mark should be data: the threshold circles, tilt zones and strike dots.
  - No gradients, shadows or 3-D in data views.
  - Use hairlines for structure and colour only for state.

## If we do it

- Add an `accent` token family to `brand/tokens/` (JSON, CSS, Swift) so the app never hard-codes the alternates.
- Have `Theme.swift` read the accent from one setting. Views keep using `Color.Trillium.signal` through a wrapper, so the change stays in one place.
- Add screenshots of each accent to the iPad screenshot job.
- Get brand sign-off before shipping any new colour.
