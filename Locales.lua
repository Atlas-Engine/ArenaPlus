local ADDON_NAME, ns = ...
ns.L = {}
local L = ns.L

-----------------------------------------------------------------------
-- Localization: English (base) with per-locale overrides below.
-- Any key not overridden by the active locale falls back to English.
--
-- Ordered the way the settings window lists them, so a tweak's strings are
-- where you would look for them. Within a tweak: title, the switch, what it
-- does, then any extra options, then anything it says in chat.
--
-- House style, so seventeen tweaks read as one addon:
--   * the switch label is an instruction -- "Repair at vendors", not "Repairing"
--   * the description says what it does, then at most one thing worth knowing
--   * chat messages are sentences, and name who or what they are about
-----------------------------------------------------------------------

----------------------------------------------------------------
-- General
----------------------------------------------------------------
L.ADDON_NAME              = "ArenaPlus"
L.CHAT_PREFIX             = "|cff33ff99ArenaPlus|r: "

----------------------------------------------------------------
-- Settings window
----------------------------------------------------------------
-- The four headings the tweak list is broken into.

L.WINDOW_TITLE            = "ArenaPlus"
L.OPTIONS_OPEN            = "Open ArenaPlus"
L.OPTIONS_DESC            = "Rated arena and battleground tracking: match history, title cutoffs and the ladder. Type |cffffff00/arenaplus|r or |cffffff00/arena|r to open this in its own window."

----------------------------------------------------------------
-- PvP panel
----------------------------------------------------------------
L.PVP_TITLE               = "PvP panel"
L.PVP_ENABLE              = "Open on Rated"
L.PVP_DESC                = "The Player vs Player panel opens on Rated rather than Random Battleground."

L.PVP_GROUPFINDER_LABEL   = "Group Finder opens on Dungeons"
L.PVP_GROUPFINDER_TOOLTIP = "The Group Finder and the PvP panel are tabs of one window, and the game reopens whichever you used last. This sends it back to Dungeons and Raids, while opening the PvP panel deliberately still goes to Rated."

L.PVP_BRACKET_GONE        = "The page cannot be opened on a chosen bracket: highlighting a row from an addon makes the game refuse to queue. Pick the bracket yourself and Join Battle works as normal."

----------------------------------------------------------------
-- Rated page
----------------------------------------------------------------
L.RATED_TITLE             = "Rated page"
L.RATED_ENABLE            = "Show rank and record"
L.RATED_DESC              = "The Best column becomes your ladder position, coloured by the current title cutoffs, and Wins becomes your season record."

L.RATED_TOOLTIP_LABEL     = "Hide the row tooltip"
L.RATED_TOOLTIP_TOOLTIP   = "The weekly and season stats that open when you hover a bracket cover the arena history beside the panel, and say what the row already shows."

L.RATED_RANK_LABEL        = "Rank"
L.RATED_WINS_LABEL        = "W/L"
L.RATED_NONE              = "|cffb3b3b3-|r"
L.RATED_RECORD            = "|cff1eff00%d|r |cffb3b3b3-|r |cffff2020%d|r"

----------------------------------------------------------------
-- What each arena did, and how long it took
----------------------------------------------------------------
-- No MMR here any more. It was estimated from the ratio of a win to a loss,
-- which assumes you were matched at your own MMR -- and whether you were is
-- unknowable, since the enemy team's MMR is not published anywhere the client
-- can reach. What is left is measured rather than inferred.
L.MMR_TITLE               = "Arena results"
L.MMR_ENABLE              = "Report each arena in chat"
L.MMR_DESC                = "After a rated match, says what it did to your rating, where that puts you on the ladder, your season record, and how long it took."

-- The rating arrives already coloured by ladder tier, so it is %s.
L.MMR_MSG_RESULT          = "%s: rating %s (%s)."
L.MMR_MSG_NOCHANGE        = "%s: rating %s -- that match moved nothing."
L.MMR_MSG_PLACEMENT       = "  Placement game %d of %d -- rating swings are larger until those are done."
L.MMR_CHANGE_MULTI        = "%+d over %d games"

-- Gathered onto one line under the result. The rank takes the same ladder
-- tier colour as the rating it belongs to.
L.MMR_DETAIL_RANK         = "ladder rank |cff%s#%d|r"
L.MMR_DETAIL_SEASON       = "season |cff1eff00%d|r won |cffff2020%d|r lost"

-- Short forms, for the shared line above the Leave Arena button.
L.MMR_BOARD_BRACKET       = "|cffffd100%s|r"
L.MMR_BOARD_RANK          = "|cff%s#%d|r"
L.MMR_BOARD_SEASON        = "|cff1eff00%d|r|cffb3b3b3-|r|cffff2020%d|r"

L.LENGTH_MSG              = "Arena lasted %s."
L.LENGTH_MIN_SEC          = "|cffffff00%d|r min |cffffff00%d|r sec"
L.LENGTH_SEC              = "|cffffff00%d|r sec"

----------------------------------------------------------------
-- Player tooltips
----------------------------------------------------------------
L.UNITTIP_TITLE           = "Player tooltips"
L.UNITTIP_ENABLE          = "Show ladder standing on player tooltips"
L.UNITTIP_DESC            = "Pointing at a player shows where they stand on the ladder. Nothing is added for anyone the ladder does not have, which is most players."
L.UNITTIP_HEADER          = "Ladder Standing"
-- Bracket, then the rating in its title colour, then the place.
L.UNITTIP_LINE            = "%s  |cff%s%d|r  |cff808080#%d|r"

----------------------------------------------------------------
-- Group finder
----------------------------------------------------------------
L.LFG_TITLE               = "Group finder"
L.LFG_ENABLE              = "Show ladder standing in the group finder"
L.LFG_DESC                = "Hovering a listing under Arenas, Battlegrounds, World PvP or Custom shows where its leader stands on the ladder. Nothing is added for a leader the ladder does not have, which is most of them."

----------------------------------------------------------------
-- Minimap button
----------------------------------------------------------------
L.MINIMAP_TITLE           = "Minimap button"
L.MINIMAP_ENABLE          = "Show a button on the minimap"
L.MINIMAP_DESC            = "A gladiator helmet beside the minimap: your match history, or the ladder on a right-click. Drag it around the edge to move it."
L.MINIMAP_TIP_LEFT        = "Left-click: your match history"
L.MINIMAP_TIP_RIGHT       = "Right-click: the ladder"
L.MINIMAP_TIP_MIDDLE      = "Middle-click: settings"
L.MINIMAP_TIP_DRAG        = "Drag: move it around the minimap"

----------------------------------------------------------------
-- Arena history
----------------------------------------------------------------
L.HISTORY_TITLE           = "Arena history"
L.HISTORY_SWAP            = "Leaderboard"
L.HISTORY_ENABLE          = "Show recent matches beside the panel"
L.HISTORY_DESC            = "The last ten matches of the selected bracket, against the side of the Rated page: rating and change, your comp against theirs, and whether it was a win."

L.HISTORY_WINDOW_TITLE    = "Last %d matches -- %s"
L.HISTORY_FULL_TITLE      = "Arena history -- %s"
L.HISTORY_EMPTY           = "Nothing recorded yet -- it fills as you play."
L.HISTORY_VS              = "vs"
L.HISTORY_SUMMARY_INCOMPLETE = "|cffff8000nothing recorded|r -- disconnected, or left before anything was seen"
L.HISTORY_SUMMARY_LEFT    = "|cffffd100left early|r -- everything up to the moment you left"
L.HISTORY_SUMMARY_MIXED   = "|cffff8000rosters mixed|r -- two matches recorded as one"
L.HISTORY_PRUNED          = "Removed %d match(es) whose rosters were stitched from two games."
L.HISTORY_PRUNE_NONE      = "No mixed matches to remove."

-- The header above the list, which stands in for the row tooltip the Rated
-- page tweak hides.
-- The ladder cutoffs, read from Blizzard's API by the companion script and
-- shown for whichever bracket is selected.
-- Built by name rather than written out: the settings window looks up
-- GROUP_<group> and the cutoffs box looks up CUTOFF_<tier key>. Nothing in the
-- code mentions these spellings, so a search for unused strings will offer to
-- delete every one of them. It has already tried once.
L.INHERITED               = "Brought %d setting group(s) across from QoLPlus, including your recorded matches. QoLPlus keeps its own copy."
L.INHERIT_AGAIN           = "Copied again from QoLPlus. |cffffff00/reload|r to see it."
L.REGION_MISMATCH         = "The cutoffs and ladder were read for |cffffff00%s|r, but you play on |cffffff00%s|r. Rerun the update scripts with |cffffff00-Region %s|r or the numbers are somebody else's."

L.GROUP_ARENA             = "Arena and battlegrounds"
L.CUTOFF_R1               = "Rank one"
-- Rated battlegrounds call the top title Hero of the Alliance or Hero of the
-- Horde, so it is named for whichever the reader plays. The neutral wording is
-- only for a pandaren who has not picked a side yet.
L.CUTOFF_HERO_ALLIANCE    = "Hero of the Alliance"
L.CUTOFF_HERO_HORDE       = "Hero of the Horde"
L.CUTOFF_HERO             = "Hero of the Faction"
L.CUTOFF_GLADIATOR        = "Gladiator"
L.CUTOFF_DUELIST          = "Duelist"
L.CUTOFF_RIVAL            = "Rival"
L.CUTOFF_CHALLENGER       = "Challenger"

L.CUTOFF_TITLE            = "%s title cutoffs"
-- Appended to a heading so both windows say whose numbers these are. Gold
-- rather than grey: which region you are reading changes every figure under it,
-- and a grey aside is exactly what the eye skips.
L.REGION_TAG              = "  |cffffd100%s|r"
L.CUTOFF_VALUE            = "|cff%s%d|r"
-- Rank one and Gladiator are a fixed number of places, and the rating is the
-- one sitting in the last of them. Its own column, so the ratings stay in line.
L.CUTOFF_SPOTS            = "%d slots"
-- How far the next title is from where you stand, beside the heading.
L.CUTOFF_NEXT             = "|cff%s+%d to %s|r"
L.CUTOFF_NEXT_TOP         = "|cffff8000above every cutoff|r"
-- The date a user can act on. What they have is whatever shipped in the last
-- release, and a release only happens when the numbers moved -- so this is when
-- the companion script last read Blizzard, not when Blizzard last changed them.
L.CUTOFF_SOURCE           = "|cff9a9a9aBlizzard API|r, updated %s"
-- Both times, because they are not the same and the difference is the whole
-- explanation when a rating that has clearly changed is not in here yet:
-- Blizzard rebuilds these snapshots on their own schedule, measured at nearly
-- two hours behind, and nothing we do reaches data they have not published.
L.CUTOFF_SOURCE_SNAPSHOT  = "|cff9a9a9aBlizzard|r %s UTC |cff6a6a6a(%s)|r"

-- How long ago the companion script last read Blizzard. Relative, because the
-- question is whether it is recent, and a clock time makes the reader work
-- that out.
L.LADDER_AGO_NOW          = "just now"
L.LADDER_AGO_MINUTES      = "%d minutes ago"
L.LADDER_AGO_HOUR         = "an hour ago"
L.LADDER_AGO_HOURS        = "%d hours ago"
L.LADDER_AGO_DAY          = "a day ago"
L.LADDER_AGO_DAYS         = "%d days ago"

-- The inspect panel. Only the best few of each spec in each bracket carry gear,
-- talents and glyphs, so some of these say why there is nothing to show.
L.INSPECT_RATING          = "%d rating"
L.INSPECT_RANK            = "#%d"
L.INSPECT_HINT            = "Drag to turn, wheel to zoom, right click to reset."
-- Only when their race is not known, which is now the rare case.
L.INSPECT_HINT_OWN_RACE   = "Drag to turn, wheel to zoom, right click to reset.  Shown on your own race."
L.INSPECT_NOT_COVERED     = "Gear and talents are only recorded for the top five of each spec in each bracket."

-- The played character, which the gear cannot say: every worn item is reported
-- with its vendor stats, so gems, enchants and reforges are missing there and
-- present here. Blizzard derives these from the character's own percentages, so
-- they are not a sum of gear and should not be read as one.
L.INSPECT_TAB_STATS       = "Stats"
L.INSPECT_STATS_ATTRIBUTES = "Attributes"
L.INSPECT_STATS_SECONDARY = "Secondary"
L.INSPECT_STAT_STRENGTH   = "Strength"
L.INSPECT_STAT_AGILITY    = "Agility"
L.INSPECT_STAT_INTELLECT  = "Intellect"
L.INSPECT_STAT_STAMINA    = "Stamina"
L.INSPECT_STAT_HEALTH     = "Health"
L.INSPECT_STAT_SPELL_POWER = "Spell Power"
L.INSPECT_STAT_ATTACK_POWER = "Attack Power"
L.INSPECT_STAT_CRIT       = "Critical Strike"
L.INSPECT_STAT_HASTE      = "Haste"
L.INSPECT_STAT_MASTERY    = "Mastery"
L.INSPECT_STAT_SPIRIT     = "Spirit"
L.INSPECT_STATS_NOTE      = "The character as the game had them at logout -- gear, gems, enchants, reforges and passives all counted in, not a sum of the gear. Hit and expertise are not in Blizzard's data."
L.INSPECT_STATS_NONE      = "No stats on file for this character yet."
-- The shopping list: gems, enchants and glyphs, everything you would have to
-- buy to wear what they are wearing. Gems are counted rather than listed one
-- per socket, because what somebody copying a build needs to know is how many.
--
-- Named for the job rather than the contents. It was "Gems", then "Gems &
-- Enchants", and glyphs made the third name in a row that would have to change
-- again the next time a column moved in.
L.INSPECT_TAB_SOCKETS     = "Shopping List"
L.INSPECT_GEMS            = "Gems"
L.INSPECT_ENCHANTS        = "Enchants"
L.INSPECT_GEM_COUNT       = "%dx %s"
L.INSPECT_NO_GEMS         = "No gems."
L.INSPECT_NO_ENCHANTS     = "No enchants."
L.INSPECT_NO_GLYPHS       = "No glyphs."
-- No "with the auction house open" any more: the tab this sits on only exists
-- there.
L.INSPECT_AH_HINT         = "Click any gem, enchant or glyph to search the auction house for it."
-- Searching goes through Auctionator. Blizzard's own browse box is gone on this
-- client -- the modern auction house replaced it -- so without Auctionator
-- there is nothing to type into and a click can only be explained, not obeyed.
L.INSPECT_AH_HINT_NO_AUCTIONATOR = "Install Auctionator to search for these from here."
L.INSPECT_AH_NEEDS_AUCTIONATOR = "%s -- searching the auction house needs Auctionator installed."
L.INSPECT_AH_SEARCHED     = "Searching the auction house for %s."
L.INSPECT_AH_SEARCHED_COUNT = "Searching the auction house for %d x %s."
L.INSPECT_AH_CLOSED       = "%s -- open the auction house and click again to search for it."
-- Shown while the client fetches an item's name, which it does not have until
-- something asks for it.
L.INSPECT_LOADING         = "loading..."
L.INSPECT_ENCHANT_ID      = "enchant %d"

-- The PvP tab, laid out the way Blizzard lays out the one on the PvP frame, so
-- that reading somebody else's needs no second vocabulary.
L.INSPECT_PVP_ARENA       = "Arena Battles"
L.INSPECT_PVP_RBG         = "Rated Battlegrounds"
L.INSPECT_PVP_WL          = "W/L"
L.INSPECT_PVP_RANK        = "Rank"
L.INSPECT_PVP_CURRENT     = "Current"
L.INSPECT_PVP_DASH        = "|cff666666--|r"

-- The auction house shortcut: pick a spec, pick a player, read their gems
-- without leaving the auction house you are standing at.
L.AH_PVP_BUTTON           = "PvP"
L.AH_PVP_TITLE            = "Top PvP gear"
L.AH_PVP_TOOLTIP          = "What the best players of your class are gemming and enchanting."
L.AH_PVP_PICK             = "Pick a spec."
L.AH_PVP_TOP              = "Best %s in %s:"
L.AH_PVP_NONE             = "No %s in %s with gear recorded yet."
L.AH_PVP_HINT             = "Click a player to see their gems and enchants."
L.AH_PVP_NO_SPECS         = "This client did not name your specs."
L.INSPECT_HIDDEN          = "This character's profile is hidden, so there is nothing to read. One in five at the top of the ladder is."
-- Ids the client cannot turn into words on its own. Enchants and glyphs ship
-- their text with the data.
L.INSPECT_ENCHANT_UNKNOWN = "Enchanted (%d)"
L.INSPECT_GLYPH_UNKNOWN   = "Glyph %d"
-- Blizzard's inspect tabs, less Guild: the leaderboard carries no guild, and a
-- tab that is always empty is worse than no tab.
L.INSPECT_TAB_CHARACTER   = "Character"
L.INSPECT_TAB_PVP         = "PvP"
L.INSPECT_TAB_TALENTS     = "Talents"
L.INSPECT_GLYPHS          = "Glyphs"
L.INSPECT_GLYPH_MAJOR     = "Major Glyph"
L.INSPECT_GLYPH_MINOR     = "Minor Glyph"
L.INSPECT_GLYPH_NONE      = "None glyphed."
-- MoP talents come one tier every fifteen levels, so the row number gives the
-- tier without it having to be stored.
-- The grid is harvested from what players were actually seen taking, because
-- Blizzard publishes no talent tree for classic. A talent nobody on the ladder
-- picked is not in it, and a blank cell would otherwise read as a talent that
-- does not exist.
L.INSPECT_TALENT_GAPS     = "%d choices not yet seen on the ladder."
-- On each piece, replacing the count the client works out for the viewer.
L.INSPECT_SET_TOOLTIP     = "%s (%d/%d)"
-- Professions, worked out from the gear rather than asked for: the classic API
-- has no professions endpoint. Only what a piece of gear could not have without
-- it, so the absence of an icon is not a claim that they lack the profession.
L.INSPECT_PROFESSION_ENGINEERING   = "Engineering"
L.INSPECT_PROFESSION_ENCHANTING    = "Enchanting"
L.INSPECT_PROFESSION_BLACKSMITHING = "Blacksmithing"
L.INSPECT_PROFESSION_TAILORING     = "Tailoring"
L.INSPECT_PROFESSION_NOTE          = "Read from their gear, not from the armoury."
L.INSPECT_PVP_NONE        = "not on this ladder"
L.INSPECT_PVP_NOTE        = "Read from the ladder already on disk, so a bracket they have not placed in shows nothing."

L.HISTORY_BEST_SEASON     = "Season best"
L.HISTORY_BEST_VALUE      = "%s |cff808080%d games|r"
-- The second reading: the median rating of who the game matched you against.
-- Median rather than average on purpose -- past about seven minutes in the
-- queue the game stops caring about MMR and hands you whoever is waiting, and
-- measured over real matches the two differ by up to 116 points because of it.
-- Beside a player's ladder place: what they are rated now. Not what they were
-- rated during that match, which nothing records.
L.HISTORY_LADDER_RATING   = " |cffb3b3b3%d|r"
-- Wins and losses over the listed matches, in the colours the row squares use.
L.HISTORY_RECORD          = "|cff1fff00%d|r/|cffff2121%d|r"
L.HISTORY_TOTAL           = "%d games"
-- Won, lost, and what the day cost or paid. The rating change arrives already
-- coloured, so it is %s rather than a number.
L.HISTORY_TODAY           = "today |cff1eff00%d|r/|cffff2020%d|r  %s"
-- A ladder place beside a name, in the colour of the title it is worth.
--
-- The place only. Their current rating sat next to the points the match was
-- worth and the two read as one number -- and the standing is the less
-- interesting of the two now that the match change is known.
L.HISTORY_LADDER          = "  |cff%s#%d|r"
-- What the match was worth to that player. Only ever shown for you.
L.HISTORY_DELTA           = "  |cff%s%+d|r"

L.LADDER_BUTTON           = "Ladder"
-- No depth named. It was "down to the Duelist cutoff", which went out of date
-- the moment the depth became a setting -- and the window says how many places
-- it holds anyway.
L.LADDER_BUTTON_TOOLTIP   = "This bracket's ladder, read from Blizzard's API."
-- The bracket alone. "2v2 ladder" against "Rated BG ladder" is a heading that
-- changes width with the bracket, which shifted everything anchored after it.
L.LADDER_TITLE            = "%s"
L.LADDER_SUBTITLE         = "top %d"
-- The button that goes to your own place, which the window used to do by
-- itself every time it opened.
L.LADDER_MINE             = "My rank"
-- Each window names the other, so the pair reads as two views of one thing
-- rather than two unrelated windows.
L.LADDER_SWAP             = "History"
L.LADDER_PAGE             = "page %d of %d"
-- Tier colour, rank, rating. Said on the source line rather than in the list:
-- the rows are a snapshot and stay one, and this is the live number.
L.LADDER_LIVE_SELF        = "   |cff9a9a9a--|r  you are |cff%s#%d|r |cff6a6a6a(|r|cff%s%d|r|cff6a6a6a)|r"
L.LADDER_EMPTY            = "No ladder recorded for this bracket."
-- The My alts view: your own characters, numbered among themselves rather than
-- by where they sit on the ladder. An alt at 1400 has no ladder place at all,
-- which is the whole reason this cannot just filter the ladder.
L.LADDER_ALTS             = "My alts"
L.LADDER_TITLE_ALTS       = "My %s alts"
L.LADDER_SUBTITLE_ALTS    = "%d rated"
L.LADDER_NO_ALTS          = "None of your characters has a rating in this bracket."
-- For an alt the ladder does not list: the store keeps how many games it has
-- played but not how they went, and "0/0" would be a wrong answer rather than
-- a missing one.
L.LADDER_PLAYED           = "|cffb3b3b3%d games|r"
-- Blank on purpose: the box is plainly a search box, and the prompt read as
-- text somebody had left in it.
L.LADDER_SEARCH           = ""
L.LADDER_HIDDEN           = "  |cff808080(hidden)|r"
L.LADDER_COL_RANK         = "#"
L.LADDER_COL_NAME         = "Name"
L.LADDER_COL_REALM        = "Realm"
L.LADDER_COL_RECORD       = "Won / lost"
L.LADDER_COL_RATING       = "Rating"

L.HISTORY_SPECS_FILLED    = "Filled in %d missing specs on matches recorded before teammate specs could be read."
L.HISTORY_IMPORTED        = "Filled the arena history with %d past matches read from ArenaAnalytics."

-- Columns inside an expanded match. Each header is placed at its column's own
-- offset rather than padded with spaces, which never lines up.
L.HISTORY_HEAD_PLAYER     = "Player"
L.HISTORY_HEAD_KD         = "K/D"
L.HISTORY_HEAD_DAMAGE     = "Damage (dps)"
L.HISTORY_HEAD_HEALING    = "Healing (hps)"
L.HISTORY_HEAD_TAKEN      = "Damage taken (dps)"
L.HISTORY_HEAD_CC         = "CC done / taken"

L.HISTORY_DETAIL_KD       = "|cffffffff%d|r / |cffffffff%d|r"
L.HISTORY_DETAIL_RATE     = "%s |cff808080(%s)|r"

-- Seconds of hard crowd control landed, then seconds sat in. Stuns, fears,
-- incapacitates and silences; not roots.
--
-- The counts behind these are still recorded and can come back if they are
-- ever worth the width, but two numbers in a column is as much as reads at a
-- glance.
L.HISTORY_DETAIL_CC       = "|cffffffff%ds|r |cffb3b3b3/|r |cffff8080%ds|r"

-- Magenta: no class wears it and no number beside it is that colour, so the
-- tag is found at a glance instead of read for. It rides on the name, so it is
-- the name that gives way when a long one runs out of room -- never the rating.
L.HISTORY_MVP             = "%s |cffff40ff(MVP)|r"

-- Over the place and rating, which had no heading while every other column had
-- one. Named for the rating rather than the ladder: the rating is about to stop
-- coming from the ladder at all.
L.HISTORY_HEAD_RATING     = "Rating"
-- Not on the published ladder: it stops at 1108 in 2v2 and 864 in 3v3, so this
-- is most people in most matches rather than a fault.
L.HISTORY_LADDER_NONE     = "|cff808080--|r"
L.HISTORY_LADDER_CLICK    = "Click to find them on the ladder"
L.HISTORY_SUMMARY_LENGTH  = "%d min %d sec"

L.HISTORY_TIP_KILLS       = "Kills |cffffffff%d|r    Deaths |cffffffff%d|r"
L.HISTORY_TIP_TAKEN       = "Damage taken |cffffffff%s|r"
-- The kill that broke the tie, which is the one the MVP tag pays for.
L.HISTORY_TIP_DECISIVE    = "Decisive kills |cffffffff%d|r"
L.HISTORY_TIP_DAMAGE      = "Damage |cffffffff%s|r  (%s dps)"
L.HISTORY_TIP_HEALING     = "Healing |cffffffff%s|r  (%s hps)"
L.HISTORY_TIP_DAMAGE_ONLY = "Damage |cffffffff%s|r"
L.HISTORY_TIP_HEALING_ONLY= "Healing |cffffffff%s|r"

----------------------------------------------------------------
-- Auto marker
----------------------------------------------------------------

-- The mark's own icon in front of its name, so the list is picked by sight.

----------------------------------------------------------------
-- Tab targeting
----------------------------------------------------------------

----------------------------------------------------------------
-- Spirit release
----------------------------------------------------------------

----------------------------------------------------------------
-- Repairs
----------------------------------------------------------------

----------------------------------------------------------------
-- Durability
----------------------------------------------------------------

----------------------------------------------------------------
-- Selling junk
----------------------------------------------------------------

----------------------------------------------------------------
-- Loot confirmations
----------------------------------------------------------------

----------------------------------------------------------------
-- Resurrection
----------------------------------------------------------------

----------------------------------------------------------------
-- Deleting items
----------------------------------------------------------------

----------------------------------------------------------------
-- Duels
----------------------------------------------------------------

----------------------------------------------------------------
-- Invites
----------------------------------------------------------------

----------------------------------------------------------------
-- Guild invites
----------------------------------------------------------------

----------------------------------------------------------------
-- Summons
----------------------------------------------------------------

----------------------------------------------------------------
-- Item level
----------------------------------------------------------------

-- Grey label, coloured number: the label is there to say what the number is,
-- not to compete with it.

----------------------------------------------------------------
-- Dungeon finder
----------------------------------------------------------------

----------------------------------------------------------------
-- Copying chat
----------------------------------------------------------------
