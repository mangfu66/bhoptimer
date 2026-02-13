/*
 * shavit's Timer - Replay Recorder
 * by: shavit, rtldg, KiD Fearless, Ciallo-Ani, BoomShotKapow
 *
 * This file is part of shavit's Timer (https://github.com/shavitush/bhoptimer)
 *
 *
 * This program is free software;
 * you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.
 * If not, see <http://www.gnu.org/licenses/>.
 *
 */

#include <sourcemod>
#include <sdktools>
#include <convar_class>

#include <shavit/replay-recorder>

#include <shavit/core>

#undef REQUIRE_PLUGIN
#include <shavit/replay-playback>
#include <shavit/zones>
#include <shavit/wr>

#include <shavit/replay-file>
#include <shavit/replay-stocks.sp>

#undef REQUIRE_EXTENSIONS
#include <srcwr/floppy>


public Plugin myinfo =
{
	name = "[shavit] Replay Recorder",
	author = "shavit, rtldg, KiD Fearless, Ciallo-Ani, BoomShotKapow",
	description = "A replay recorder for shavit's bhop timer.",
	version = SHAVIT_VERSION,
	url = "https://github.com/shavitush/bhoptimer"
}

enum struct finished_run_info
{
	int iSteamID;
	int style;
	float time;
	int jumps;
	int strafes;
	float sync;
	int track;
	float oldtime;
	float perfs;
	float avgvel;
	float maxvel;
	int timestamp;
	float fZoneOffset[2];
	int playerRank;
}

bool gB_Late = false;
char gS_Map[PLATFORM_MAX_PATH];
float gF_Tickrate = 0.0;

int gI_Styles = 0;
char gS_ReplayFolder[PLATFORM_MAX_PATH];

Convar gCV_Enabled = null;
Convar gCV_PlaybackPostRunTime = null;
Convar gCV_PlaybackPreRunTime = null;
Convar gCV_PreRunAlways = null;
Convar gCV_TimeLimit = null;
Convar gCV_TopN_Count = null;
Convar gCV_TopN_Tracks = null;
Convar gCV_TopN_Maps = null;

Handle gH_AddAdditionalReplayPathsHere = null;
Handle gH_OnReplaySaved = null;

bool gB_RecordingEnabled[MAXPLAYERS+1]; // just a simple thing to prevent plugin reloads from recording half-replays

// stuff related to postframes
finished_run_info gA_FinishedRunInfo[MAXPLAYERS+1];
bool gB_GrabbingPostFrames[MAXPLAYERS+1];
Handle gH_PostFramesTimer[MAXPLAYERS+1];
int gI_PlayerFinishFrame[MAXPLAYERS+1];

// we use gI_PlayerFrames instead of grabbing gA_PlayerFrames.Length because the ArrayList is resized to handle 2s worth of extra frames to reduce how often we have to resize it
int gI_PlayerFrames[MAXPLAYERS+1];
int gI_PlayerPrerunFrames[MAXPLAYERS+1];
ArrayList gA_PlayerFrames[MAXPLAYERS+1];

int gI_HijackFrames[MAXPLAYERS+1];
float gF_HijackedAngles[MAXPLAYERS+1][2];
bool gB_HijackFramesKeepOnStart[MAXPLAYERS+1];

bool gB_ReplayPlayback = false;
bool gB_Floppy = false;
ArrayList gA_PathsToSaveReplayTo = null;

//#include <TickRateControl>
forward void TickRate_OnTickRateChanged(float fOld, float fNew);
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("Shavit_GetClientFrameCount", Native_GetClientFrameCount);
	CreateNative("Shavit_GetPlayerPreFrames", Native_GetPlayerPreFrames);
	CreateNative("Shavit_GetReplayData", Native_GetReplayData);
	CreateNative("Shavit_HijackAngles", Native_HijackAngles);
	CreateNative("Shavit_SetReplayData", Native_SetReplayData);
	CreateNative("Shavit_SetPlayerPreFrames", Native_SetPlayerPreFrames);
	CreateNative("Shavit_AlsoSaveReplayTo", Native_AlsoSaveReplayTo);
	CreateNative("Shavit_AdditionalReplayPath", Native_AdditionalReplayPath);

	if (!FileExists("cfg/sourcemod/plugin.shavit-replay-recorder.cfg") && FileExists("cfg/sourcemod/plugin.shavit-replay.cfg"))
	{
		File source = OpenFile("cfg/sourcemod/plugin.shavit-replay.cfg", "r");
		File destination = OpenFile("cfg/sourcemod/plugin.shavit-replay-recorder.cfg", "w");
		if (source && destination)
		{
			char line[512];

			while (!source.EndOfFile() && source.ReadLine(line, sizeof(line)))
			{
				destination.WriteLine("%s", line);
			}
		}

		delete destination;
		delete source;
	}

	RegPluginLibrary("shavit-replay-recorder");

	gB_Late = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	gH_AddAdditionalReplayPathsHere = CreateGlobalForward("Shavit_AddAdditionalReplayPathsHere", ET_Ignore, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell);
	gH_OnReplaySaved = CreateGlobalForward("Shavit_OnReplaySaved", ET_Ignore, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_String);
	gCV_Enabled = new Convar("shavit_replay_recording_enabled", "1", "Enable replay bot functionality?", 0, true, 0.0, true, 1.0);
	gCV_PlaybackPostRunTime = new Convar("shavit_replay_postruntime", "1.5", "Time (in seconds) to record after a player enters the end zone.", 0, true, 0.0, true, 2.0);
	gCV_PreRunAlways = new Convar("shavit_replay_prerun_always", "1", "Record prerun frames outside the start zone?", 0, true, 0.0, true, 1.0);
	gCV_PlaybackPreRunTime = new Convar("shavit_replay_preruntime", "1.5", "Time (in seconds) to record before a player leaves start zone.", 0, true, 0.0, true, 2.0);
	gCV_TimeLimit = new Convar("shavit_replay_timelimit", "7200.0", "Maximum amount of time (in seconds) to allow saving to disk.\nDefault is 7200 (2 hours)\n0 - No limit (unlimited recording)", 0, true, 0.0);
	gCV_TopN_Count = new Convar("shavit_replay_topn_count", "1", "How many top replays to save per style/track combination (1-5). 保存每个风格/轨道组合的前N个录像(1-5).", 0, true, 1.0, true, 5.0);
	gCV_TopN_Tracks = new Convar("shavit_replay_topn_tracks", "", "Comma-separated list of track numbers for multi-replay (empty = all tracks). 多录像的轨道编号列表，用逗号分隔（空=所有轨道）.");
	gCV_TopN_Maps = new Convar("shavit_replay_topn_maps", "", "Comma-separated list of map name patterns for multi-replay (empty = all maps). 多录像的地图名称模式列表，用逗号分隔（空=所有地图）.");


	Convar.AutoExecConfig();
	gF_Tickrate = (1.0 / GetTickInterval());

	gB_ReplayPlayback = LibraryExists("shavit-replay-playback");
	gB_Floppy = LibraryExists("srcwr💾");

	if (gB_Late)
	{
		Shavit_OnStyleConfigLoaded(Shavit_GetStyleCount());
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsValidClient(i) && !IsFakeClient(i))
			{
				OnClientPutInServer(i);
			}
		}
	}
}

public void OnLibraryAdded(const char[] name)
{
	if( StrEqual(name, "shavit-replay-playback"))
	{
		gB_ReplayPlayback = true;
	}
	else if (StrEqual(name, "srcwr💾"))
	{
		gB_Floppy = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "shavit-replay-playback"))
	{
		gB_ReplayPlayback = false;
	}
	else if (StrEqual(name, "srcwr💾"))
	{
		gB_Floppy = false;
	}
}

public void OnMapStart()
{
	GetLowercaseMapName(gS_Map);
}

// Helper function to check if the current track qualifies for multi-replay
bool IsTopNEnabledForTrack(int track)
{
	char sTracksConfig[256];
	gCV_TopN_Tracks.GetString(sTracksConfig, sizeof(sTracksConfig));
	TrimString(sTracksConfig);
	// Empty string means all tracks are enabled
	if (strlen(sTracksConfig) == 0)
	{
		return true;
	}
	
	// Parse comma-separated track numbers
	char sTrackNumbers[16][8];
	int count = ExplodeString(sTracksConfig, ",", sTrackNumbers, sizeof(sTrackNumbers), sizeof(sTrackNumbers[]));
	
	for (int i = 0; i < count; i++)
	{
		TrimString(sTrackNumbers[i]);
		if (StringToInt(sTrackNumbers[i]) == track)
		{
			return true;
		}
	}
	
	return false;
}

// Helper function to check if the current map qualifies for multi-replay
bool IsTopNEnabledForMap()
{
	char sMapsConfig[512];
	gCV_TopN_Maps.GetString(sMapsConfig, sizeof(sMapsConfig));
	TrimString(sMapsConfig);
	
	// Empty string means all maps are enabled
	if (strlen(sMapsConfig) == 0)
	{
		return true;
	}
	
	// Parse comma-separated map patterns
	char sMapPatterns[16][64];
	int count = ExplodeString(sMapsConfig, ",", sMapPatterns, sizeof(sMapPatterns), sizeof(sMapPatterns[]));
	for (int i = 0; i < count; i++)
	{
		TrimString(sMapPatterns[i]);
		if (strlen(sMapPatterns[i]) > 0 && StrContains(gS_Map, sMapPatterns[i], false) != -1)
		{
			return true;
		}
	}
	
	return false;
}

// Get replay file path for a specific rank
void GetReplayPathForRank(int style, int track, int rank, char[] path, int maxlen)
{
	#pragma unused maxlen
	Shavit_GetReplayFilePathForRank(style, track, rank, gS_Map, gS_ReplayFolder, path);
}

// Check if a replay file exists for a specific rank
bool ReplayExistsForRank(int style, int track, int rank)
{
	char sPath[PLATFORM_MAX_PATH];
	GetReplayPathForRank(style, track, rank, sPath, sizeof(sPath));
	return FileExists(sPath);
}

// Delete replay file for a specific rank
void DeleteReplayForRank(int style, int track, int rank)
{
	char sPath[PLATFORM_MAX_PATH];
	GetReplayPathForRank(style, track, rank, sPath, sizeof(sPath));
	if (FileExists(sPath))
	{
		DeleteFile(sPath);
	}
}

// Find the correct file-based rank for a given time by scanning existing replay files
// 
// @param style      The bhop style ID
// @param track      The track ID (0 = main, 1+ = bonus)
// @param time       The run time to find a rank for
// @param topNCount  Maximum number of Top-N replay slots configured
// @return           Rank position (1 to topNCount) where this time should be saved,
//                   or topNCount+1 if the time doesn't qualify for Top-N (all slots have faster times)
//
// This function determines the file-based rank by:
// 1. Scanning replay files from rank 1 to topNCount
// 2. Finding the first empty slot (returns that rank)
// 3. Or finding the first replay with a slower time (returns that rank for insertion)
// 4. Or returning topNCount+1 if all slots are filled with faster times
int FindReplayFileRank(int style, int track, float time, int topNCount)
{
	for (int rank = 1; rank <= topNCount; rank++)
	{
		char path[PLATFORM_MAX_PATH];
		GetReplayPathForRank(style, track, rank, path, sizeof(path));
		
		if (!FileExists(path))
		{
			// Empty slot found, use it
			return rank;
		}
		
		// File exists, read its time from header
		replay_header_t header;
		File file = ReadReplayHeader(path, header, style, track);
		if (file == null)
		{
			// Failed to read header, treat as empty slot
			return rank;
		}
		
		delete file;
		// Compare times - if our time is faster, insert here
		if (time < header.fTime)
		{
			return rank;
		}
	}
	
	// All slots are filled with faster times, doesn't fit
	return topNCount + 1;
}

// Find the rank of an existing replay for the same SteamID
int FindExistingRankForSteamID(int style, int track, int steamid, int topNCount)
{
    for (int rank = 1; rank <= topNCount; rank++)
    {
        char path[PLATFORM_MAX_PATH];
        GetReplayPathForRank(style, track, rank, path, sizeof(path));
        
        if (!FileExists(path)) continue;
        
        replay_header_t header;
        File file = ReadReplayHeader(path, header, style, track);
        
        if (file == null) continue;
        
        delete file;
        
        if (header.iSteamID == steamid)
        {
            return rank;
        }
    }
    
    return 0; // not found
}

public void Shavit_OnStyleConfigLoaded(int styles)
{
	if (!Shavit_GetReplayFolderPath_Stock(gS_ReplayFolder))
	{
		SetFailState("Could not load the replay bots' configuration file. Make sure it exists (addons/sourcemod/configs/shavit-replay.cfg) and follows the proper syntax!");
	}

	gI_Styles = styles;

	Shavit_Replay_CreateDirectories(gS_ReplayFolder, gI_Styles);
}

public void OnClientPutInServer(int client)
{
	ClearFrames(client);
}

public void OnClientDisconnect(int client)
{
	gB_RecordingEnabled[client] = false;
	// reset a little state...

	if (gB_GrabbingPostFrames[client])
	{
		FinishGrabbingPostFrames(client, gA_FinishedRunInfo[client]);
	}
}

public void OnClientDisconnect_Post(int client)
{
	// This runs after shavit-misc has cloned the handle
	delete gA_PlayerFrames[client];
}

public void TickRate_OnTickRateChanged(float fOld, float fNew)
{
	gF_Tickrate = fNew;
}

void ClearFrames(int client)
{
	delete gA_PlayerFrames[client];
	gA_PlayerFrames[client] = new ArrayList(sizeof(frame_t));
	gI_PlayerFrames[client] = 0;
	gI_PlayerPrerunFrames[client] = 0;
	gI_PlayerFinishFrame[client] = 0;
	gI_HijackFrames[client] = 0;
	gB_HijackFramesKeepOnStart[client] = false;
}

public Action Shavit_OnStart(int client)
{
	gB_RecordingEnabled[client] = true;
	if (!gB_HijackFramesKeepOnStart[client])
	{
		gI_HijackFrames[client] = 0;
	}

	if (gB_GrabbingPostFrames[client])
	{
		FinishGrabbingPostFrames(client, gA_FinishedRunInfo[client]);
	}

	int iMaxPreFrames = RoundToFloor(gCV_PlaybackPreRunTime.FloatValue * gF_Tickrate / Shavit_GetStyleSettingFloat(Shavit_GetBhopStyle(client), "speed"));
	bool bInStart = Shavit_InsideZone(client, Zone_Start, Shavit_GetClientTrack(client));

	if (bInStart)
	{
		int iFrameDifference = gI_PlayerFrames[client] - iMaxPreFrames;
		if (iFrameDifference > 0)
		{
			// For too many extra frames, we'll just shift the preframes to the start of the array.
			if (iFrameDifference > 100)
			{
				for (int i = iFrameDifference; i < gI_PlayerFrames[client]; i++)
				{
					gA_PlayerFrames[client].SwapAt(i, i-iFrameDifference);
				}

				gI_PlayerFrames[client] = iMaxPreFrames;
			}
			else // iFrameDifference isn't that bad, just loop through and erase.
			{
				while (iFrameDifference--)
				{
					gA_PlayerFrames[client].Erase(0);
					gI_PlayerFrames[client]--;
				}
			}
		}
	}
	else
	{
		if (!gCV_PreRunAlways.BoolValue)
		{
			ClearFrames(client);
		}
	}

	gI_PlayerPrerunFrames[client] = gI_PlayerFrames[client];
	return Plugin_Continue;
}

public void Shavit_OnStop(int client)
{
	if (gB_GrabbingPostFrames[client])
	{
		FinishGrabbingPostFrames(client, gA_FinishedRunInfo[client]);
	}

	ClearFrames(client);
}

public Action Timer_PostFrames(Handle timer, int client)
{
	gH_PostFramesTimer[client] = null;
	FinishGrabbingPostFrames(client, gA_FinishedRunInfo[client]);
	return Plugin_Stop;
}

void FinishGrabbingPostFrames(int client, finished_run_info info)
{
	gB_GrabbingPostFrames[client] = false;
	delete gH_PostFramesTimer[client];
	DoReplaySaverCallbacks(info.iSteamID, client, info.style, info.time, info.jumps, info.strafes, info.sync, info.track, info.oldtime, info.perfs, info.avgvel, info.maxvel, info.timestamp, info.fZoneOffset, info.playerRank);
}

float ExistingWrReplayLength(int style, int track)
{
	if (gB_ReplayPlayback)
	{
		return Shavit_GetReplayLength(style, track);
	}

	char sPath[PLATFORM_MAX_PATH];
	Shavit_GetReplayFilePath(style, track, gS_Map, gS_ReplayFolder, sPath);

	replay_header_t header;
	File f = ReadReplayHeader(sPath, header, style, track);

	if (f != null)
	{
		delete f;
		return header.fTime;
	}

	return 0.0;
}

void DoReplaySaverCallbacks(int iSteamID, int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, float fZoneOffset[2], int playerRank)
{
	#pragma unused playerRank
	gA_PlayerFrames[client].Resize(gI_PlayerFrames[client]);
	bool isTooLong = (gCV_TimeLimit.FloatValue > 0.0 && time > gCV_TimeLimit.FloatValue);

	float length = ExistingWrReplayLength(style, track);
	bool isBestReplay = (length == 0.0 || time < length);

	delete gA_PathsToSaveReplayTo;
	ArrayList paths = gA_PathsToSaveReplayTo = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	bool makeReplay = (isBestReplay && !isTooLong);

	// Check if Top-N system is enabled for this track/map
	int topNCount = gCV_TopN_Count.IntValue;
	bool topNEnabled = (topNCount > 1 && IsTopNEnabledForTrack(track) && IsTopNEnabledForMap());
	
	// Calculate file-based rank if Top-N is enabled (to avoid duplicate scanning)
	// This determines where the replay should be saved based on existing replay files, not database rank
	// Note: fileRank will be between 1 and topNCount (fits in Top-N), or topNCount+1 (doesn't fit)
	//       If Top-N is disabled, fileRank remains 0 (unassigned/unused)
	int fileRank = 0;
	if (topNEnabled)
	{
		fileRank = FindReplayFileRank(style, track, time, topNCount);
		
		// Bug 2 Fix: Prevent same player from occupying multiple Top-N ranks
		int existingRank = FindExistingRankForSteamID(style, track, iSteamID, topNCount);
		if (existingRank > 0)
		{
			char existingPath[PLATFORM_MAX_PATH];
			GetReplayPathForRank(style, track, existingRank, existingPath, sizeof(existingPath));
			
			replay_header_t header;
			File file = ReadReplayHeader(existingPath, header, style, track);
			
			if (file != null)
			{
				delete file;
				
				if (time < header.fTime)
				{
					// New time is better, delete old replay
					DeleteReplayForRank(style, track, existingRank);
					// Re-calculate rank after removing old
					fileRank = FindReplayFileRank(style, track, time, topNCount);
				}
				else
				{
					// New time is not better, skip saving
					fileRank = 0;
				}
			}
		}
	}
	
	// playerRank was pre-calculated in Shavit_OnFinish before any DB writes
	// This ensures accurate ranking even when shavit-wr writes the new time to the database

	if (makeReplay)
	{
		// Handle Top-N replay shifting if enabled
		if (topNEnabled)
		{
			// Use the pre-calculated file-based rank to determine where to shift from
			// This ensures we shift based on actual file positions, not database ranks
			
			// Only shift if the new WR fits within Top-N (fileRank between 1 and topNCount)
			if (fileRank <= topNCount)
			{
				// Shift existing replays down (e.g., rank 3→4, rank 2→3)
				// Start from the bottom and work our way up to avoid overwriting
				for (int rank = topNCount; rank > fileRank; rank--)
				{
					if (ReplayExistsForRank(style, track, rank - 1))
					{
						char oldPath[PLATFORM_MAX_PATH], newPath[PLATFORM_MAX_PATH];
						GetReplayPathForRank(style, track, rank - 1, oldPath, sizeof(oldPath));
						GetReplayPathForRank(style, track, rank, newPath, sizeof(newPath));
						
						// Delete the target file if it exists
						if (FileExists(newPath))
						{
							DeleteFile(newPath);
						}
						
						// Rename (move) the file
						RenameFile(newPath, oldPath);
					}
				}
				
				// Delete any replays that exceed topNCount
				// Check a buffer of 5 additional ranks to clean up any orphaned replay files
				for (int rank = topNCount + 1; rank <= topNCount + 5; rank++)
				{
					DeleteReplayForRank(style, track, rank);
				}
			}
		}
		
		// Save the new WR replay (always at rank 1)
		char wrpath[PLATFORM_MAX_PATH];
		GetReplayPathForRank(style, track, 1, wrpath, sizeof(wrpath));
		paths.PushString(wrpath);
	}
	else if (topNEnabled && !isTooLong)
	{
		// Use the pre-calculated file-based rank to determine where this replay should be saved
		
		// Only save if it fits within Top-N (fileRank <= topNCount)
		// Skip if fileRank is 1 because that would be a WR (faster than all existing replays),
		// which is already handled by the makeReplay branch above
		if (fileRank > 1 && fileRank <= topNCount)
		{
			// Bug 3 Fix: Only save Top-N replay if player actually improved their PB
			// If oldtime > 0.0 && time >= oldtime, player didn't beat their PB, so skip saving
			// (Removed return to ensure forwards are called)
			if (oldtime > 0.0 && time >= oldtime)
			{
				// Player didn't beat their PB, don't save a new replay
				// Continue to allow forwards to be called
			}
			
			// This is not a WR, but it qualifies for Top-N
			// Shift replays down from the insertion point
			for (int rank = topNCount; rank > fileRank; rank--)
			{
				if (ReplayExistsForRank(style, track, rank - 1))
				{
					char oldPath[PLATFORM_MAX_PATH], newPath[PLATFORM_MAX_PATH];
					GetReplayPathForRank(style, track, rank - 1, oldPath, sizeof(oldPath));
					GetReplayPathForRank(style, track, rank, newPath, sizeof(newPath));
					
					if (FileExists(newPath))
					{
						DeleteFile(newPath);
					}
					
					RenameFile(newPath, oldPath);
				}
			}
			
			// Delete any replays that exceed topNCount
			// Check a buffer of 5 additional ranks to clean up any orphaned replay files
			for (int rank = topNCount + 1; rank <= topNCount + 5; rank++)
			{
				DeleteReplayForRank(style, track, rank);
			}
			
			// Save this replay at its file-based rank position
			char rankpath[PLATFORM_MAX_PATH];
			GetReplayPathForRank(style, track, fileRank, rankpath, sizeof(rankpath));
			paths.PushString(rankpath);
		}
	}

	Call_StartForward(gH_AddAdditionalReplayPathsHere);
	Call_PushCell(client);
	Call_PushCell(style);
	Call_PushCell(time);
	Call_PushCell(jumps);
	Call_PushCell(strafes);
	Call_PushCell(sync);
	Call_PushCell(track);
	Call_PushCell(oldtime);
	Call_PushCell(perfs);
	Call_PushCell(avgvel);
	Call_PushCell(maxvel);
	Call_PushCell(timestamp);
	Call_PushCell(isBestReplay);
	Call_PushCell(isTooLong);
	Call_Finish();

	gA_PathsToSaveReplayTo = null;

	if (paths.Length == 0)
	{
		// Call Shavit_OnReplaySaved with empty paths and empty playerrecording
		ArrayList emptyPaths = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
		ArrayList emptyRecording = new ArrayList(sizeof(frame_t));
		
		Call_StartForward(gH_OnReplaySaved);
		Call_PushCell(client);
		Call_PushCell(style);
		Call_PushCell(time);
		Call_PushCell(jumps);
		Call_PushCell(strafes);
		Call_PushCell(sync);
		Call_PushCell(track);
		Call_PushCell(oldtime);
		Call_PushCell(perfs);
		Call_PushCell(avgvel);
		Call_PushCell(maxvel);
		Call_PushCell(timestamp);
		Call_PushCell(isBestReplay);
		Call_PushCell(isTooLong);
		Call_PushCell(emptyPaths);
		Call_PushCell(emptyRecording);
		Call_PushCell(0); // preframes
		Call_PushCell(0); // postframes
		
		char sName[MAX_NAME_LENGTH];
		GetClientName(client, sName, sizeof(sName));
		ReplaceString(sName, MAX_NAME_LENGTH, "#", "?");
		Call_PushString(sName);
		Call_Finish();
		
		delete emptyPaths;
		delete emptyRecording;
		
		return;
	}

	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));
	ReplaceString(sName, MAX_NAME_LENGTH, "#", "?");

	int postframes = gI_PlayerFrames[client] - gI_PlayerFinishFrame[client];

	ArrayList playerrecording = view_as<ArrayList>(CloneHandle(gA_PlayerFrames[client]));
	DataPack dp = new DataPack();
	dp.WriteCell(GetClientSerial(client));
	dp.WriteCell(style);
	dp.WriteCell(time);
	dp.WriteCell(jumps);
	dp.WriteCell(strafes);
	dp.WriteCell(sync);
	dp.WriteCell(track);
	dp.WriteCell(oldtime);
	dp.WriteCell(perfs);
	dp.WriteCell(avgvel);
	dp.WriteCell(maxvel);
	dp.WriteCell(timestamp);
	dp.WriteCell(isBestReplay);
	dp.WriteCell(isTooLong);
	dp.WriteCell(paths);
	dp.WriteCell(playerrecording);
	dp.WriteCell(gI_PlayerPrerunFrames[client]);
	dp.WriteCell(postframes);
	dp.WriteString(sName);

	if (gB_Floppy)
	{
		char headerbuf[512];
		int headersize = WriteReplayHeaderToBuffer(headerbuf, style, track, time, iSteamID, gI_PlayerPrerunFrames[client], postframes, fZoneOffset, gI_PlayerFrames[client], gF_Tickrate, gS_Map);
		SRCWRFloppy_AsyncSaveReplay(
			  FloppyAsynchronouslySavedMyReplayWhichWasNiceOfThem
			, dp
			, paths
			, headerbuf
			, headersize
			, playerrecording
			, gI_PlayerFrames[client]
		);
	}
	else
	{
		bool saved = false;
		for (int i = 0, size = paths.Length; i < size; ++i)
		{
			char path[PLATFORM_MAX_PATH], tmp[PLATFORM_MAX_PATH];
			paths.GetString(i, path, sizeof(path));
			FormatEx(tmp, sizeof(tmp), "%s.tmp", path);

			if (SaveReplay(style, track, time, iSteamID, gI_PlayerPrerunFrames[client], playerrecording, gI_PlayerFrames[client], postframes, fZoneOffset, tmp))
			{
				saved = true;
				RenameFile(path, tmp);
			}
		}

		FloppyAsynchronouslySavedMyReplayWhichWasNiceOfThem(saved, dp)
	}

	ClearFrames(client);
}

void FloppyAsynchronouslySavedMyReplayWhichWasNiceOfThem(bool saved, any value)
{
	DataPack dp = value;
	dp.Reset();

	int client = GetClientFromSerial(dp.ReadCell());
	int style = dp.ReadCell();
	float time = dp.ReadCell();
	int jumps = dp.ReadCell();
	int strafes = dp.ReadCell();
	float sync = dp.ReadCell();
	int track = dp.ReadCell();
	float oldtime = dp.ReadCell();
	float perfs  = dp.ReadCell();
	float avgvel = dp.ReadCell();
	float maxvel = dp.ReadCell();
	int timestamp = dp.ReadCell();
	bool isBestReplay = dp.ReadCell();
	bool isTooLong = dp.ReadCell();
	ArrayList paths = dp.ReadCell();
	ArrayList playerrecording = dp.ReadCell();
	int preframes = dp.ReadCell();
	int postframes = dp.ReadCell();
	char sName[MAX_NAME_LENGTH];
	dp.ReadString(sName, sizeof(sName));

	if (!saved)
	{
		LogError("Failed to save replay... Skipping OnReplaySaved");
		delete playerrecording; // importante!
		return;
	}

	Call_StartForward(gH_OnReplaySaved);
	Call_PushCell(client);
	Call_PushCell(style);
	Call_PushCell(time);
	Call_PushCell(jumps);
	Call_PushCell(strafes);
	Call_PushCell(sync);
	Call_PushCell(track);
	Call_PushCell(oldtime);
	Call_PushCell(perfs);
	Call_PushCell(avgvel);
	Call_PushCell(maxvel);
	Call_PushCell(timestamp);
	Call_PushCell(isBestReplay);
	Call_PushCell(isTooLong);
	Call_PushCell(paths);
	Call_PushCell(playerrecording);
	Call_PushCell(preframes);
	Call_PushCell(postframes);
	Call_PushString(sName);
	Call_Finish();

	delete playerrecording;
}

public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp)
{
	if (Shavit_IsPracticeMode(client) || !gCV_Enabled.BoolValue || (gI_PlayerFrames[client]-gI_PlayerPrerunFrames[client] <= 10))
	{
		return;
	}

	// Someone using checkpoints presumably
	if (gB_GrabbingPostFrames[client])
	{
		FinishGrabbingPostFrames(client, gA_FinishedRunInfo[client]);
	}

	gI_PlayerFinishFrame[client] = gI_PlayerFrames[client];

	float fZoneOffset[2];
	fZoneOffset[0] = Shavit_GetZoneOffset(client, 0);
	fZoneOffset[1] = Shavit_GetZoneOffset(client, 1);
	// Calculate player rank BEFORE any database writes to get accurate ranking
	// This is needed because shavit-wr may write the new time to DB, affecting rank calculation
	// We always calculate the rank here so it's available for both WR and Top-N replay logic
	int playerRank = Shavit_GetRankForTime(style, time, track);
	int topNCount = gCV_TopN_Count.IntValue;

	if (gCV_PlaybackPostRunTime.FloatValue > 0.0)
	{
		finished_run_info info;
		info.iSteamID = GetSteamAccountID(client);
		info.style = style;
		info.time = time;
		info.jumps = jumps;
		info.strafes = strafes;
		info.sync = sync;
		info.track = track;
		info.oldtime = oldtime;
		info.perfs = perfs;
		info.avgvel = avgvel;
		info.maxvel = maxvel;
		info.timestamp = timestamp;
		info.fZoneOffset = fZoneOffset;
		info.playerRank = playerRank;

		gA_FinishedRunInfo[client] = info;
		gB_GrabbingPostFrames[client] = true;
		delete gH_PostFramesTimer[client];
		gH_PostFramesTimer[client] = CreateTimer(gCV_PlaybackPostRunTime.FloatValue, Timer_PostFrames, client, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		DoReplaySaverCallbacks(GetSteamAccountID(client), client, style, time, jumps, strafes, sync, track, oldtime, perfs, avgvel, maxvel, timestamp, fZoneOffset, playerRank);
	}
}

bool SaveReplay(int style, int track, float time, int steamid, int preframes, ArrayList playerrecording, int iSize, int postframes, float fZoneOffset[2], const char[] sPath)
{
	File fReplay = null;
	if (!(fReplay = OpenFile(sPath, "wb+"))) {
		LogError("Failed to open replay file for writing. ('%s')", sPath);
		return false;
	}

	WriteReplayHeader(fReplay, style, track, time, steamid, preframes, postframes, fZoneOffset, iSize, gF_Tickrate, gS_Map);
	WriteReplayFrames(playerrecording, iSize, fReplay);

	delete fReplay;
	return true;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	static bool resizeFailed[MAXPLAYERS+1];
	if (resizeFailed[client]) // rip
	{
		resizeFailed[client] = false;
		gB_RecordingEnabled[client] = false;
		ClearFrames(client);
		LogError("failed to resize frames for %N... clearing frames I guess...", client);
		return;
	}

	if (IsFakeClient(client) || !IsPlayerAlive(client))
	{
		return;
	}

	if (!gA_PlayerFrames[client] || !gB_RecordingEnabled[client])
	{
		return;
	}

	if (!gB_GrabbingPostFrames[client] && !(Shavit_ReplayEnabledStyle(Shavit_GetBhopStyle(client)) && Shavit_GetTimerStatus(client) == Timer_Running))
	{
		return;
	}

	if (gCV_TimeLimit.FloatValue > 0.0 && (gI_PlayerFrames[client] / gF_Tickrate) > gCV_TimeLimit.FloatValue)
	{
		if (gI_HijackFrames[client])
		{
			gI_HijackFrames[client] = 0;
		}

		return;
	}

	if (!Shavit_ShouldProcessFrame(client))
	{
		return;
	}

	if (gA_PlayerFrames[client].Length <= gI_PlayerFrames[client])
	{
		resizeFailed[client] = true;
		// Add about two seconds worth of frames so we don't have to resize so often
		gA_PlayerFrames[client].Resize(gI_PlayerFrames[client] + (RoundToCeil(gF_Tickrate) * 2));
		//PrintToChat(client, "resizing %d -> %d", gI_PlayerFrames[client], gA_PlayerFrames[client].Length);
		resizeFailed[client] = false;
	}

	frame_t aFrame;
	GetClientAbsOrigin(client, aFrame.pos);

	if (!gI_HijackFrames[client])
	{
		float vecEyes[3];
		GetClientEyeAngles(client, vecEyes);
		aFrame.ang[0] = vecEyes[0];
		aFrame.ang[1] = vecEyes[1];
	}
	else
	{
		aFrame.ang = gF_HijackedAngles[client];
		--gI_HijackFrames[client];
	}

	aFrame.buttons = buttons;
	aFrame.flags = GetEntityFlags(client);
	aFrame.mt = GetEntityMoveType(client);
	aFrame.mousexy = (mouse[0] & 0xFFFF) | ((mouse[1] & 0xFFFF) << 16);
	aFrame.vel = LimitMoveVelFloat(vel[0]) | (LimitMoveVelFloat(vel[1]) << 16);
	gA_PlayerFrames[client].SetArray(gI_PlayerFrames[client]++, aFrame, sizeof(frame_t));
}

stock int LimitMoveVelFloat(float vel)
{
	int x = RoundToCeil(vel);
	return ((x < -666) ? -666 : ((x > 666) ? 666 : x)) & 0xFFFF;
}

public int Native_GetClientFrameCount(Handle handler, int numParams)
{
	return gI_PlayerFrames[GetNativeCell(1)];
}

public int Native_GetPlayerPreFrames(Handle handler, int numParams)
{
	return gI_PlayerPrerunFrames[GetNativeCell(1)];
}

public int Native_SetPlayerPreFrames(Handle handler, int numParams)
{
	int client = GetNativeCell(1);
	int preframes = GetNativeCell(2);

	gI_PlayerPrerunFrames[client] = preframes;
	return 1;
}

public int Native_AlsoSaveReplayTo(Handle plugin, int numParams)
{
	if (gA_PathsToSaveReplayTo)
	{
		char path[PLATFORM_MAX_PATH];
		GetNativeString(1, path, sizeof(path));
		gA_PathsToSaveReplayTo.PushString(path);
	}
	return 0;
// native has void return so this value doesn't matter.
}

public int Native_GetReplayData(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	bool cheapCloneHandle = view_as<bool>(GetNativeCell(2));
	Handle cloned = null;

	if(gA_PlayerFrames[client] != null)
	{
		ArrayList frames = cheapCloneHandle ? gA_PlayerFrames[client] : gA_PlayerFrames[client].Clone();
		frames.Resize(gI_PlayerFrames[client]);
		cloned = CloneHandle(frames, plugin); // set the calling plugin as the handle owner

		if (!cheapCloneHandle)
		{
			// Only hit for .Clone()'d handles.Clone() != CloneHandle()
			CloseHandle(frames);
		}
	}

	return view_as<int>(cloned);
}

public int Native_SetReplayData(Handle handler, int numParams)
{
	int client = GetNativeCell(1);
	ArrayList data = view_as<ArrayList>(GetNativeCell(2));
	bool cheapCloneHandle = view_as<bool>(GetNativeCell(3));

	if (gB_GrabbingPostFrames[client])
	{
		FinishGrabbingPostFrames(client, gA_FinishedRunInfo[client]);
	}

	// Player starts run, reconnects, savestate reloads, and this needs to be true...
	gB_RecordingEnabled[client] = true;
	if (cheapCloneHandle)
	{
		data = view_as<ArrayList>(CloneHandle(data));
	}
	else
	{
		data = data.Clone();
	}

	delete gA_PlayerFrames[client];
	gA_PlayerFrames[client] = data;
	gI_PlayerFrames[client] = data.Length;
	return 1;
}

public int Native_HijackAngles(Handle handler, int numParams)
{
	int client = GetNativeCell(1);

	gF_HijackedAngles[client][0] = view_as<float>(GetNativeCell(2));
	gF_HijackedAngles[client][1] = view_as<float>(GetNativeCell(3));

	int ticks = GetNativeCell(4);
	if (ticks == -1)
	{
		float latency = GetClientLatency(client, NetFlow_Both);

		if (latency > 0.0)
		{
			ticks = RoundToCeil(latency / GetTickInterval()) + 1;
			//PrintToChat(client, "%f %f %d", latency, GetTickInterval(), ticks);
			gI_HijackFrames[client] = ticks;
		}
	}
	else
	{
		gI_HijackFrames[client] = ticks;
	}

	gB_HijackFramesKeepOnStart[client] = (numParams < 5) ?
	false : view_as<bool>(GetNativeCell(5));
	return ticks;
}

public int Native_AdditionalReplayPath(Handle plugin, int numParams)
{
    if (gA_PathsToSaveReplayTo == null)
    {
        return 0;
    }
    
    char path[PLATFORM_MAX_PATH];
    GetNativeString(1, path, sizeof(path));
    gA_PathsToSaveReplayTo.PushString(path);
    return 0;
}
