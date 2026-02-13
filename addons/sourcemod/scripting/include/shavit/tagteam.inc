/*
 * shavit's Timer - TagTeam API
 * by: shavit, KiD Fearless, rtldg, Nairda, arnelovasal
 *
 * This file is part of shavit's Timer (https://github.com/shavitush/bhoptimer)
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 */

#if defined _shavit_tagteam_included
	#endinput
#endif
#define _shavit_tagteam_included

/**
 * Retrieves TagTeam WR information for a specific map/style/track combination.
 *
 * @param map         Map name
 * @param style       Style ID
 * @param track       Track ID
 * @param teamName    Buffer to store team name
 * @param nameLen     Maximum length of teamName buffer
 * @param members     ArrayList to store member names (must be created by caller, will be cleared)
 * @return            true if TagTeam WR found, false otherwise
 */
native bool Shavit_GetTagTeamWRInfo(const char[] map, int style, int track,
                                     char[] teamName, int nameLen,
                                     ArrayList members);

/**
 * Called when a TagTeam completes a map.
 *
 * @param teamidx     Team index
 * @param time        Completion time
 * @param teamName    Team name
 * @param members     Array of member names
 * @param memberCount Number of members
 */
forward void Shavit_OnTagTeamFinish(int teamidx, float time, const char[] teamName,
                                      const char[][] members, int memberCount);

public SharedPlugin __pl_shavit_tagteam =
{
	name = "shavit-tagteam",
	file = "shavit-tagteam.smx",
#if defined REQUIRE_PLUGIN
	required = 1
#else
	required = 0
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_shavit_tagteam_SetNTVOptional()
{
	MarkNativeAsOptional("Shavit_GetTagTeamWRInfo");
}
#endif
