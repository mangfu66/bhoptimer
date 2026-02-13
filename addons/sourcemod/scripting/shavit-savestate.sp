#include <sourcemod>
#include <convar_class>
#include <sdktools>
#include <shavit>
#include <shavit/replay-file>
#include <shavit/replay-stocks.sp>

#undef REQUIRE_PLUGIN
#include <eventqueuefix>

#pragma newdecls required
#pragma semicolon 1

cp_cache_t g_aSavestates[MAXPLAYERS+1];
frame_cache_t g_aReplayCache[MAXPLAYERS+1];
chatstrings_t g_sChatStrings;
stylestrings_t g_sStyleStrings[STYLE_LIMIT];

bool g_bLate = false;
Handle g_hSavesDB = INVALID_HANDLE;
float g_fTickrate = 0.0;
int g_iStyleCount;
char g_sReplayFolder[PLATFORM_MAX_PATH];
char g_sCurrentMap[128];

bool g_bHasAnySaves[MAXPLAYERS+1];
bool g_bHasCurrentMapSaves[MAXPLAYERS+1];
bool g_bHasSave[MAXPLAYERS+1][STYLE_LIMIT][TRACKS_SIZE];
float g_fSaveTime[MAXPLAYERS+1][STYLE_LIMIT][TRACKS_SIZE];
int g_iSaveDate[MAXPLAYERS+1][STYLE_LIMIT][TRACKS_SIZE];
bool g_bNotified[MAXPLAYERS+1];
bool g_bHasAutosave[MAXPLAYERS+1][STYLE_LIMIT][TRACKS_SIZE];
float g_fAutosaveTime[MAXPLAYERS+1][STYLE_LIMIT][TRACKS_SIZE];
int g_iAutosaveDate[MAXPLAYERS+1][STYLE_LIMIT][TRACKS_SIZE];
bool g_bAutosaveNotified[MAXPLAYERS+1];

ConVar g_cvSaveReplayOverWR = null;
ConVar g_cvSaveExpiration = null;
ConVar g_cvAutosaveExpiration = null;

public Plugin myinfo =
{
	name = "[shavit] Savestate",
	author = "olivia",
	description = "Allow saving and loading savestates in shavit's bhoptimer",
	version = "1.2",
	url = "https://KawaiiClan.com"
}

public void OnPluginStart()
{
	// Removed InitSavesDB call from here, it's handled in Shavit_OnDatabaseLoaded
	g_fTickrate = (1.0 / GetTickInterval());

	RegConsoleCmd("sm_savestate", Command_Savestate, "保存或加载计时器状态");
	RegConsoleCmd("sm_savestates", Command_Savestate, "保存或加载计时器状态");
	RegConsoleCmd("sm_savegame", Command_Savestate, "保存或加载计时器状态");
	RegConsoleCmd("sm_savetimer", Command_Savestate, "保存或加载计时器状态");
	RegConsoleCmd("sm_load", Command_Savestate, "保存或加载计时器状态");
	RegConsoleCmd("sm_loadgame", Command_Savestate, "保存或加载计时器状态");
	RegConsoleCmd("sm_loadtimer", Command_Savestate, "保存或加载计时器状态");
	
	g_cvSaveReplayOverWR = new Convar("shavit_savestate_savereplayoverwr", "0", "如果玩家时间慢于世界纪录，是否保存回放帧", 0, true, 0.0, true, 1.0);
	g_cvSaveExpiration = new Convar("shavit_savestate_expiration", "2592000", "手动保存状态的过期时间（秒）。过期的手动保存将被自动删除。\n-1 - 永不过期\n0 - 禁用（保留所有手动保存）\n默认: 2592000 (30天)", 0, true, -1.0);
	g_cvAutosaveExpiration = new Convar("shavit_savestate_autosave_expiration", "86400", "自动保存的过期时间（秒）。玩家断线时自动保存，重连时自动加载。定时清理任务每5分钟运行一次。\n-1 - 永不过期\n0 - 禁用自动保存功能\n默认: 86400 (1天)\n最大: 31536000 (365天)", 0, true, -1.0, true, 31536000.0);
	Convar.AutoExecConfig();

	// Create timer for cleanup (runs every 5 minutes)
	CreateTimer(300.0, Timer_CleanupOldSaves, 0, TIMER_REPEAT);

	if(g_bLate)
	{
		for(int i = 1; i <= MaxClients; i++)
		{
			if(IsValidClient(i))
				OnClientPutInServer(i);
		}

		Shavit_OnChatConfigLoaded();
		Shavit_OnStyleConfigLoaded(-1);
		GetLowercaseMapName(g_sCurrentMap);
		
		// Attempt to grab the database if we loaded late
		Shavit_OnDatabaseLoaded();
	}
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLate = late;
	return APLRes_Success;
}

public void Shavit_OnChatConfigLoaded()
{
	Shavit_GetChatStringsStruct(g_sChatStrings);
}

public void Shavit_OnStyleConfigLoaded(int styles)
{
	if(styles == -1)
		styles = Shavit_GetStyleCount();

	for(int i = 0; i < styles; i++)
		Shavit_GetStyleStrings(i, sStyleName, g_sStyleStrings[i].sStyleName, sizeof(stylestrings_t::sStyleName));

	g_iStyleCount = styles;

	if(!Shavit_GetReplayFolderPath_Stock(g_sReplayFolder))
		SetFailState("无法加载回放机器人的配置文件。请确保文件存在 (addons/sourcemod/configs/shavit-replay.cfg) 且语法正确！");

	char sSavedGamesPath[PLATFORM_MAX_PATH];
	FormatEx(sSavedGamesPath, sizeof(sSavedGamesPath), "%s/savedgames", g_sReplayFolder);
	if(!DirExists(sSavedGamesPath) && !CreateDirectory(sSavedGamesPath, 511))
		SetFailState("无法创建回放文件夹 (%s)。请确保您有文件权限", sSavedGamesPath);
}

public void OnMapStart()
{
	GetLowercaseMapName(g_sCurrentMap);
}

public void OnClientPutInServer(int client)
{
	for(int i = 0; i < STYLE_LIMIT; i++)
	{
		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			g_bHasAutosave[client][i][j] = false;
			g_fAutosaveTime[client][i][j] = 0.0;
			g_iAutosaveDate[client][i][j] = 0;
		}
	}
	g_bAutosaveNotified[client] = false;
	GetClientSaves(client);
	CheckAutosave(client);
}

public void OnClientDisconnect(int client)
{
	// Only auto-save if autosave feature is enabled and timer is running
	if (g_cvAutosaveExpiration.IntValue == 0)
		return;
	
	if (!IsValidClient(client) || IsFakeClient(client) || GetSteamAccountID(client) == 0)
		return;
	
	// Check timer status - save if Running or Paused (same as manual save logic)
	// Don't save if Stopped (includes noclip players who have no active timer)
	TimerStatus status = Shavit_GetTimerStatus(client);
	if (status == Timer_Stopped)
		return;
	
	AutosaveGame(client);
}

// Forward from Shavit core when DB is ready
public void Shavit_OnDatabaseLoaded()
{
	g_hSavesDB = Shavit_GetDatabase();
	
	if(g_hSavesDB != INVALID_HANDLE)
	{
		CreateSavesTables(g_hSavesDB);
	}
	else if (g_bLate)
	{
		LogError("延迟加载时无法获取 shavit 数据库句柄。");
	}
}

// Replaces InitSavesDB
void CreateSavesTables(Handle db)
{
	char sQuery[4096];
	// Manual saves table - with track column in CREATE for new installations
	FormatEx(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `saves` (`map` varchar(100) NOT NULL, `auth` int NOT NULL, `style` int NOT NULL, `track` int NOT NULL DEFAULT 0, `date` int NOT NULL, `TbTimerEnabled` int NOT NULL, `TfCurrentTime` float NOT NULL, `TbClientPaused` int NOT NULL, `TiJumps` int NOT NULL, `TiStrafes` int NOT NULL, `TiTotalMeasures` int, `TiGoodGains` int, `TfServerTime` int NOT NULL, `TiKeyCombo` int NOT NULL, `TiTimerTrack` int NOT NULL, `TiMeasuredJumps` int, `TiPerfectJumps` int, `TfZoneOffset1` float, `TfZoneOffset2` float, `TfDistanceOffset1` float, `TfDistanceOffset2` float, `TfAvgVelocity` float, `TfMaxVelocity` float, `TfTimescale` float NOT NULL, `TiZoneIncrement` int, `TiFullTicks` int NOT NULL, `TiFractionalTicks` int NOT NULL, `TbPracticeMode` int NOT NULL, `TbJumped` int NOT NULL, `TbCanUseAllKeys` int NOT NULL, `TbOnGround` int NOT NULL, `TiLastButtons` int, `TfLastAngle` float, `TiLandingTick` int, `TiLastMoveType` int, `TfStrafeWarning` float, `TfLastInputVel1` float, `TfLastInputVel2` float, `Tfplayer_speedmod` float, `TfNextFrameTime` float, `TiLastMoveTypeTAS` int, `CfPosition1` float NOT NULL, `CfPosition2` float NOT NULL, `CfPosition3` float NOT NULL, `CfAngles1` float NOT NULL, `CfAngles2` float NOT NULL, `CfAngles3` float NOT NULL, `CfVelocity1` float NOT NULL, `CfVelocity2` float NOT NULL, `CfVelocity3` float NOT NULL, `CiMovetype` int NOT NULL, `CfGravity` float NOT NULL, `CfSpeed` float NOT NULL, `CfStamina` float NOT NULL, `CbDucked` int NOT NULL, `CbDucking` int NOT NULL, `CfDuckTime` float, `CfDuckSpeed` float, `CiFlags` int NOT NULL, `CsTargetname` varchar(64) NOT NULL, `CsClassname` varchar(64) NOT NULL, `CiPreFrames` int NOT NULL, `CbSegmented` int NOT NULL, `CiGroundEntity` int, `CvecLadderNormal1` float, `CvecLadderNormal2` float, `CvecLadderNormal3` float, `Cm_bHasWalkMovedSinceLastJump` int, `Cm_ignoreLadderJumpTime` float, `Cm_lastStandingPos1` float, `Cm_lastStandingPos2` float, `Cm_lastStandingPos3` float, `Cm_ladderSuppressionTimer1` float, `Cm_ladderSuppressionTimer2` float, `Cm_lastLadderNormal1` float, `Cm_lastLadderNormal2` float, `Cm_lastLadderNormal3` float, `Cm_lastLadderPos1` float, `Cm_lastLadderPos2` float, `Cm_lastLadderPos3` float, `Cm_afButtonDisabled` int, `Cm_afButtonForced` int, UNIQUE KEY `unique_index` (`map`,`auth`,`style`,`track`)) ENGINE=INNODB;");
	SQL_TQuery(db, SQL_InitSavesDB, sQuery);
	
	FormatEx(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `saves-events` (`type` varchar(16) NOT NULL, `id` int NOT NULL, `map` varchar(100) NOT NULL, `auth` int NOT NULL, `style` int NOT NULL, `track_id` int NOT NULL DEFAULT 0, `Etarget` varchar(512), `EtargetInput` varchar(512), `EvariantValue` varchar(512), `Edelay` float, `Eactivator` int, `Ecaller` int, `EoutputID` int, `EwaitTime` float, UNIQUE KEY `unique_index` (`type`, `id`, `map`, `auth`,`style`,`track_id`)) ENGINE=INNODB;");
	SQL_TQuery(db, SQL_InitSavesDB, sQuery);
	
	FormatEx(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `saves-customdata` (`id` int NOT NULL, `map` varchar(100) NOT NULL, `auth` int NOT NULL, `style` int NOT NULL, `track` int NOT NULL DEFAULT 0, `key` varchar(64) NOT NULL, `value` varchar(64) NOT NULL, UNIQUE KEY `unique_index` (`id`, `map`,`auth`,`style`,`track`)) ENGINE=INNODB;");
	SQL_TQuery(db, SQL_InitSavesDB, sQuery);
	
	// Autosave tables (separate from manual saves) - with track column in CREATE for new installations
	FormatEx(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `autosaves` (`map` varchar(100) NOT NULL, `auth` int NOT NULL, `style` int NOT NULL, `track` int NOT NULL DEFAULT 0, `disconnect_time` int NOT NULL, `TbTimerEnabled` int NOT NULL, `TfCurrentTime` float NOT NULL, `TbClientPaused` int NOT NULL, `TiJumps` int NOT NULL, `TiStrafes` int NOT NULL, `TiTotalMeasures` int, `TiGoodGains` int, `TfServerTime` int NOT NULL, `TiKeyCombo` int NOT NULL, `TiTimerTrack` int NOT NULL, `TiMeasuredJumps` int, `TiPerfectJumps` int, `TfZoneOffset1` float, `TfZoneOffset2` float, `TfDistanceOffset1` float, `TfDistanceOffset2` float, `TfAvgVelocity` float, `TfMaxVelocity` float, `TfTimescale` float NOT NULL, `TiZoneIncrement` int, `TiFullTicks` int NOT NULL, `TiFractionalTicks` int NOT NULL, `TbPracticeMode` int NOT NULL, `TbJumped` int NOT NULL, `TbCanUseAllKeys` int NOT NULL, `TbOnGround` int NOT NULL, `TiLastButtons` int, `TfLastAngle` float, `TiLandingTick` int, `TiLastMoveType` int, `TfStrafeWarning` float, `TfLastInputVel1` float, `TfLastInputVel2` float, `Tfplayer_speedmod` float, `TfNextFrameTime` float, `TiLastMoveTypeTAS` int, `CfPosition1` float NOT NULL, `CfPosition2` float NOT NULL, `CfPosition3` float NOT NULL, `CfAngles1` float NOT NULL, `CfAngles2` float NOT NULL, `CfAngles3` float NOT NULL, `CfVelocity1` float NOT NULL, `CfVelocity2` float NOT NULL, `CfVelocity3` float NOT NULL, `CiMovetype` int NOT NULL, `CfGravity` float NOT NULL, `CfSpeed` float NOT NULL, `CfStamina` float NOT NULL, `CbDucked` int NOT NULL, `CbDucking` int NOT NULL, `CfDuckTime` float, `CfDuckSpeed` float, `CiFlags` int NOT NULL, `CsTargetname` varchar(64) NOT NULL, `CsClassname` varchar(64) NOT NULL, `CiPreFrames` int NOT NULL, `CbSegmented` int NOT NULL, `CiGroundEntity` int, `CvecLadderNormal1` float, `CvecLadderNormal2` float, `CvecLadderNormal3` float, `Cm_bHasWalkMovedSinceLastJump` int, `Cm_ignoreLadderJumpTime` float, `Cm_lastStandingPos1` float, `Cm_lastStandingPos2` float, `Cm_lastStandingPos3` float, `Cm_ladderSuppressionTimer1` float, `Cm_ladderSuppressionTimer2` float, `Cm_lastLadderNormal1` float, `Cm_lastLadderNormal2` float, `Cm_lastLadderNormal3` float, `Cm_lastLadderPos1` float, `Cm_lastLadderPos2` float, `Cm_lastLadderPos3` float, `Cm_afButtonDisabled` int, `Cm_afButtonForced` int, UNIQUE KEY `unique_index` (`map`,`auth`,`style`,`track`)) ENGINE=INNODB;");
	SQL_TQuery(db, SQL_InitSavesDB, sQuery);
	
	FormatEx(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `autosaves-events` (`type` varchar(16) NOT NULL, `id` int NOT NULL, `map` varchar(100) NOT NULL, `auth` int NOT NULL, `style` int NOT NULL, `track_id` int NOT NULL DEFAULT 0, `Etarget` varchar(512), `EtargetInput` varchar(512), `EvariantValue` varchar(512), `Edelay` float, `Eactivator` int, `Ecaller` int, `EoutputID` int, `EwaitTime` float, UNIQUE KEY `unique_index` (`type`, `id`, `map`, `auth`,`style`,`track_id`)) ENGINE=INNODB;");
	SQL_TQuery(db, SQL_InitSavesDB, sQuery);
	
	FormatEx(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `autosaves-customdata` (`id` int NOT NULL, `map` varchar(100) NOT NULL, `auth` int NOT NULL, `style` int NOT NULL, `track` int NOT NULL DEFAULT 0, `key` varchar(64) NOT NULL, `value` varchar(64) NOT NULL, UNIQUE KEY `unique_index` (`id`, `map`,`auth`,`style`,`track`)) ENGINE=INNODB;");
	SQL_TQuery(db, SQL_InitSavesDB, sQuery);
	
	// Migrate existing tables by adding track column if it doesn't exist
	MigrateTablesForTrack(db);
}

void MigrateTablesForTrack(Handle db)
{
	char sQuery[1024];
	
	// Migrate saves table
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `saves` ADD COLUMN `track` int NOT NULL DEFAULT 0 AFTER `style`;");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 1);
	
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `saves` DROP INDEX `unique_index`, ADD UNIQUE KEY `unique_index` (`map`,`auth`,`style`,`track`);");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 1);
	
	// Migrate saves-events table
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `saves-events` ADD COLUMN `track_id` int NOT NULL DEFAULT 0 AFTER `style`;");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 2);
	
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `saves-events` DROP INDEX `unique_index`, ADD UNIQUE KEY `unique_index` (`type`, `id`, `map`, `auth`,`style`,`track_id`);");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 2);
	
	// Migrate saves-customdata table
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `saves-customdata` ADD COLUMN `track` int NOT NULL DEFAULT 0 AFTER `style`;");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 3);
	
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `saves-customdata` DROP INDEX `unique_index`, ADD UNIQUE KEY `unique_index` (`id`, `map`,`auth`,`style`,`track`);");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 3);
	
	// Migrate autosaves table
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `autosaves` ADD COLUMN `track` int NOT NULL DEFAULT 0 AFTER `style`;");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 4);
	
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `autosaves` DROP INDEX `unique_index`, ADD UNIQUE KEY `unique_index` (`map`,`auth`,`style`,`track`);");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 4);
	
	// Migrate autosaves-events table
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `autosaves-events` ADD COLUMN `track_id` int NOT NULL DEFAULT 0 AFTER `style`;");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 5);
	
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `autosaves-events` DROP INDEX `unique_index`, ADD UNIQUE KEY `unique_index` (`type`, `id`, `map`, `auth`,`style`,`track_id`);");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 5);
	
	// Migrate autosaves-customdata table
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `autosaves-customdata` ADD COLUMN `track` int NOT NULL DEFAULT 0 AFTER `style`;");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 6);
	
	FormatEx(sQuery, sizeof(sQuery), "ALTER TABLE `autosaves-customdata` DROP INDEX `unique_index`, ADD UNIQUE KEY `unique_index` (`id`, `map`,`auth`,`style`,`track`);");
	SQL_TQuery(db, SQL_MigrateCallback, sQuery, 6);
}

public void SQL_MigrateCallback(Handle owner, Handle hndl, const char[] error, any tableNum)
{
	// Ignore errors for ALTERs that may fail if column already exists or index doesn't exist
	// This is expected on already-migrated databases or fresh installations
	if (hndl == INVALID_HANDLE && !StrContains(error, "Duplicate column") && !StrContains(error, "Can't DROP") && !StrContains(error, "check that column/key exists"))
	{
		LogError("数据库迁移警告 (表 %d): %s", tableNum, error);
	}
}

public void SQL_InitSavesDB(Handle owner, Handle hndl, const char[] error, any data)
{
	if(hndl == INVALID_HANDLE)
		LogError("数据库初始化查询失败! %s", error);
}

public void SQL_GeneralCallback(Handle owner, Handle hndl, const char[] error, any data)
{
	if(hndl == INVALID_HANDLE)
		LogError("查询失败! %s", error);
}

void GetClientSaves(int client)
{
	if (g_hSavesDB == INVALID_HANDLE)
		return;

	char sQuery[255];
	FormatEx(sQuery, sizeof(sQuery), "SELECT `map`, `style`, `track`, `TfCurrentTime`, `date` FROM `saves` WHERE auth = %i;", GetSteamAccountID(client));
	SQL_TQuery(g_hSavesDB, SQL_GetClientSaves, sQuery, client);
}

public void SQL_GetClientSaves(Handle owner, Handle hndl, const char[] error, int client)
{
	g_bHasAnySaves[client] = false;
	g_bHasCurrentMapSaves[client] = false;
	g_bNotified[client] = false;
	for(int i = 0; i <= g_iStyleCount; i++)
	{
		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			g_bHasSave[client][i][j] = false;
			g_fSaveTime[client][i][j] = 0.0;
			g_iSaveDate[client][i][j] = 0;
		}
	}

	if(SQL_GetRowCount(hndl) != 0)
	{
		g_bHasAnySaves[client] = true;

		char sMap[255];
		while(SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, sMap, sizeof(sMap));
			int iStyle = SQL_FetchInt(hndl, 1);
			int iTrack = SQL_FetchInt(hndl, 2);

			if(StrEqual(sMap, g_sCurrentMap))
			{
				g_bHasCurrentMapSaves[client] = true;
				g_bHasSave[client][iStyle][iTrack] = true;
				g_fSaveTime[client][iStyle][iTrack] = SQL_FetchFloat(hndl, 3);
				g_iSaveDate[client][iStyle][iTrack] = SQL_FetchInt(hndl, 4);
			}
		}
	}
}

public void Shavit_OnRestart(int client, int track)
{
	if(g_bHasCurrentMapSaves[client] && !g_bNotified[client])
	{
		Shavit_PrintToChat(client, "您在这张地图上有存档！使用 %s!savestate 加载", g_sChatStrings.sVariable);
		g_bNotified[client] = true;
	}
}

public Action Command_Savestate(int client, int args)
{
	if(client != 0)
		OpenSavestateMenu(client);
	return Plugin_Handled;
}

void OpenSavestateMenu(int client)
{
	Menu menu = new Menu(OpenSavestateMenuHandler);
	menu.SetTitle("存档菜单\n ");

	menu.AddItem("save", "保存当前计时", Shavit_GetTimerStatus(client) == Timer_Stopped ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	
	// Enable load if player has either manual saves or autosaves on current map
	bool bHasAnyCurrentMapSave = g_bHasCurrentMapSaves[client];
	if (!bHasAnyCurrentMapSave)
	{
		// Check if player has any autosave for current map
		for(int i = 0; i < g_iStyleCount && !bHasAnyCurrentMapSave; i++)
		{
			for(int j = 0; j < TRACKS_SIZE && !bHasAnyCurrentMapSave; j++)
			{
				if(g_bHasAutosave[client][i][j])
					bHasAnyCurrentMapSave = true;
			}
		}
	}
	
	menu.AddItem("load", "加载计时存档\n ", bHasAnyCurrentMapSave ? ITEMDRAW_DEFAULT: ITEMDRAW_DISABLED);
	menu.AddItem("view", "查看所有存档", g_bHasAnySaves[client] ? ITEMDRAW_DEFAULT: ITEMDRAW_DISABLED);

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int OpenSavestateMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char s[8];
		menu.GetItem(param2, s, sizeof(s));

		if(StrEqual(s, "save"))
		{
			if(!Shavit_CanPause(param1) || Shavit_IsPaused(param1))
			{
				int iStyle = Shavit_GetBhopStyle(param1);
				int iTrack = Shavit_GetClientTrack(param1);

				if(g_bHasSave[param1][iStyle][iTrack])
					OpenOverwriteSaveMenu(param1, iStyle, iTrack);

				else
					SaveGame(param1, iStyle, iTrack);
			}
			else
			{
				Shavit_PrintToChat(param1, "%s未%s保存您的游戏。您的计时器必须%s暂停%s，或者必须满足暂停条件！（活着、未移动、未蹲下等）", g_sChatStrings.sWarning, g_sChatStrings.sText, g_sChatStrings.sVariable, g_sChatStrings.sText);
				OpenSavestateMenu(param1);
			}
		}
		else if(StrEqual(s, "load"))
		{
			OpenLoadGameMenu(param1);
		}
		else if(StrEqual(s, "view"))
		{
			OpenViewSavesMenu(param1);
		}
		else
		{
			Shavit_PrintToChat(param1, "无效选择，请重试");
			OpenSavestateMenu(param1);
		}
	}
	return Plugin_Handled;
}

public void SaveGame(int client, int style, int track)
{
	if (g_hSavesDB == INVALID_HANDLE)
	{
		Shavit_PrintToChat(client, "%s未%s保存您的游戏。数据库未连接！", g_sChatStrings.sWarning, g_sChatStrings.sText);
		return;
	}

	if(style != Shavit_GetBhopStyle(client) || track != Shavit_GetClientTrack(client))
		return;

	if(Shavit_GetTimerStatus(client) == Timer_Paused)
		Shavit_ResumeTimer(client, true);

	Shavit_SaveCheckpointCache(client, client, g_aSavestates[client], -1, sizeof(g_aSavestates[client]));
	g_aSavestates[client].iPreFrames = Shavit_GetPlayerPreFrames(client); //this is needed until https://github.com/shavitush/bhoptimer/pull/1244 is addressed, but might only be used if we save a replay, idk. i'll leave it here to be safe
	float fZoneOffset[2];
	fZoneOffset[0] = g_aSavestates[client].aSnapshot.fZoneOffset[0];
	fZoneOffset[1] = g_aSavestates[client].aSnapshot.fZoneOffset[1];

	//if there are eventqueuefix events
	if(g_aSavestates[client].aEvents != null && g_aSavestates[client].aOutputWaits != null)
	{
		//clear db
		char sQuery[2048];
		FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `saves-events` WHERE `map` = '%s' AND `auth` = %i AND `style` = %i AND `track_id` = %i;", g_sCurrentMap, GetSteamAccountID(client), style, track);
		SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);

		//events
		for(int i = 0; i < g_aSavestates[client].aEvents.Length; i++)
		{
			event_t e;
			g_aSavestates[client].aEvents.GetArray(i, e);
			FormatEx(sQuery, sizeof(sQuery), "INSERT INTO `saves-events` (`type`, `id`, `map`, `auth`, `style`, `track_id`, `Etarget`, `EtargetInput`, `EvariantValue`, `Edelay`, `Eactivator`, `Ecaller`, `EoutputID`) VALUES ('event', '%i', '%s', '%i', '%i', '%i', '%s', '%s', '%s', '%f', '%i', '%i', '%i');", i, g_sCurrentMap, GetSteamAccountID(client), style, track, e.target, e.targetInput, e.variantValue, e.delay, e.activator, e.caller, e.outputID);
			SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
		}

		//outputwaits
		for(int i = 0; i < g_aSavestates[client].aOutputWaits.Length; i++)
		{
			entity_t e;
			g_aSavestates[client].aOutputWaits.GetArray(i, e);
			FormatEx(sQuery, sizeof(sQuery), "INSERT INTO `saves-events` (`type`, `id`, `map`, `auth`, `style`, `track_id`, `Ecaller`, `EwaitTime`) VALUES ('output', '%i', '%s', '%i', '%i', '%i', '%i', '%f');", i, g_sCurrentMap, GetSteamAccountID(client), style, track, e.caller, e.waitTime);
			SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
		}
	}
	
	//customdata (mpbhops)
	if(g_aSavestates[client].customdata != null)
	{
		//clear db
		char sQuery[1024];
		FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `saves-customdata` WHERE `map` = '%s' AND `auth` = %i AND `style` = %i AND `track` = %i;", g_sCurrentMap, GetSteamAccountID(client), style, track);
		SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);

		float fPunishTime;
		int iLastBlock;
		if(g_aSavestates[client].customdata.ContainsKey("mpbhops_punishtime"))
			g_aSavestates[client].customdata.GetValue("mpbhops_punishtime", fPunishTime);
		if(g_aSavestates[client].customdata.ContainsKey("mpbhops_lastblock"))
			g_aSavestates[client].customdata.GetValue("mpbhops_lastblock", iLastBlock);

		char sPunishTime[64];
		char sLastBlock[64];
		FloatToString(fPunishTime, sPunishTime, sizeof(sPunishTime));
		IntToString(iLastBlock, sLastBlock, sizeof(sLastBlock));

		FormatEx(sQuery, sizeof(sQuery), "INSERT INTO `saves-customdata` (`id`, `map`, `auth`, `style`, `track`, `key`, `value`) VALUES ('0', '%s', '%i', '%i', '%i', 'mpbhops_punishtime', '%s'), ('1', '%s', '%i', '%i', '%i', 'mpbhops_lastblock', '%s');", g_sCurrentMap, GetSteamAccountID(client), style, track, sPunishTime, g_sCurrentMap, GetSteamAccountID(client), style, track, sLastBlock);
		SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
	}

	//if time is under wr, save replay frames to file
	if(g_cvSaveReplayOverWR.BoolValue || Shavit_GetWorldRecord(style, track) == 0.0 || g_aSavestates[client].aSnapshot.fCurrentTime < Shavit_GetWorldRecord(style, track))
	{
		char sPath[PLATFORM_MAX_PATH];
		FormatEx(sPath, sizeof(sPath), "%s/savedgames/%s_%i_%i_t%i.replay", g_sReplayFolder, g_sCurrentMap, style, GetSteamAccountID(client), track);

		File fFile = null;
		if(!(fFile = OpenFile(sPath, "wb+")))
		{
			LogError("Failed to open savegame replay file for writing. Permissions issue? ('%s')", sPath);
			Shavit_PrintToChat(client, "%s未%s保存您的游戏，因为文件权限错误，请联系管理员检查日志！", g_sChatStrings.sWarning, g_sChatStrings.sText);
			return;
		}

		ArrayList ReplayFrames = Shavit_GetReplayData(client);
		int iSize = Shavit_GetClientFrameCount(client);

		WriteReplayHeader(fFile, style, 0, g_aSavestates[client].aSnapshot.fCurrentTime, GetSteamAccountID(client), g_aSavestates[client].iPreFrames, 0, fZoneOffset, iSize, g_fTickrate, g_sCurrentMap);
		WriteReplayFrames(ReplayFrames, iSize, fFile);
		delete fFile;
		delete ReplayFrames;
	}
	
	char sQuery[8192];
	FormatEx(sQuery, sizeof(sQuery), "REPLACE INTO `saves` (`map`, `auth`, `style`, `track`, `date`, `TbTimerEnabled`, `TfCurrentTime`, `TbClientPaused`, `TiJumps`, `TiStrafes`, `TiTotalMeasures`, `TiGoodGains`, `TfServerTime`, `TiKeyCombo`, `TiTimerTrack`, `TiMeasuredJumps`, `TiPerfectJumps`, `TfZoneOffset1`, `TfZoneOffset2`, `TfDistanceOffset1`, `TfDistanceOffset2`, `TfAvgVelocity`, `TfMaxVelocity`, `TfTimescale`, `TiZoneIncrement`, `TiFullTicks`, `TiFractionalTicks`, `TbPracticeMode`, `TbJumped`, `TbCanUseAllKeys`, `TbOnGround`, `TiLastButtons`, `TfLastAngle`, `TiLandingTick`, `TiLastMoveType`, `TfStrafeWarning`, `TfLastInputVel1`, `TfLastInputVel2`, `Tfplayer_speedmod`, `TfNextFrameTime`, `TiLastMoveTypeTAS`, `CfPosition1`, `CfPosition2`, `CfPosition3`, `CfAngles1`, `CfAngles2`, `CfAngles3`, `CfVelocity1`, `CfVelocity2`, `CfVelocity3`, `CiMovetype`, `CfGravity`, `CfSpeed`, `CfStamina`, `CbDucked`, `CbDucking`, `CfDuckTime`, `CfDuckSpeed`, `CiFlags`, `CsTargetname`, `CsClassname`, `CiPreFrames`, `CbSegmented`, `CiGroundEntity`, `CvecLadderNormal1`, `CvecLadderNormal2`, `CvecLadderNormal3`, `Cm_bHasWalkMovedSinceLastJump`, `Cm_ignoreLadderJumpTime`, `Cm_lastStandingPos1`, `Cm_lastStandingPos2`, `Cm_lastStandingPos3`, `Cm_ladderSuppressionTimer1`, `Cm_ladderSuppressionTimer2`,  `Cm_lastLadderNormal1`, `Cm_lastLadderNormal2`, `Cm_lastLadderNormal3`, `Cm_lastLadderPos1`, `Cm_lastLadderPos2`, `Cm_lastLadderPos3`, `Cm_afButtonDisabled`, `Cm_afButtonForced`) VALUES ('%s', '%i', '%i', '%i', '%i', '%i', '%f', '%i', '%i', '%i', '%i', '%i', '%f', '%i', '%i', '%i', '%i', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%i', '%i', '%i', '%i', '%i', '%i', '%i', '%i', '%f', '%i', '%i', '%f', '%f', '%f', '%f', '%f', '%i', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%i', '%f', '%f', '%f', '%i', '%i', '%f', '%f', '%i', '%s', '%s', '%i', '%i', '%i', '%f', '%f', '%f', '%i', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%i', '%i');",
		g_sCurrentMap, GetSteamAccountID(client), g_aSavestates[client].aSnapshot.bsStyle, track, GetTime(), view_as<int>(g_aSavestates[client].aSnapshot.bTimerEnabled), g_aSavestates[client].aSnapshot.fCurrentTime, view_as<int>(g_aSavestates[client].aSnapshot.bClientPaused), g_aSavestates[client].aSnapshot.iJumps,
		g_aSavestates[client].aSnapshot.iStrafes, g_aSavestates[client].aSnapshot.iTotalMeasures, g_aSavestates[client].aSnapshot.iGoodGains, g_aSavestates[client].aSnapshot.fServerTime, g_aSavestates[client].aSnapshot.iKeyCombo, g_aSavestates[client].aSnapshot.iTimerTrack, 
		g_aSavestates[client].aSnapshot.iMeasuredJumps, g_aSavestates[client].aSnapshot.iPerfectJumps, g_aSavestates[client].aSnapshot.fZoneOffset[0], g_aSavestates[client].aSnapshot.fZoneOffset[1], 
		g_aSavestates[client].aSnapshot.fDistanceOffset[0], g_aSavestates[client].aSnapshot.fDistanceOffset[1], g_aSavestates[client].aSnapshot.fAvgVelocity, 
		g_aSavestates[client].aSnapshot.fMaxVelocity, g_aSavestates[client].aSnapshot.fTimescale, g_aSavestates[client].aSnapshot.iZoneIncrement, g_aSavestates[client].aSnapshot.iFullTicks, g_aSavestates[client].aSnapshot.iFractionalTicks, view_as<int>(g_aSavestates[client].aSnapshot.bPracticeMode), 
		view_as<int>(g_aSavestates[client].aSnapshot.bJumped), view_as<int>(g_aSavestates[client].aSnapshot.bCanUseAllKeys), view_as<int>(g_aSavestates[client].aSnapshot.bOnGround), g_aSavestates[client].aSnapshot.iLastButtons, g_aSavestates[client].aSnapshot.fLastAngle, 
		g_aSavestates[client].aSnapshot.iLandingTick, g_aSavestates[client].aSnapshot.iLastMoveType, g_aSavestates[client].aSnapshot.fStrafeWarning, 
		g_aSavestates[client].aSnapshot.fLastInputVel[0], g_aSavestates[client].aSnapshot.fLastInputVel[1],  g_aSavestates[client].aSnapshot.fplayer_speedmod, 
		g_aSavestates[client].aSnapshot.fNextFrameTime, g_aSavestates[client].aSnapshot.iLastMoveTypeTAS, 
		
		g_aSavestates[client].fPosition[0], g_aSavestates[client].fPosition[1], g_aSavestates[client].fPosition[2], 
		g_aSavestates[client].fAngles[0], g_aSavestates[client].fAngles[1], g_aSavestates[client].fAngles[2], 
		g_aSavestates[client].fVelocity[0], g_aSavestates[client].fVelocity[1], g_aSavestates[client].fVelocity[2], 
		g_aSavestates[client].iMoveType, g_aSavestates[client].fGravity, g_aSavestates[client].fSpeed, g_aSavestates[client].fStamina, 
		view_as<int>(g_aSavestates[client].bDucked), view_as<int>(g_aSavestates[client].bDucking), g_aSavestates[client].fDucktime, g_aSavestates[client].fDuckSpeed, 
		g_aSavestates[client].iFlags, g_aSavestates[client].sTargetname, g_aSavestates[client].sClassname, 
		g_aSavestates[client].iPreFrames, view_as<int>(g_aSavestates[client].bSegmented), g_aSavestates[client].iGroundEntity, 
		g_aSavestates[client].vecLadderNormal[0], g_aSavestates[client].vecLadderNormal[1], g_aSavestates[client].vecLadderNormal[2], 
		view_as<int>(g_aSavestates[client].m_bHasWalkMovedSinceLastJump), g_aSavestates[client].m_ignoreLadderJumpTime, 
		g_aSavestates[client].m_lastStandingPos[0], g_aSavestates[client].m_lastStandingPos[1], g_aSavestates[client].m_lastStandingPos[2], 
		g_aSavestates[client].m_ladderSurpressionTimer[0], g_aSavestates[client].m_ladderSurpressionTimer[1], 
		g_aSavestates[client].m_lastLadderNormal[0], g_aSavestates[client].m_lastLadderNormal[1], g_aSavestates[client].m_lastLadderNormal[2], 
		g_aSavestates[client].m_lastLadderPos[0], g_aSavestates[client].m_lastLadderPos[1], g_aSavestates[client].m_lastLadderPos[2], 
		g_aSavestates[client].m_afButtonDisabled, g_aSavestates[client].m_afButtonForced);
	SQL_TQuery(g_hSavesDB, SQL_SaveGame, sQuery, client);
}

public void SQL_SaveGame(Handle owner, Handle hndl, const char[] error, any client)
{
	if(hndl == INVALID_HANDLE)
	{
		int iTrack = Shavit_GetClientTrack(client);
		char sPath[PLATFORM_MAX_PATH];
		FormatEx(sPath, sizeof(sPath), "%s/savedgames/%s_%i_%i_t%i.replay", g_sReplayFolder, g_sCurrentMap, Shavit_GetBhopStyle(client), GetSteamAccountID(client), iTrack);
		if(FileExists(sPath))
			DeleteFile(sPath);

		LogError("SQL_SaveGame() query failed! %s", error);
		Shavit_PrintToChat(client, "%s未%s保存您的游戏。数据库错误，请重试或联系管理员！", g_sChatStrings.sWarning, g_sChatStrings.sText);
	}
	else
	{
		Shavit_StopTimer(client, true);
		GetClientSaves(client);
		Shavit_PrintToChat(client, "计时器已保存！稍后使用 %s!savestate 加载此地图上的存档", g_sChatStrings.sVariable);
	}
}

public Action OpenOverwriteSaveMenu(int client, int style, int track)
{
	Panel hPanel = CreatePanel();
	char sDisplay[128];
	char sTime[32];
	FloatToString(g_fSaveTime[client][style][track], sTime, sizeof(sTime));

	FormatEx(sDisplay, sizeof(sDisplay), "您在 %s 上已经有一个存档", g_sCurrentMap);
	hPanel.SetTitle(sDisplay);

	FormatEx(sDisplay, sizeof(sDisplay), "样式: %s", g_sStyleStrings[style].sStyleName);
	hPanel.DrawItem(sDisplay, ITEMDRAW_RAWLINE);

	FormatEx(sDisplay, sizeof(sDisplay), "时间: %s", FormatToSeconds(sTime));
	hPanel.DrawItem(sDisplay, ITEMDRAW_RAWLINE);

	hPanel.DrawItem(" ", ITEMDRAW_RAWLINE);
	hPanel.DrawItem("覆盖？", ITEMDRAW_RAWLINE);
	hPanel.DrawItem("是", ITEMDRAW_CONTROL);
	hPanel.DrawItem("否", ITEMDRAW_CONTROL);
	hPanel.DrawItem(" ", ITEMDRAW_RAWLINE);

	SetPanelCurrentKey(hPanel, 10);
	hPanel.DrawItem("退出", ITEMDRAW_CONTROL);

	hPanel.Send(client, OpenOverwriteSaveMenuHandler, MENU_TIME_FOREVER);
	CloseHandle(hPanel);

	return Plugin_Handled;
}

public int OpenOverwriteSaveMenuHandler(Handle hPanel, MenuAction action, int client, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			CloseHandle(hPanel);

		case MenuAction_Cancel: 
		{
			if(IsValidClient(client))
				EmitSoundToClient(client, "buttons/combine_button7.wav");

			CloseHandle(hPanel);
		}
		case MenuAction_Select:
		{
			switch(param2)
			{
				case 1:
				{
					if(IsValidClient(client))
					{
						EmitSoundToClient(client, "buttons/button14.wav");
						SaveGame(client, Shavit_GetBhopStyle(client), Shavit_GetClientTrack(client));
						CloseHandle(hPanel);
						return Plugin_Handled;
					}
				}
				case 2:
				{
					if(IsValidClient(client))
						EmitSoundToClient(client, "buttons/button14.wav");
						OpenSavestateMenu(client);
				}
				case 10:
				{
					if(IsValidClient(client))
						EmitSoundToClient(client, "buttons/combine_button7.wav");
				}
			}
			Shavit_PrintToChat(client, "%s未%s保存您的游戏。使用 %s!savestate 加载您当前的存档", g_sChatStrings.sWarning, g_sChatStrings.sText, g_sChatStrings.sVariable);
		}
	}
	CloseHandle(hPanel);
	return Plugin_Handled;
}

void OpenLoadGameMenu(int client)
{
	Menu menu = new Menu(OpenLoadGameMenuHandler);
	int[] iOrderedStyles = new int[g_iStyleCount];
	Shavit_GetOrderedStyles(iOrderedStyles, g_iStyleCount);
	char sInfo[32];
	char sTime[32];
	char sDate[32];
	char sDisplay[256];
	char sTrackName[32];

	FormatEx(sDisplay, sizeof(sDisplay), "%s\n选择要加载的存档\n ", g_sCurrentMap);
	menu.SetTitle(sDisplay);

	// List manual saves first
	for(int i = 0; i < g_iStyleCount; i++)
	{
		int iStyle = iOrderedStyles[i];
		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			if(g_bHasSave[client][iStyle][j])
			{
				// Format track name
				if(j == 0)
					FormatEx(sTrackName, sizeof(sTrackName), "[Main]");
				else
					FormatEx(sTrackName, sizeof(sTrackName), "[Bonus %d]", j);
				
				// Format save info
				FloatToString(g_fSaveTime[client][iStyle][j], sTime, sizeof(sTime));
				FormatTime(sDate, sizeof(sDate), "%d %b %Y", g_iSaveDate[client][iStyle][j]);
				FormatEx(sDisplay, sizeof(sDisplay), "%s %s\n    时间: %s (%s)\n ", 
					g_sStyleStrings[iStyle].sStyleName, sTrackName, FormatToSeconds(sTime), sDate);
				
				// Info string: m_style_track (m for manual)
				FormatEx(sInfo, sizeof(sInfo), "m_%d_%d", iStyle, j);
				menu.AddItem(sInfo, sDisplay);
			}
		}
	}
	
	// List autosaves
	for(int i = 0; i < g_iStyleCount; i++)
	{
		int iStyle = iOrderedStyles[i];
		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			if(g_bHasAutosave[client][iStyle][j])
			{
				// Format track name
				if(j == 0)
					FormatEx(sTrackName, sizeof(sTrackName), "[Main]");
				else
					FormatEx(sTrackName, sizeof(sTrackName), "[Bonus %d]", j);
				
				// Format autosave info
				FloatToString(g_fAutosaveTime[client][iStyle][j], sTime, sizeof(sTime));
				FormatTime(sDate, sizeof(sDate), "%d %b %Y", g_iAutosaveDate[client][iStyle][j]);
				FormatEx(sDisplay, sizeof(sDisplay), "%s %s (Autosave)\n    时间: %s (断线于 %s)\n ", 
					g_sStyleStrings[iStyle].sStyleName, sTrackName, FormatToSeconds(sTime), sDate);
				
				// Info string: a_style_track (a for autosave)
				FormatEx(sInfo, sizeof(sInfo), "a_%d_%d", iStyle, j);
				menu.AddItem(sInfo, sDisplay);
			}
		}
	}

	menu.ExitBackButton = true;
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int OpenLoadGameMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		if(!IsPlayerAlive(param1))
		{
			Shavit_PrintToChat(param1, "您必须%s活着%s才能加载存档", g_sChatStrings.sVariable, g_sChatStrings.sText);
			OpenLoadGameMenu(param1);
			return Plugin_Handled;
		}

		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		// Parse the info string: prefix_style_track
		char sParts[3][16];
		ExplodeString(sInfo, "_", sParts, 3, 16);
		
		int iStyle = StringToInt(sParts[1]);
		int iTrack = StringToInt(sParts[2]);
		
		if(iStyle > -1 && iStyle < g_iStyleCount && iTrack >= 0 && iTrack < TRACKS_SIZE)
		{
			// Check prefix: m for manual, a for autosave
			if(StrEqual(sParts[0], "m"))
			{
				LoadGame(param1, iStyle, iTrack);
			}
			else if(StrEqual(sParts[0], "a"))
			{
				AutoloadGame(param1, iStyle, iTrack);
			}
		}
		else
		{
			Shavit_PrintToChat(param1, "无效的样式或赛道，请重试");
			OpenLoadGameMenu(param1);
		}
	}
	if(action == MenuAction_Cancel)
		if(param2 == MenuCancel_ExitBack)
			OpenSavestateMenu(param1);

	return Plugin_Handled;
}

public void LoadGame(int client, int style, int track)
{
	if(!IsValidClient(client) || !IsPlayerAlive(client) || !g_bHasSave[client][style][track])
		return;

	if (g_hSavesDB == INVALID_HANDLE)
	{
		Shavit_PrintToChat(client, "%s无法%s加载您的游戏。数据库未连接！", g_sChatStrings.sWarning, g_sChatStrings.sText);
		return;
	}

	// Load replay file - try new format first, fallback to old format
	char sPath[PLATFORM_MAX_PATH];
	FormatEx(sPath, sizeof(sPath), "%s/savedgames/%s_%i_%i_t%i.replay", g_sReplayFolder, g_sCurrentMap, style, GetSteamAccountID(client), track);
	
	// Fallback to old format if new format doesn't exist (for backwards compatibility)
	if (!FileExists(sPath) && track == 0)
	{
		FormatEx(sPath, sizeof(sPath), "%s/savedgames/%s_%i_%i.replay", g_sReplayFolder, g_sCurrentMap, style, GetSteamAccountID(client));
	}

	if(FileExists(sPath))
	{
		if(!LoadReplayCache(g_aReplayCache[client], style, track, sPath, g_sCurrentMap))
		{
			LogError("Saved game replay failed to load! (%s)", sPath);
			Shavit_PrintToChat(client, "%s无法%s加载您的游戏。无法加载回放文件，请重试或联系管理员！", g_sChatStrings.sWarning, g_sChatStrings.sText);
			return;
		}
	}

	LoadEvents(client, style, track);
	LoadCustomData(client, style, track);

	char sQuery[2048];
	FormatEx(sQuery, sizeof(sQuery), "SELECT `style`, `track`, `TbTimerEnabled`, `TfCurrentTime`, `TbClientPaused`, `TiJumps`, `TiStrafes`, `TiTotalMeasures`, `TiGoodGains`, `TfServerTime`, `TiKeyCombo`, `TiTimerTrack`, `TiMeasuredJumps`, `TiPerfectJumps`, `TfZoneOffset1`, `TfZoneOffset2`, `TfDistanceOffset1`, `TfDistanceOffset2`, `TfAvgVelocity`, `TfMaxVelocity`, `TfTimescale`, `TiZoneIncrement`, `TiFullTicks`, `TiFractionalTicks`, `TbPracticeMode`, `TbJumped`, `TbCanUseAllKeys`, `TbOnGround`, `TiLastButtons`, `TfLastAngle`, `TiLandingTick`, `TiLastMoveType`, `TfStrafeWarning`, `TfLastInputVel1`, `TfLastInputVel2`, `Tfplayer_speedmod`, `TfNextFrameTime`, `TiLastMoveTypeTAS`, `CfPosition1`, `CfPosition2`, `CfPosition3`, `CfAngles1`, `CfAngles2`, `CfAngles3`, `CfVelocity1`, `CfVelocity2`, `CfVelocity3`, `CiMovetype`, `CfGravity`, `CfSpeed`, `CfStamina`, `CbDucked`, `CbDucking`, `CfDuckTime`, `CfDuckSpeed`, `CiFlags`, `CsTargetname`, `CsClassname`, `CiPreFrames`, `CbSegmented`, `CiGroundEntity`, `CvecLadderNormal1`, `CvecLadderNormal2`, `CvecLadderNormal3`, `Cm_bHasWalkMovedSinceLastJump`, `Cm_ignoreLadderJumpTime`, `Cm_lastStandingPos1`, `Cm_lastStandingPos2`, `Cm_lastStandingPos3`, `Cm_ladderSuppressionTimer1`, `Cm_ladderSuppressionTimer2`, `Cm_lastLadderNormal1`, `Cm_lastLadderNormal2`, `Cm_lastLadderNormal3`, `Cm_lastLadderPos1`, `Cm_lastLadderPos2`, `Cm_lastLadderPos3`, `Cm_afButtonDisabled`, `Cm_afButtonForced` FROM `saves` WHERE `map` = '%s' AND `auth` = %i AND `style` = %i AND `track` = %i;", g_sCurrentMap, GetSteamAccountID(client), style, track);
	SQL_TQuery(g_hSavesDB, SQL_LoadGame, sQuery, client);
}

public void SQL_LoadGame(Handle owner, Handle hndl, const char[] error, any client)
{
	if(hndl == INVALID_HANDLE)
	{
		LogError("SQL_LoadGame() query failed! %s", error);
		Shavit_PrintToChat(client, "%s无法%s加载您的游戏。数据库错误，请重试或联系管理员！", g_sChatStrings.sWarning, g_sChatStrings.sText);
	}
	else
	{
		if(SQL_GetRowCount(hndl) < 1)
		{
			LogError("SQL_LoadGame() query returned 0 rows!");
			Shavit_PrintToChat(client, "%s无法%s加载您的游戏。未在此样式上找到存档，请重试或联系管理员！", g_sChatStrings.sWarning, g_sChatStrings.sText);
		}
		else if(SQL_GetRowCount(hndl) > 1) //this shouldn't be able to happen.. but better to catch it here just in case (^:
		{
			LogError("SQL_LoadGame() query returned >1 row!");
			Shavit_PrintToChat(client, "%s无法%s加载您的游戏。在此样式上找到多个存档，请重试或联系管理员！", g_sChatStrings.sWarning, g_sChatStrings.sText);
		}
		else
		{
			int iStyle;
			int iTrack;
			while(SQL_FetchRow(hndl))
			{
				iStyle = SQL_FetchInt(hndl, 0);
				iTrack = SQL_FetchInt(hndl, 1);
				g_aSavestates[client].aSnapshot.bTimerEnabled = view_as<bool>(SQL_FetchInt(hndl, 2));
				g_aSavestates[client].aSnapshot.fCurrentTime = SQL_FetchFloat(hndl, 3);
				g_aSavestates[client].aSnapshot.bClientPaused = view_as<bool>(SQL_FetchInt(hndl, 4));
				g_aSavestates[client].aSnapshot.iJumps = SQL_FetchInt(hndl, 5);
				g_aSavestates[client].aSnapshot.iStrafes = SQL_FetchInt(hndl, 6);
				g_aSavestates[client].aSnapshot.iTotalMeasures = SQL_FetchInt(hndl, 7);
				g_aSavestates[client].aSnapshot.iGoodGains = SQL_FetchInt(hndl, 8);
				g_aSavestates[client].aSnapshot.fServerTime = SQL_FetchFloat(hndl, 9);
				g_aSavestates[client].aSnapshot.iKeyCombo = SQL_FetchInt(hndl, 10);
				g_aSavestates[client].aSnapshot.iTimerTrack = SQL_FetchInt(hndl, 11);
				g_aSavestates[client].aSnapshot.iMeasuredJumps = SQL_FetchInt(hndl, 12);
				g_aSavestates[client].aSnapshot.iPerfectJumps = SQL_FetchInt(hndl, 13);
				g_aSavestates[client].aSnapshot.fZoneOffset[0] = SQL_FetchFloat(hndl, 14);
				g_aSavestates[client].aSnapshot.fZoneOffset[1] = SQL_FetchFloat(hndl, 15);
				g_aSavestates[client].aSnapshot.fDistanceOffset[0] = SQL_FetchFloat(hndl, 16);
				g_aSavestates[client].aSnapshot.fDistanceOffset[1] = SQL_FetchFloat(hndl, 17);
				g_aSavestates[client].aSnapshot.fAvgVelocity = SQL_FetchFloat(hndl, 18);
				g_aSavestates[client].aSnapshot.fMaxVelocity = SQL_FetchFloat(hndl, 19);
				g_aSavestates[client].aSnapshot.fTimescale = SQL_FetchFloat(hndl, 20);
				g_aSavestates[client].aSnapshot.iZoneIncrement = SQL_FetchInt(hndl, 21);
				g_aSavestates[client].aSnapshot.iFullTicks = SQL_FetchInt(hndl, 22);
				g_aSavestates[client].aSnapshot.iFractionalTicks = SQL_FetchInt(hndl, 23);
				g_aSavestates[client].aSnapshot.bPracticeMode = view_as<bool>(SQL_FetchInt(hndl, 24));
				g_aSavestates[client].aSnapshot.bJumped = view_as<bool>(SQL_FetchInt(hndl, 25));
				g_aSavestates[client].aSnapshot.bCanUseAllKeys = view_as<bool>(SQL_FetchInt(hndl, 26));
				g_aSavestates[client].aSnapshot.bOnGround = view_as<bool>(SQL_FetchInt(hndl, 27));
				g_aSavestates[client].aSnapshot.iLastButtons = SQL_FetchInt(hndl, 28);
				g_aSavestates[client].aSnapshot.fLastAngle = SQL_FetchFloat(hndl, 29);
				g_aSavestates[client].aSnapshot.iLandingTick = SQL_FetchInt(hndl, 30);
				g_aSavestates[client].aSnapshot.iLastMoveType = view_as<MoveType>(SQL_FetchInt(hndl, 31));
				g_aSavestates[client].aSnapshot.fStrafeWarning = SQL_FetchFloat(hndl, 32);
				g_aSavestates[client].aSnapshot.fLastInputVel[0] = SQL_FetchFloat(hndl, 33);
				g_aSavestates[client].aSnapshot.fLastInputVel[1] = SQL_FetchFloat(hndl, 34);
				g_aSavestates[client].aSnapshot.fplayer_speedmod = SQL_FetchFloat(hndl, 35);
				g_aSavestates[client].aSnapshot.fNextFrameTime = SQL_FetchFloat(hndl, 36);
				g_aSavestates[client].aSnapshot.iLastMoveTypeTAS = view_as<MoveType>(SQL_FetchInt(hndl, 37));
				g_aSavestates[client].fPosition[0] = SQL_FetchFloat(hndl, 38);
				g_aSavestates[client].fPosition[1] = SQL_FetchFloat(hndl, 39);
				g_aSavestates[client].fPosition[2] = SQL_FetchFloat(hndl, 40);
				g_aSavestates[client].fAngles[0] = SQL_FetchFloat(hndl, 41);
				g_aSavestates[client].fAngles[1] = SQL_FetchFloat(hndl, 42);
				g_aSavestates[client].fAngles[2] = SQL_FetchFloat(hndl, 43);
				g_aSavestates[client].fVelocity[0] = SQL_FetchFloat(hndl, 44);
				g_aSavestates[client].fVelocity[1] = SQL_FetchFloat(hndl, 45);
				g_aSavestates[client].fVelocity[2] = SQL_FetchFloat(hndl, 46);
				g_aSavestates[client].iMoveType = MOVETYPE_WALK;//view_as<MoveType>(SQL_FetchInt(hndl, 47));
				g_aSavestates[client].fGravity = SQL_FetchFloat(hndl, 48);
				g_aSavestates[client].fSpeed = SQL_FetchFloat(hndl, 49);
				g_aSavestates[client].fStamina = SQL_FetchFloat(hndl, 50);
				g_aSavestates[client].bDucked = view_as<bool>(SQL_FetchInt(hndl, 51));
				g_aSavestates[client].bDucking = view_as<bool>(SQL_FetchInt(hndl, 52));
				g_aSavestates[client].fDucktime = SQL_FetchFloat(hndl, 53);
				g_aSavestates[client].fDuckSpeed = SQL_FetchFloat(hndl, 54);
				g_aSavestates[client].iFlags = SQL_FetchInt(hndl, 55);
				SQL_FetchString(hndl, 56, g_aSavestates[client].sTargetname, sizeof(g_aSavestates[client].sTargetname));
				SQL_FetchString(hndl, 57, g_aSavestates[client].sClassname, sizeof(g_aSavestates[client].sClassname));
				g_aSavestates[client].iPreFrames = SQL_FetchInt(hndl, 58);
				g_aSavestates[client].bSegmented = view_as<bool>(SQL_FetchInt(hndl, 59));
				g_aSavestates[client].iGroundEntity = SQL_FetchInt(hndl, 60);
				g_aSavestates[client].vecLadderNormal[0] = SQL_FetchFloat(hndl, 61);
				g_aSavestates[client].vecLadderNormal[1] = SQL_FetchFloat(hndl, 62);
				g_aSavestates[client].vecLadderNormal[2] = SQL_FetchFloat(hndl, 63);
				g_aSavestates[client].m_bHasWalkMovedSinceLastJump = view_as<bool>(SQL_FetchInt(hndl, 64));
				g_aSavestates[client].m_ignoreLadderJumpTime = SQL_FetchFloat(hndl, 65);
				g_aSavestates[client].m_lastStandingPos[0] = SQL_FetchFloat(hndl, 66);
				g_aSavestates[client].m_lastStandingPos[1] = SQL_FetchFloat(hndl, 67);
				g_aSavestates[client].m_lastStandingPos[2] = SQL_FetchFloat(hndl, 68);
				g_aSavestates[client].m_ladderSurpressionTimer[0] = SQL_FetchFloat(hndl, 69);
				g_aSavestates[client].m_ladderSurpressionTimer[1] = SQL_FetchFloat(hndl, 70);
				g_aSavestates[client].m_lastLadderNormal[0] = SQL_FetchFloat(hndl, 71);
				g_aSavestates[client].m_lastLadderNormal[1] = SQL_FetchFloat(hndl, 72);
				g_aSavestates[client].m_lastLadderNormal[2] = SQL_FetchFloat(hndl, 73);
				g_aSavestates[client].m_lastLadderPos[0] = SQL_FetchFloat(hndl, 74);
				g_aSavestates[client].m_lastLadderPos[1] = SQL_FetchFloat(hndl, 75);
				g_aSavestates[client].m_lastLadderPos[2] = SQL_FetchFloat(hndl, 76);
				g_aSavestates[client].m_afButtonDisabled = SQL_FetchInt(hndl, 77);
				g_aSavestates[client].m_afButtonForced = SQL_FetchInt(hndl, 78);
			}
			g_aSavestates[client].iSteamID = GetSteamAccountID(client);
			g_aSavestates[client].aSnapshot.bsStyle = iStyle;
			Shavit_ClearCheckpoints(client);
			Shavit_StopTimer(client, true);
			if(g_aReplayCache[client].aFrames)
				Shavit_SetReplayData(client, g_aReplayCache[client].aFrames);
			Shavit_SetPlayerPreFrames(client, g_aReplayCache[client].iPreFrames);
			Shavit_LoadCheckpointCache(client, g_aSavestates[client], -1, sizeof(g_aSavestates[client]), true);
			if(Shavit_GetTimerStatus(client) == Timer_Paused)
				Shavit_ResumeTimer(client);
			if(Shavit_GetStyleSettingBool(iStyle, "kzcheckpoints") || Shavit_GetStyleSettingBool(iStyle, "segments"))
				Shavit_SaveCheckpoint(client);
			DeleteLoadedGame(client, iStyle, iTrack);
			Shavit_PrintToChat(client, "存档%s加载%s成功并已删除！", g_sChatStrings.sVariable, g_sChatStrings.sText);
		}
	}
}

void LoadEvents(int client, int iStyle, int track)
{
	char sQuery[2048];
	FormatEx(sQuery, sizeof(sQuery), "SELECT `type`, `Etarget`, `EtargetInput`, `EvariantValue`, `Edelay`, `Eactivator`, `Ecaller`, `EoutputID`, `EwaitTime` FROM `saves-events` WHERE `map` = '%s' AND `auth` = '%i' AND `style` = '%i' AND `track_id` = '%i' ORDER BY `id` ASC;", g_sCurrentMap, GetSteamAccountID(client), iStyle, track);
	SQL_TQuery(g_hSavesDB, SQL_LoadEvents, sQuery, client);
}

void SQL_LoadEvents(Handle owner, Handle hndl, const char[] error, int client)
{
	if(SQL_GetRowCount(hndl) != 0)
	{
		g_aSavestates[client].aEvents = new ArrayList(sizeof(event_t));
		g_aSavestates[client].aOutputWaits = new ArrayList(sizeof(entity_t));

		char sType[16];

		while(SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, sType, sizeof(sType));
			if(StrEqual(sType, "event"))
			{
				event_t e;
				SQL_FetchString(hndl, 1, e.target, sizeof(e.target));
				SQL_FetchString(hndl, 2, e.targetInput, sizeof(e.targetInput));
				SQL_FetchString(hndl, 3, e.variantValue, sizeof(e.variantValue));
				e.delay = SQL_FetchFloat(hndl, 4);
				e.activator = SQL_FetchInt(hndl, 5);
				e.caller = SQL_FetchInt(hndl, 6);
				e.outputID = SQL_FetchInt(hndl, 7);
				g_aSavestates[client].aEvents.Push(e);
			}
			else if(StrEqual(sType, "output"))
			{
				entity_t e;
				e.caller = SQL_FetchInt(hndl, 6);
				e.waitTime = SQL_FetchFloat(hndl, 8);
				g_aSavestates[client].aOutputWaits.Push(e);
			}
		}
	}
}

void LoadCustomData(int client, int iStyle, int track)
{
	char sQuery[2048];
	FormatEx(sQuery, sizeof(sQuery), "SELECT `key`, `value` FROM `saves-customdata` WHERE `map` = '%s' AND `auth` = '%i' AND `style` = '%i' AND `track` = '%i' ORDER BY `id` ASC;", g_sCurrentMap, GetSteamAccountID(client), iStyle, track);
	SQL_TQuery(g_hSavesDB, SQL_LoadCustomData, sQuery, client);
}

void SQL_LoadCustomData(Handle owner, Handle hndl, const char[] error, int client)
{
	StringMap cd = new StringMap();
	char sKey[64];
	char sValue[64];

	cd.SetValue("mpbhops_punishtime", 0.0);
	cd.SetValue("mpbhops_lastblock", 0);

	if(SQL_GetRowCount(hndl) != 0)
	{
		while(SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, sKey, sizeof(sKey));
			SQL_FetchString(hndl, 1, sValue, sizeof(sValue));
			if(StrEqual(sKey, "mpbhops_punishtime"))
				cd.SetValue("mpbhops_punishtime", StringToFloat(sValue));
			else if(StrEqual(sKey, "mpbhops_lastblock"))
				cd.SetValue("mpbhops_lastblock", StringToInt(sValue));
		}
	}

	g_aSavestates[client].customdata = cd;
}

void DeleteLoadedGame(int client, int iStyle, int track)
{
	// Delete replay file - try new format first, fallback to old format
	char sPath[PLATFORM_MAX_PATH];
	FormatEx(sPath, sizeof(sPath), "%s/savedgames/%s_%i_%i_t%i.replay", g_sReplayFolder, g_sCurrentMap, iStyle, GetSteamAccountID(client), track);
	if(FileExists(sPath))
	{
		DeleteFile(sPath);
	}
	else if (track == 0)
	{
		// Try old format for backwards compatibility
		FormatEx(sPath, sizeof(sPath), "%s/savedgames/%s_%i_%i.replay", g_sReplayFolder, g_sCurrentMap, iStyle, GetSteamAccountID(client));
		if(FileExists(sPath))
			DeleteFile(sPath);
	}

	char sQuery[512];
	FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `saves` WHERE auth = %i AND map = '%s' AND style = %i AND track = %i;", GetSteamAccountID(client), g_sCurrentMap, iStyle, track);
	SQL_TQuery(g_hSavesDB, SQL_DeleteLoadedGame, sQuery, client);

	FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `saves-events` WHERE auth = %i AND map = '%s' AND style = %i AND track_id = %i;", GetSteamAccountID(client), g_sCurrentMap, iStyle, track);
	SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery, client);

	FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `saves-customdata` WHERE auth = %i AND map = '%s' AND style = %i AND track = %i;", GetSteamAccountID(client), g_sCurrentMap, iStyle, track);
	SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery, client);
}

public void SQL_DeleteLoadedGame(Handle owner, Handle hndl, const char[] error, int client)
{
	if(hndl == INVALID_HANDLE)
	{
		LogError("SQL_DeleteLoadedGame 查询失败! %s", error);
		Shavit_PrintToChat(client, "[Shavit-SaveGame] %s数据库错误%s，请联系管理员检查日志！", g_sChatStrings.sWarning, g_sChatStrings.sText);
	}
	else
		GetClientSaves(client);
}

void OpenViewSavesMenu(int client)
{
	if (g_hSavesDB == INVALID_HANDLE)
		return;

	char sQuery[512];
	FormatEx(sQuery, sizeof(sQuery), "SELECT `map`, `style`, `TfCurrentTime`, `date` FROM `saves` WHERE auth = %i ORDER BY `date` DESC;", GetSteamAccountID(client));
	SQL_TQuery(g_hSavesDB, SQL_OpenViewSavesMenu, sQuery, client);
}

void SQL_OpenViewSavesMenu(Handle owner, Handle hndl, const char[] error, int client)
{
	if(SQL_GetRowCount(hndl) == 0)
	{
		Shavit_PrintToChat(client, "未找到存档");
		OpenSavestateMenu(client);
		return;
	}

	Menu menu = new Menu(OpenViewSavesMenuHandler);
	menu.SetTitle("所有存档 (选择以提名)\n ");

	char sMap[255];
	int iStyle;
	char sStyle[4];
	float fTime;
	char sTime[32];
	int iDate;
	char sDate[32];
	char sDisplay[255];
	while(SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, sMap, sizeof(sMap));
		iStyle = SQL_FetchInt(hndl, 1);
		fTime = SQL_FetchFloat(hndl, 2);
		iDate = SQL_FetchInt(hndl, 3);

		IntToString(iStyle, sStyle, sizeof(sStyle));
		FloatToString(fTime, sTime, sizeof(sTime));
		FormatTime(sDate, sizeof(sDate), "%d %b %Y", iDate);

		FormatEx(sDisplay, sizeof(sDisplay), "%s - %s\n    时间: %s (%s)\n ", sMap, g_sStyleStrings[iStyle].sStyleName, FormatToSeconds(sTime), sDate);
		menu.AddItem(sMap, sDisplay, StrEqual(g_sCurrentMap, sMap) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	}

	menu.ExitBackButton = true;
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int OpenViewSavesMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sMap[PLATFORM_MAX_PATH];
		menu.GetItem(param2, sMap, sizeof(sMap));
		FakeClientCommand(param1, "sm_nominate %s", sMap);
	}
	if(action == MenuAction_Cancel)
		if(param2 == MenuCancel_ExitBack)
			OpenSavestateMenu(param1);
	return Plugin_Handled;
}

char[] FormatToSeconds(char time[32])
{
	int iTemp = RoundToFloor(StringToFloat(time));
	int iHours = 0;

	if(iTemp > 3600)
	{
		iHours = iTemp / 3600;
		iTemp %= 3600;
	}

	int iMinutes = 0;

	if(iTemp >= 60)
	{
		iMinutes = iTemp / 60;
		iTemp %= 60;
	}

	float fSeconds = iTemp + StringToFloat(time) - RoundToFloor(StringToFloat(time));

	char result[32];

	if (iHours > 0)
	{
		Format(result, sizeof(result), "%i小时 %i分 %.1f秒", iHours, iMinutes, fSeconds);
	}
	else if(iMinutes > 0)
	{
		Format(result, sizeof(result), "%i分 %.1f秒", iMinutes, fSeconds);
	}
	else
	{
		Format(result, sizeof(result), "%.1f秒", fSeconds);
	}

	return result;
}

public Action Timer_CleanupOldSaves(Handle timer)
{
	if (g_hSavesDB == INVALID_HANDLE)
	{
		return Plugin_Continue;
	}

	// Cleanup manual saves
	int expirationTime = g_cvSaveExpiration.IntValue;
	if (expirationTime > 0)
	{
		int currentTime = GetTime();
		int cutoffTime = currentTime - expirationTime;

		char sQuery[512];
		FormatEx(sQuery, sizeof(sQuery), 
			"DELETE s, e, c FROM `saves` s " ...
			"LEFT JOIN `saves-events` e ON s.map = e.map AND s.auth = e.auth AND s.style = e.style AND s.track = e.track_id " ...
			"LEFT JOIN `saves-customdata` c ON s.map = c.map AND s.auth = c.auth AND s.style = c.style AND s.track = c.track " ...
			"WHERE s.date < %d;", 
			cutoffTime);
		
		SQL_TQuery(g_hSavesDB, SQL_CleanupCallback, sQuery, 0);
	}

	// Cleanup autosaves
	int autosaveExpiration = g_cvAutosaveExpiration.IntValue;
	if (autosaveExpiration > 0)
	{
		int currentTime = GetTime();
		int autosaveCutoff = currentTime - autosaveExpiration;

		char sQuery[512];
		FormatEx(sQuery, sizeof(sQuery), 
			"DELETE s, e, c FROM `autosaves` s " ...
			"LEFT JOIN `autosaves-events` e ON s.map = e.map AND s.auth = e.auth AND s.style = e.style AND s.track = e.track_id " ...
			"LEFT JOIN `autosaves-customdata` c ON s.map = c.map AND s.auth = c.auth AND s.style = c.style AND s.track = c.track " ...
			"WHERE s.disconnect_time < %d;", 
			autosaveCutoff);
		
		SQL_TQuery(g_hSavesDB, SQL_CleanupCallback, sQuery, 1);
	}

	return Plugin_Continue;
}

public void SQL_CleanupCallback(Handle owner, Handle hndl, const char[] error, any data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("清理旧保存失败! %s", error);
		return;
	}

	int affectedRows = SQL_GetAffectedRows(owner);
	if (affectedRows > 0)
	{
		int isAutosave = view_as<int>(data);
		if (isAutosave)
			LogMessage("已自动删除 %d 个过期的自动保存。", affectedRows);
		else
			LogMessage("已自动删除 %d 个过期的手动保存。", affectedRows);
	}
}

// Check if player has autosave on current map
void CheckAutosave(int client)
{
	if (g_cvAutosaveExpiration.IntValue == 0)
		return;
	
	if (g_hSavesDB == INVALID_HANDLE)
		return;
	
	if (!IsValidClient(client) || IsFakeClient(client))
		return;
	
	char sQuery[512];
	FormatEx(sQuery, sizeof(sQuery), 
		"SELECT style, track, TfCurrentTime, disconnect_time, TiTimerTrack FROM `autosaves` WHERE map = '%s' AND auth = %d;",
		g_sCurrentMap, GetSteamAccountID(client));
	
	SQL_TQuery(g_hSavesDB, SQL_CheckAutosave, sQuery, GetClientSerial(client));
}

public void SQL_CheckAutosave(Handle owner, Handle hndl, const char[] error, int serial)
{
	int client = GetClientFromSerial(serial);
	
	if (!IsValidClient(client))
		return;
	
	if (hndl == INVALID_HANDLE)
	{
		LogError("SQL_CheckAutosave failed: %s", error);
		return;
	}
	
	if (SQL_GetRowCount(hndl) > 0)
	{
		while (SQL_FetchRow(hndl))
		{
			int iStyle = SQL_FetchInt(hndl, 0);
			int iTrack = SQL_FetchInt(hndl, 1);
			float fTime = SQL_FetchFloat(hndl, 2);
			int iDate = SQL_FetchInt(hndl, 3);
			
			g_bHasAutosave[client][iStyle][iTrack] = true;
			g_fAutosaveTime[client][iStyle][iTrack] = fTime;
			g_iAutosaveDate[client][iStyle][iTrack] = iDate;
		}
		
		// Silent detection - no chat notification
		// Autosave will load when player enters start zone
	}
}

// Auto-save when player disconnects
void AutosaveGame(int client)
{
	int style = Shavit_GetBhopStyle(client);
	int track = Shavit_GetClientTrack(client);
	
	// Capture current state
	Shavit_SaveCheckpointCache(client, client, g_aSavestates[client], -1, sizeof(g_aSavestates[client]));
	g_aSavestates[client].iPreFrames = Shavit_GetPlayerPreFrames(client);
	
	float fZoneOffset[2];
	fZoneOffset[0] = g_aSavestates[client].aSnapshot.fZoneOffset[0];
	fZoneOffset[1] = g_aSavestates[client].aSnapshot.fZoneOffset[1];
	
	// Save replay frames to autosave file
	char sPath[PLATFORM_MAX_PATH];
	FormatEx(sPath, sizeof(sPath), "%s/autosaves/%s_%i_%i_t%i.replay", g_sReplayFolder, g_sCurrentMap, style, GetSteamAccountID(client), track);
	
	// Ensure autosaves directory exists
	char sDirPath[PLATFORM_MAX_PATH];
	FormatEx(sDirPath, sizeof(sDirPath), "%s/autosaves", g_sReplayFolder);
	if (!DirExists(sDirPath))
		CreateDirectory(sDirPath, 511);
	
	File fFile = OpenFile(sPath, "wb+");
	if (fFile != null)
	{
		ArrayList ReplayFrames = Shavit_GetReplayData(client);
		int iSize = Shavit_GetClientFrameCount(client);
		
		WriteReplayHeader(fFile, style, 0, g_aSavestates[client].aSnapshot.fCurrentTime, GetSteamAccountID(client), 
			g_aSavestates[client].iPreFrames, 0, fZoneOffset, iSize, g_fTickrate, g_sCurrentMap);
		WriteReplayFrames(ReplayFrames, iSize, fFile);
		delete fFile;
		delete ReplayFrames;
	}
	
	// Save events
	if (g_aSavestates[client].aEvents != null && g_aSavestates[client].aOutputWaits != null)
	{
		char sQuery[2048];
		FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `autosaves-events` WHERE `map` = '%s' AND `auth` = %i AND `style` = %i AND `track_id` = %i;", 
			g_sCurrentMap, GetSteamAccountID(client), style, track);
		SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
		
		for (int i = 0; i < g_aSavestates[client].aEvents.Length; i++)
		{
			event_t e;
			g_aSavestates[client].aEvents.GetArray(i, e);
			FormatEx(sQuery, sizeof(sQuery), 
				"INSERT INTO `autosaves-events` (`type`, `id`, `map`, `auth`, `style`, `track_id`, `Etarget`, `EtargetInput`, `EvariantValue`, `Edelay`, `Eactivator`, `Ecaller`, `EoutputID`) " ...
				"VALUES ('event', '%i', '%s', '%i', '%i', '%i', '%s', '%s', '%s', '%f', '%i', '%i', '%i');", 
				i, g_sCurrentMap, GetSteamAccountID(client), style, track, e.target, e.targetInput, e.variantValue, e.delay, e.activator, e.caller, e.outputID);
			SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
		}
		
		for (int i = 0; i < g_aSavestates[client].aOutputWaits.Length; i++)
		{
			entity_t e;
			g_aSavestates[client].aOutputWaits.GetArray(i, e);
			FormatEx(sQuery, sizeof(sQuery), 
				"INSERT INTO `autosaves-events` (`type`, `id`, `map`, `auth`, `style`, `track_id`, `Ecaller`, `EwaitTime`) " ...
				"VALUES ('output', '%i', '%s', '%i', '%i', '%i', '%i', '%f');", 
				i, g_sCurrentMap, GetSteamAccountID(client), style, track, e.caller, e.waitTime);
			SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
		}
	}
	
	// Save customdata
	if (g_aSavestates[client].customdata != null)
	{
		char sQuery[1024];
		FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `autosaves-customdata` WHERE `map` = '%s' AND `auth` = %i AND `style` = %i AND `track` = %i;", 
			g_sCurrentMap, GetSteamAccountID(client), style, track);
		SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
		
		float fPunishTime;
		int iLastBlock;
		if (g_aSavestates[client].customdata.ContainsKey("mpbhops_punishtime"))
			g_aSavestates[client].customdata.GetValue("mpbhops_punishtime", fPunishTime);
		if (g_aSavestates[client].customdata.ContainsKey("mpbhops_lastblock"))
			g_aSavestates[client].customdata.GetValue("mpbhops_lastblock", iLastBlock);
		
		char sPunishTime[64];
		char sLastBlock[64];
		FloatToString(fPunishTime, sPunishTime, sizeof(sPunishTime));
		IntToString(iLastBlock, sLastBlock, sizeof(sLastBlock));
		
		FormatEx(sQuery, sizeof(sQuery), 
			"INSERT INTO `autosaves-customdata` (`id`, `map`, `auth`, `style`, `track`, `key`, `value`) " ...
			"VALUES ('0', '%s', '%i', '%i', '%i', 'mpbhops_punishtime', '%s'), ('1', '%s', '%i', '%i', '%i', 'mpbhops_lastblock', '%s');", 
			g_sCurrentMap, GetSteamAccountID(client), style, track, sPunishTime, g_sCurrentMap, GetSteamAccountID(client), style, track, sLastBlock);
		SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
	}
	
	// Save to database
	char sQuery[8192];
	FormatEx(sQuery, sizeof(sQuery), 
		"REPLACE INTO `autosaves` (`map`, `auth`, `style`, `track`, `disconnect_time`, `TbTimerEnabled`, `TfCurrentTime`, `TbClientPaused`, `TiJumps`, `TiStrafes`, `TiTotalMeasures`, `TiGoodGains`, `TfServerTime`, `TiKeyCombo`, `TiTimerTrack`, `TiMeasuredJumps`, `TiPerfectJumps`, `TfZoneOffset1`, `TfZoneOffset2`, `TfDistanceOffset1`, `TfDistanceOffset2`, `TfAvgVelocity`, `TfMaxVelocity`, `TfTimescale`, `TiZoneIncrement`, `TiFullTicks`, `TiFractionalTicks`, `TbPracticeMode`, `TbJumped`, `TbCanUseAllKeys`, `TbOnGround`, `TiLastButtons`, `TfLastAngle`, `TiLandingTick`, `TiLastMoveType`, `TfStrafeWarning`, `TfLastInputVel1`, `TfLastInputVel2`, `Tfplayer_speedmod`, `TfNextFrameTime`, `TiLastMoveTypeTAS`, `CfPosition1`, `CfPosition2`, `CfPosition3`, `CfAngles1`, `CfAngles2`, `CfAngles3`, `CfVelocity1`, `CfVelocity2`, `CfVelocity3`, `CiMovetype`, `CfGravity`, `CfSpeed`, `CfStamina`, `CbDucked`, `CbDucking`, `CfDuckTime`, `CfDuckSpeed`, `CiFlags`, `CsTargetname`, `CsClassname`, `CiPreFrames`, `CbSegmented`, `CiGroundEntity`, `CvecLadderNormal1`, `CvecLadderNormal2`, `CvecLadderNormal3`, `Cm_bHasWalkMovedSinceLastJump`, `Cm_ignoreLadderJumpTime`, `Cm_lastStandingPos1`, `Cm_lastStandingPos2`, `Cm_lastStandingPos3`, `Cm_ladderSuppressionTimer1`, `Cm_ladderSuppressionTimer2`,  `Cm_lastLadderNormal1`, `Cm_lastLadderNormal2`, `Cm_lastLadderNormal3`, `Cm_lastLadderPos1`, `Cm_lastLadderPos2`, `Cm_lastLadderPos3`, `Cm_afButtonDisabled`, `Cm_afButtonForced`) " ...
		"VALUES ('%s', '%i', '%i', '%i', '%i', '%i', '%f', '%i', '%i', '%i', '%i', '%i', '%f', '%i', '%i', '%i', '%i', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%i', '%i', '%i', '%i', '%i', '%i', '%i', '%i', '%f', '%i', '%i', '%f', '%f', '%f', '%f', '%f', '%i', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%i', '%f', '%f', '%f', '%i', '%i', '%f', '%f', '%i', '%s', '%s', '%i', '%i', '%i', '%f', '%f', '%f', '%i', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%i', '%i');",
		g_sCurrentMap, GetSteamAccountID(client), style, track, GetTime(),
		view_as<int>(g_aSavestates[client].aSnapshot.bTimerEnabled), g_aSavestates[client].aSnapshot.fCurrentTime, view_as<int>(g_aSavestates[client].aSnapshot.bClientPaused), g_aSavestates[client].aSnapshot.iJumps,
		g_aSavestates[client].aSnapshot.iStrafes, g_aSavestates[client].aSnapshot.iTotalMeasures, g_aSavestates[client].aSnapshot.iGoodGains, g_aSavestates[client].aSnapshot.fServerTime, g_aSavestates[client].aSnapshot.iKeyCombo, g_aSavestates[client].aSnapshot.iTimerTrack, 
		g_aSavestates[client].aSnapshot.iMeasuredJumps, g_aSavestates[client].aSnapshot.iPerfectJumps, g_aSavestates[client].aSnapshot.fZoneOffset[0], g_aSavestates[client].aSnapshot.fZoneOffset[1], 
		g_aSavestates[client].aSnapshot.fDistanceOffset[0], g_aSavestates[client].aSnapshot.fDistanceOffset[1], g_aSavestates[client].aSnapshot.fAvgVelocity, 
		g_aSavestates[client].aSnapshot.fMaxVelocity, g_aSavestates[client].aSnapshot.fTimescale, g_aSavestates[client].aSnapshot.iZoneIncrement, g_aSavestates[client].aSnapshot.iFullTicks, g_aSavestates[client].aSnapshot.iFractionalTicks, view_as<int>(g_aSavestates[client].aSnapshot.bPracticeMode), 
		view_as<int>(g_aSavestates[client].aSnapshot.bJumped), view_as<int>(g_aSavestates[client].aSnapshot.bCanUseAllKeys), view_as<int>(g_aSavestates[client].aSnapshot.bOnGround), g_aSavestates[client].aSnapshot.iLastButtons, g_aSavestates[client].aSnapshot.fLastAngle, 
		g_aSavestates[client].aSnapshot.iLandingTick, g_aSavestates[client].aSnapshot.iLastMoveType, g_aSavestates[client].aSnapshot.fStrafeWarning, 
		g_aSavestates[client].aSnapshot.fLastInputVel[0], g_aSavestates[client].aSnapshot.fLastInputVel[1],  g_aSavestates[client].aSnapshot.fplayer_speedmod, 
		g_aSavestates[client].aSnapshot.fNextFrameTime, g_aSavestates[client].aSnapshot.iLastMoveTypeTAS, 
		g_aSavestates[client].fPosition[0], g_aSavestates[client].fPosition[1], g_aSavestates[client].fPosition[2], 
		g_aSavestates[client].fAngles[0], g_aSavestates[client].fAngles[1], g_aSavestates[client].fAngles[2], 
		g_aSavestates[client].fVelocity[0], g_aSavestates[client].fVelocity[1], g_aSavestates[client].fVelocity[2], 
		g_aSavestates[client].iMoveType, g_aSavestates[client].fGravity, g_aSavestates[client].fSpeed, g_aSavestates[client].fStamina, 
		view_as<int>(g_aSavestates[client].bDucked), view_as<int>(g_aSavestates[client].bDucking), g_aSavestates[client].fDucktime, g_aSavestates[client].fDuckSpeed, 
		g_aSavestates[client].iFlags, g_aSavestates[client].sTargetname, g_aSavestates[client].sClassname, 
		g_aSavestates[client].iPreFrames, view_as<int>(g_aSavestates[client].bSegmented), g_aSavestates[client].iGroundEntity, 
		g_aSavestates[client].vecLadderNormal[0], g_aSavestates[client].vecLadderNormal[1], g_aSavestates[client].vecLadderNormal[2], 
		view_as<int>(g_aSavestates[client].m_bHasWalkMovedSinceLastJump), g_aSavestates[client].m_ignoreLadderJumpTime, 
		g_aSavestates[client].m_lastStandingPos[0], g_aSavestates[client].m_lastStandingPos[1], g_aSavestates[client].m_lastStandingPos[2], 
		g_aSavestates[client].m_ladderSurpressionTimer[0], g_aSavestates[client].m_ladderSurpressionTimer[1], 
		g_aSavestates[client].m_lastLadderNormal[0], g_aSavestates[client].m_lastLadderNormal[1], g_aSavestates[client].m_lastLadderNormal[2], 
		g_aSavestates[client].m_lastLadderPos[0], g_aSavestates[client].m_lastLadderPos[1], g_aSavestates[client].m_lastLadderPos[2], 
		g_aSavestates[client].m_afButtonDisabled, g_aSavestates[client].m_afButtonForced);
	
	SQL_TQuery(g_hSavesDB, SQL_AutosaveCallback, sQuery, GetClientSerial(client));
}

public void SQL_AutosaveCallback(Handle owner, Handle hndl, const char[] error, int serial)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("自动保存失败! %s", error);
	}
}

// Forward from zones plugin - called when player enters a zone
public void Shavit_OnEnterZone(int client, int type, int track, int id, int entity, int data)
{
	// Auto-load when entering start zone
	if (type == Zone_Start && !g_bAutosaveNotified[client])
	{
		int style = Shavit_GetBhopStyle(client);
		if (g_bHasAutosave[client][style][track])
		{
			g_bAutosaveNotified[client] = true;
			AutoloadGame(client, style, track);
		}
	}
}

// Auto-load autosave
void AutoloadGame(int client, int style, int track)
{
	if (g_cvAutosaveExpiration.IntValue == 0)
		return;
	
	if (g_hSavesDB == INVALID_HANDLE)
		return;
	
	// Load replay file - try new format first, fallback to old format
	char sPath[PLATFORM_MAX_PATH];
	FormatEx(sPath, sizeof(sPath), "%s/autosaves/%s_%i_%i_t%i.replay", g_sReplayFolder, g_sCurrentMap, style, GetSteamAccountID(client), track);
	
	// Fallback to old format if new format doesn't exist (for backwards compatibility)
	if (!FileExists(sPath) && track == 0)
	{
		FormatEx(sPath, sizeof(sPath), "%s/autosaves/%s_%i_%i.replay", g_sReplayFolder, g_sCurrentMap, style, GetSteamAccountID(client));
	}
	
	if (FileExists(sPath))
	{
		if (!LoadReplayCache(g_aReplayCache[client], style, track, sPath, g_sCurrentMap))
		{
			LogError("自动加载回放失败! (%s)", sPath);
			// Silent failure - no chat notification
			return;
		}
	}
	
	// Load events and customdata
	LoadAutosaveEvents(client, style, track);
	LoadAutosaveCustomData(client, style, track);
	
	// Load from database
	char sQuery[2048];
	FormatEx(sQuery, sizeof(sQuery), 
		"SELECT `style`, `track`, `TbTimerEnabled`, `TfCurrentTime`, `TbClientPaused`, `TiJumps`, `TiStrafes`, `TiTotalMeasures`, `TiGoodGains`, `TfServerTime`, `TiKeyCombo`, `TiTimerTrack`, `TiMeasuredJumps`, `TiPerfectJumps`, `TfZoneOffset1`, `TfZoneOffset2`, `TfDistanceOffset1`, `TfDistanceOffset2`, `TfAvgVelocity`, `TfMaxVelocity`, `TfTimescale`, `TiZoneIncrement`, `TiFullTicks`, `TiFractionalTicks`, `TbPracticeMode`, `TbJumped`, `TbCanUseAllKeys`, `TbOnGround`, `TiLastButtons`, `TfLastAngle`, `TiLandingTick`, `TiLastMoveType`, `TfStrafeWarning`, `TfLastInputVel1`, `TfLastInputVel2`, `Tfplayer_speedmod`, `TfNextFrameTime`, `TiLastMoveTypeTAS`, `CfPosition1`, `CfPosition2`, `CfPosition3`, `CfAngles1`, `CfAngles2`, `CfAngles3`, `CfVelocity1`, `CfVelocity2`, `CfVelocity3`, `CiMovetype`, `CfGravity`, `CfSpeed`, `CfStamina`, `CbDucked`, `CbDucking`, `CfDuckTime`, `CfDuckSpeed`, `CiFlags`, `CsTargetname`, `CsClassname`, `CiPreFrames`, `CbSegmented`, `CiGroundEntity`, `CvecLadderNormal1`, `CvecLadderNormal2`, `CvecLadderNormal3`, `Cm_bHasWalkMovedSinceLastJump`, `Cm_ignoreLadderJumpTime`, `Cm_lastStandingPos1`, `Cm_lastStandingPos2`, `Cm_lastStandingPos3`, `Cm_ladderSuppressionTimer1`, `Cm_ladderSuppressionTimer2`, `Cm_lastLadderNormal1`, `Cm_lastLadderNormal2`, `Cm_lastLadderNormal3`, `Cm_lastLadderPos1`, `Cm_lastLadderPos2`, `Cm_lastLadderPos3`, `Cm_afButtonDisabled`, `Cm_afButtonForced` " ...
		"FROM `autosaves` WHERE `map` = '%s' AND `auth` = %i AND `style` = %i AND `track` = %i;", 
		g_sCurrentMap, GetSteamAccountID(client), style, track);
	
	SQL_TQuery(g_hSavesDB, SQL_AutoloadGame, sQuery, GetClientSerial(client));
}

void LoadAutosaveEvents(int client, int style, int track)
{
	char sQuery[2048];
	FormatEx(sQuery, sizeof(sQuery), "SELECT * FROM `autosaves-events` WHERE map = '%s' AND auth = %i AND style = %i AND track_id = %i ORDER BY id ASC;", 
		g_sCurrentMap, GetSteamAccountID(client), style, track);
	SQL_TQuery(g_hSavesDB, SQL_LoadAutosaveEvents, sQuery, GetClientSerial(client));
}

public void SQL_LoadAutosaveEvents(Handle owner, Handle hndl, const char[] error, int serial)
{
	int client = GetClientFromSerial(serial);
	if (!IsValidClient(client))
		return;
	
	if (hndl == INVALID_HANDLE)
	{
		LogError("SQL_LoadAutosaveEvents failed: %s", error);
		return;
	}
	
	if (SQL_GetRowCount(hndl) > 0)
	{
		if (g_aSavestates[client].aEvents != null)
			delete g_aSavestates[client].aEvents;
		if (g_aSavestates[client].aOutputWaits != null)
			delete g_aSavestates[client].aOutputWaits;
		
		g_aSavestates[client].aEvents = new ArrayList(sizeof(event_t));
		g_aSavestates[client].aOutputWaits = new ArrayList(sizeof(entity_t));
		
		while (SQL_FetchRow(hndl))
		{
			char sType[16];
			SQL_FetchString(hndl, 0, sType, sizeof(sType));
			
			if (StrEqual(sType, "event"))
			{
				event_t e;
				SQL_FetchString(hndl, 5, e.target, sizeof(e.target));
				SQL_FetchString(hndl, 6, e.targetInput, sizeof(e.targetInput));
				SQL_FetchString(hndl, 7, e.variantValue, sizeof(e.variantValue));
				e.delay = SQL_FetchFloat(hndl, 8);
				e.activator = SQL_FetchInt(hndl, 9);
				e.caller = SQL_FetchInt(hndl, 10);
				e.outputID = SQL_FetchInt(hndl, 11);
				g_aSavestates[client].aEvents.PushArray(e);
			}
			else if (StrEqual(sType, "output"))
			{
				entity_t e;
				e.caller = SQL_FetchInt(hndl, 10);
				e.waitTime = SQL_FetchFloat(hndl, 12);
				g_aSavestates[client].aOutputWaits.PushArray(e);
			}
		}
	}
}

void LoadAutosaveCustomData(int client, int style, int track)
{
	char sQuery[2048];
	FormatEx(sQuery, sizeof(sQuery), "SELECT * FROM `autosaves-customdata` WHERE map = '%s' AND auth = %i AND style = %i AND track = %i;", 
		g_sCurrentMap, GetSteamAccountID(client), style, track);
	SQL_TQuery(g_hSavesDB, SQL_LoadAutosaveCustomData, sQuery, GetClientSerial(client));
}

public void SQL_LoadAutosaveCustomData(Handle owner, Handle hndl, const char[] error, int serial)
{
	int client = GetClientFromSerial(serial);
	if (!IsValidClient(client))
		return;
	
	if (hndl == INVALID_HANDLE)
	{
		LogError("SQL_LoadAutosaveCustomData failed: %s", error);
		return;
	}
	
	if (SQL_GetRowCount(hndl) > 0)
	{
		if (g_aSavestates[client].customdata != null)
			delete g_aSavestates[client].customdata;
		
		g_aSavestates[client].customdata = new StringMap();
		
		while (SQL_FetchRow(hndl))
		{
			char sKey[64];
			char sValue[64];
			SQL_FetchString(hndl, 4, sKey, sizeof(sKey));
			SQL_FetchString(hndl, 5, sValue, sizeof(sValue));
			
			if (StrEqual(sKey, "mpbhops_punishtime"))
			{
				float fPunishTime = StringToFloat(sValue);
				g_aSavestates[client].customdata.SetValue("mpbhops_punishtime", fPunishTime);
			}
			else if (StrEqual(sKey, "mpbhops_lastblock"))
			{
				int iLastBlock = StringToInt(sValue);
				g_aSavestates[client].customdata.SetValue("mpbhops_lastblock", iLastBlock);
			}
		}
	}
}

public void SQL_AutoloadGame(Handle owner, Handle hndl, const char[] error, int serial)
{
	int client = GetClientFromSerial(serial);
	
	if (!IsValidClient(client))
		return;
	
	if (hndl == INVALID_HANDLE)
	{
		LogError("SQL_AutoloadGame failed: %s", error);
		return;
	}
	
	if (SQL_GetRowCount(hndl) < 1)
	{
		return;
	}
	
	int iStyle;
	int iTrack;
	if (SQL_FetchRow(hndl))
	{
		iStyle = SQL_FetchInt(hndl, 0);
		iTrack = SQL_FetchInt(hndl, 1);
		g_aSavestates[client].aSnapshot.bTimerEnabled = view_as<bool>(SQL_FetchInt(hndl, 2));
		g_aSavestates[client].aSnapshot.fCurrentTime = SQL_FetchFloat(hndl, 3);
		g_aSavestates[client].aSnapshot.bClientPaused = view_as<bool>(SQL_FetchInt(hndl, 4));
		g_aSavestates[client].aSnapshot.iJumps = SQL_FetchInt(hndl, 5);
		g_aSavestates[client].aSnapshot.iStrafes = SQL_FetchInt(hndl, 6);
		g_aSavestates[client].aSnapshot.iTotalMeasures = SQL_FetchInt(hndl, 7);
		g_aSavestates[client].aSnapshot.iGoodGains = SQL_FetchInt(hndl, 8);
		g_aSavestates[client].aSnapshot.fServerTime = SQL_FetchFloat(hndl, 9);
		g_aSavestates[client].aSnapshot.iKeyCombo = SQL_FetchInt(hndl, 10);
		g_aSavestates[client].aSnapshot.iTimerTrack = SQL_FetchInt(hndl, 11);
		g_aSavestates[client].aSnapshot.iMeasuredJumps = SQL_FetchInt(hndl, 12);
		g_aSavestates[client].aSnapshot.iPerfectJumps = SQL_FetchInt(hndl, 13);
		g_aSavestates[client].aSnapshot.fZoneOffset[0] = SQL_FetchFloat(hndl, 14);
		g_aSavestates[client].aSnapshot.fZoneOffset[1] = SQL_FetchFloat(hndl, 15);
		g_aSavestates[client].aSnapshot.fDistanceOffset[0] = SQL_FetchFloat(hndl, 16);
		g_aSavestates[client].aSnapshot.fDistanceOffset[1] = SQL_FetchFloat(hndl, 17);
		g_aSavestates[client].aSnapshot.fAvgVelocity = SQL_FetchFloat(hndl, 18);
		g_aSavestates[client].aSnapshot.fMaxVelocity = SQL_FetchFloat(hndl, 19);
		g_aSavestates[client].aSnapshot.fTimescale = SQL_FetchFloat(hndl, 20);
		g_aSavestates[client].aSnapshot.iZoneIncrement = SQL_FetchInt(hndl, 21);
		g_aSavestates[client].aSnapshot.iFullTicks = SQL_FetchInt(hndl, 22);
		g_aSavestates[client].aSnapshot.iFractionalTicks = SQL_FetchInt(hndl, 23);
		g_aSavestates[client].aSnapshot.bPracticeMode = view_as<bool>(SQL_FetchInt(hndl, 24));
		g_aSavestates[client].aSnapshot.bJumped = view_as<bool>(SQL_FetchInt(hndl, 25));
		g_aSavestates[client].aSnapshot.bCanUseAllKeys = view_as<bool>(SQL_FetchInt(hndl, 26));
		g_aSavestates[client].aSnapshot.bOnGround = view_as<bool>(SQL_FetchInt(hndl, 27));
		g_aSavestates[client].aSnapshot.iLastButtons = SQL_FetchInt(hndl, 28);
		g_aSavestates[client].aSnapshot.fLastAngle = SQL_FetchFloat(hndl, 29);
		g_aSavestates[client].aSnapshot.iLandingTick = SQL_FetchInt(hndl, 30);
		g_aSavestates[client].aSnapshot.iLastMoveType = view_as<MoveType>(SQL_FetchInt(hndl, 31));
		g_aSavestates[client].aSnapshot.fStrafeWarning = SQL_FetchFloat(hndl, 32);
		g_aSavestates[client].aSnapshot.fLastInputVel[0] = SQL_FetchFloat(hndl, 33);
		g_aSavestates[client].aSnapshot.fLastInputVel[1] = SQL_FetchFloat(hndl, 34);
		g_aSavestates[client].aSnapshot.fplayer_speedmod = SQL_FetchFloat(hndl, 35);
		g_aSavestates[client].aSnapshot.fNextFrameTime = SQL_FetchFloat(hndl, 36);
		g_aSavestates[client].aSnapshot.iLastMoveTypeTAS = view_as<MoveType>(SQL_FetchInt(hndl, 37));
		g_aSavestates[client].fPosition[0] = SQL_FetchFloat(hndl, 38);
		g_aSavestates[client].fPosition[1] = SQL_FetchFloat(hndl, 39);
		g_aSavestates[client].fPosition[2] = SQL_FetchFloat(hndl, 40);
		g_aSavestates[client].fAngles[0] = SQL_FetchFloat(hndl, 41);
		g_aSavestates[client].fAngles[1] = SQL_FetchFloat(hndl, 42);
		g_aSavestates[client].fAngles[2] = SQL_FetchFloat(hndl, 43);
		g_aSavestates[client].fVelocity[0] = SQL_FetchFloat(hndl, 44);
		g_aSavestates[client].fVelocity[1] = SQL_FetchFloat(hndl, 45);
		g_aSavestates[client].fVelocity[2] = SQL_FetchFloat(hndl, 46);
		g_aSavestates[client].iMoveType = MOVETYPE_WALK;
		g_aSavestates[client].fGravity = SQL_FetchFloat(hndl, 48);
		g_aSavestates[client].fSpeed = SQL_FetchFloat(hndl, 49);
		g_aSavestates[client].fStamina = SQL_FetchFloat(hndl, 50);
		g_aSavestates[client].bDucked = view_as<bool>(SQL_FetchInt(hndl, 51));
		g_aSavestates[client].bDucking = view_as<bool>(SQL_FetchInt(hndl, 52));
		g_aSavestates[client].fDucktime = SQL_FetchFloat(hndl, 53);
		g_aSavestates[client].fDuckSpeed = SQL_FetchFloat(hndl, 54);
		g_aSavestates[client].iFlags = SQL_FetchInt(hndl, 55);
		SQL_FetchString(hndl, 56, g_aSavestates[client].sTargetname, sizeof(g_aSavestates[client].sTargetname));
		SQL_FetchString(hndl, 57, g_aSavestates[client].sClassname, sizeof(g_aSavestates[client].sClassname));
		g_aSavestates[client].iPreFrames = SQL_FetchInt(hndl, 58);
		g_aSavestates[client].bSegmented = view_as<bool>(SQL_FetchInt(hndl, 59));
		g_aSavestates[client].iGroundEntity = SQL_FetchInt(hndl, 60);
		g_aSavestates[client].vecLadderNormal[0] = SQL_FetchFloat(hndl, 61);
		g_aSavestates[client].vecLadderNormal[1] = SQL_FetchFloat(hndl, 62);
		g_aSavestates[client].vecLadderNormal[2] = SQL_FetchFloat(hndl, 63);
		g_aSavestates[client].m_bHasWalkMovedSinceLastJump = view_as<bool>(SQL_FetchInt(hndl, 64));
		g_aSavestates[client].m_ignoreLadderJumpTime = SQL_FetchFloat(hndl, 65);
		g_aSavestates[client].m_lastStandingPos[0] = SQL_FetchFloat(hndl, 66);
		g_aSavestates[client].m_lastStandingPos[1] = SQL_FetchFloat(hndl, 67);
		g_aSavestates[client].m_lastStandingPos[2] = SQL_FetchFloat(hndl, 68);
		g_aSavestates[client].m_ladderSurpressionTimer[0] = SQL_FetchFloat(hndl, 69);
		g_aSavestates[client].m_ladderSurpressionTimer[1] = SQL_FetchFloat(hndl, 70);
		g_aSavestates[client].m_lastLadderNormal[0] = SQL_FetchFloat(hndl, 71);
		g_aSavestates[client].m_lastLadderNormal[1] = SQL_FetchFloat(hndl, 72);
		g_aSavestates[client].m_lastLadderNormal[2] = SQL_FetchFloat(hndl, 73);
		g_aSavestates[client].m_lastLadderPos[0] = SQL_FetchFloat(hndl, 74);
		g_aSavestates[client].m_lastLadderPos[1] = SQL_FetchFloat(hndl, 75);
		g_aSavestates[client].m_lastLadderPos[2] = SQL_FetchFloat(hndl, 76);
		g_aSavestates[client].m_afButtonDisabled = SQL_FetchInt(hndl, 77);
		g_aSavestates[client].m_afButtonForced = SQL_FetchInt(hndl, 78);
	}
	
	g_aSavestates[client].iSteamID = GetSteamAccountID(client);
	g_aSavestates[client].aSnapshot.bsStyle = iStyle;
	
	// Clear checkpoints and stop timer
	Shavit_ClearCheckpoints(client);
	Shavit_StopTimer(client, true);
	
	// Set replay frames
	if (g_aReplayCache[client].aFrames)
		Shavit_SetReplayData(client, g_aReplayCache[client].aFrames);
	Shavit_SetPlayerPreFrames(client, g_aReplayCache[client].iPreFrames);
	
	// Load the checkpoint cache
	Shavit_LoadCheckpointCache(client, g_aSavestates[client], -1, sizeof(g_aSavestates[client]), true);
	
	if (Shavit_GetTimerStatus(client) == Timer_Paused)
		Shavit_ResumeTimer(client);
	
	if (Shavit_GetStyleSettingBool(iStyle, "kzcheckpoints") || Shavit_GetStyleSettingBool(iStyle, "segments"))
		Shavit_SaveCheckpoint(client);
	
	// Notify player that autosave was loaded
	Shavit_PrintToChat(client, "%s自动存档%s加载%s成功！(Autosave)", g_sChatStrings.sVariable, g_sChatStrings.sText, g_sChatStrings.sVariable);
	
	// Delete the autosave after loading
	DeleteAutosave(client, iStyle, iTrack);
}

void DeleteAutosave(int client, int style, int track)
{
	char sQuery[2048];
	
	// Delete from database
	FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `autosaves` WHERE auth = %i AND map = '%s' AND style = %i AND track = %i;", 
		GetSteamAccountID(client), g_sCurrentMap, style, track);
	SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
	
	FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `autosaves-events` WHERE auth = %i AND map = '%s' AND style = %i AND track_id = %i;", 
		GetSteamAccountID(client), g_sCurrentMap, style, track);
	SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
	
	FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `autosaves-customdata` WHERE auth = %i AND map = '%s' AND style = %i AND track = %i;", 
		GetSteamAccountID(client), g_sCurrentMap, style, track);
	SQL_TQuery(g_hSavesDB, SQL_GeneralCallback, sQuery);
	
	// Delete replay file - try new format first, fallback to old format
	char sPath[PLATFORM_MAX_PATH];
	FormatEx(sPath, sizeof(sPath), "%s/autosaves/%s_%i_%i_t%i.replay", g_sReplayFolder, g_sCurrentMap, style, GetSteamAccountID(client), track);
	if (FileExists(sPath))
	{
		DeleteFile(sPath);
	}
	else if (track == 0)
	{
		// Try old format for backwards compatibility
		FormatEx(sPath, sizeof(sPath), "%s/autosaves/%s_%i_%i.replay", g_sReplayFolder, g_sCurrentMap, style, GetSteamAccountID(client));
		if (FileExists(sPath))
			DeleteFile(sPath);
	}
}