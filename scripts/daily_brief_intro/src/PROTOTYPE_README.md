# Daily Briefs · intro modal

A clickable build of the "Introducing Dayflow Daily Briefs" modal over the Timeline view (Figma › Daily: 563:10268, 563:28112, 563:28687 + 563:31262, 563:32024). It has four steps. The two "Get caught up" frames are one step, and their two visuals take turns. The illustration on the right of each step is animated: it plays an entrance when the step opens, then keeps looping.

| Step | Right-side animation |
| --- | --- |
| 1 · Introducing Dayflow Daily Briefs | Timeline cards drop in (one Figma, one GitHub, one Slack). The app icons (GitHub, Gmail, Slack, Notion and Figma) pop up, and each is wired to both Claude and ChatGPT. Lines draw in, points of light travel from the apps to the LLMs and from the LLMs into the ring, and the thin ring at the centre pulses. |
| 2 · Your day, sorted into tasks | Clawd (orange) walks under the stack, the front card swipes onto its raised hands, and it carries the card off to the left. The Codex pet (blue) walks in from the right, catches the next card and carries it off to the right. Each card takes 0.5 s to fly to a pet, and each pet is out of sight for 2 s before walking back in from its own side. Then the loop repeats. The pets use their real animations: Clawd's traced walk, sway and hands-up frames (`../clawd-vectors`, `../pet-poses`) and the Codex sprite sheet (`../codex-pet`), drawn the way `../mac-handoff.js` draws them. |
| 3 · Get caught up in no time | The update cards come in (blur-up, avatars, channel pill). Once everything has landed, each set stays fully on screen for 2 s. Then the update cards lift away and the two source cards are dealt in. Next the source cards slide off, fanning apart, and the updates load back in. |
| 4 · Envelope | A paper envelope (folds, grain, soft shadow) drops in and floats over a slowly drifting, colour-shifting background. Clicking **See my first brief** pops the seal, folds back the flap and slides the brief up. Then the modal goes, the window grows to 757 tall and the first brief appears (Figma 563:32642, "Give to agent · Card view"). |

**To open it:** unzip the folder and double-click `index.html`. It runs straight from the folder in Chrome or Safari, with no server needed.

Or run it from `DailyPrototypes` with the `daily-prototype` launch config (`python3 -m http.server 4319`) and open http://localhost:4319/daily-briefs-intro/

- **Next** or → moves forward and ← moves back. The bar above the window jumps to any step or restarts the flow. `?step=1`…`?step=4` opens a step directly.
- The 1192 × 680 frame is scaled to fit the window.
- Motion is turned off under `prefers-reduced-motion`.

Notes:
- The left copy and the Next button share one x position (32px). In Figma it varies between 30 and 37px from step to step, which would make the copy jump during the crossfade.
- Not in Figma: the extra task titles in step 2, the brief "letter" in step 4, two step-1 timeline cards (GitHub and Slack), the Clawd and Codex pet animations in step 2 (Figma has still images), the envelope's paper styling, the 44px Next button and the modal's 8px corners, the GitHub/Gmail/Notion/Figma connector logos and the network lines between apps and LLMs. The step-1 centre is a thin pulsing ring drawn in CSS in place of Figma's spinner. The Codex pet rests fully inside the panel (Figma has it half off the right edge).
- All assets were downloaded from Figma into `assets/`. The page doesn't use any of the docket prototype's code.
- The Codex pet art is OpenAI's (see `../codex-pet/README.md`): fine for prototyping here, not for anything that ships.
