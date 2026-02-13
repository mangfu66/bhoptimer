/*
 * shavit's Timer - HUD
 * by: shavit, strafe, KiD Fearless, rtldg, Technoblazed, Nairda, Nuko, GAMMA CASE
 *
 * This file is part of shavit's Timer (https://github.com/shavitush/bhoptimer)
 *
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <convar_class>
#include <dhooks>

#include <shavit/core>
#include <shavit/hud>

#include <shavit/weapon-stocks>

#undef REQUIRE_PLUGIN
#include <shavit/rankings>
#include <shavit/replay-playback>
#include <shavit/wr>
#include <shavit/zones>
#include <DynamicChannels>

#undef REQUIRE_EXTENSIONS
#include <cstrike>
#include <modern-landfix>

#pragma newdecls required
#pragma semicolon 1

#define MAX_HINT_SIZE 1024
#define HUD_PRINTCENTER 4

// =============================================================================
// NEW: Custom Color System & WR Name Cache
// =============================================================================
enum HUDColorElement {
	Color_Zone = 0,    // Zone Enter/Leave Text
	Color_MapTier,     // Tier Text
	Color_Time,        // Main Time
	Color_Speed,       // Main Speed
	Color_Jumps,       // Jumps Count
	Color_Strafes,     // Strafes Count
	Color_Sync,        // Sync Percent
	Color_PB,          // Personal Best
	Color_WR,          // World Record
	Color_Rank,        // Rank (#123)
	Color_Track,       // Track Name (Bonus/Main)
	HUD_COLOR_COUNT
}

// Names for the menu
char gS_ColorElementNames[HUD_COLOR_COUNT][] = {
	"区域提示 (Zone)",
	"地图难度 (Tier)",
	"时间 (Time)",
	"速度 (Speed)",
	"跳跃数 (Jumps)",
	"平移数 (Strafes)",
	"同步率 (Sync)",
	"个人纪录 (PB)",
	"世界纪录 (WR)",
	"当前排名 (Rank)",
	"赛道名称 (Track)"
};

// Preset colors for the menu
enum struct ColorPreset {
	char name[32];
	int color;
}

ColorPreset g_Presets[] = {
	{"默认 (Default)", -1},
	{"白色 (White)", 0xFFFFFF},
	{"红色 (Red)", 0xFF0000},
	{"绿色 (Green)", 0x00FF00},
	{"蓝色 (Blue)", 0x00BFFF}, // Deep Sky Blue
	{"黄色 (Yellow)", 0xFFFF00},
	{"紫色 (Purple)", 0x9932CC}, // Dark Orchid
	{"青色 (Cyan)", 0x00FFFF},
	{"橙色 (Orange)", 0xFFA500},
	{"粉色 (Pink)", 0xFF69B4},
	{"灰色 (Grey)", 0xCCCCCC}
};

// Storage: -1 means default, otherwise HEX
int gI_HUDColors[MAXPLAYERS+1][HUD_COLOR_COUNT];
Handle gH_Cookie_HUDColors = null;

// =============================================================================
// NEW: WR/PB Tri-state & Font Size
// =============================================================================
enum WrPbState {
	WrPb_Hidden = 0,
	WrPb_TopLeft,
	WrPb_Bottom,
	WrPb_Both // Added "Both" state
};

WrPbState gI_WrPbState[MAXPLAYERS+1];
int gI_HudFontSize[MAXPLAYERS+1];

Handle gH_Cookie_WrPbState = null;
Handle gH_Cookie_HudFontSize = null;

#define DEFAULT_FONT_SIZE 14

// =============================================================================
// NEW: SQL WR Name Caching (To fix !wr name vs replay bot name)
// =============================================================================
Database gH_SQL = null;
StringMap gSM_WRNames = null;
char gS_CurrentMap[PLATFORM_MAX_PATH];
char gS_MySQLPrefix[32]; // [FIX] Added prefix variable

// =============================================================================

enum struct color_t
{
	int r;
	int g;
	int b;
}

// game type (CS:S/CS:GO/TF2)
EngineVersion gEV_Type = Engine_Unknown;

UserMsg gI_HintText = view_as<UserMsg>(-1);
UserMsg gI_TextMsg = view_as<UserMsg>(-1);

// forwards
Handle gH_Forwards_OnTopLeftHUD = null;
Handle gH_Forwards_PreOnTopLeftHUD = null;
Handle gH_Forwards_OnKeyHintHUD = null;
Handle gH_Forwards_PreOnKeyHintHUD = null;
Handle gH_Forwards_PreOnDrawCenterHUD = null;
Handle gH_Forwards_PreOnDrawKeysHUD = null;

// modules
bool gB_ReplayPlayback = false;
bool gB_Zones = false;
bool gB_Sounds = false;
bool gB_Rankings = false;
bool gB_DynamicChannels = false;
bool gB_WR = false; // 新增：检查 shavit-wr 是否存在

// cache
int gI_Cycle = 0;
color_t gI_Gradient;
int gI_GradientDirection = -1;
int gI_Styles = 0;

Handle gH_HUDCookie = null;
Handle gH_HUDCookieMain = null;
int gI_HUDSettings[MAXPLAYERS+1];
int gI_HUD2Settings[MAXPLAYERS+1];
int gI_LastScrollCount[MAXPLAYERS+1];
int gI_ScrollCount[MAXPLAYERS+1];
int gI_Buttons[MAXPLAYERS+1];
float gF_ConnectTime[MAXPLAYERS+1];
bool gB_FirstPrint[MAXPLAYERS+1];
int gI_PreviousSpeed[MAXPLAYERS+1];
int gI_ZoneSpeedLimit[MAXPLAYERS+1];
float gF_Angle[MAXPLAYERS+1];
float gF_PreviousAngle[MAXPLAYERS+1];
float gF_AngleDiff[MAXPLAYERS+1];

bool gB_Late = false;
char gS_HintPadding[MAX_HINT_SIZE];
bool gB_AlternateCenterKeys[MAXPLAYERS+1]; // use for css linux gamers

// hud handle
Handle gH_HUDTopleft = null;
Handle gH_HUDCenter = null;

// plugin convars
Convar gCV_GradientStepSize = null;
Convar gCV_TicksPerUpdate = null;
Convar gCV_SpectatorList = null;
Convar gCV_UseHUDFix = null;
Convar gCV_SpecNameSymbolLength = null;
Convar gCV_BlockYouHaveSpottedHint = null;
Convar gCV_DefaultHUD = null;
Convar gCV_DefaultHUD2 = null;

// timer settings
stylestrings_t gS_StyleStrings[STYLE_LIMIT];
chatstrings_t gS_ChatStrings;

public Plugin myinfo =
{
	name = "[shavit] HUD",
	author = "shavit, strafe, KiD Fearless, rtldg, Technoblazed, Nairda, Nuko, GAMMA CASE",
	description = "HUD for shavit's bhop timer.",
	version = SHAVIT_VERSION,
	url = "https://github.com/shavitush/bhoptimer"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// forwards
	gH_Forwards_OnTopLeftHUD = CreateGlobalForward("Shavit_OnTopLeftHUD", ET_Event, Param_Cell, Param_Cell, Param_String, Param_Cell, Param_Cell, Param_Cell);
	gH_Forwards_PreOnTopLeftHUD = CreateGlobalForward("Shavit_PreOnTopLeftHUD", ET_Event, Param_Cell, Param_Cell, Param_String, Param_Cell, Param_Cell, Param_Cell, Param_CellByRef);
	gH_Forwards_OnKeyHintHUD = CreateGlobalForward("Shavit_OnKeyHintHUD", ET_Event, Param_Cell, Param_Cell, Param_String, Param_Cell, Param_Cell, Param_Cell);
	gH_Forwards_PreOnKeyHintHUD = CreateGlobalForward("Shavit_PreOnKeyHintHUD", ET_Event, Param_Cell, Param_Cell, Param_String, Param_Cell, Param_Cell, Param_Cell, Param_CellByRef);
	gH_Forwards_PreOnDrawCenterHUD = CreateGlobalForward("Shavit_PreOnDrawCenterHUD", ET_Event, Param_Cell, Param_Cell, Param_String, Param_Cell, Param_Array);
	gH_Forwards_PreOnDrawKeysHUD = CreateGlobalForward("Shavit_PreOnDrawKeysHUD", ET_Event, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_String, Param_Cell, Param_Cell, Param_Cell, Param_Cell);

	// natives
	CreateNative("Shavit_ForceHUDUpdate", Native_ForceHUDUpdate);
	CreateNative("Shavit_GetHUDSettings", Native_GetHUDSettings);
	CreateNative("Shavit_GetHUD2Settings", Native_GetHUD2Settings);

	// registers library, check "bool LibraryExists(const char[] name)" in order to use with other plugins
	RegPluginLibrary("shavit-hud");

	gB_Late = late;

	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("shavit-common.phrases");
	LoadTranslations("shavit-hud.phrases");
	
	// Init WR Name Cache
	gSM_WRNames = new StringMap();
	GetTimerSQLPrefix(gS_MySQLPrefix, sizeof(gS_MySQLPrefix)); // [FIX] Get DB Prefix

	// game-specific
	gEV_Type = GetEngineVersion();

	gI_HintText = GetUserMessageId("HintText");
	gI_TextMsg = GetUserMessageId("TextMsg");

	if(gEV_Type == Engine_TF2)
	{
		HookEvent("player_changeclass", Player_ChangeClass);
		HookEvent("player_team", Player_ChangeClass);
		HookEvent("teamplay_round_start", Teamplay_Round_Start);
	}
	else if (gEV_Type == Engine_CSS)
	{
		HookUserMessage(gI_HintText, Hook_HintText, true);
	}

	gB_ReplayPlayback = LibraryExists("shavit-replay-playback");
	gB_Zones = LibraryExists("shavit-zones");
	gB_Sounds = LibraryExists("shavit-sounds");
	gB_Rankings = LibraryExists("shavit-rankings");
	gB_DynamicChannels = LibraryExists("DynamicChannels");
	gB_WR = LibraryExists("shavit-wr"); // 检查排名插件

	// HUD handle
	gH_HUDTopleft = CreateHudSynchronizer();
	gH_HUDCenter = CreateHudSynchronizer();

	// plugin convars
	gCV_GradientStepSize = new Convar("shavit_hud_gradientstepsize", "15", "How fast should the start/end HUD gradient be?\nThe number is the amount of color change per 0.1 seconds.\nThe higher the number the faster the gradient.", 0, true, 1.0, true, 255.0);
	gCV_TicksPerUpdate = new Convar("shavit_hud_ticksperupdate", "5", "How often (in ticks) should the HUD update?\nPlay around with this value until you find the best for your server.\nThe maximum value is your tickrate.\nNote: You should probably avoid 1-2 on CSS since players will probably feel stuttery FPS due to all the usermessages.", 0, true, 1.0, true, (1.0 / GetTickInterval()));
	gCV_SpectatorList = new Convar("shavit_hud_speclist", "1", "Who to show in the specators list?\n0 - everyone\n1 - all admins (admin_speclisthide override to bypass)\n2 - players you can target", 0, true, 0.0, true, 2.0);
	gCV_UseHUDFix = new Convar("shavit_hud_csgofix", "1", "Apply the csgo color fix to the center hud?\nThis will add a dollar sign and block sourcemod hooks to hint message", 0, true, 0.0, true, 1.0);
	gCV_SpecNameSymbolLength = new Convar("shavit_hud_specnamesymbollength", "32", "Maximum player name length that should be displayed in spectators panel", 0, true, 0.0, true, float(MAX_NAME_LENGTH));
	gCV_BlockYouHaveSpottedHint = new Convar("shavit_hud_block_spotted_hint", "1", "Blocks the hint message for spotting an enemy or friendly (which covers the center HUD)", 0, true, 0.0, true, 1.0);

	char defaultHUD[8];
	IntToString(HUD_DEFAULT, defaultHUD, 8);
	gCV_DefaultHUD = new Convar("shavit_hud_default", defaultHUD, "Default HUD settings as a bitflag\n"
		..."HUD_MASTER				1\n"
		..."HUD_CENTER				2\n"
		..."HUD_ZONEHUD				4\n"
		..."HUD_OBSERVE				8\n"
		..."HUD_SPECTATORS			16\n"
		..."HUD_KEYOVERLAY			32\n"
		..."HUD_HIDEWEAPON			64\n"
		..."HUD_TOPLEFT				128\n"
		..."HUD_SYNC				256\n"
		..."HUD_TIMELEFT			512\n"
		..."HUD_2DVEL				1024\n"
		..."HUD_NOSOUNDS			2048\n"
		..."HUD_NOPRACALERT			4096\n"
		..."HUD_USP                  8192\n"
		..."HUD_GLOCK                16384\n"
		..."HUD_DEBUGTARGETNAME      32768\n"
		..."HUD_SPECTATORSDEAD       65536\n"
		..."HUD_PERFS_CENTER        131072\n"
	);

	IntToString(HUD_DEFAULT2, defaultHUD, 8);
	gCV_DefaultHUD2 = new Convar("shavit_hud2_default", defaultHUD, "Default HUD2 settings as a bitflag of what to remove\n"
		..."HUD2_TIME				1\n"
		..."HUD2_SPEED				2\n"
		..."HUD2_JUMPS				4\n"
		..."HUD2_STRAFE				8\n"
		..."HUD2_SYNC				16\n"
		..."HUD2_STYLE				32\n"
		..."HUD2_RANK				64\n"
		..."HUD2_TRACK				128\n"
		..."HUD2_SPLITPB			256\n"
		..."HUD2_MAPTIER			512\n"
		..."HUD2_TIMEDIFFERENCE			1024\n"
		..."HUD2_PERFS				2048\n"
		..."HUD2_TOPLEFT_RANK			4096\n"
		..."HUD2_VELOCITYDIFFERENCE		8192\n"
		..."HUD2_USPSILENCER			16384\n"
		..."HUD2_GLOCKBURST			32768\n"
		..."HUD2_CENTERKEYS			65536\n"
		..."HUD2_LANDFIX			1073741824\n"
	);

	Convar.AutoExecConfig();

	for (int i = 0; i < sizeof(gS_HintPadding) - 1; i++)
	{
		gS_HintPadding[i] = '\n';
	}

	// commands
	RegConsoleCmd("sm_hud", Command_HUD, "Opens the HUD settings menu.");
	RegConsoleCmd("sm_options", Command_HUD, "Opens the HUD settings menu. (alias for sm_hud)");

	// hud togglers
	RegConsoleCmd("sm_keys", Command_Keys, "Toggles key display.");
	RegConsoleCmd("sm_showkeys", Command_Keys, "Toggles key display. (alias for sm_keys)");
	RegConsoleCmd("sm_showmykeys", Command_Keys, "Toggles key display. (alias for sm_keys)");

	RegConsoleCmd("sm_master", Command_Master, "Toggles HUD.");
	RegConsoleCmd("sm_masterhud", Command_Master, "Toggles HUD. (alias for sm_master)");

	RegConsoleCmd("sm_center", Command_Center, "Toggles center text HUD.");
	RegConsoleCmd("sm_centerhud", Command_Center, "Toggles center text HUD. (alias for sm_center)");

	RegConsoleCmd("sm_zonehud", Command_ZoneHUD, "Toggles zone HUD.");

	RegConsoleCmd("sm_hideweapon", Command_HideWeapon, "Toggles weapon hiding.");
	RegConsoleCmd("sm_hideweap", Command_HideWeapon, "Toggles weapon hiding. (alias for sm_hideweapon)");
	RegConsoleCmd("sm_hideweps", Command_HideWeapon, "Toggles weapon hiding. (alias for sm_hideweapon)");
	RegConsoleCmd("sm_hidewep", Command_HideWeapon, "Toggles weapon hiding. (alias for sm_hideweapon)");

	RegConsoleCmd("sm_truevel", Command_TrueVel, "Toggles 2D ('true') velocity.");
	RegConsoleCmd("sm_truvel", Command_TrueVel, "Toggles 2D ('true') velocity. (alias for sm_truevel)");
	RegConsoleCmd("sm_2dvel", Command_TrueVel, "Toggles 2D ('true') velocity. (alias for sm_truevel)");

	AddCommandListener(Command_SpecNextPrev, "spec_player");
	AddCommandListener(Command_SpecNextPrev, "spec_next");
	AddCommandListener(Command_SpecNextPrev, "spec_prev");

	// cookies
	gH_HUDCookie = RegClientCookie("shavit_hud_setting", "HUD settings", CookieAccess_Protected);
	gH_HUDCookieMain = RegClientCookie("shavit_hud_settingmain", "HUD settings for hint text.", CookieAccess_Protected);
	
	// NEW: Color Cookie
	gH_Cookie_HUDColors = RegClientCookie("shavit_hud_colors", "Custom HUD Colors", CookieAccess_Protected);
	
	// NEW: Settings Cookies
	gH_Cookie_WrPbState = RegClientCookie("shavit_hud_wrpb", "WR/PB Position", CookieAccess_Protected);
	gH_Cookie_HudFontSize = RegClientCookie("shavit_hud_fontsize", "HUD Font Size", CookieAccess_Protected);

	HookEvent("player_spawn", Player_Spawn);

	// Initialize arrays to prevent undefined behavior
	for (int i = 0; i <= MaxClients; i++)
	{
		gI_ZoneSpeedLimit[i] = 0;
		gF_ConnectTime[i] = 0.0;
	}
	
	if(gB_Late)
	{
		Shavit_OnStyleConfigLoaded(Shavit_GetStyleCount());
		Shavit_OnChatConfigLoaded();

		for(int i = 1; i <= MaxClients; i++)
		{
			if(IsValidClient(i))
			{
				OnClientPutInServer(i);

				if(AreClientCookiesCached(i) && !IsFakeClient(i))
				{
					OnClientCookiesCached(i);
				}
			}
		}
	}
	
	// DB Connect (Fix for missing Shavit_GetDb)
	// We connect to "shavit" conf which is the standard
	Database.Connect(SQL_ConnectCallback, "shavit");
}

public void OnPluginEnd()
{
	// Clean up resources to prevent memory leaks
	delete gSM_WRNames;
}

// SQL Caching Implementation
public void SQL_ConnectCallback(Database db, const char[] error, any data)
{
	if (db == null)
	{
		LogError("Could not connect to database: %s", error);
		return;
	}
	gH_SQL = db;
	
	gH_SQL.SetCharset("utf8mb4"); 
	
	// Re-fetch current map stuff now that DB is ready
	// [FIX] Ensure map name matches DB (lowercase, no workshop path)
	GetCurrentMap(gS_CurrentMap, sizeof(gS_CurrentMap));
	GetMapDisplayName(gS_CurrentMap, gS_CurrentMap, sizeof(gS_CurrentMap));
	int len = strlen(gS_CurrentMap);
	for(int i=0;i<len;i++) if(IsCharUpper(gS_CurrentMap[i])) gS_CurrentMap[i] = CharToLower(gS_CurrentMap[i]);

	if(gSM_WRNames != null)
	{
		gSM_WRNames.Clear();
	}
}

public void OnMapStart()
{
	// [FIX] Ensure map name matches DB
	GetCurrentMap(gS_CurrentMap, sizeof(gS_CurrentMap));
	GetMapDisplayName(gS_CurrentMap, gS_CurrentMap, sizeof(gS_CurrentMap));
	int len = strlen(gS_CurrentMap);
	for(int i=0;i<len;i++) if(IsCharUpper(gS_CurrentMap[i])) gS_CurrentMap[i] = CharToLower(gS_CurrentMap[i]);

	if(gSM_WRNames != null)
	{
		gSM_WRNames.Clear();
	}
}

public void Shavit_OnWorldRecord(int client, int style, float time, int jumps, int strafes, float sync, int track)
{
	if (gSM_WRNames != null)
	{
		char sKey[32];
		Format(sKey, sizeof(sKey), "%d_%d", style, track);
		
		char sName[MAX_NAME_LENGTH];
		GetClientName(client, sName, sizeof(sName));
		
		gSM_WRNames.SetString(sKey, sName);
	}
}

void GetCachedWRName(int style, int track, char[] buffer, int maxlen)
{
	char sKey[32];
	Format(sKey, sizeof(sKey), "%d_%d", style, track);
	
	if (!gSM_WRNames.GetString(sKey, buffer, maxlen))
	{
		// FIX: If DB is not ready, return empty string so we don't show "Loading..." forever.
		if (gH_SQL == null)
		{
			buffer[0] = '\0';
			return;
		}
		
		// If DB is ready, set temporary loading to debounce queries
		strcopy(buffer, maxlen, "Loading...");
		gSM_WRNames.SetString(sKey, "Loading...");
		
		// [FIX] Updated SQL query to JOIN with users table to get the name
		char sEscapedMap[PLATFORM_MAX_PATH*2+1];
		gH_SQL.Escape(gS_CurrentMap, sEscapedMap, sizeof(sEscapedMap));
		
		char query[512];
		Format(query, sizeof(query), "SELECT u.name FROM %splayertimes p JOIN %susers u ON p.auth = u.auth WHERE p.style = %d AND p.track = %d AND p.map = '%s' ORDER BY p.time ASC LIMIT 1", gS_MySQLPrefix, gS_MySQLPrefix, style, track, sEscapedMap);
		
		DataPack pack = new DataPack();
		pack.WriteCell(style);
		pack.WriteCell(track);
		gH_SQL.Query(SQL_FetchWRNameCallback, query, pack);
	}
	else if (StrEqual(buffer, "N/A"))
	{
		// If cached as "N/A", just return empty string to avoid ugly text
		buffer[0] = '\0';
	}
}

public void SQL_FetchWRNameCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	pack.Reset();
	int style = pack.ReadCell();
	int track = pack.ReadCell();
	delete pack;

	char sKey[32];
	Format(sKey, sizeof(sKey), "%d_%d", style, track);

	if (results != null && results.FetchRow())
	{
		char sName[MAX_NAME_LENGTH];
		results.FetchString(0, sName, sizeof(sName));
		gSM_WRNames.SetString(sKey, sName);
	}
	else
	{
		// No record found, cache N/A
		gSM_WRNames.SetString(sKey, "N/A");
	}
}
// End SQL Caching

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "shavit-replay-playback"))
	{
		gB_ReplayPlayback = true;
	}
	else if(StrEqual(name, "shavit-zones"))
	{
		gB_Zones = true;
	}
	else if(StrEqual(name, "shavit-sounds"))
	{
		gB_Sounds = true;
	}
	else if(StrEqual(name, "shavit-rankings"))
	{
		gB_Rankings = true;
	}
	else if(StrEqual(name, "DynamicChannels"))
	{
		gB_DynamicChannels = true;
	}
	else if(StrEqual(name, "shavit-wr"))
	{
		gB_WR = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "shavit-replay-playback"))
	{
		gB_ReplayPlayback = false;
	}
	else if(StrEqual(name, "shavit-zones"))
	{
		gB_Zones = false;
	}
	else if(StrEqual(name, "shavit-sounds"))
	{
		gB_Sounds = false;
	}
	else if(StrEqual(name, "shavit-rankings"))
	{
		gB_Rankings = false;
	}
	else if(StrEqual(name, "DynamicChannels"))
	{
		gB_DynamicChannels = false;
	}
	else if(StrEqual(name, "shavit-wr"))
	{
		gB_WR = false;
	}
}

public void OnConfigsExecuted()
{
	ConVar sv_hudhint_sound = FindConVar("sv_hudhint_sound");

	if(sv_hudhint_sound != null)
	{
		sv_hudhint_sound.SetBool(false);
	}
}

public void Shavit_OnStyleConfigLoaded(int styles)
{
	gI_Styles = styles;

	for(int i = 0; i < styles; i++)
	{
		Shavit_GetStyleStringsStruct(i, gS_StyleStrings[i]);
	}
}

void MakeAngleDiff(int client, float newAngle)
{
	gF_PreviousAngle[client] = gF_Angle[client];
	gF_Angle[client] = newAngle;
	gF_AngleDiff[client] = GetAngleDiff(newAngle, gF_PreviousAngle[client]);
}

public Action Shavit_OnUserCmdPre(int client, int &buttons, int &impulse, float vel[3], float angles[3], TimerStatus status, int track, int style)
{
	gI_Buttons[client] = buttons;
	MakeAngleDiff(client, angles[1]);

	for(int i = 1; i <= MaxClients; i++)
	{
		if(i == client || (IsValidClient(i) && GetSpectatorTarget(i, i) == client))
		{
			TriggerHUDUpdate(i, true);
		}
	}

	return Plugin_Continue;
}

public void Shavit_OnChatConfigLoaded()
{
	Shavit_GetChatStringsStruct(gS_ChatStrings);
}

public void OnClientPutInServer(int client)
{
	gI_LastScrollCount[client] = 0;
	gI_ScrollCount[client] = 0;
	gB_FirstPrint[client] = false;
	gB_AlternateCenterKeys[client] = false;
	gF_ConnectTime[client] = GetEngineTime(); // Initialize connection time
	
	// Reset Colors
	for (int i = 0; i < view_as<int>(HUD_COLOR_COUNT); i++)
	{
		gI_HUDColors[client][i] = -1;
	}
	
	// Reset Settings
	gI_WrPbState[client] = WrPb_Both; // Default to Both (TopLeft + Bottom)
	gI_HudFontSize[client] = DEFAULT_FONT_SIZE;

	if(IsFakeClient(client))
	{
		SDKHook(client, SDKHook_PostThinkPost, BotPostThinkPost);
	}
	else
	{
		if (gEV_Type != Engine_CSGO)
		{
			CreateTimer(5.0, Timer_QueryWindowsCvar, GetClientSerial(client), TIMER_FLAG_NO_MAPCHANGE);
		}
	}
}

public Action Timer_QueryWindowsCvar(Handle timer, any data)
{
	int client = GetClientFromSerial(data);

	if (client > 0)
	{
		QueryClientConVar(client, "windows_speaker_config", OnWindowsCvarQueried);
	}

	return Plugin_Stop;
}

public void OnWindowsCvarQueried(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any value)
{
	if (!(1 <= client <= MaxClients))
		return;
		
	gB_AlternateCenterKeys[client] = (result == ConVarQuery_NotFound);
}

public void BotPostThinkPost(int client)
{
	if (!(1 <= client <= MaxClients))
		return;
		
	int buttons = GetClientButtons(client);

	float ang[3];
	GetClientEyeAngles(client, ang);

	if(gI_Buttons[client] != buttons || ang[1] != gF_Angle[client])
	{
		gI_Buttons[client] = buttons;

		if (ang[1] != gF_Angle[client])
		{
			MakeAngleDiff(client, ang[1]);
		}

		for(int i = 1; i <= MaxClients; i++)
		{
			if(i != client && (IsValidClient(i) && GetSpectatorTarget(i, i) == client))
			{
				TriggerHUDUpdate(i, true);
			}
		}
	}
}

public void OnClientCookiesCached(int client)
{
	char sHUDSettings[12];
	GetClientCookie(client, gH_HUDCookie, sHUDSettings, sizeof(sHUDSettings));

	if(strlen(sHUDSettings) == 0)
	{
		gCV_DefaultHUD.GetString(sHUDSettings, sizeof(sHUDSettings));
		SetClientCookie(client, gH_HUDCookie, sHUDSettings);
	}

	gI_HUDSettings[client] = StringToInt(sHUDSettings);

	GetClientCookie(client, gH_HUDCookieMain, sHUDSettings, sizeof(sHUDSettings));

	if(strlen(sHUDSettings) == 0)
	{
		gCV_DefaultHUD2.GetString(sHUDSettings, sizeof(sHUDSettings));
		SetClientCookie(client, gH_HUDCookieMain, sHUDSettings);
	}

	gI_HUD2Settings[client] = StringToInt(sHUDSettings);
	
	// NEW: Load Colors
	char sColors[256];
	GetClientCookie(client, gH_Cookie_HUDColors, sColors, sizeof(sColors));
	if (sColors[0] != '\0')
	{
		char sExploded[HUD_COLOR_COUNT][16];
		int iCount = ExplodeString(sColors, ";", sExploded, view_as<int>(HUD_COLOR_COUNT), 16);
		
		// Validate parsed cookie data
		if (iCount >= view_as<int>(HUD_COLOR_COUNT))
		{
			for (int i = 0; i < view_as<int>(HUD_COLOR_COUNT); i++)
		{
			if (strcmp(sExploded[i], "def") == 0 || sExploded[i][0] == '\0') {
				gI_HUDColors[client][i] = -1;
			} else {
				gI_HUDColors[client][i] = StringToInt(sExploded[i], 16);
			}
		}
		}
	}
	
	// NEW: Load WR/PB and Font settings
	char sVal[8];
	GetClientCookie(client, gH_Cookie_WrPbState, sVal, sizeof(sVal));
	if (sVal[0] != '\0') gI_WrPbState[client] = view_as<WrPbState>(StringToInt(sVal));
	
	GetClientCookie(client, gH_Cookie_HudFontSize, sVal, sizeof(sVal));
	if (sVal[0] != '\0') gI_HudFontSize[client] = StringToInt(sVal);
	else gI_HudFontSize[client] = DEFAULT_FONT_SIZE;

	if (gEV_Type != Engine_TF2 && IsValidClient(client, true) && GetClientTeam(client) > 1)
	{
		GivePlayerDefaultGun(client);
	}
}

// NEW: Save Colors
void SaveClientColors(int client)
{
	if (!AreClientCookiesCached(client)) return;
	
	char sBuffer[256];
	for (int i = 0; i < view_as<int>(HUD_COLOR_COUNT); i++)
	{
		char sTemp[16];
		if (gI_HUDColors[client][i] == -1) {
			Format(sTemp, sizeof(sTemp), "def");
		} else {
			Format(sTemp, sizeof(sTemp), "%X", gI_HUDColors[client][i]);
		}
		
		if (i > 0) StrCat(sBuffer, sizeof(sBuffer), ";");
		StrCat(sBuffer, sizeof(sBuffer), sTemp);
	}
	SetClientCookie(client, gH_Cookie_HUDColors, sBuffer);
}

public void Player_ChangeClass(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if((gI_HUDSettings[client] & HUD_MASTER) > 0 && (gI_HUDSettings[client] & HUD_CENTER) > 0)
	{
		CreateTimer(0.5, Timer_FillerHintText, GetClientSerial(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void Teamplay_Round_Start(Event event, const char[] name, bool dontBroadcast)
{
	CreateTimer(0.5, Timer_FillerHintTextAll, 0, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Hook_HintText(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	if (gCV_BlockYouHaveSpottedHint.BoolValue)
	{
		char text[64];
		msg.ReadString(text, sizeof(text));

		if (StrEqual(text, "#Hint_spotted_a_friend") || StrEqual(text, "#Hint_spotted_an_enemy"))
		{
			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
}

public Action Timer_FillerHintTextAll(Handle timer, any data)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientConnected(i) && IsClientInGame(i))
		{
			FillerHintText(i);
		}
	}

	return Plugin_Stop;
}

public Action Timer_FillerHintText(Handle timer, any data)
{
	int client = GetClientFromSerial(data);

	if(client != 0)
	{
		FillerHintText(client);
	}

	return Plugin_Stop;
}

void FillerHintText(int client)
{
	PrintHintText(client, "...");
	gF_ConnectTime[client] = GetEngineTime();
	gB_FirstPrint[client] = true;
}

public void OnClientDisconnect(int client)
{
	// Clean up client-specific data
	gF_ConnectTime[client] = 0.0;
	gI_ZoneSpeedLimit[client] = 0;
	gB_FirstPrint[client] = false;
}

void ToggleHUD(int client, int hud, bool chat)
{
	if(!(1 <= client <= MaxClients))
	{
		return;
	}

	char sCookie[16];
	gI_HUDSettings[client] ^= hud;
	IntToString(gI_HUDSettings[client], sCookie, 16);
	SetClientCookie(client, gH_HUDCookie, sCookie);

	if(chat)
	{
		char sHUDSetting[64];

		switch(hud)
		{
			case HUD_MASTER: FormatEx(sHUDSetting, 64, "%T", "HudMaster", client);
			case HUD_CENTER: FormatEx(sHUDSetting, 64, "%T", "HudCenter", client);
			case HUD_ZONEHUD: FormatEx(sHUDSetting, 64, "%T", "HudZoneHud", client);
			case HUD_OBSERVE: FormatEx(sHUDSetting, 64, "%T", "HudObserve", client);
			case HUD_SPECTATORS: FormatEx(sHUDSetting, 64, "%T", "HudSpectators", client);
			case HUD_KEYOVERLAY: FormatEx(sHUDSetting, 64, "%T", "HudKeyOverlay", client);
			case HUD_HIDEWEAPON: FormatEx(sHUDSetting, 64, "%T", "HudHideWeapon", client);
			case HUD_TOPLEFT: FormatEx(sHUDSetting, 64, "%T", "HudTopLeft", client);
			case HUD_SYNC: FormatEx(sHUDSetting, 64, "%T", "HudSync", client);
			case HUD_TIMELEFT: FormatEx(sHUDSetting, 64, "%T", "HudTimeLeft", client);
			case HUD_2DVEL: FormatEx(sHUDSetting, 64, "%T", "Hud2dVel", client);
			case HUD_NOSOUNDS: FormatEx(sHUDSetting, 64, "%T", "HudNoRecordSounds", client);
			case HUD_NOPRACALERT: FormatEx(sHUDSetting, 64, "%T", "HudPracticeModeAlert", client);
		}

		if((gI_HUDSettings[client] & hud) > 0)
		{
			Shavit_PrintToChat(client, "%T", "HudEnabledComponent", client,
				gS_ChatStrings.sVariable, sHUDSetting, gS_ChatStrings.sText, gS_ChatStrings.sVariable2, gS_ChatStrings.sText);
		}
		else
		{
			Shavit_PrintToChat(client, "%T", "HudDisabledComponent", client,
				gS_ChatStrings.sVariable, sHUDSetting, gS_ChatStrings.sText, gS_ChatStrings.sWarning, gS_ChatStrings.sText);
		}
	}
}

void Frame_UpdateTopLeftHUD(int serial)
{
	int client = GetClientFromSerial(serial);

	if (client)
	{
		UpdateTopLeftHUD(client, false);
	}
}

public Action Command_SpecNextPrev(int client, const char[] command, int args)
{
	RequestFrame(Frame_UpdateTopLeftHUD, GetClientSerial(client));
	return Plugin_Continue;
}

public Action Command_Master(int client, int args)
{
	ToggleHUD(client, HUD_MASTER, true);

	return Plugin_Handled;
}

public Action Command_Center(int client, int args)
{
	ToggleHUD(client, HUD_CENTER, true);

	return Plugin_Handled;
}

public Action Command_ZoneHUD(int client, int args)
{
	ToggleHUD(client, HUD_ZONEHUD, true);

	return Plugin_Handled;
}

public Action Command_HideWeapon(int client, int args)
{
	ToggleHUD(client, HUD_HIDEWEAPON, true);

	return Plugin_Handled;
}

public Action Command_TrueVel(int client, int args)
{
	ToggleHUD(client, HUD_2DVEL, true);

	return Plugin_Handled;
}

public Action Command_Keys(int client, int args)
{
	ToggleHUD(client, HUD_KEYOVERLAY, true);

	return Plugin_Handled;
}

public Action Command_HUD(int client, int args)
{
	return ShowHUDMenu(client, 0);
}

// =============================================================================
// NEW: Color Menus
// =============================================================================

void ShowHUDColorsMenu(int client)
{
	Menu menu = new Menu(MenuHandler_HUDColors);
	menu.SetTitle("HUD 颜色设置 (Custom Colors)");
	
	for (int i = 0; i < view_as<int>(HUD_COLOR_COUNT); i++)
	{
		char sInfo[8], sDisplay[64], sHex[16];
		IntToString(i, sInfo, sizeof(sInfo));
		
		int color = gI_HUDColors[client][i];
		if (color == -1) {
			Format(sHex, sizeof(sHex), "默认 (Default)");
		} else {
			Format(sHex, sizeof(sHex), "#%06X", color);
		}
		
		Format(sDisplay, sizeof(sDisplay), "%s [%s]", gS_ColorElementNames[i], sHex);
		menu.AddItem(sInfo, sDisplay);
	}
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_HUDColors(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		int element = StringToInt(sInfo);
		
		ShowColorPicker(param1, element);
	}
	else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		ShowHUDMenu(param1, 0);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

void ShowColorPicker(int client, int element)
{
	Menu menu = new Menu(MenuHandler_ColorPicker);
	
	char sTitle[64];
	Format(sTitle, sizeof(sTitle), "选择颜色: %s", gS_ColorElementNames[element]);
	menu.SetTitle(sTitle);
	
	// Pass element index as hidden info
	char sElement[8];
	IntToString(element, sElement, sizeof(sElement));
	
	// Items
	for (int i = 0; i < sizeof(g_Presets); i++)
	{
		// Info format: "element_index;color_value"
		char sInfo[32];
		Format(sInfo, sizeof(sInfo), "%d;%d", element, g_Presets[i].color);
		
		menu.AddItem(sInfo, g_Presets[i].name);
	}
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ColorPicker(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		char sParts[2][16];
		ExplodeString(sInfo, ";", sParts, 2, 16);
		
		int element = StringToInt(sParts[0]);
		int color = StringToInt(sParts[1]);
		
		gI_HUDColors[param1][element] = color;
		SaveClientColors(param1);
		
		PrintToChat(param1, " \x04[HUD]\x01 已将 \x03%s\x01 的颜色设置为 \x04%s", gS_ColorElementNames[element], (color == -1) ? "默认" : "自定义");
		
		// Return to color list
		ShowHUDColorsMenu(param1);
	}
	else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		ShowHUDColorsMenu(param1);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}
// =============================================================================

Action ShowHUDMenu(int client, int item)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	Menu menu = new Menu(MenuHandler_HUD, MENU_ACTIONS_DEFAULT|MenuAction_DisplayItem);
	menu.SetTitle("%T", "HUDMenuTitle", client);

	char sInfo[16];
	char sHudItem[64];
	FormatEx(sInfo, 16, "!%d", HUD_MASTER);
	FormatEx(sHudItem, 64, "%T", "HudMaster", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "!%d", HUD_CENTER);
	FormatEx(sHudItem, 64, "%T", "HudCenter", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "!%d", HUD_ZONEHUD);
	FormatEx(sHudItem, 64, "%T", "HudZoneHud", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "!%d", HUD_OBSERVE);
	FormatEx(sHudItem, 64, "%T", "HudObserve", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "!%d", HUD_SPECTATORS);
	FormatEx(sHudItem, 64, "%T", "HudSpectators", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "!%d", HUD_SPECTATORSDEAD);
	FormatEx(sHudItem, 64, "%T", "HudSpectatorsDead", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "!%d", HUD_KEYOVERLAY);
	FormatEx(sHudItem, 64, "%T", "HudKeyOverlay", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "!%d", HUD_HIDEWEAPON);
	FormatEx(sHudItem, 64, "%T", "HudHideWeapon", client);
	menu.AddItem(sInfo, sHudItem);

	// REPLACED: Original HUD_TOPLEFT with WR/PB State Toggle
	// Using "WRPB" as the key to hook into MenuHandler_HUD
	// This usually corresponds to item 9 in the list (Page 2, Item 3 approx)
	menu.AddItem("WRPB", "WR/PB HUD State"); // Logic inside DisplayItem will format this

	if(IsSource2013(gEV_Type))
	{
		FormatEx(sInfo, 16, "!%d", HUD_SYNC);
		FormatEx(sHudItem, 64, "%T", "HudSync_keyhint", client);
		menu.AddItem(sInfo, sHudItem);

		FormatEx(sInfo, 16, "!%d", HUD_TIMELEFT);
		FormatEx(sHudItem, 64, "%T", "HudTimeLeft", client);
		menu.AddItem(sInfo, sHudItem);
	}

	FormatEx(sInfo, 16, "!%d", HUD_2DVEL);
	FormatEx(sHudItem, 64, "%T", "Hud2dVel", client);
	menu.AddItem(sInfo, sHudItem);

	if(gB_Sounds)
	{
		FormatEx(sInfo, 16, "!%d", HUD_NOSOUNDS);
		FormatEx(sHudItem, 64, "%T", "HudNoRecordSounds", client);
		menu.AddItem(sInfo, sHudItem);
	}

	FormatEx(sInfo, 16, "!%d", HUD_NOPRACALERT);
	FormatEx(sHudItem, 64, "%T", "HudPracticeModeAlert", client);
	menu.AddItem(sInfo, sHudItem);

	if (gEV_Type != Engine_TF2)
	{
		FormatEx(sInfo, 16, "#%d", HUD_USP);
		FormatEx(sHudItem, 64, "%T", "HudDefaultPistol", client);
		menu.AddItem(sInfo, sHudItem);
	}

	FormatEx(sInfo, 16, "!%d", HUD_DEBUGTARGETNAME);
	FormatEx(sHudItem, 64, "%T", "HudDebugTargetname", client);
	menu.AddItem(sInfo, sHudItem);

	// HUD2 - disables selected elements
	FormatEx(sInfo, 16, "@%d", HUD2_TIME);
	FormatEx(sHudItem, 64, "%T", "HudTimeText", client);
	menu.AddItem(sInfo, sHudItem);

	if(gB_ReplayPlayback)
	{
		FormatEx(sInfo, 16, "@%d", HUD2_TIMEDIFFERENCE);
		FormatEx(sHudItem, 64, "%T", "HudTimeDifference", client);
		menu.AddItem(sInfo, sHudItem);
	}

	FormatEx(sInfo, 16, "@%d", HUD2_SPEED);
	FormatEx(sHudItem, 64, "%T", "HudSpeedText", client);
	menu.AddItem(sInfo, sHudItem);

	if (gB_ReplayPlayback)
	{
		FormatEx(sInfo, 16, "@%d", HUD2_VELOCITYDIFFERENCE);
		FormatEx(sHudItem, 64, "%T", "HudVelocityDifference", client);
		menu.AddItem(sInfo, sHudItem);
	}

	FormatEx(sInfo, 16, "@%d", HUD2_JUMPS);
	FormatEx(sHudItem, 64, "%T", "HudJumpsText", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "@%d", HUD2_STRAFE);
	FormatEx(sHudItem, 64, "%T", "HudStrafeText", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "@%d", HUD2_SYNC);
	FormatEx(sHudItem, 64, "%T", "HudSync_center", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "@%d", HUD2_PERFS);
	FormatEx(sHudItem, 64, "%T", "HudPerfs_keyhint", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "!%d", HUD_PERFS_CENTER);
	FormatEx(sHudItem, 64, "%T", "HudPerfsCenter", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "@%d", HUD2_STYLE);
	FormatEx(sHudItem, 64, "%T", "HudStyleText", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "@%d", HUD2_RANK);
	FormatEx(sHudItem, 64, "%T", "HudRankText", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "@%d", HUD2_TRACK);
	FormatEx(sHudItem, 64, "%T", "HudTrackText", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "@%d", HUD2_SPLITPB);
	FormatEx(sHudItem, 64, "%T", "HudSplitPbText", client);
	menu.AddItem(sInfo, sHudItem);

	FormatEx(sInfo, 16, "@%d", HUD2_TOPLEFT_RANK);
	FormatEx(sHudItem, 64, "%T", "HudTopLeftRankText", client);
	menu.AddItem(sInfo, sHudItem);

	if(gB_Rankings)
	{
		FormatEx(sInfo, 16, "@%d", HUD2_MAPTIER);
		FormatEx(sHudItem, 64, "%T", "HudMapTierText", client);
		menu.AddItem(sInfo, sHudItem);
	}

	if (LibraryExists("modern-landfix"))
	{
		FormatEx(sInfo, 16, "@%d", HUD2_LANDFIX);
		FormatEx(sHudItem, 64, "%T", "HudLandfix", client);
		menu.AddItem(sInfo, sHudItem);
	}

	if (gEV_Type != Engine_TF2)
	{
		FormatEx(sInfo, 16, "@%d", HUD2_GLOCKBURST);
		FormatEx(sHudItem, 64, "%T", "HudGlockBurst", client);
		menu.AddItem(sInfo, sHudItem);

		FormatEx(sInfo, 16, "@%d", HUD2_USPSILENCER);
		FormatEx(sHudItem, 64, "%T", "HudUSPSilencer", client);
		menu.AddItem(sInfo, sHudItem);
	}

	if (gEV_Type == Engine_CSGO)
	{
		FormatEx(sInfo, 16, "@%d", HUD2_CENTERKEYS);
		FormatEx(sHudItem, 64, "%T", "HudCenterKeys", client);
		menu.AddItem(sInfo, sHudItem);
		
		// NEW ITEMS
		
		// Font Size
		char sSize[32];
		Format(sSize, sizeof(sSize), "[+] 字体大小: %dpx", gI_HudFontSize[client]);
		menu.AddItem("FONT", sSize);
		
		// Add "HUD Colors" option at bottom
		menu.AddItem("COLORS", "HUD 颜色设置 (Custom Colors)");
	}

	menu.ExitButton = true;
	menu.DisplayAt(client, item, MENU_TIME_FOREVER);

	return Plugin_Handled;
}

public int MenuHandler_HUD(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sCookie[16];
		menu.GetItem(param2, sCookie, 16);
		
		if (StrEqual(sCookie, "COLORS"))
		{
			ShowHUDColorsMenu(param1);
			return 0;
		}
		else if (StrEqual(sCookie, "WRPB"))
		{
			// Cycle WR/PB: Bottom -> TopLeft -> Both -> Hidden -> Bottom
			// Logic: 2 -> 1 -> 3 -> 0 -> 2
			
			if (gI_WrPbState[param1] == WrPb_Bottom) 
			{
				gI_WrPbState[param1] = WrPb_TopLeft;
				gI_HUDSettings[param1] |= HUD_TOPLEFT;
			}
			else if (gI_WrPbState[param1] == WrPb_TopLeft) 
			{
				gI_WrPbState[param1] = WrPb_Both;
				gI_HUDSettings[param1] |= HUD_TOPLEFT;
			}
			else if (gI_WrPbState[param1] == WrPb_Both)
			{
				gI_WrPbState[param1] = WrPb_Hidden;
				gI_HUDSettings[param1] &= ~HUD_TOPLEFT;
			}
			else 
			{
				gI_WrPbState[param1] = WrPb_Bottom;
				gI_HUDSettings[param1] &= ~HUD_TOPLEFT;
			}
			
			// Save State
			char sVal[8];
			IntToString(view_as<int>(gI_WrPbState[param1]), sVal, sizeof(sVal));
			SetClientCookie(param1, gH_Cookie_WrPbState, sVal);
			
			// Save HUD Settings Bitmask
			IntToString(gI_HUDSettings[param1], sVal, sizeof(sVal));
			SetClientCookie(param1, gH_HUDCookie, sVal);
			
			ShowHUDMenu(param1, GetMenuSelectionPosition());
			return 0;
		}
		else if (StrEqual(sCookie, "FONT"))
		{
			// Cycle Font Size: 12 -> 40, step 2
			gI_HudFontSize[param1] += 2;
			if (gI_HudFontSize[param1] > 40) gI_HudFontSize[param1] = 12;
			
			char sVal[8];
			IntToString(gI_HudFontSize[param1], sVal, sizeof(sVal));
			SetClientCookie(param1, gH_Cookie_HudFontSize, sVal);
			ShowHUDMenu(param1, GetMenuSelectionPosition());
			return 0;
		}

		int type = (sCookie[0] == '!') ? 1 : (sCookie[0] == '@' ? 2 : 3);
		ReplaceString(sCookie, 16, "!", "");
		ReplaceString(sCookie, 16, "@", "");
		ReplaceString(sCookie, 16, "#", "");

		int iSelection = StringToInt(sCookie);

		if(type == 1)
		{
			gI_HUDSettings[param1] ^= iSelection;
			IntToString(gI_HUDSettings[param1], sCookie, 16);
			SetClientCookie(param1, gH_HUDCookie, sCookie);
		}
		else if (type == 2)
		{
			gI_HUD2Settings[param1] ^= iSelection;
			IntToString(gI_HUD2Settings[param1], sCookie, 16);
			SetClientCookie(param1, gH_HUDCookieMain, sCookie);
		}
		else if (type == 3) // special trinary ones :)
		{
			int mask = (iSelection | (iSelection << 1));

			if (!(gI_HUDSettings[param1] & mask))
			{
				gI_HUDSettings[param1] |= iSelection;
			}
			else if (gI_HUDSettings[param1] & iSelection)
			{
				gI_HUDSettings[param1] ^= mask;
			}
			else
			{
				gI_HUDSettings[param1] &= ~mask;
			}

			IntToString(gI_HUDSettings[param1], sCookie, 16);
			SetClientCookie(param1, gH_HUDCookie, sCookie);
			
			// Bug 3 Fix: Immediately apply pistol change if toggling HUD_USP
			if (iSelection == HUD_USP && IsPlayerAlive(param1) && gEV_Type != Engine_TF2)
			{
				GivePlayerDefaultGun(param1);
			}
		}

		if(gEV_Type == Engine_TF2 && iSelection == HUD_CENTER && (gI_HUDSettings[param1] & HUD_MASTER) > 0)
		{
			FillerHintText(param1);
		}

		ShowHUDMenu(param1, GetMenuSelectionPosition());
	}
	else if(action == MenuAction_DisplayItem)
	{
		char sInfo[16];
		char sDisplay[64];
		int style = 0;
		menu.GetItem(param2, sInfo, 16, style, sDisplay, 64);
		
		if (StrEqual(sInfo, "WRPB"))
		{
			// Replacement Display logic for the standard Top Left item
			char sState[32];
			switch (gI_WrPbState[param1]) {
				case WrPb_TopLeft: Format(sState, sizeof(sState), "[+] 左上角 (TopLeft)");
				case WrPb_Bottom:  Format(sState, sizeof(sState), "[+] 底部 (Bottom)");
				case WrPb_Both:    Format(sState, sizeof(sState), "[+] 全部 (Both)");
				case WrPb_Hidden:  Format(sState, sizeof(sState), "[-] 隐藏 (Hidden)");
			}
			Format(sDisplay, sizeof(sDisplay), "%s HUD (WR/PB)", sState);
			return RedrawMenuItem(sDisplay);
		}
		else if (StrEqual(sInfo, "COLORS") || StrEqual(sInfo, "FONT"))
		{
			return RedrawMenuItem(sDisplay);
		}

		int type = (sInfo[0] == '!') ? 1 : (sInfo[0] == '@' ? 2 : 3);
		ReplaceString(sInfo, 16, "!", "");
		ReplaceString(sInfo, 16, "@", "");
		ReplaceString(sInfo, 16, "#", "");

		int iSelection = StringToInt(sInfo);

		if(type == 1)
		{
			Format(sDisplay, 64, "[%s] %s", ((gI_HUDSettings[param1] & iSelection) > 0)? "＋":"－", sDisplay);
		}
		else if (type == 2)
		{
			Format(sDisplay, 64, "[%s] %s", ((gI_HUD2Settings[param1] & iSelection) == 0)? "＋":"－", sDisplay);
		}
		else if (type == 3) // special trinary ones :)
		{
			bool first = 0 != (gI_HUDSettings[param1] & iSelection);
			bool second = 0 != (gI_HUDSettings[param1] & (iSelection << 1));
			Format(sDisplay, 64, "[%s] %s", first ? "１" : (second ? "２" : "０"), sDisplay);
		}

		return RedrawMenuItem(sDisplay);
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

bool is_usp(int entity, const char[] classname)
{
	if (gEV_Type == Engine_CSGO)
	{
		return (61 == GetEntProp(entity, Prop_Send, "m_iItemDefinitionIndex"));
	}
	else
	{
		return StrEqual(classname, "weapon_usp");
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "weapon_glock")
	||  StrEqual(classname, "weapon_hkp2000")
	||  StrContains(classname, "weapon_usp") != -1
	)
	{
		SDKHook(entity, SDKHook_Touch, Hook_GunTouch);
	}
}

public Action Hook_GunTouch(int entity, int client)
{
	if (1 <= client <= MaxClients)
	{
		char classname[64];
		GetEntityClassname(entity, classname, sizeof(classname));

		if (StrEqual(classname, "weapon_glock"))
		{
			if (!IsFakeClient(client) && !(gI_HUD2Settings[client] & HUD2_GLOCKBURST))
			{
				SetEntProp(entity, Prop_Send, "m_bBurstMode", 1);
			}
		}
		else if (is_usp(entity, classname))
		{
			if (!(gI_HUD2Settings[client] & HUD2_USPSILENCER) != (gEV_Type == Engine_CSS))
			{
				return Plugin_Continue;
			}

			int state = (gEV_Type == Engine_CSS) ? 1 : 0;
			SetEntProp(entity, Prop_Send, "m_bSilencerOn", state);
			SetEntProp(entity, Prop_Send, "m_weaponMode", state);
			SetEntPropFloat(entity, Prop_Send, "m_flDoneSwitchingSilencer", GetGameTime());
		}
	}

	return Plugin_Continue;
}

void GivePlayerDefaultGun(int client)
{
	if (!(gI_HUDSettings[client] & (HUD_GLOCK|HUD_USP)))
	{
		return;
	}

	int iSlot = CS_SLOT_SECONDARY;
	int iWeapon = GetPlayerWeaponSlot(client, iSlot);
	char sWeapon[32];

	if (gI_HUDSettings[client] & HUD_USP)
	{
		strcopy(sWeapon, 32, (gEV_Type == Engine_CSS) ? "weapon_usp" : "weapon_usp_silencer");
	}
	else
	{
		strcopy(sWeapon, 32, "weapon_glock");
	}

	if (iWeapon != -1)
	{
		RemovePlayerItem(client, iWeapon);
		AcceptEntityInput(iWeapon, "Kill");
	}

	iWeapon = (gEV_Type == Engine_CSGO) ? GiveSkinnedWeapon(client, sWeapon) : GivePlayerItem(client, sWeapon);
	FakeClientCommand(client, "use %s", sWeapon);
	
	// Bug 4 Fix: Explicitly apply burst/silencer settings after giving weapon
	if (iWeapon != -1 && IsValidEntity(iWeapon))
	{
		if (StrEqual(sWeapon, "weapon_glock"))
		{
			// HUD2 uses inverted logic: bit NOT set = feature enabled
			// Apply burst mode if HUD2_GLOCKBURST bit is NOT set
			if (!(gI_HUD2Settings[client] & HUD2_GLOCKBURST))
			{
				SetEntProp(iWeapon, Prop_Send, "m_bBurstMode", 1);
			}
		}
		else if (StrContains(sWeapon, "usp") != -1)
		{
			// HUD2 uses inverted logic: bit NOT set = feature enabled
			// Apply silencer based on engine type:
			// - CSGO: Apply if HUD2_USPSILENCER bit is NOT set
			// - CSS: Apply if HUD2_USPSILENCER bit IS set (different default)
			if ((!(gI_HUD2Settings[client] & HUD2_USPSILENCER)) != (gEV_Type == Engine_CSS))
			{
				int state = (gEV_Type == Engine_CSS) ? 1 : 0;
				SetEntProp(iWeapon, Prop_Send, "m_bSilencerOn", state);
				SetEntProp(iWeapon, Prop_Send, "m_weaponMode", state);
				SetEntPropFloat(iWeapon, Prop_Send, "m_flDoneSwitchingSilencer", GetGameTime());
			}
		}
	}
}

public void Player_Spawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsFakeClient(client))
	{
		if (gEV_Type != Engine_TF2)
		{
			GivePlayerDefaultGun(client);
		}
	}
}

public void OnGameFrame()
{
	if((GetGameTickCount() % gCV_TicksPerUpdate.IntValue) == 0)
	{
		Cron();
	}
}

void Cron()
{
	if(++gI_Cycle >= 65535)
	{
		gI_Cycle = 0;
	}

	switch(gI_GradientDirection)
	{
		case 0:
		{
			gI_Gradient.b += gCV_GradientStepSize.IntValue;

			if(gI_Gradient.b >= 255)
			{
				gI_Gradient.b = 255;
				gI_GradientDirection = 1;
			}
		}

		case 1:
		{
			gI_Gradient.r -= gCV_GradientStepSize.IntValue;

			if(gI_Gradient.r <= 0)
			{
				gI_Gradient.r = 0;
				gI_GradientDirection = 2;
			}
		}

		case 2:
		{
			gI_Gradient.g += gCV_GradientStepSize.IntValue;

			if(gI_Gradient.g >= 255)
			{
				gI_Gradient.g = 255;
				gI_GradientDirection = 3;
			}
		}

		case 3:
		{
			gI_Gradient.b -= gCV_GradientStepSize.IntValue;

			if(gI_Gradient.b <= 0)
			{
				gI_Gradient.b = 0;
				gI_GradientDirection = 4;
			}
		}

		case 4:
		{
			gI_Gradient.r += gCV_GradientStepSize.IntValue;

			if(gI_Gradient.r >= 255)
			{
				gI_Gradient.r = 255;
				gI_GradientDirection = 5;
			}
		}

		case 5:
		{
			gI_Gradient.g -= gCV_GradientStepSize.IntValue;

			if(gI_Gradient.g <= 0)
			{
				gI_Gradient.g = 0;
				gI_GradientDirection = 0;
			}
		}

		default:
		{
			gI_Gradient.r = 255;
			gI_GradientDirection = 0;
		}
	}

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsValidClient(i) || IsFakeClient(i) || (gI_HUDSettings[i] & HUD_MASTER) == 0)
		{
			continue;
		}

		if((gI_Cycle % 50) == 0)
		{
			float fSpeed[3];
			GetEntPropVector(GetSpectatorTarget(i, i), Prop_Data, "m_vecVelocity", fSpeed);
			gI_PreviousSpeed[i] = RoundToNearest(((gI_HUDSettings[i] & HUD_2DVEL) == 0)? GetVectorLength(fSpeed):(SquareRoot(Pow(fSpeed[0], 2.0) + Pow(fSpeed[1], 2.0))));
		}

		TriggerHUDUpdate(i);
	}
}

void TriggerHUDUpdate(int client, bool keysonly = false) // keysonly because CS:S lags when you send too many usermessages
{
	if(!keysonly)
	{
		UpdateMainHUD(client);
		SetEntProp(client, Prop_Data, "m_bDrawViewmodel", ((gI_HUDSettings[client] & HUD_HIDEWEAPON) > 0)? 0:1);
		UpdateTopLeftHUD(client, true);
	}

	bool draw_keys = HUD1Enabled(gI_HUDSettings[client], HUD_KEYOVERLAY);
	bool center_keys = HUD2Enabled(gI_HUD2Settings[client], HUD2_CENTERKEYS);

	if (draw_keys && center_keys)
	{
		UpdateCenterKeys(client);
	}

	if(IsSource2013(gEV_Type))
	{
		if(!keysonly)
		{
			UpdateKeyHint(client);
		}
	}
	else if (((gI_HUDSettings[client] & HUD_SPECTATORS) > 0 || (draw_keys && !center_keys))
	      && (!gB_Zones || !Shavit_IsClientCreatingZone(client))
	      && (GetClientMenu(client, null) == MenuSource_None || GetClientMenu(client, null) == MenuSource_RawPanel)
	)
	{
		if (gI_HUDSettings[client] & HUD_SPECTATORSDEAD && IsPlayerAlive(client))
		{
			return;
		}

		bool bShouldDraw = false;
		Panel pHUD = new Panel();

		if (!center_keys)
		{
			UpdateKeyOverlay(client, pHUD, bShouldDraw);
			pHUD.DrawItem("", ITEMDRAW_RAWLINE);
		}

		UpdateSpectatorList(client, pHUD, bShouldDraw);

		if(bShouldDraw)
		{
			pHUD.Send(client, PanelHandler_Nothing, 1);
		}

		delete pHUD;
	}
}

void AddHUDLine(char[] buffer, int maxlen, const char[] line, int& lines)
{
	if (lines++ > 0)
	{
		Format(buffer, maxlen, "%s\n%s", buffer, line);
	}
	else
	{
		StrCat(buffer, maxlen, line);
	}
}

stock void GetRGB(int color, color_t arr)
{
	arr.r = ((color >> 16) & 0xFF);
	arr.g = ((color >> 8) & 0xFF);
	arr.b = (color & 0xFF);
}

stock int GetHex(color_t color)
{
	return (((color.r & 0xFF) << 16) + ((color.g & 0xFF) << 8) + (color.b & 0xFF));
}

stock int GetGradient(int start, int end, int steps)
{
	color_t aColorStart;
	GetRGB(start, aColorStart);

	color_t aColorEnd;
	GetRGB(end, aColorEnd);

	color_t aColorGradient;
	aColorGradient.r = (aColorStart.r + RoundToZero((aColorEnd.r - aColorStart.r) * steps / 100.0));
	aColorGradient.g = (aColorStart.g + RoundToZero((aColorEnd.g - aColorStart.g) * steps / 100.0));
	aColorGradient.b = (aColorStart.b + RoundToZero((aColorEnd.b - aColorStart.b) * steps / 100.0));

	return GetHex(aColorGradient);
}

public void Shavit_OnEnterZone(int client, int type, int track, int id, int entity)
{
	if(type == Zone_CustomSpeedLimit)
	{
		gI_ZoneSpeedLimit[client] = Shavit_GetZoneData(id);
	}
}


int AddHUDToBuffer_Source2013(int client, huddata_t data, char[] buffer, int maxlen)
{
	// 保持 Source 2013 (CSS/TF2) 逻辑不变
	int iLines = 0;
	char sLine[128];
	int target = GetSpectatorTarget(client, client);

	if (client == data.iTarget && !AreClientCookiesCached(client))
	{
		FormatEx(sLine, sizeof(sLine), "%T", "TimerLoading", client);
		AddHUDLine(buffer, maxlen, sLine, iLines);
	}

	if (gI_HUDSettings[client] & HUD_DEBUGTARGETNAME)
	{
		char targetname[64], classname[64];
		GetEntPropString(data.iTarget, Prop_Data, "m_iName", targetname, sizeof(targetname));
		GetEntityClassname(data.iTarget, classname, sizeof(classname));

		char speedmod[33];

		if (IsValidClient(data.iTarget) && !IsFakeClient(data.iTarget))
		{
			timer_snapshot_t snapshot;
			Shavit_SaveSnapshot(data.iTarget, snapshot, sizeof(snapshot));
			FormatEx(speedmod, sizeof(speedmod), " sm=%.2f lm=%.2f", snapshot.fplayer_speedmod, GetEntPropFloat((data.iTarget), Prop_Send, "m_flLaggedMovementValue"));
		}

		FormatEx(sLine, sizeof(sLine), "t='%s' c='%s'%s", targetname, classname, speedmod);
		AddHUDLine(buffer, maxlen, sLine, iLines);
	}

	if(data.bReplay)
	{
		if(data.iStyle != -1 && Shavit_GetReplayStatus(data.iTarget) != Replay_Idle && Shavit_GetReplayCacheFrameCount(data.iTarget) > 0)
		{
			char sTrack[32];

			if(data.iTrack != Track_Main && (gI_HUD2Settings[client] & HUD2_TRACK) == 0)
			{
				GetTrackName(client, data.iTrack, sTrack, 32);
				Format(sTrack, 32, "(%s) ", sTrack);
			}

			if((gI_HUD2Settings[client] & HUD2_STYLE) == 0)
			{
				FormatEx(sLine, 128, "%s %s%T", gS_StyleStrings[data.iStyle].sStyleName, sTrack, "ReplayText", client);
				AddHUDLine(buffer, maxlen, sLine, iLines);
			}

			char sPlayerName[MAX_NAME_LENGTH];
			Shavit_GetReplayCacheName(data.iTarget, sPlayerName, sizeof(sPlayerName));
			AddHUDLine(buffer, maxlen, sPlayerName, iLines);

			if((gI_HUD2Settings[client] & HUD2_TIME) == 0)
			{
				char sTime[32];
				FormatSeconds(data.fTime, sTime, 32, false);

				char sWR[32];
				FormatSeconds(data.fWR, sWR, 32, false);

				FormatEx(sLine, 128, "%s / %s\n(%.1f％)", sTime, sWR, ((data.fTime < 0.0 ? 0.0 : data.fTime / data.fWR) * 100));
				AddHUDLine(buffer, maxlen, sLine, iLines);
			}

			if((gI_HUD2Settings[client] & HUD2_SPEED) == 0)
			{
				FormatEx(sLine, 128, "%d u/s", data.iSpeed);
				AddHUDLine(buffer, maxlen, sLine, iLines);
			}
		}
		else
		{
			FormatEx(sLine, 128, "%T", (gEV_Type == Engine_TF2)? "NoReplayDataTF2":"NoReplayData", client);
			AddHUDLine(buffer, maxlen, sLine, iLines);
		}

		return iLines;
	}

	if((gI_HUDSettings[client] & HUD_ZONEHUD) > 0 && data.iZoneHUD != ZoneHUD_None)
	{
		if(gB_Rankings && (gI_HUD2Settings[client] & HUD2_MAPTIER) == 0)
		{
			FormatEx(sLine, 128, "%T", "HudZoneTier", client, data.iMapTier);
			AddHUDLine(buffer, maxlen, sLine, iLines);
		}

		if(data.iZoneHUD == ZoneHUD_Start)
		{
			FormatEx(sLine, 128, "%T ", (gI_HUD2Settings[client] & HUD2_SPEED) ? "HudInStartZoneNoSpeed" : "HudInStartZone", client, data.iSpeed);
		}
		else
		{
			FormatEx(sLine, 128, "%T ", (gI_HUD2Settings[client] & HUD2_SPEED) ? "HudInEndZoneNoSpeed" : "HudInEndZone", client, data.iSpeed);
		}

		AddHUDLine(buffer, maxlen, sLine, iLines);
		return iLines;
	}

	if(data.iTimerStatus != Timer_Stopped)
	{
		if((gI_HUD2Settings[client] & HUD2_STYLE) == 0)
		{
			if(Shavit_GetStyleSettingBool(data.iStyle, "a_or_d_only"))
			{
				char sKey1[16] = "A-Only";
				char sKey2[16] = "D-Only";

				if(StrEqual(gS_StyleStrings[data.iStyle].sStyleName, "W-A/W-D-Only"))
				{
					sKey1 = "W-A-Only";
					sKey2 = "W-D-Only";
				}
				if(StrEqual(gS_StyleStrings[data.iStyle].sStyleName, "A/D-Only Pro"))
				{
					sKey1 = "A-Only Pro";
					sKey2 = "D-Only Pro";
				}

				if (Shavit_GetClientKeyCombo(target) == 0)
				{
					AddHUDLine(buffer, maxlen, sKey1, iLines);

				}
				else if (Shavit_GetClientKeyCombo(target) == 1)
				{
					AddHUDLine(buffer, maxlen, sKey2, iLines);
				}
				else
				{
					if (data.iStyle >= 0 && data.iStyle < gI_Styles)
					{
						AddHUDLine(buffer, maxlen, gS_StyleStrings[data.iStyle].sStyleName, iLines);
					}
				}
			}
			else
			{
				if (data.iStyle >= 0 && data.iStyle < gI_Styles)
				{
					AddHUDLine(buffer, maxlen, gS_StyleStrings[data.iStyle].sStyleName, iLines);
				}
			}
		}

		if(data.bPractice || data.iTimerStatus == Timer_Paused)
		{
			FormatEx(sLine, 128, "%T", (data.iTimerStatus == Timer_Paused)? "HudPaused":"HudPracticeMode", client);
			AddHUDLine(buffer, maxlen, sLine, iLines);
		}

		if((gI_HUD2Settings[client] & HUD2_TIME) == 0)
		{
			char sTime[32];
			FormatSeconds(data.fTime, sTime, 32, false);

			char sTimeDiff[32];

			if ((gI_HUD2Settings[client] & HUD2_TIMEDIFFERENCE) == 0 && data.fClosestReplayTime != -1.0 && Shavit_GetClosestReplayStyle(client) == Shavit_GetBhopStyle(target))
			{
				float fDifference = data.fTime - data.fClosestReplayTime;
				FormatSeconds(fDifference, sTimeDiff, 32, false, FloatAbs(fDifference) >= 60.0);
				Format(sTimeDiff, 32, " (%s%s)", (fDifference >= 0.0)? "+":"", sTimeDiff);
			}

			if((gI_HUD2Settings[client] & HUD2_RANK) == 0)
			{
				FormatEx(sLine, 128, "%T: %s%s (#%d)", "HudTimeText", client, sTime, sTimeDiff, data.iRank);
			}
			else
			{
				FormatEx(sLine, 128, "%T: %s%s", "HudTimeText", client, sTime, sTimeDiff);
			}

			AddHUDLine(buffer, maxlen, sLine, iLines);
		}

		if((gI_HUD2Settings[client] & HUD2_JUMPS) == 0)
		{
			if (!Shavit_GetStyleSettingBool(data.iStyle, "autobhop") && (gI_HUDSettings[client] & HUD_PERFS_CENTER))
			{
				FormatEx(sLine, 128, "%T: %d (%.1f％)", "HudJumpsText", client, data.iJumps, Shavit_GetPerfectJumps(data.iTarget));
			}
			else
			{
				FormatEx(sLine, 128, "%T: %d", "HudJumpsText", client, data.iJumps);
			}
			AddHUDLine(buffer, maxlen, sLine, iLines);
		}

		if((gI_HUD2Settings[client] & HUD2_STRAFE) == 0)
		{
			if((gI_HUD2Settings[client] & HUD2_SYNC) == 0)
			{
				FormatEx(sLine, 128, "%T: %d (%.1f％)", "HudStrafeText", client, data.iStrafes, data.fSync);
			}
			else
			{
				FormatEx(sLine, 128, "%T: %d", "HudStrafeText", client, data.iStrafes);
			}
			//FormatEx(sLine, 128, "%T: %d", "HudStrafeText", client, data.iStrafes);
			AddHUDLine(buffer, maxlen, sLine, iLines);
		}
	}

	if((gI_HUD2Settings[client] & HUD2_SPEED) == 0)
	{
		// timer: Speed: %d
		// no timer: straight up number
		if(data.iTimerStatus != Timer_Stopped)
		{
			if (data.fClosestReplayTime != -1.0 && (gI_HUD2Settings[client] & HUD2_VELOCITYDIFFERENCE) == 0)
			{
				float res = data.fClosestVelocityDifference;
				FormatEx(sLine, 128, "%T: %d (%s%.0f)", "HudSpeedText", client, data.iSpeed, (res >= 0.0) ? "+":"", res);
			}
			else
			{
				FormatEx(sLine, 128, "%T: %d", "HudSpeedText", client, data.iSpeed);
			}
		}
		else
		{
			IntToString(data.iSpeed, sLine, 128);
		}

		AddHUDLine(buffer, maxlen, sLine, iLines);

		float limit = Shavit_GetStyleSettingFloat(data.iStyle, "velocity_limit");

		if (limit > 0.0 && gB_Zones && Shavit_InsideZone(data.iTarget, Zone_CustomSpeedLimit, data.iTrack))
		{
			if(gI_ZoneSpeedLimit[data.iTarget] == 0)
			{
				FormatEx(sLine, 128, "%T", "HudNoSpeedLimit", data.iTarget);
			}
			else
			{
				FormatEx(sLine, sizeof(sLine), "%T", "HudCustomSpeedLimit", client, gI_ZoneSpeedLimit[data.iTarget]);
			}

			AddHUDLine(buffer, maxlen, sLine, iLines);
		}
	}

	if(data.iTimerStatus != Timer_Stopped && data.fClosestReplayTime != -1.0)
	{
		float progress = ((data.fTime - (data.fTime - data.fClosestReplayTime)) / data.fWR) * 100.0;
		if(progress > 99.9)
			progress = 99.9;
		FormatEx(sLine, sizeof(sLine), "Progress: %.1f％", progress);
		AddHUDLine(buffer, maxlen, sLine, iLines);
	}

	if(data.iTimerStatus != Timer_Stopped && data.iTrack != Track_Main && (gI_HUD2Settings[client] & HUD2_TRACK) == 0)
	{
		char sTrack[32];
		GetTrackName(client, data.iTrack, sTrack, 32);

		AddHUDLine(buffer, maxlen, sTrack, iLines);
	}

	return iLines;
}

// 4-Line Custom Layout for CS:GO
int AddHUDToBuffer_CSGO(int client, huddata_t data, char[] buffer, int maxlen)
{
	int iLines = 0;
	char sLine[256]; // Increased from 128 to 256
	
	// Helper to colorize
	int col;

	// 使用 size=xxx 字体 (默认 18)
	int fontSize = gI_HudFontSize[client];
	if (fontSize < 12)
		fontSize = 12; // Min limit
	else if (fontSize > 72)
		fontSize = 72; // Max limit
	
	char sHeader[64];
	Format(sHeader, sizeof(sHeader), "<font size='%d'><pre>", fontSize);
	StrCat(buffer, maxlen, sHeader);

	// 调试信息 (如果开启)
	if (gI_HUDSettings[client] & HUD_DEBUGTARGETNAME)
	{
		char targetname[64], classname[64];
		GetEntPropString(data.iTarget, Prop_Data, "m_iName", targetname, sizeof(targetname));
		GetEntityClassname(data.iTarget, classname, sizeof(classname));

		char speedmod[33];
		if (IsValidClient(data.iTarget) && !IsFakeClient(data.iTarget))
		{
			timer_snapshot_t snapshot;
			Shavit_SaveSnapshot(data.iTarget, snapshot, sizeof(snapshot));
			FormatEx(speedmod, sizeof(speedmod), " sm=%.2f lm=%.2f", snapshot.fplayer_speedmod, GetEntPropFloat((data.iTarget), Prop_Send, "m_flLaggedMovementValue"));
		}

		FormatEx(sLine, sizeof(sLine), "t='%s' c='%s'%s", targetname, classname, speedmod);
		AddHUDLine(buffer, maxlen, sLine, iLines);
	}

	// 区域 HUD (Start/End Zone)
	if (data.iZoneHUD != ZoneHUD_None && (gI_HUDSettings[client] & HUD_ZONEHUD))
	{
		// Color Logic for Zone
		int zoneColor = gI_HUDColors[client][Color_Zone];
		if (zoneColor == -1) zoneColor = ((gI_Gradient.r << 16) + (gI_Gradient.g << 8) + (gI_Gradient.b));
		
		FormatEx(sLine, sizeof(sLine),
			"<font color='#%06X'>%T</font>",
			zoneColor,
			(data.iZoneHUD == ZoneHUD_Start) ? "HudInStartZoneCSGO" : "HudInEndZoneCSGO",
			client,
			data.iSpeed
		);
		AddHUDLine(buffer, maxlen, sLine, iLines);
		
		StrCat(buffer, maxlen, "</pre></font>");
		return iLines;
	}

	// 计时器停止时
	if (data.iTimerStatus == Timer_Stopped && !data.bReplay)
	{
		// 显示基本信息
		// Style Name
		if (data.iStyle >= 0 && data.iStyle < gI_Styles)
		{
			FormatEx(sLine, sizeof(sLine), "<font color='#%s'>%s</font>", gS_StyleStrings[data.iStyle].sHTMLColor, gS_StyleStrings[data.iStyle].sStyleName);
		}
		else
		{
			FormatEx(sLine, sizeof(sLine), "Unknown Style");
		}
		AddHUDLine(buffer, maxlen, sLine, iLines);
		
		// Map Tier
		if (gB_Rankings && (gI_HUD2Settings[client] & HUD2_MAPTIER) == 0)
		{
			// Color Logic for Tier
			col = gI_HUDColors[client][Color_MapTier];
			if (col != -1) {
				FormatEx(sLine, sizeof(sLine), "<font color='#%06X'>%T</font>", col, "HudZoneTier", client, data.iMapTier);
			} else {
				FormatEx(sLine, sizeof(sLine), "%T", "HudZoneTier", client, data.iMapTier);
			}
			AddHUDLine(buffer, maxlen, sLine, iLines);
		}
		
		// Speed
		col = gI_HUDColors[client][Color_Speed];
		if (col != -1) FormatEx(sLine, sizeof(sLine), "<font color='#%06X'>%d u/s</font>", col, data.iSpeed);
		else FormatEx(sLine, sizeof(sLine), "%d u/s", data.iSpeed);
		AddHUDLine(buffer, maxlen, sLine, iLines);
		
		StrCat(buffer, maxlen, "</pre></font>");
		return iLines;
	}
	
	// 处理 Replay Bot (特殊显示)
	if(data.bReplay)
	{
		// [修复] 如果样式为 -1 (Bot空闲/未加载)，直接显示无数据并返回，防止崩溃
		if (data.iStyle < 0 || data.iStyle >= gI_Styles)
		{
			FormatEx(sLine, sizeof(sLine), "No Replay Data");
			AddHUDLine(buffer, maxlen, sLine, iLines);
			StrCat(buffer, maxlen, "</pre></font>");
			return iLines;
		}

		// 这里可以自定义 Replay 的 HUD，为了保持风格一致，我们尽量模仿下面的格式，但简化数据
		// Line 1: Time | Speed
		char sTime[32];
		FormatSeconds(data.fTime, sTime, 32, false);
		FormatEx(sLine, sizeof(sLine), "%s   %d u/s", sTime, data.iSpeed);
		AddHUDLine(buffer, maxlen, sLine, iLines);
		
		// Line 2: Replay Name
		char sPlayerName[MAX_NAME_LENGTH];
		Shavit_GetReplayCacheName(data.iTarget, sPlayerName, sizeof(sPlayerName));
		FormatEx(sLine, sizeof(sLine), "%s", sPlayerName);
		AddHUDLine(buffer, maxlen, sLine, iLines);
		
		// Line 3: WR Time (Total Length)
		char sWR[32];
		FormatSeconds(data.fWR, sWR, 32, false);
		FormatEx(sLine, sizeof(sLine), "Total: %s (%.1f%%)", sWR, ((data.fTime / data.fWR) * 100));
		AddHUDLine(buffer, maxlen, sLine, iLines);
		
		// Line 4: Style
		FormatEx(sLine, sizeof(sLine), "<font color='#%s'>%s</font> | Replay", gS_StyleStrings[data.iStyle].sHTMLColor, gS_StyleStrings[data.iStyle].sStyleName);
		AddHUDLine(buffer, maxlen, sLine, iLines);
		
		StrCat(buffer, maxlen, "</pre></font>");
		return iLines;
	}

	// -------------------------------------------------------------------------
	// NEW LINE 1: 样式名称 | 赛道/难度 #实时排名 (Moved from bottom)
	// -------------------------------------------------------------------------
	
	char sStyleInfo[128];
	sStyleInfo[0] = '\0';
	
	// Logic for Track Info / Tier
	char sTrackInfo[64];
	
	col = gI_HUDColors[client][Color_Track]; // Custom track color
	if (col == -1 && data.iTrack == Track_Main) col = gI_HUDColors[client][Color_MapTier]; // Use tier color if main
	
	// Format Track Text
	char sRawTrack[32];
	if (data.iTrack == Track_Main) {
		if (gB_Rankings && !(data.iHUD2Settings & HUD2_MAPTIER)) {
			Format(sRawTrack, sizeof(sRawTrack), "T%d", data.iMapTier);
		} else {
			sRawTrack = "Main";
		}
	} else {
		if (!(data.iHUD2Settings & HUD2_TRACK)) {
			GetTrackName(client, data.iTrack, sRawTrack, sizeof(sRawTrack));
		} else {
			sRawTrack[0] = '\0'; // Hidden
		}
	}
	
	// Apply Color to Track Name
	if (sRawTrack[0] != '\0') {
		if (col != -1) Format(sTrackInfo, sizeof(sTrackInfo), "<span color='#%06X'>%s</span>", col, sRawTrack);
		else strcopy(sTrackInfo, sizeof(sTrackInfo), sRawTrack);
	}
	
	// Logic for Live Rank
	// 使用实时排名 (进终点前的排名)
	if (gB_WR && data.iTimerStatus == Timer_Running && !(data.iHUD2Settings & HUD2_RANK)) {
		int iLiveRank = Shavit_GetRankForTime(data.iStyle, data.fTime, data.iTrack);
		
		col = gI_HUDColors[client][Color_Rank];
		char sRankText[16];
		if (col != -1) Format(sRankText, sizeof(sRankText), "<span color='#%06X'>#%d</span>", col, iLiveRank);
		else Format(sRankText, sizeof(sRankText), "#%d", iLiveRank);
		
		// 直接显示 #排名, 用空格隔开
		if (data.fTime > 0.0) {
			if (sTrackInfo[0] != '\0')
				Format(sTrackInfo, sizeof(sTrackInfo), "%s %s", sTrackInfo, sRankText);
			else
				strcopy(sTrackInfo, sizeof(sTrackInfo), sRankText);
		}
	}
	
	// Logic for Style Name
	char sStyleNameBuf[64];
	sStyleNameBuf[0] = '\0';
	
	if (!(data.iHUD2Settings & HUD2_STYLE)) {
		if (data.iStyle >= 0 && data.iStyle < gI_Styles) {
			FormatEx(sStyleNameBuf, sizeof(sStyleNameBuf), "<font color='#%s'>%s</font>", gS_StyleStrings[data.iStyle].sHTMLColor, gS_StyleStrings[data.iStyle].sStyleName);
		} else {
			sStyleNameBuf = "Unknown";
		}
	}
	
	// Combine Style + Track Info
	if (sStyleNameBuf[0] != '\0' && sTrackInfo[0] != '\0') {
		FormatEx(sStyleInfo, sizeof(sStyleInfo), "%s | %s", sStyleNameBuf, sTrackInfo);
	} else if (sStyleNameBuf[0] != '\0') {
		FormatEx(sStyleInfo, sizeof(sStyleInfo), "%s", sStyleNameBuf);
	} else if (sTrackInfo[0] != '\0') {
		FormatEx(sStyleInfo, sizeof(sStyleInfo), "%s", sTrackInfo);
	}
	
	if (sStyleInfo[0] != '\0') {
		AddHUDLine(buffer, maxlen, sStyleInfo, iLines);
	}


	// -------------------------------------------------------------------------
	// NEW LINE 2: 时间 (差值)   [间隔]   速度 (差值) (Was Line 1)
	// -------------------------------------------------------------------------
	
	char sTimePart[256] = ""; // Increased buffer for color tags
	char sSpeedPart[256] = "";
	
	// Time Logic (Controlled by HUD2_TIME)
	if (!(data.iHUD2Settings & HUD2_TIME)) {
		char sTime[64], sTimeDiff[64]; // sTime needs more space for color
		
		col = gI_HUDColors[client][Color_Time];
		char sRawTime[32];
		FormatSeconds(data.fTime, sRawTime, 32, false);
		
		if (col != -1) Format(sTime, sizeof(sTime), "<font color='#%06X'>%s</font>", col, sRawTime);
		else strcopy(sTime, sizeof(sTime), sRawTime);
		
		if (data.fClosestReplayTime != -1.0 && !(data.iHUD2Settings & HUD2_TIMEDIFFERENCE)) {
			float fDifference = data.fTime - data.fClosestReplayTime;
			char sDiffVal[32];
			FormatSeconds(fDifference, sDiffVal, 32, false, FloatAbs(fDifference) >= 60.0);
			
			// 绿色为快 (-)，红色为慢 (+)
			int diffColor = (fDifference <= 0.0) ? 0x00FF00 : 0xFF0000;
			Format(sTimeDiff, sizeof(sTimeDiff), " (<font color='#%06X'>%s%s</font>)", diffColor, (fDifference >= 0.0) ? "+" : "", sDiffVal);
		} else {
			sTimeDiff[0] = '\0';
		}
		Format(sTimePart, sizeof(sTimePart), "%s%s", sTime, sTimeDiff);
	}
	
	// Speed Logic (Controlled by HUD2_SPEED)
	if (!(data.iHUD2Settings & HUD2_SPEED)) {
		char sVelDiff[64];
		if (data.fClosestReplayTime != -1.0 && !(data.iHUD2Settings & HUD2_VELOCITYDIFFERENCE)) {
			float res = data.fClosestVelocityDifference;
			// 绿色为快 (+)，红色为慢 (-)
			int velColor = (res >= 0.0) ? 0x00FF00 : 0xFF0000;
			Format(sVelDiff, sizeof(sVelDiff), " (<font color='#%06X'>%s%.0f</font>)", velColor, (res >= 0.0) ? "+" : "", res);
		} else {
			sVelDiff[0] = '\0';
		}
		
		col = gI_HUDColors[client][Color_Speed];
		if (col != -1) Format(sSpeedPart, sizeof(sSpeedPart), "<font color='#%06X'>%d u/s</font>%s", col, data.iSpeed, sVelDiff);
		else Format(sSpeedPart, sizeof(sSpeedPart), "%d u/s%s", data.iSpeed, sVelDiff);
	}
	
	// Combine Line 2
	if (sTimePart[0] != '\0' && sSpeedPart[0] != '\0') {
		FormatEx(sLine, sizeof(sLine), "%s     %s", sTimePart, sSpeedPart);
		AddHUDLine(buffer, maxlen, sLine, iLines);
	} else if (sTimePart[0] != '\0') {
		AddHUDLine(buffer, maxlen, sTimePart, iLines);
	} else if (sSpeedPart[0] != '\0') {
		AddHUDLine(buffer, maxlen, sSpeedPart, iLines);
	}
	
	
	// -------------------------------------------------------------------------
	// NEW LINE 3: PB: xx.xx (#排名)     WR: xx.xx (Was Line 2)
	// -------------------------------------------------------------------------
	// FIX: BUG: Hiding time (HUD2_TIME) also hides WR/PB. 
	// Fix implemented: Check gI_WrPbState (if set to Bottom OR Both) instead of HUD2_TIME.
	
	if (gI_WrPbState[client] == WrPb_Bottom || gI_WrPbState[client] == WrPb_Both) {
		char sPB[64], sWR[64];
		char sPBRankText[64];
		sPBRankText[0] = '\0';
		char sRawPB[32];
		FormatSeconds(data.fPB, sRawPB, sizeof(sRawPB), true);
		col = gI_HUDColors[client][Color_PB];
		if (col != -1) Format(sPB, sizeof(sPB), "<font color='#%06X'>%s</font>", col, (data.fPB > 0.0 ? sRawPB : "N/A"));
		else strcopy(sPB, sizeof(sPB), (data.fPB > 0.0 ? sRawPB : "N/A"));
		if (gB_WR && data.fPB > 0.0 && !(data.iHUD2Settings & HUD2_RANK)) {
			int iPBRank = Shavit_GetRankForTime(data.iStyle, data.fPB, data.iTrack);
			col = gI_HUDColors[client][Color_Rank];
			if (col != -1) Format(sPBRankText, sizeof(sPBRankText), " (<font color='#%06X'>#%d</font>)", col, iPBRank);
			else Format(sPBRankText, sizeof(sPBRankText), " (#%d)", iPBRank);
		}
		char sRawWR[32];
		FormatSeconds(data.fWR, sRawWR, sizeof(sRawWR), true);
		col = gI_HUDColors[client][Color_WR];
		if (col != -1) Format(sWR, sizeof(sWR), "<font color='#%06X'>%s</font>", col, (data.fWR > 0.0 ? sRawWR : "N/A"));
		else strcopy(sWR, sizeof(sWR), (data.fWR > 0.0 ? sRawWR : "N/A"));
		FormatEx(sLine, sizeof(sLine), "PB: %s%s   WR: %s", sPB, sPBRankText, sWR);
		AddHUDLine(buffer, maxlen, sLine, iLines);
	}
	
	// -------------------------------------------------------------------------
	// NEW LINE 4: 跳跃: xx   [间隔]   平移: xx (同步) (Was Line 3)
	// -------------------------------------------------------------------------
	
	char sJumpPart[256] = ""; // Increased from 128 to 256
	char sStrafePart[256] = ""; // Increased from 128 to 256
	
	// Jumps Logic (Controlled by HUD2_JUMPS)
	if (!(data.iHUD2Settings & HUD2_JUMPS)) {
		col = gI_HUDColors[client][Color_Jumps];
		
		if (!Shavit_GetStyleSettingBool(data.iStyle, "autobhop") && (gI_HUDSettings[client] & HUD_PERFS_CENTER)) {
			// Perfs included
			if (col != -1) {
				Format(sJumpPart, sizeof(sJumpPart), "Jumps: <font color='#%06X'>%d (%.1f%%)</font>", col, data.iJumps, Shavit_GetPerfectJumps(data.iTarget));
			} else {
				Format(sJumpPart, sizeof(sJumpPart), "Jumps: %d (%.1f%%)", data.iJumps, Shavit_GetPerfectJumps(data.iTarget));
			}
		} else {
			if (col != -1) {
				Format(sJumpPart, sizeof(sJumpPart), "Jumps: <font color='#%06X'>%d</font>", col, data.iJumps);
			} else {
				Format(sJumpPart, sizeof(sJumpPart), "Jumps: %d", data.iJumps);
			}
		}
	}
	
	// Strafes Logic (Controlled by HUD2_STRAFE)
	if (!(data.iHUD2Settings & HUD2_STRAFE)) {
		char sSync[64];
		// Sync is controlled by HUD2_SYNC
		col = gI_HUDColors[client][Color_Sync];
		if (!(data.iHUD2Settings & HUD2_SYNC) && data.fSync >= 0.0) {
			if (col != -1) Format(sSync, sizeof(sSync), " (<font color='#%06X'>%.1f%%</font>)", col, data.fSync);
			else Format(sSync, sizeof(sSync), " (%.1f%%)", data.fSync);
		} else {
			sSync[0] = '\0';
		}
		
		col = gI_HUDColors[client][Color_Strafes];
		if (col != -1) Format(sStrafePart, sizeof(sStrafePart), "Strafes: <font color='#%06X'>%d</font>%s", col, data.iStrafes, sSync);
		else Format(sStrafePart, sizeof(sStrafePart), "Strafes: %d%s", data.iStrafes, sSync);
	}
	
	// Combine Line 4
	if (sJumpPart[0] != '\0' && sStrafePart[0] != '\0') {
		FormatEx(sLine, sizeof(sLine), "%s     %s", sJumpPart, sStrafePart);
		AddHUDLine(buffer, maxlen, sLine, iLines);
	} else if (sJumpPart[0] != '\0') {
		AddHUDLine(buffer, maxlen, sJumpPart, iLines);
	} else if (sStrafePart[0] != '\0') {
		AddHUDLine(buffer, maxlen, sStrafePart, iLines);
	}

	StrCat(buffer, maxlen, "</pre></font>");

	return iLines;
}

void UpdateMainHUD(int client)
{
	int target = GetSpectatorTarget(client, client);
	bool bReplay = (gB_ReplayPlayback && Shavit_IsReplayEntity(target));

	if((gI_HUDSettings[client] & HUD_CENTER) == 0 ||
		((gI_HUDSettings[client] & HUD_OBSERVE) == 0 && client != target) ||
		(!IsValidClient(target) && !bReplay) ||
		(gEV_Type == Engine_TF2 && IsValidClient(target) && (!gB_FirstPrint[target] || GetEngineTime() - gF_ConnectTime[target] < 1.5))) // TF2 has weird handling for hint text
	{
		return;
	}

	// Prevent flicker when scoreboard is open
	if (IsSource2013(gEV_Type) && (GetClientButtons(client) & IN_SCORE) != 0)
	{
		return;
	}

	float fSpeed[3];
	GetEntPropVector(target, Prop_Data, "m_vecVelocity", fSpeed);

	float fSpeedHUD = ((gI_HUDSettings[client] & HUD_2DVEL) == 0)? GetVectorLength(fSpeed):(SquareRoot(Pow(fSpeed[0], 2.0) + Pow(fSpeed[1], 2.0)));
	ZoneHUD iZoneHUD = ZoneHUD_None;
	float fReplayTime = 0.0;
	float fReplayLength = 0.0;

	huddata_t huddata;
	huddata.iStyle = (bReplay) ? Shavit_GetReplayBotStyle(target) : Shavit_GetBhopStyle(target);
	huddata.iTrack = (bReplay) ? Shavit_GetReplayBotTrack(target) : Shavit_GetClientTrack(target);

	if(!bReplay)
	{
		if (gB_Zones && Shavit_GetClientTime(client) < 0.3)
		{
			if (Shavit_InsideZone(target, Zone_Start, huddata.iTrack))
			{
				iZoneHUD = ZoneHUD_Start;
			}
			else if (Shavit_InsideZone(target, Zone_End, huddata.iTrack))
			{
				iZoneHUD = ZoneHUD_End;
			}
		}
	}
	else
	{
		if (huddata.iStyle != -1)
		{
			fReplayTime = Shavit_GetReplayTime(target);
			fReplayLength = Shavit_GetReplayCacheLength(target);

			fSpeedHUD /= Shavit_GetStyleSettingFloat(huddata.iStyle, "speed") * Shavit_GetStyleSettingFloat(huddata.iStyle, "timescale");
		}

		if (Shavit_GetReplayPlaybackSpeed(target) == 0.5)
		{
			fSpeedHUD *= 2.0;
		}
	}

	huddata.iTarget = target;
	huddata.iSpeed = RoundToNearest(fSpeedHUD);
	huddata.iZoneHUD = iZoneHUD;
	huddata.fTime = (bReplay)? fReplayTime:Shavit_GetClientTime(target);
	huddata.iJumps = (bReplay)? 0:Shavit_GetClientJumps(target);
	huddata.iStrafes = (bReplay)? 0:Shavit_GetStrafeCount(target);
	
	// FIX: Don't call Shavit_GetRankForTime if shavit-wr is not loaded or data is invalid.
	// Also only call it if we actually have a time to rank.
	if (bReplay || !gB_WR || huddata.fTime <= 0.0)
	{
		huddata.iRank = 0;
	}
	else
	{
		huddata.iRank = Shavit_GetRankForTime(huddata.iStyle, huddata.fTime, huddata.iTrack);
	}
	
	huddata.fSync = (bReplay)? 0.0:Shavit_GetSync(target);
	huddata.fPB = (bReplay)? 0.0:Shavit_GetClientPB(target, huddata.iStyle, huddata.iTrack);
	
	// FIX: Don't call Shavit_GetWorldRecord if shavit-wr is not loaded.
	if (bReplay)
	{
		huddata.fWR = fReplayLength;
	}
	else if (!gB_WR)
	{
		huddata.fWR = 0.0;
	}
	else
	{
		huddata.fWR = Shavit_GetWorldRecord(huddata.iStyle, huddata.iTrack);
	}
	
	huddata.iTimerStatus = (bReplay)? Timer_Running:Shavit_GetTimerStatus(target);
	huddata.bReplay = bReplay;
	huddata.bPractice = (bReplay)? false:Shavit_IsPracticeMode(target);
	huddata.iHUDSettings = gI_HUDSettings[client];
	huddata.iHUD2Settings = gI_HUD2Settings[client];
	huddata.iPreviousSpeed = gI_PreviousSpeed[client];
	huddata.iMapTier = gB_Rankings ? Shavit_GetMapTier() : 0;

	if (IsValidClient(target))
	{
		huddata.fAngleDiff = gF_AngleDiff[target];
		huddata.iButtons = gI_Buttons[target];
		huddata.iScrolls = gI_ScrollCount[target];
		huddata.iScrollsPrev = gI_LastScrollCount[target];
	}
	else
	{
		huddata.iButtons = Shavit_GetReplayButtons(target, huddata.fAngleDiff);
		huddata.iScrolls = -1;
		huddata.iScrollsPrev = -1;
	}

	huddata.fClosestReplayTime = -1.0;
	huddata.fClosestVelocityDifference = 0.0;
	huddata.fClosestReplayLength = 0.0;

	if (!bReplay && gB_ReplayPlayback)
	{
		if (Shavit_GetReplayFrameCount(Shavit_GetBhopStyle(target), huddata.iTrack) != 0)
		{
			Shavit_SetClosestReplayStyle(client, Shavit_GetBhopStyle(target));
		}
		else if (Shavit_GetReplayFrameCount(0, huddata.iTrack) != 0)
		{
			Shavit_SetClosestReplayStyle(client, 0);
		}
		else
		{
			Shavit_SetClosestReplayStyle(client, 3);
		}

		if (Shavit_GetReplayFrameCount(Shavit_GetClosestReplayStyle(client), huddata.iTrack) != 0)
		{
			if(Shavit_GetClosestReplayStyle(client) == Shavit_GetBhopStyle(target))
			{
				huddata.fClosestReplayTime = Shavit_GetClosestReplayTime(target, huddata.fClosestReplayLength);
				if (huddata.fClosestReplayTime != -1.0)
				{
					huddata.fClosestVelocityDifference = Shavit_GetClosestReplayVelocityDifference(
						target,
						(gI_HUDSettings[client] & HUD_2DVEL) == 0
					);
				}
			}
			else
			{
				// FIX: Don't call Shavit_GetWorldRecord if shavit-wr is missing.
				// huddata.fWR = gB_WR ? Shavit_GetWorldRecord(0, huddata.iTrack) : 0.0;
				huddata.fClosestReplayTime = Shavit_GetClosestReplayTime(target, huddata.fClosestReplayLength);
			}
		}
	}

	char sBuffer[512];

	Action preresult = Plugin_Continue;
	Call_StartForward(gH_Forwards_PreOnDrawCenterHUD);
	Call_PushCell(client);
	Call_PushCell(target);
	Call_PushStringEx(sBuffer, sizeof(sBuffer), SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushCell(sizeof(sBuffer));
	Call_PushArray(huddata, sizeof(huddata));
	Call_Finish(preresult);

	if (preresult == Plugin_Handled || preresult == Plugin_Stop)
	{
		return;
	}

	if (preresult == Plugin_Continue)
	{
		int lines = 0;

		if (IsSource2013(gEV_Type))
		{
			lines = AddHUDToBuffer_Source2013(client, huddata, sBuffer, sizeof(sBuffer));
		}
		else
		{
			lines = AddHUDToBuffer_CSGO(client, huddata, sBuffer, sizeof(sBuffer));
		}

		if (lines < 1)
		{
			return;
		}
	}

	if (IsSource2013(gEV_Type))
	{
		UnreliablePrintHintText(client, sBuffer);
	}
	else
	{
		if (gCV_UseHUDFix.BoolValue)
		{
			PrintCSGOHUDText(client, sBuffer);
		}
		else
		{
			PrintHintText(client, "%s", sBuffer);
		}
	}
}

void UpdateKeyOverlay(int client, Panel panel, bool &draw)
{
	if((gI_HUDSettings[client] & HUD_KEYOVERLAY) == 0)
	{
		return;
	}

	int target = GetSpectatorTarget(client, client);

	if(((gI_HUDSettings[client] & HUD_OBSERVE) == 0 && client != target))
	{
		return;
	}

	if (IsValidClient(target))
	{
		if (IsClientObserver(target))
		{
			return;
		}
	}
	else if (!(gB_ReplayPlayback && Shavit_IsReplayEntity(target)))
	{
		return;
	}

	float fAngleDiff;
	int buttons;

	if (IsValidClient(target) && !IsFakeClient(target))
	{
		fAngleDiff = gF_AngleDiff[target];
		buttons = gI_Buttons[target];
	}
	else
	{
		buttons = Shavit_GetReplayButtons(target, fAngleDiff);
	}

	int style = (gB_ReplayPlayback && Shavit_IsReplayEntity(target))? Shavit_GetReplayBotStyle(target):Shavit_GetBhopStyle(target);

	if(!(0 <= style < gI_Styles))
	{
		style = 0;
	}

	char sPanelLine[128];

	if(!Shavit_GetStyleSettingBool(style, "autobhop"))
	{
		FormatEx(sPanelLine, 64, " %d%s%d\n", gI_ScrollCount[target], (gI_ScrollCount[target] > 9)? "   ":"     ", gI_LastScrollCount[target]);
	}

	Format(sPanelLine, 128, "%s［%s］　［%s］\n%s  %s  %s\n%s　 %s 　%s\n　%s　　%s", sPanelLine,
		(buttons & IN_JUMP) > 0? "Ｊ":"ｰ", (buttons & IN_DUCK) > 0? "Ｃ":"ｰ",
		(fAngleDiff > 0) ? "←":"   ", (buttons & IN_FORWARD) > 0 ? "Ｗ":"ｰ", (fAngleDiff < 0) ? "→":"",
		(buttons & IN_MOVELEFT) > 0? "Ａ":"ｰ", (buttons & IN_BACK) > 0? "Ｓ":"ｰ", (buttons & IN_MOVERIGHT) > 0? "Ｄ":"ｰ",
		(buttons & IN_LEFT) > 0? "Ｌ":" ", (buttons & IN_RIGHT) > 0? "Ｒ":" ");

	panel.DrawItem(sPanelLine, ITEMDRAW_RAWLINE);

	draw = true;
}

public void Shavit_Bhopstats_OnTouchGround(int client)
{
	gI_LastScrollCount[client] = Shavit_BunnyhopStats.GetScrollCount(client);
}

public void Shavit_Bhopstats_OnJumpPressed(int client)
{
	gI_ScrollCount[client] = Shavit_BunnyhopStats.GetScrollCount(client);
}

void UpdateCenterKeys(int client)
{
	if((gI_HUDSettings[client] & HUD_KEYOVERLAY) == 0)
	{
		return;
	}

	int current_tick = GetGameTickCount();
	static int last_drawn[MAXPLAYERS+1];

	if (current_tick == last_drawn[client])
	{
		return;
	}

	last_drawn[client] = current_tick;

	int target = GetSpectatorTarget(client, client);

	if((gI_HUDSettings[client] & HUD_OBSERVE) == 0 && client != target)
	{
		return;
	}

	if (IsValidClient(target))
	{
		if (IsClientObserver(target))
		{
			return;
		}
	}
	else if (!(gB_ReplayPlayback && Shavit_IsReplayEntity(target)))
	{
		return;
	}

	float fAngleDiff;
	int buttons;
	int scrolls = -1;
	int prevscrolls = -1;

	if (IsValidClient(target))
	{
		if (IsFakeClient(target))
		{
			buttons = Shavit_GetReplayButtons(target, fAngleDiff);
		}
		else
		{
			fAngleDiff = gF_AngleDiff[target];
			buttons = gI_Buttons[target];
		}

		scrolls = gI_ScrollCount[target];
		prevscrolls = gI_LastScrollCount[target];
	}
	else
	{
		buttons = Shavit_GetReplayButtons(target, fAngleDiff);
	}

	int style = (gB_ReplayPlayback && Shavit_IsReplayEntity(target))? Shavit_GetReplayBotStyle(target):Shavit_GetBhopStyle(target);

	if(!(0 <= style < gI_Styles))
	{
		style = 0;
	}

	char sCenterText[512];
	int usable_size = (gEV_Type == Engine_CSGO) ? 512 : 254;

	Action preresult = Plugin_Continue;
	Call_StartForward(gH_Forwards_PreOnDrawKeysHUD);
	Call_PushCell(client);
	Call_PushCell(target);
	Call_PushCell(style);
	Call_PushCell(buttons);
	Call_PushCell(fAngleDiff);
	Call_PushStringEx(sCenterText, usable_size, SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushCell(usable_size);
	Call_PushCell(scrolls);
	Call_PushCell(prevscrolls);
	Call_PushCell(gB_AlternateCenterKeys[client]);
	Call_Finish(preresult);

	if (preresult == Plugin_Handled || preresult == Plugin_Stop)
	{
		return;
	}

	if (preresult == Plugin_Continue)
	{
		FillCenterKeys(client, target, style, buttons, fAngleDiff, sCenterText, usable_size);
	}

	if (IsSource2013(gEV_Type))
	{
		UnreliablePrintCenterText(client, sCenterText);
	}
	else
	{
		PrintCSGOCenterText(client, sCenterText);
	}
}

void FillCenterKeys(int client, int target, int style, int buttons, float fAngleDiff, char[] buffer, int buflen)
{
	if (gEV_Type == Engine_CSGO)
	{
		FormatEx(buffer, buflen, "%s   %s\n%s  %s  %s\n%s　 %s 　%s\n %s　　%s",
			(buttons & IN_JUMP) > 0? "Ｊ":"ｰ", (buttons & IN_DUCK) > 0? "Ｃ":"ｰ",
			(fAngleDiff > 0) ? "<":"ｰ", (buttons & IN_FORWARD) > 0 ? "Ｗ":"ｰ", (fAngleDiff < 0) ? ">":"ｰ",
			(buttons & IN_MOVELEFT) > 0? "Ａ":"ｰ", (buttons & IN_BACK) > 0? "Ｓ":"ｰ", (buttons & IN_MOVERIGHT) > 0? "Ｄ":"ｰ",
			(buttons & IN_LEFT) > 0? "Ｌ":" ", (buttons & IN_RIGHT) > 0? "Ｒ":" ");
	}
	else if (gB_AlternateCenterKeys[client])
	{
		FormatEx(buffer, buflen, "　%s　　%s\n%s   %s   %s\n%s　 %s 　%s\n　%s　　%s",
			(buttons & IN_JUMP) > 0? "J":"_", (buttons & IN_DUCK) > 0? "C":"_",
			(fAngleDiff > 0) ? "<":"  ", (buttons & IN_FORWARD) > 0 ? "W":" _", (fAngleDiff < 0) ? ">":"",
			(buttons & IN_MOVELEFT) > 0? "A":"_", (buttons & IN_BACK) > 0? "S":"_", (buttons & IN_MOVERIGHT) > 0? "D":"_",
			(buttons & IN_LEFT) > 0? "L":" ", (buttons & IN_RIGHT) > 0? "R":" ");
	}
	else
	{
		FormatEx(buffer, buflen, "　  %s　　%s\n  %s   %s   %s\n  %s　 %s 　%s\n　  %s　　%s",
			(buttons & IN_JUMP) > 0? "Ｊ":"ｰ", (buttons & IN_DUCK) > 0? "Ｃ":"ｰ",
			(fAngleDiff > 0) ? "<":"  ", (buttons & IN_FORWARD) > 0 ? "Ｗ":" ｰ", (fAngleDiff < 0) ? ">":"",
			(buttons & IN_MOVELEFT) > 0? "Ａ":"ｰ", (buttons & IN_BACK) > 0? "Ｓ":"ｰ", (buttons & IN_MOVERIGHT) > 0? "Ｄ":"ｰ",
			(buttons & IN_LEFT) > 0? "Ｌ":" ", (buttons & IN_RIGHT) > 0? "Ｒ":" ");
	}

	if(!Shavit_GetStyleSettingBool(style, "autobhop") && IsValidClient(target))
	{
		Format(buffer, buflen, "%s\n　　%s%d %s%s%d", buffer, gI_ScrollCount[target] < 10 ? " " : "", gI_ScrollCount[target], gI_ScrollCount[target] < 10 ? " " : "", gI_LastScrollCount[target] < 10 ? " " : "", gI_LastScrollCount[target]);
	}
}

void PrintCSGOCenterText(int client, const char[] text)
{
	SetHudTextParams(
		-1.0, 0.35,
		0.1,
		255, 255, 255, 255,
		0,
		0.0,
		0.0,
		0.0
	);

	if (gB_DynamicChannels)
	{
		ShowHudText(client, GetDynamicChannel(4), "%s", text);
	}
	else
	{
		ShowSyncHudText(client, gH_HUDCenter, "%s", text);
	}
}

void UpdateSpectatorList(int client, Panel panel, bool &draw)
{
	if((gI_HUDSettings[client] & HUD_SPECTATORS) == 0)
	{
		return;
	}


	if (gI_HUDSettings[client] & HUD_SPECTATORSDEAD && IsPlayerAlive(client))
	{
		return;
	}

	int target = GetSpectatorTarget(client, client);

	if(((gI_HUDSettings[client] & HUD_OBSERVE) == 0 && client != target))
	{
		return;
	}

	int iSpectatorClients[MAXPLAYERS+1];
	int iSpectators = 0;
	bool bIsAdmin = CheckCommandAccess(client, "admin_speclisthide", ADMFLAG_KICK);

	for(int i = 1; i <= MaxClients; i++)
	{
		if(i == client || !IsValidClient(i) || IsFakeClient(i) || !IsClientObserver(i) || GetClientTeam(i) < 1 || GetSpectatorTarget(i, i) != target)
		{
			continue;
		}

		if((gCV_SpectatorList.IntValue == 1 && !bIsAdmin && CheckCommandAccess(i, "admin_speclisthide", ADMFLAG_KICK)) ||
			(gCV_SpectatorList.IntValue == 2 && !CanUserTarget(client, i)))
		{
			continue;
		}

		iSpectatorClients[iSpectators++] = i;
	}

	if(iSpectators > 0)
	{
		char sName[MAX_NAME_LENGTH];
		char sSpectators[32];
		FormatEx(sSpectators, sizeof(sSpectators), "%T (%d):",
			(client == target) ? "SpectatorPersonal" : "SpectatorWatching", client,
			iSpectators);
		panel.DrawItem(sSpectators, ITEMDRAW_RAWLINE);

		for(int i = 0; i < iSpectators; i++)
		{
			if(i == 7)
			{
				panel.DrawItem("...", ITEMDRAW_RAWLINE);

				break;
			}

			GetClientName(iSpectatorClients[i], sName, sizeof(sName));
			ReplaceString(sName, sizeof(sName), "#", "?");
			TrimDisplayString(sName, sName, sizeof(sName), gCV_SpecNameSymbolLength.IntValue);

			panel.DrawItem(sName, ITEMDRAW_RAWLINE);
		}

		draw = true;
	}
}

void UpdateTopLeftHUD(int client, bool wait)
{
	if (wait && gI_Cycle % 20 != 0)
	{
		return;
	}

	int target = GetSpectatorTarget(client, client);
	bool bReplay = (gB_ReplayPlayback && Shavit_IsReplayEntity(target));

	if (!bReplay && !IsValidClient(target))
	{
		return;
	}

	int track = 0;
	int style = 0;
	// float fTargetPB = 0.0;

	if (!bReplay)
	{
		style = Shavit_GetBhopStyle(target);
		track = Shavit_GetClientTrack(target);
		// fTargetPB = Shavit_GetClientPB(target, style, track);
	}
	else
	{
		style = Shavit_GetReplayBotStyle(target);
		track = Shavit_GetReplayBotTrack(target);
	}

	style = (style == -1) ? 0 : style; // central replay bot probably
	track = (track == -1) ? 0 : track; // central replay bot probably

	if (!(0 <= style < gI_Styles) || !(0 <= track <= TRACKS_SIZE))
	{
		return;
	}

	char sTopLeft[512];

	Action preresult = Plugin_Continue;
	bool forceUpdate = false;

	Call_StartForward(gH_Forwards_PreOnTopLeftHUD);
	Call_PushCell(client);
	Call_PushCell(target);
	Call_PushStringEx(sTopLeft, sizeof(sTopLeft), SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushCell(sizeof(sTopLeft));
	Call_PushCell(track);
	Call_PushCell(style);
	Call_PushCellRef(forceUpdate);
	Call_Finish(preresult);

	if (preresult == Plugin_Handled || preresult == Plugin_Stop)
	{
		return;
	}

	if (!(gI_HUDSettings[client] & HUD_TOPLEFT) && !forceUpdate)
	{
		return;
	}

	if ((gI_HUDSettings[client] & HUD_TOPLEFT))
	{
		sTopLeft[0] = '\0'; // Default empty

		// Only show Target PB when spectating
		// Standard Logic (Kept for compatibility if not using Tri-state or for default view)
		// But if using Tri-State TopLeft, we override or append.
		
		// NEW: WR/PB Tri-state for Top Left
		if ((gI_WrPbState[client] == WrPb_TopLeft || gI_WrPbState[client] == WrPb_Both) && gB_WR)
		{
			// Get Data
			float fPB = Shavit_GetClientPB(target, style, track);
			float fWR = Shavit_GetWorldRecord(style, track);

			// Logic to hide if no records exist (requested optimization)
			// If both WR and PB are 0 (or less/none), we simply don't append anything to sTopLeft.
			// However, usually WR exists if PB exists.
			
			if (fWR > 0.0) 
			{
				// Add separator if text exists
				if (strlen(sTopLeft) > 0) StrCat(sTopLeft, sizeof(sTopLeft), "\n");
				
				char sPB[32], sWR[32];
				if (fWR > 0.0) FormatSeconds(fWR, sWR, sizeof(sWR), true); // Changed to true to force full format
				else sWR = "N/A";

				// Try to get cached WR name
				char sWRName[MAX_NAME_LENGTH];
				GetCachedWRName(style, track, sWRName, sizeof(sWRName));

				// Format WR Line
                if (sWRName[0] != '\0')
                {
				    Format(sTopLeft, sizeof(sTopLeft), "%sWR: %s (%s)", sTopLeft, sWR, sWRName);
                }
                else
                {
                    Format(sTopLeft, sizeof(sTopLeft), "%sWR: %s", sTopLeft, sWR);
                }

				// Only add PB line if PB exists
				if (fPB > 0.0)
				{
					FormatSeconds(fPB, sPB, sizeof(sPB), true); // Changed to true to force full format
					int iPBRank = Shavit_GetRankForTime(style, fPB, track);
					Format(sTopLeft, sizeof(sTopLeft), "%s\nPB: %s (#%d)", sTopLeft, sPB, iPBRank);
				}
			}
			// If fWR <= 0.0, we assume no records at all, so we print nothing extra.
		}
		else if (target != client && gB_WR) 
		{
			// Fallback: Old logic for spectating target PB if not using new mode
			float fTargetPB = Shavit_GetClientPB(target, style, track);
			if (fTargetPB > 0.0)
			{
				char sTargetPB[64];
				FormatSeconds(fTargetPB, sTargetPB, sizeof(sTargetPB), true); // Changed to true to force full format
				Format(sTopLeft, sizeof(sTopLeft), "%T: %s", "HudBestText", client, sTargetPB);
			}
		}
	}

	Action postresult = Plugin_Continue;
	Call_StartForward(gH_Forwards_OnTopLeftHUD);
	Call_PushCell(client);
	Call_PushCell(target);
	Call_PushStringEx(sTopLeft, sizeof(sTopLeft), SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushCell(sizeof(sTopLeft));
	Call_PushCell(track);
	Call_PushCell(style);
	Call_Finish(postresult);

	if (postresult != Plugin_Continue && postresult != Plugin_Changed)
	{
		return;
	}

	SetHudTextParams(0.01, 0.01, 3.01, 255, 100, 255, 255, 0, 0.0, 0.0, 0.0);

	if (gB_DynamicChannels)
	{
		ShowHudText(client, GetDynamicChannel(5), "%s", sTopLeft);
	}
	else
	{
		ShowSyncHudText(client, gH_HUDTopleft, "%s", sTopLeft);
	}
}

void UpdateKeyHint(int client)
{
	if ((gI_Cycle % 10) != 0 || !IsValidClient(client))
	{
		return;
	}

	char sMessage[256];
	int iTimeLeft = -1;

	int target = GetSpectatorTarget(client, client);

	int bReplay = gB_ReplayPlayback && Shavit_IsReplayEntity(target);
	int style;
	int track;

	if (!bReplay)
	{
		if (target > 0 && target <= MaxClients)
		{
			style = Shavit_GetBhopStyle(target);
			track = Shavit_GetClientTrack(target);
		}
	}
	else
	{
		style = Shavit_GetReplayBotStyle(target);
		track = Shavit_GetReplayBotTrack(target);
	}

	style = (style == -1) ? 0 : style;
	track = (track == -1) ? 0 : track;

	if (!(0 <= style < gI_Styles) || !(0 <= track <= TRACKS_SIZE))
	{
		return;
	}

	Action preresult = Plugin_Continue;
	bool forceUpdate = false;

	Call_StartForward(gH_Forwards_PreOnKeyHintHUD);
	Call_PushCell(client);
	Call_PushCell(target);
	Call_PushStringEx(sMessage, sizeof(sMessage), SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushCell(sizeof(sMessage));
	Call_PushCell(track);
	Call_PushCell(style);
	Call_PushCellRef(forceUpdate);
	Call_Finish(preresult);

	if (preresult == Plugin_Handled || preresult == Plugin_Stop)
	{
		return;
	}

	if (!forceUpdate && !(gI_HUDSettings[client] & HUD_SYNC) && gI_HUDSettings[client] & HUD2_LANDFIX && !(gI_HUDSettings[client] & HUD_TIMELEFT) && gI_HUD2Settings[client] & HUD2_PERFS)
	{
		return;
	}

	if (LibraryExists("modern-landfix"))
	{
		if (((gI_HUD2Settings[client] & HUD2_LANDFIX) == 0) && (target > 0 && target <= MaxClients))
		{
			FormatEx(sMessage, 256, "%s", Landfix_GetLandfixEnabled(target)?"Landfix On\n\n":"");
		}
	}

	if ((gI_HUDSettings[client] & HUD_TIMELEFT) > 0 && GetMapTimeLeft(iTimeLeft) && iTimeLeft > 0)
	{
		FormatEx(sMessage, 256, (iTimeLeft > 150)? "%s%T: %d minutes":"%s%T: %d seconds", sMessage, "HudTimeLeft", client, (iTimeLeft > 150) ? (iTimeLeft / 60)+1 : iTimeLeft);
	}

	if (target == client || (gI_HUDSettings[client] & HUD_OBSERVE) > 0)
	{
		if (!bReplay && !IsValidClient(target))
		{
			return;
		}

		if (!bReplay && Shavit_GetTimerStatus(target) != Timer_Stopped)
		{
			bool perf_double_newline = true;

			if ((gI_HUDSettings[client] & HUD_SYNC) > 0 && Shavit_GetStyleSettingBool(style, "sync"))
			{
				perf_double_newline = false;
				Format(sMessage, 256, "%s%s%T: %.01f", sMessage, (strlen(sMessage) > 0)? "\n\n":"", "HudSync", client, Shavit_GetSync(target));
			}

			if (!Shavit_GetStyleSettingBool(style, "autobhop") && (gI_HUD2Settings[client] & HUD2_PERFS) == 0)
			{
				Format(sMessage, 256, "%s%s\n%T: %.1f", sMessage, perf_double_newline ? "\n":"", "HudPerfs", client, Shavit_GetPerfectJumps(target));
			}
		}

		if ((gI_HUDSettings[client] & HUD_SPECTATORS) > 0 && (!(gI_HUDSettings[client] & HUD_SPECTATORSDEAD) || !IsPlayerAlive(client)))
		{
			int iSpectatorClients[MAXPLAYERS+1];
			int iSpectators = 0;
			bool bIsAdmin = CheckCommandAccess(client, "admin_speclisthide", ADMFLAG_KICK);

			for (int i = 1; i <= MaxClients; i++)
			{
				if (i == client || !IsValidClient(i) || IsFakeClient(i) || !IsClientObserver(i) || GetClientTeam(i) < 1 || GetSpectatorTarget(i, i) != target)
				{
					continue;
				}

				if ((gCV_SpectatorList.IntValue == 1 && !bIsAdmin && CheckCommandAccess(i, "admin_speclisthide", ADMFLAG_KICK)) ||
				    (gCV_SpectatorList.IntValue == 2 && !CanUserTarget(client, i)))
				{
					continue;
				}

				iSpectatorClients[iSpectators++] = i;
			}

			if (iSpectators > 0)
			{
				Format(sMessage, 256, "%s%s%spectators (%d):", sMessage, (strlen(sMessage) > 0)? "\n\n":"", (client == target)? "S":"Other S", iSpectators);
				char sName[MAX_NAME_LENGTH];

				for (int i = 0; i < iSpectators; i++)
				{
					if (i == 7)
					{
						Format(sMessage, 256, "%s\n...", sMessage);
						break;
					}

					GetClientName(iSpectatorClients[i], sName, sizeof(sName));
					ReplaceString(sName, sizeof(sName), "#", "?");
					TrimDisplayString(sName, sName, sizeof(sName), gCV_SpecNameSymbolLength.IntValue);
					Format(sMessage, 256, "%s\n%s", sMessage, sName);
				}
			}
		}
	}

	Action postresult = Plugin_Continue;
	Call_StartForward(gH_Forwards_OnKeyHintHUD);
	Call_PushCell(client);
	Call_PushCell(target);
	Call_PushStringEx(sMessage, sizeof(sMessage), SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushCell(sizeof(sMessage));
	Call_PushCell(track);
	Call_PushCell(style);
	Call_Finish(postresult);

	if (postresult == Plugin_Handled || postresult == Plugin_Stop)
	{
		return;
	}

	if (strlen(sMessage) > 0)
	{
		Handle hKeyHintText = StartMessageOne("KeyHintText", client);
		BfWriteByte(hKeyHintText, 1);
		BfWriteString(hKeyHintText, sMessage);
		EndMessage();
	}
}

public int PanelHandler_Nothing(Menu m, MenuAction action, int param1, int param2)
{
	// i don't need anything here
	return 0;
}

public void Shavit_OnStyleChanged(int client, int oldstyle, int newstyle, int track, bool manual)
{
	if(IsClientInGame(client))
	{
		UpdateTopLeftHUD(client, false);
	}
}

public void Shavit_OnTrackChanged(int client, int oldtrack, int newtrack)
{
	if (IsClientInGame(client))
	{
		UpdateTopLeftHUD(client, false);
	}
}

public int Native_ForceHUDUpdate(Handle handler, int numParams)
{
	int clients[MAXPLAYERS+1];
	int count = 0;

	int client = GetNativeCell(1);

	if(!IsValidClient(client))
	{
		ThrowNativeError(200, "Invalid client index %d", client);

		return -1;
	}

	clients[count++] = client;

	if(view_as<bool>(GetNativeCell(2)))
	{
		for(int i = 1; i <= MaxClients; i++)
		{
			if(i == client || !IsValidClient(i) || GetSpectatorTarget(i, i) != client)
			{
				continue;
			}

			clients[count++] = client;
		}
	}

	for(int i = 0; i < count; i++)
	{
		TriggerHUDUpdate(clients[i]);
	}

	return count;
}

public int Native_GetHUDSettings(Handle handler, int numParams)
{
	int client = GetNativeCell(1);

	if(!IsValidClient(client))
	{
		ThrowNativeError(200, "Invalid client index %d", client);

		return -1;
	}

	return gI_HUDSettings[client];
}

public int Native_GetHUD2Settings(Handle handler, int numParams)
{
	int client = GetNativeCell(1);
	return gI_HUD2Settings[client];
}

void UnreliablePrintCenterText(int client, const char[] str)
{
	int clients[1];
	clients[0] = client;

	// Start our own message instead of using PrintCenterText so we can exclude USERMSG_RELIABLE.
	// This makes the HUD update visually faster.
	BfWrite msg = view_as<BfWrite>(StartMessageEx(gI_TextMsg, clients, 1, USERMSG_BLOCKHOOKS));
	msg.WriteByte(HUD_PRINTCENTER);
	msg.WriteString(str);
	msg.WriteString("");
	msg.WriteString("");
	msg.WriteString("");
	msg.WriteString("");
	EndMessage();
}

void UnreliablePrintHintText(int client, const char[] str)
{
	int clients[1];
	clients[0] = client;

	// Start our own message instead of using PrintHintText so we can exclude USERMSG_RELIABLE.
	// This makes the HUD update visually faster.
	BfWrite msg = view_as<BfWrite>(StartMessageEx(gI_HintText, clients, 1, USERMSG_BLOCKHOOKS));
	msg.WriteString(str);
	EndMessage();
}

void PrintCSGOHUDText(int client, const char[] str)
{
	char buff[MAX_HINT_SIZE];
	FormatEx(buff, sizeof(buff), "</font>%s%s", str, gS_HintPadding);

	int clients[1];
	clients[0] = client;

	Protobuf pb = view_as<Protobuf>(StartMessageEx(gI_TextMsg, clients, 1, USERMSG_BLOCKHOOKS));
	pb.SetInt("msg_dst", HUD_PRINTCENTER);
	pb.AddString("params", "#SFUI_ContractKillStart");
	pb.AddString("params", buff);
	pb.AddString("params", NULL_STRING);
	pb.AddString("params", NULL_STRING);
	pb.AddString("params", NULL_STRING);
	pb.AddString("params", NULL_STRING);

	EndMessage();
}