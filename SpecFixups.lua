local ADDON_NAME, ns = ...

-- Specs for players the game never told us about.
--
-- Empty, and it ships that way: the entries here were one player's teammates,
-- named by hand, which is nothing to distribute.
--
-- The mechanism stays because the problem it solves recurs. A match recorded
-- before a teammate's spec could be asked for has no spec for anyone on your
-- own side, and nothing can go back and ask -- the match is over. Where you
-- know the spec anyway, adding it here fills it in.
--
-- Keyed on the bare name, so it matches whether the entry was recorded with a
-- realm attached or without. Only ever fills a spec that is missing: anything
-- the game itself reported is left exactly as it was.
--
--   ns.SPEC_FIXUPS = { ["Somebody"] = 258 }  -- Shadow Priest
ns.SPEC_FIXUPS = {
	-- Read out of the stored matches rather than remembered: this shaman is
	-- recorded with spec 264 in six of his eight appearances and blank in the
	-- other two, which is the inspect having gone unanswered in those games.
	["Yamborghini"] = 264,  -- Restoration Shaman
}

-- Bump when entries are added, so the pass runs once more over stored matches.
ns.SPEC_FIXUP_VERSION = 2
