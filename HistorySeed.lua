local ADDON_NAME, ns = ...

-- Matches to import once, before you have played any.
--
-- Empty, and it ships that way. This existed to carry one player's own games
-- across from ArenaAnalytics' saved variables, and those are that player's
-- business rather than something to hand to everybody who installs this.
--
-- The mechanism is kept because it costs nothing and is the way to bring a
-- history in from elsewhere: fill the table below and the addon will merge it
-- on the next login, matching on when each game happened so nothing is
-- duplicated.
--
-- Keyed by "Name-Realm" exactly as the game spells it, then by bracket:
--   1 = 2v2, 2 = 3v3, 3 = 5v5, 4 = rated battlegrounds
--
-- Per match: at (when, unix seconds), r rating, d change, w won, dur seconds,
-- and the two sides as mine and theirs.
-- Per player: c class, n name, k kills, x deaths, dmg, heal, spec.
ns.HISTORY_SEED = {}
