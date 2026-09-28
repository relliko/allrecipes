# allrecipes

Every era synthesis and desynthesis recipe on PhoenixXI, by craft, for Ashita v4.

- Pick a recipe to see its materials and results, with your odds at your craft levels:
  - success;
  - HQ, with the next HQ bracket and the level it starts at;
  - skill-up chance.
- Names are coloured by how hard the recipe is for you.
- Skill-up mode lists only the recipes that can raise the craft.
- Type in AH prices to see the profit a try, selling on the AH or to an NPC. The profit is broken down into NQ, each HQ and a break. A price typed once is used by every recipe and every character.
- Ctrl+click any item to open its page on ffxiah.com, and from there whichever wiki you like.

Nothing is ever sent to the server and nothing is asked of it: allrecipes only reads client memory and the packets the game receives anyway. Phoenix only allows tools on its [approved addon list](https://phoenix-xi.com/approved-addons), so check it's there before using it on the server.

## Installation
- Copy the `allrecipes` folder into your Ashita v4 `addons` directory.
- Type `/addon load allrecipes` in game, then `/ar` to open the window.

## Usage
| Command | |
|---|---|
| `/allrecipes` or `/ar` | show or hide the window |
| `/ar <craft>` | open it on a craft: `wood`, `smith`, `gold`, `cloth`, `leather`, `bone`, `alchemy`, `cook` |
| `/ar prices export [file]` | save your prices as JSON (`prices.json` in `config/addons/allrecipes`) |
| `/ar prices import <file>` | add prices from JSON |
| `/ar reset` | move the window back to where it starts |
| `/ar debug` | your craft levels, ranks and image support as the addon reads them |

**In the window** (it looks like scouter's):
- **Craft chips** show your level in each craft. The one you're on is shown big, with your rank and how far you are toward its cap.
- **Toolbar:** switch between synthesis and desynthesis, all recipes or skill-ups, and selling on the AH or to an NPC.
- **Settings chip:** opens a settings window where you can:
  - pick the theme: clean (scouter's), guild (warm leather and gold) or Vana'diel (the game's blue menus);
  - hide expansions;
  - hide recipes where the craft is only a sub-craft, or recipes that need a key item;
  - add a skill bonus for gear or moghancements;
  - export your prices.
- **Sorting:** click a column head to sort by it; click again to reverse.
- **Tooltips:** hover over a profit in the list to see how it adds up.

Image support counts toward your odds. It starts at +1. If it's still up after 2 minutes it must be advanced support or a guild belt, so it turns +3 by itself. Click the image support button to change it by hand.

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

**Profit a try** is what the results sell for, weighted by their chances, less what you use up on average: the crystal, and the materials in full on a success or at their loss rate on a break.

The addon can't see crafting rings, foods that raise success, or advanced image support's lower break rate, so those aren't counted.

## AH price history
Look at an item's price history at the auction house and allrecipes keeps it. Any price you haven't typed in then comes from it, shown faintly with a `~`.
- **What it keeps:** the newest ten sales of each item from the last 180 days, singles and stacks separately.
- **Singles or stacks:** the history itself doesn't say which it is. The category list you browsed to get there does: it gives how many singles and stacks are on sale. An item that doesn't stack on Phoenix (ores, logs and more) is always singles. A history that can't be told apart is kept, but not used as a price.
- **Price used:** the middle sale. A stack's price is divided by the stack size, and a price from stacks is marked `stk` in the box.
- **Singles or stacks, when an item has both:** the settings say which to use (singles to start). Right-click a price box to switch that one item; the choice is remembered.
- **Hover a price box** to see the sales behind it.
- **Your own price** always wins; empty the box to use the AH's again.

It never asks the server for anything. The history comes from the game's search server over its own connection, where no packet event can see it. So allrecipes reads it from the game's memory after the game has received it for you. When you open the auction house, it looks through memory in the background for the layout of a history or a category list (known from `src/search/packets/`) until it finds where the game keeps them. Browsing any category is usually enough. After that it just watches those spots. All of this is through `ReadProcessMemory`, so memory the game frees can't crash it.

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
