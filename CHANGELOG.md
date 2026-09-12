# Changelog

## 1.5d

- New: Activity on the ladder. The button at the end of the spec icons lists who has actually been playing this bracket, with a slider for how far back to look -- an hour, three, six, twelve or a day. Sorted by rating, with what each of them won, lost and moved in that window, and when they were last seen. Needs the data addon updated alongside it.
- Clicking Last seen orders the list by who played most recently, and clicking Rating puts it back.
- The ladder window is wider, so nothing in the header crowds the buttons beside it.
- Home now returns you to your own region and game as well as to the ladder.
- The inspect panel's Titles Earned is now Achievements Earned, since the rating milestones listed under it are not titles.
- In the match history, a player's rating is what the ladder says today rather than a figure kept from when the match was saved, so it agrees with the ladder window and with the game. Your own line still shows the rating that match actually finished at.
- In the match history, a rating change the client never reported is left blank instead of shown as +0.
- The rating in the match history is no longer clickable.
- The Leaderboard button is hidden while the match history is open beside the PvP panel.

## 1.5c

- New on the inspect panel's PvP tab: the titles a player has earned. Gladiator, Duelist, Rival or Challenger, with the rating milestones behind them, in the colour that title is worth. Only the highest is shown, since every Gladiator is also a Duelist. Mists only -- Blizzard does not publish achievements for Anniversary.
- The weapons under the inspect model sit together and centred again, each enchant beside the weapon it belongs to, with the thrown weapon or bow out to their right.
- The model shows a player's main hand rather than their off hand. It can only wear what your own character could wear, which the line underneath now says.
- A long name in the match history is no longer cut short by the rating column beside it, which was holding room it rarely used. The MVP tag fits again.

## 1.5b

- Fixes and improvements in Shared code, Match history, Ladder window, Auction house, Inspect panel.

## 1.5a

- Clicking a player in the Top PvP gear list now lights up their row, so it is clear whose shopping list is open. Changing spec, bracket or region closes it.
- The shopping list is no longer a tab in the inspect panel as well. It has its own window beside the auction house.
- The ladder heading is now a fixed width, so the buttons and flags beside it stop moving when you switch bracket.
- The alts view is headed "My alts" rather than repeating the bracket you are already in.

## 1.4c

- Fixes and improvements in Auction house, shopping panel.

## 1.4b

- Added cutoffs for TBC, fixed bunch of stuff.

## 1.4a

- Fixes and improvements in Match history, Minimap button.

## 1.3c

- The PvP button now appears on the Anniversary auction house. It was never drawn there at all -- that client uses the original auction house window, and the button was only ever looking for the modern one.
- Clicking a player in the Top PvP gear list on Anniversary now opens their gear. Every one of them reported having no gear recorded, including the five it had just listed.
- The shopping list now only shows things that can actually be bought at the auction house. Most of Burning Crusade's enchants are an enchanter's own work with no item to buy, and the list was offering them anyway.
- Glyphs are no longer given a column on Anniversary, where they do not exist.
- The inspect panel now shows the ranged weapon -- bow, gun, wand or thrown -- between the two weapons on Anniversary. It was missing entirely, and the off-hand enchant is no longer written over the slot beside it.
- Anniversary no longer suggests installing Auctionator. Searching from the shopping list works there without it; the suggestion still appears on Mists, where it is needed.
- Arena matches that end because somebody leaves are now recorded. Nothing at all was kept for them -- no damage, no healing, no rating change -- because the scoreboard is only read once somebody has died, and a forfeit has no deaths in it.

## 1.3b

- The PvP button now appears on the Anniversary auction house. It was never drawn there at all -- that client uses the original auction house window, and the button was only ever looking for the modern one.
- Clicking a player in the Top PvP gear list on Anniversary now opens their gear. Every one of them reported having no gear recorded, including the five it had just listed.
- The shopping list now only shows things that can actually be bought at the auction house. Most of Burning Crusade's enchants are an enchanter's own work with no item to buy, and the list was offering them anyway.
- Glyphs are no longer given a column on Anniversary, where they do not exist.
- The inspect panel now shows the ranged weapon -- bow, gun, wand or thrown -- between the two weapons on Anniversary. It was missing entirely, and the off-hand enchant is no longer written over the slot beside it.
- Anniversary no longer suggests installing Auctionator. Searching from the shopping list works there without it; the suggestion still appears on Mists, where it is needed.
- Arena matches that end because somebody leaves are now recorded. Nothing at all was kept for them -- no damage, no healing, no rating change -- because the scoreboard is only read once somebody has died, and a forfeit has no deaths in it.

## 1.3a

- Fixes and improvements in Auction house.

## 1.2c

- ArenaPlus now runs on TBC Classic Anniversary. The ladder, title cutoffs, ranks, class and spec, and the gear, gems and enchants behind the auction house list are all there for the Anniversary realms, in both regions.
- A game picker at the top of the leaderboard switches between Classic and Anniversary, and the region flags work with either. It opens on the game you are playing, and only appears when both ladders are installed.
- The talents tab now draws a Burning Crusade build the way that game reads it: three trees with the points spent in each, and every talent at the rank it was taken. Mists characters keep the tier grid.
- The inspect panel names the spec and class across the top, in the class colour -- "Subtlety Rogue".
- Spec icons now ship with the addon instead of being asked for from the game, so they draw on both versions. Several were missing outright on Anniversary, and death knight, monk, Enhancement, Assassination and the hunter specs showed as blank squares.
- The minimap button now carries its own icon, which was missing entirely on Anniversary.
- 10v10 is hidden on Anniversary, which has no rated battlegrounds, and death knights and monks are left out of the spec filter there.
- Glyphs and professions are no longer shown for an Anniversary character. Neither exists in that game, and the professions were being guessed from gear against a Mists list.
- The arena history and leaderboard windows now close when you leave the Rated page, rather than staying open over Casual, War Games, Premade Groups, Dungeons & Raids or Challenges. Opening either from the minimap button still works with the PvP window closed, and closing the PvP window itself leaves them alone.
- Fixed the drag-to-turn hint on the inspect panel sitting on top of the tabs, and removed two notes that explained more than they were worth.

## 1.2b

- Fixes and improvements in Auction house.

## 1.2a

- Opening bracket
- Start on the bracket you last played
- The Rated page opens with the bracket you played most recently already lit, instead of 10v10. Join Battle stays greyed out until you click a row yourself: the game only accepts a queue you chose by hand.
- Pick a bracket

## 1.1c

- Fixes and improvements in Shared code, Match history, Ladder window.

## 1.1b

- Home
- Back to the top of the ladder, with no search, spec filter or alts list
- Ctrl+C to copy
- Right-click to copy the name
- name, or name-realm

## 1.1a

- Fixed characters with the same name on different realms showing each other's rank and rating.
- Press Enter in the ladder search to step between characters sharing a name.
- Changing page in the ladder now returns to the top of the list.
















