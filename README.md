# allrecipes

Every era synthesis and desynthesis recipe on PhoenixXI, by craft, for Ashita v4.

- Pick a recipe to see its materials and results, with your odds at your craft levels:
  - success;
  - HQ, with the next HQ bracket and the level it starts at;
  - skill-up chance, and how many synths it takes on average to reach your next level and the level where the recipe stops giving skill-ups.
- Names are coloured by how hard the recipe is for you.
- Skill-up mode lists only the recipes that can raise the craft.
- Type in AH prices to see the profit a try, selling on the AH or to an NPC. The profit is broken down into NQ, each HQ and a break. A price typed once is used by every recipe and every character.
- Ctrl+click any item to open its page on ffxiah.com, and from there whichever wiki you like.
- Your craft levels show to the tenth (22.4), worked out from your skill-up messages.
- The crystals in your inventory are counted at the top of the window.
- The **Fish** tab is a fishing atlas: every fish with the level to start it and the level it caps at, your skill-up chance, the bait it takes, where it bites, and how many fish you've caught today. See [Fishing atlas](#fishing-atlas).
- The **Harvest**, **Excavate**, **Log** and **Mine** tabs cover HELM: every zone's drops and how often you get each, how often the tool breaks with and without Field or Worker gear, and its gathering points on the game's own map of the zone. See [HELM](#helm).

Nothing is ever sent to the server and nothing is asked of it: allrecipes only reads client memory, the game's files and the packets the game receives anyway. (To sort HELM points onto a zone's floors it also asks the game which floor a spot is on, which happens inside your client.) Phoenix only allows tools on its [approved addon list](https://phoenix-xi.com/approved-addons), so check it's there before using it on the server.

## Installation
- Copy the `allrecipes` folder into your Ashita v4 `addons` directory. From a release zip, extract it into the Ashita folder itself (the one with `addons` and `config` in it, `Game` on HorizonXI), not into `config`.
- Type `/addon load allrecipes` in game, then `/ar` to open the window.

## Usage
| Command | |
|---|---|
| `/allrecipes` or `/ar` | show or hide the window, or bring it back from its icon |
| `/ar <craft>` | open it on a craft: `wood`, `smith`, `gold`, `cloth`, `leather`, `bone`, `alchemy`, `cook` |
| `/ar fish` | open the fishing atlas |
| `/ar harvest`, `excavate`, `log`, `mine` | open a HELM tab |
| `/ar min` | minimize it to an icon at the bottom right |
| `/ar prices export [file]` | save your prices as JSON (`prices.json` in `config/addons/allrecipes`) |
| `/ar prices import <file>` | add prices from JSON |
| `/ar reset` | move the window back to where it starts |
| `/ar debug` | your craft levels (with their tenths), ranks and image support as the addon reads them |

**In the window** (it looks like scouter's):
- **Minimize:** the `–` where the close button would be shrinks the window to a small crystal icon at the bottom right of the screen. The icon is as tall as the points addon's compact bar, twice as wide, and scales with your menu resolution the same way. Click it to bring the window back; `/ar` hides the window altogether. It stays minimized when you reload.
- **The icon row:** the minimized windows of deeps, droptables and scouter (its map and compass) sit in the same row. The addons tell each other which icons are showing through Ashita's plugin events, which stay inside your game. When one icon goes, the other slides over.
- **Craft chips** show your level in each craft, to the tenth once it's known. The one you're on is shown big, with its tenths beside it, your rank and how far you are toward its cap. See [Your skill to the tenth](#your-skill-to-the-tenth).
- **Crystals:** at the top right, the eight crystals with how many of each are in your inventory, in the game's own icons. The one the recipe shown needs is outlined, its count in red if you have none. Hover one to see its clusters and HQ crystals (Inferno Crystal and the like) too. In a narrow window they go in two rows, or under your level.
- **Toolbar:** switch between synthesis and desynthesis, all recipes or skill-ups, and selling on the AH or to an NPC. **can make** hides recipes you can't make now: too low in any craft they use (sub-crafts included) to start them, sure to break, or missing their key item.
- **Settings chip:** opens a settings window where you can:
  - pick the theme: clean (scouter's), guild (warm leather and gold), Vana'diel (the game's blue menus) or Phoenix (Phoenix's red and gold, like facelift's);
  - hide expansions;
  - hide recipes where the craft is only a sub-craft, or recipes that need a key item;
  - add a skill bonus for gear or moghancements;
  - export your prices.
- **Sorting:** click a column head to sort by it; click again to reverse.
- **Tooltips:** hover over a profit in the list to see how it adds up.

Image support counts toward your odds. Under your level there's a **support** selector for the craft you're on: **auto** counts what's on you (it starts at +1, and if it's still up after 2 minutes it must be advanced support or a guild belt, so it turns +3 by itself; click auto again to switch), or pick **none**, **+1** or **+3** to see the odds as if you had it. The choice is kept for each craft. Advanced support's lower break loss isn't counted.

## Fishing atlas
The **Fish** chip after the crafts opens it. Your fishing level is shown to the tenth, the same way the crafts are.

Each fish has three levels. They come from Phoenix's skill-up code (`FishingSkillup` in `src/map/utils/fishingutils.cpp`):
- **Cap**: the fish's own skill level. It gives skill-ups only while you're under it, so reaching it ends them. A fish over 100 gives them all the way to fishing's cap.
- **Start**: 20 levels under the cap. A fish more than 7 levels over you can get away for lack of skill, 0.8% more for each level past 7. From 20 under, fewer than 1 in 10 get away that way, and the skill-up chance is above its floor. Any fish up to 50 levels over you gives some skill-ups.
- **Best**: 11 under the cap, where the skill-up chance peaks.

Pick a fish to see:
- your skill-up chance on each catch, and how many catches it takes on average to reach your next level and the fish's cap;
- the rods that hold it, plainest first, and what goes wrong with the ones that don't: the line snaps, the rod breaks, or the fish is too big or too small for the rod and gets away. These follow Phoenix's own fishing rules, from the fishing patch in its repo. They use each fish's strength, each rod's ranks (with Phoenix's own changes to them) and your fishing skill with gear. A large-fish rod lets a small fish go often, more so the higher the fish's level, and a rod of the wrong size gets fewer bites either way;
- the bait and lures it takes, and how well (best, good or bites);
- **yours** beside any rod or bait in your inventory.

Hover a fish in the list to see the least rod it needs and its best bait.
- every zone and spot where it bites;
- whether it's a large fish, needs a key item, or is legendary.

The chance shown is for fishing outside a town; in a town skill-ups are rarer. On Phoenix the moon doesn't change them. Under level 50, a Lu Shang's Fishing Rod makes them rarer.

**Gear:** the chips under the toolbar pick the gear the numbers assume: no gear, the best of the era (+5 fishing skill: a Fisherman's or Angler's tunica, gloves and hose at +1 each, and Waders at +2) or what you have on. Gear's fishing skill helps you land fish (fewer get away, and lines snap and rods break less), but skill-ups go by your own level. The **Pelican Ring** chip counts the ring's effect, up to two at once: each gives a catch one more skill-up roll, which raises the skill-up chance and lowers the catches to your next level. Items such as logs and buckets never give skill-ups; the **items** chip hides them.

**Caught today**, at the top right, counts your own "caught" lines. The count starts over at midnight in Japan (15:00 UTC), when the game's daily limits reset, and the list's **Today** column shows how many of each fish you've caught. Fish you couldn't carry and monsters don't count. Catches made while the addon isn't loaded can't be counted. The count is kept for each character.

The fish come from Phoenix's fishing tables. To update them:

    python tools/gen_fish.py --phoenix C:\code\Phoenix

## HELM
One tab each for harvesting, excavation, logging and mining. The zones come from Phoenix's HELM table, which has measured rates and retail-captured point positions (`scripts/globals/hobbies/helm`). Drops that Phoenix's era module takes out (added in WotG or later) are left out here too.

The list shows each zone's chance a try of finding something, of breaking the tool, and how many spots its points move between. Type an item in the search box to list only the zones that give it, with its chance a try.

Pick a zone to see:
- **The odds:** how often a try finds something and how often the tool breaks. The table under them shows the break chance, tries a tool and finds a tool with no gear, the Field set, the Worker set and what you have on. Gear only changes how often the tool breaks: each Field piece (NQ) makes it break x0.893 as often and each Worker piece (HQ) x0.843. Three pieces of each set help each of harvesting, logging and mining, and nothing helps excavation. The chips above the list pick which gear the list and the drop table assume.
- **What it gives:** each drop's chance a try, and how many you get on average from one tool with no gear and with the gear picked. With prices typed in or AH history, it also works out what a try and a tool are worth. Drops with a daily cap or that run out until you zone are marked, and the coloured rock is the day's.
- **Where the points are:** the game's own map of the zone, read from your game files, with the spots the points move between. A point stands at one spot at a time and moves after some finds. When you're in the zone, a gold dot shows where you are. In a zone with several floors, the game can only say which floor a spot is on while you're in that zone; once you've been there, the spots sort onto their floors and stay sorted (kept in `config/addons/allrecipes/floors.lua`). Until then they show hollow on every floor.

The data comes from Phoenix and the game:

    python tools/gen_helm.py --phoenix C:\code\Phoenix
    python tools/gen_maps.py --dump C:\Games\PhoenixXI\FFXiMain_04490000.bin

## Your skill to the tenth
The server keeps craft skill in tenths but only tells your client whole levels. Every skill-up does come with a message, though: "skill rises 0.3 points", and "reaches level 23" when that crosses a level. allrecipes reads those (only reads; they're the packets the game receives anyway) and keeps your skill as a range that each skill-up narrows:
- `.?` beside your level: nothing seen yet, so it could be anything from .0 to .9;
- `.3-.9`: narrowed by a skill-up or two;
- `.3`, in the accent colour: exact. That happens when a 0.1 skill-up crosses a level, or when you're capped (the server stops a skill-up at the cap).

Hover the tenths to see what they are. A skill that drops (specialization) goes down with it. If your level changes without a message being seen (a skill-up while the addon wasn't loaded), it starts over from the new level. The ranges are kept for each character in its settings.

## Which recipes
The recipes come from Phoenix's own recipe table, through `data/recipes.lua`.
- Recipes from Abyssea and later aren't included.
- RoZ, CoP, ToAU and WotG recipes are marked, and each expansion can be hidden. WotG is hidden to start, because Phoenix is set before it.
- Rows the server can never use are left out.

To update the data from a newer Phoenix checkout:

    python tools/gen_recipes.py --phoenix C:\code\Phoenix

## How the odds work
This is how the Phoenix server works them out (`src/map/utils/synthutils.cpp`).

**Difficulty** is the recipe level minus your level (plus image support and gear), for each craft the recipe uses. You can't start a recipe more than 15 levels over you.

**Synthesis:**
- **Success:** difficulty 0 or less gives 95%; 1-3 gives 95% less 5% a level; 4 and up gives 80% less 10% a level from 3. Each craft is rolled on its own, so the chances multiply.
- **HQ:** only when you're at or over the recipe in every craft. The chance depends on how far over you are in the craft you're least over:

| Levels over | HQ (of successes) | HQ1 / HQ2 / HQ3 |
|---|---|---|
| 0-10 | 1/64 | all HQ1 |
| 11-30 | 1/16 | 3/4, 1/4, 0 |
| 31-50 | 1/4 | 3/4, 3/16, 1/16 |
| 51+ | 1/2 | 3/4, 3/16, 1/16 |

HQ is capped at 80%.

**Desynthesis:**
- **Success:** 40% at difficulty 1 or less, 5% less a level to 10% at 7, then down to nothing at 10.
- **HQ:** 60% of successes. A success comes out NQ, HQ1, HQ2 or HQ3 at 40/30/20/10%.

**Breaks:** the crystal is always used up. Each material is lost half the time; a few are lost always, or never.

**Skill-ups** (era rules):
- Only from recipes above your level, and not once you're at your rank's cap.
- 60% a success under level 50, 25% from 50, and 5% for desynthesis.
- A break gives half that (desynthesis all of it), and only when the recipe is 1-5 levels above you.
- A skill-up is 0.1 to 0.5, bigger the further the recipe is above you; always 0.1 from skill 60.0.
- **Synths on average** to your next level and to where the recipe stops (its level, or your rank's cap if that comes first) are worked out from these at every tenth on the way, so the rising success rate and shrinking skill-ups are counted. When your tenths aren't known exactly, it's averaged over the range they could be in. Hover it to see which.

**Profit a try** is what the results sell for, weighted by their chances, less what you use up on average: the crystal, and the materials in full on a success or at their loss rate on a break.

**Crafting myth:** each recipe also shows the old advice of which way to face and which day to synth on, from its crystal (N dark, NE light, E ice, SE wind, S earth, SW lightning, W water, NW fire, on the crystal's own day). Square Enix said neither matters, and Phoenix's synthesis code doesn't look at them; it's there for luck.

The addon can't see crafting rings, foods that raise success, or advanced image support's lower break rate, so those aren't counted.

## AH price history
Look at an item's price history at the auction house and allrecipes keeps it. Any price you haven't typed in then comes from it, shown faintly with a `~`.
- **What it keeps:** the newest ten sales of each item from the last 180 days, singles and stacks separately.
- **Singles or stacks:** the history itself doesn't say which it is. The category list you browsed to get there does: it gives how many singles and stacks are on sale. An item that doesn't stack on Phoenix (ores, logs and more) is always singles. A history that can't be told apart is still used: by which of the item's other histories its prices are nearer, or else by what an NPC pays for it. Its tooltip line says "likely singles (unsure)" or "likely stacks (unsure)".
- **Price used:** the middle sale. A stack's price is divided by the stack size, and a price from stacks is marked `stk` in the box.
- **Singles or stacks, when an item has both:** the settings say which to use (singles to start). Right-click a price box to switch that one item; the choice is remembered.
- **Hover a price box** to see the sales behind it.
- **Your own price** always wins; empty the box to use the AH's again.

It never asks the server for anything. The history comes from the game's search server over its own connection, where no packet event can see it. So allrecipes reads it from the game's memory after the game has received it for you. When you open the auction house, it looks through memory in the background for the layout of a history or a category list (known from `src/search/packets/`) until it finds where the game keeps them. Browsing any category is usually enough. After that it watches those spots, and looks again every 10 seconds while you're there, since the game sometimes moves where it keeps the next one. Looking takes at most half a millisecond a frame, so it doesn't cost frame rate. All of this is through `ReadProcessMemory`, so memory the game frees can't crash it.

| Command | |
|---|---|
| `/ar ah` | whether it's on, how many items it has, and the last one kept |
| `/ar ah on\|off` | keep the history or not (also in the settings) |
| `/ar ah scan` | look for it now, with a price history open at the auction house |

The history is kept in `config/addons/allrecipes/ahhistory.lua` for all your characters.

## Prices
Prices are for one of an item, in gil, and are kept in `config/addons/allrecipes/prices.lua` for all your characters.

JSON for import can be either:
- an object: `{"4098": 90, "710": 1100}`;
- an array: `[{"id": 4098, "price": 90}]`. `itemId` or `item_id` work in place of `id`, and `value` in place of `price`.

NPC prices are what a shop pays before fame, from Phoenix's item table (BaseSell) with its own module's changes (the pre-RMT reverts) applied. Stack sizes are Phoenix's too.
