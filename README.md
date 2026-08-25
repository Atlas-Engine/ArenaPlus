# ArenaPlus

**Rated PvP, with the numbers the game keeps to itself.** The ladder, live title cutoffs, a match history that remembers what actually happened, and an inspect window showing what the best of your spec is wearing — for MoP Classic.

---

## The problem

The Rated page tells you your rating and almost nothing else. Where does that put you? What is Duelist worth this week? What is the Ret paladin at rank 12 gemmed for? All of it exists, and none of it is in the game.

ArenaPlus ships the answers with the addon, because an addon cannot reach the network — the ladder, the cutoffs and the gear are read from Blizzard's own API ahead of time and travel with the download.

## What you get

### 🏆 The ladder
Every rated bracket, US and EU, searchable and filterable by spec. Ranks and ratings coloured by the title they are worth, race and class at a glance, and your own row picked out — live from the client, so it is right even when the shipped snapshot is behind.

### 🎖️ Title cutoffs, as they stand
What Gladiator, Duelist, Rival and Challenger cost right now, and how far you are from the next one. Rated battlegrounds show Hero of the Alliance or Hero of the Horde, whichever is yours.

### 📜 A match history that remembers
The last matches of each bracket: your comp against theirs, rating and change, damage, healing, damage taken, crowd control landed and taken, and who earned the game. Expand a match to see every player, with their ladder standing **as it was when you fought them** — click it to find them on the ladder.

Recorded from the scoreboard rather than guessed at, including the rating change for *every* player, not just yours.

### 🔍 Inspect anyone on the ladder
Click a row and see how they play: paper doll with every gem, enchant and tinker, their talents and glyphs, their rated record, and their actual stats — the played character, not the vendor's version of the gear.

### 🛒 A shopping list
At the auction house, that inspect window grows a **Shopping List** tab: every gem, enchant and glyph the character is wearing, counted, quality-coloured, and clickable — one click searches the auction house for it, four sockets of the same gem asking for four.

### 👤 Standings where you are already looking
Hovering a player shows where they stand. So does hovering a group in the group finder, under Arenas, Battlegrounds, World PvP and Custom. Nothing is added for anyone the ladder does not have — which is most players, and an empty line would be worse than none.

### ⚔️ After each match
A line in chat saying what the match did to your rating, where that puts you, your season record, and how long it took.

### 🧭 Getting around
A gladiator helmet on the minimap: left-click for your history, right-click for the ladder. Or `/arena`.

## For other addon authors

ArenaPlus exposes `ArenaPlusAPI` — a small, stable global for looking a character up on the ladder by name, realm and region. [SocialPlus](https://github.com/Atlas-Engine/socialplus) uses it to put rated standings in the friends list. It is versioned, hands out copies rather than live rows, and is safe to call when ArenaPlus is absent.

## Where the data comes from

Blizzard's own Game Data API — the leaderboards, the reward cutoffs, and the character profiles behind gear and specs. Nothing is scraped from a third-party site.

The scripts that do it live in `tools/` and are not part of the download. They need a Battle.net API client, which is free and self-service; `tools/blizzard-credentials.example.txt` explains how to get one. **A client secret is a password — it never belongs in this repository.**

Gear, talents and glyphs are recorded for the top five of each spec in each bracket rather than the whole ladder, which is the sample somebody comparing their own spec would actually want.

## Feedback

Bug or idea? Open a GitHub issue — every report helps.

## Licence

MIT. See [LICENSE](LICENSE).
