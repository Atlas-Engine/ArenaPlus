local ADDON_NAME, ns = ...

-- Arena title cutoffs, written by tools\UpdateFromBlizzard.ps1 from Blizzard's
-- own API. Do not edit by hand: rerun the script to refresh.
--
-- Region eu, season 14, cutoffs last changed 2026-08-25 06:12 AM, last checked 2026-08-25 04:40 PM.
ns.CUTOFFS_BY_REGION = ns.CUTOFFS_BY_REGION or {}

ns.CUTOFFS_BY_REGION["eu"] = {
	region  = "eu",
	updated = "2026-08-25 06:12 AM",
	checked = "2026-08-25 04:40 PM",

	[1] = { r1=2505, gladiator=2272, duelist=2121, rival=1839, challenger=1051 }, -- 2v2
	[2] = { r1=2277, gladiator=1621, duelist=1594, rival=1435, challenger=768 }, -- 3v3
	[3] = { r1=288, gladiator=1, duelist=1, rival=1, challenger=1 }, -- 5v5
	[4] = { r1=2347, duelist=2048, rival=1828, challenger=1510 }, -- rbg
}

-- How many places each fixed-count title is worth. Blizzard does not publish
-- these, so they are counted off the ladder: everybody at or above the cutoff.
ns.CUTOFF_SLOTS_BY_REGION = ns.CUTOFF_SLOTS_BY_REGION or {}

ns.CUTOFF_SLOTS_BY_REGION["eu"] = {
	[1] = { r1=30, gladiator=187 }, -- 2v2
	[2] = { r1=32, gladiator=186 }, -- 3v3
	[3] = { r1=17, gladiator=26 }, -- 5v5
	[4] = { r1=3 }, -- rbg
}
