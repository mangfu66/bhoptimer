#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <cstrike>
#include <sdktools>
#include <shavit>
#include <shavit/checkpoints>
#include <shavit/core> 
#include <shavit/hud>
#include <shavit/replay-playback>
#include <shavit/replay-file>
#include <shavit/wr>

#define MAX_TEAMS 12
#define MAX_TEAM_MEMBERS 10

// 音效
#define SOUND_INVITE "buttons/blip1.wav"
#define SOUND_PASS "buttons/bell1.wav"
#define SOUND_UNDO "buttons/button10.wav"
#define SOUND_SWITCH "buttons/lightswitch2.wav"

char g_cMapName[PLATFORM_MAX_PATH];

ConVar g_cvMaxPasses;
ConVar g_cvMaxUndos;
ConVar g_cvSaveToPass;
ConVar g_cvMinPlayers;

// 数据库
Database gH_SQL = null;

// 队伍邀请 & 成员管理
int g_iInviteStyle[MAXPLAYERS + 1];
bool g_bCreatingTeam[MAXPLAYERS + 1];
ArrayList g_aInvitedPlayers[MAXPLAYERS + 1];
bool g_bInvitedPlayer[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_nDeclinedPlayers[MAXPLAYERS + 1];
ArrayList g_aAcceptedPlayers[MAXPLAYERS + 1];

// 队伍状态
bool g_bAllowStyleChange[MAXPLAYERS + 1];
int g_nUndoCount[MAX_TEAMS];
bool g_bDidUndo[MAX_TEAMS];
char g_cTeamName[MAX_TEAMS][MAX_NAME_LENGTH];
int g_nPassCount[MAX_TEAMS];
int g_nRelayCount[MAX_TEAMS];
int g_iCurrentPlayer[MAX_TEAMS];
bool g_bTeamTaken[MAX_TEAMS];
int g_nTeamPlayerCount[MAX_TEAMS];
char g_sSQLPrefix[32];

// 玩家状态
int g_iTeamIndex[MAXPLAYERS + 1] = { -1, ... };
int g_iLastTeamIndex[MAXPLAYERS + 1] = { -1, ... }; // [FIX] 缓存离队前的队伍ID
int g_iNextTeamMember[MAXPLAYERS + 1];
char g_cPlayerTeamName[MAXPLAYERS + 1][MAX_NAME_LENGTH];
int g_iPendingPassId[MAXPLAYERS + 1]; // [FIX] 追踪待定的传送，用于防止重开后被强制传送
bool g_bPendingFinishCleanup[MAXPLAYERS + 1]; // 完成者等待录像保存后再重置计时器
Handle g_hFinishCleanupTimer[MAXPLAYERS + 1]; // 兜底 timer，防止 OnReplaySaved 未触发

// 记录当前队伍的跑手历史 (用于保存到数据库)
ArrayList g_aTeamRunHistory[MAX_TEAMS];
ArrayList g_aTeamRunAuthHistory[MAX_TEAMS]; // 对应每个跑手的 SteamAccountID

// [NEW] 存储每次pass时的checkpoint数据，用于正确的undo
cp_cache_t g_LastPassCheckpoint[MAX_TEAMS];
bool g_bHasLastPassCheckpoint[MAX_TEAMS];

// 回放时的缓存
ArrayList g_aReplayRunners[MAXPLAYERS + 1]; 
int g_iReplayCurrentIndex[MAXPLAYERS + 1]; 
char g_cReplayTeamName[MAXPLAYERS + 1][MAX_NAME_LENGTH];

// HUD & 检测
Handle g_hTeamHudTimer = null;
Handle g_hHUDSynchronizer = null; 
int g_iLastReplayButton[MAXPLAYERS + 1];

// [NEW] TagTeam WR Cache for each style/track combination
// Cache structure: [style][track]
char g_cCachedWRTeamName[STYLE_LIMIT][TRACKS_SIZE][64];
ArrayList g_aCachedWRMembers[STYLE_LIMIT][TRACKS_SIZE]; // ArrayList of member names
bool g_bWRCacheLoaded[STYLE_LIMIT][TRACKS_SIZE];


public Plugin myinfo =
{
	name = "[shavit] TagTeam Relay",
	author = "SlidyBat",
	description = "TagTeam",
	version = "5.3.1",
	url = "https://github.com/shavitush/bhoptimer"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("timer-tagteam");
	
	// Register natives for other plugins to query TagTeam WR info
	CreateNative("Shavit_GetTagTeamWRInfo", Native_GetTagTeamWRInfo);
	
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvMaxPasses = CreateConVar("sm_timer_tagteam_maxpasses", "-1", "队伍最大接力次数 (-1 = 无限)", _, true, -1.0, false);
	g_cvMaxUndos = CreateConVar("sm_timer_tagteam_maxundos", "3", "队伍最大撤销次数 (-1 = 无限)", _, true, -1.0, false);
	g_cvSaveToPass = CreateConVar("sm_timer_tagteam_savetopass", "1", "是否允许使用 !save (存档) 命令直接触发接力？(1=是, 0=否)", _, true, 0.0, true, 1.0);
	g_cvMinPlayers = CreateConVar("sm_timer_tagteam_minplayers", "1", "最少队伍人数 (0=关闭限制允许solo测试, 1=开启需要2人)", _, true, 0.0, true, 1.0);
	
	AutoExecConfig(true, "shavit-tagteam", "sourcemod/shavit");

	RegConsoleCmd("sm_teamname", Command_TeamName, "设置队伍名称");
	RegConsoleCmd("sm_exitteam", Command_ExitTeam, "退出当前队伍");
	RegConsoleCmd("sm_pass", Command_Pass, "将接力棒传给下一位队友");
	RegConsoleCmd("sm_undo", Command_Undo, "撤销上一次接力");
	
	RegConsoleCmd("sm_tagteam", Command_TagTeamMenu, "打开 TagTeam 菜单");
	RegConsoleCmd("sm_tt", Command_TagTeamMenu, "打开 TagTeam 菜单");
	
	RegConsoleCmd("sm_tc", Command_TeamChat, "队伍聊天");
	RegConsoleCmd("sm_teamchat", Command_TeamChat, "队伍聊天");
	
	RegConsoleCmd("sm_tagteamhud", Command_RefreshHUD, "刷新 TagTeam HUD");
	RegConsoleCmd("sm_tthud", Command_RefreshHUD, "刷新 TagTeam HUD");
	
	RegAdminCmd("sm_deleteteam", Command_DeleteTeam, ADMFLAG_RCON, "打开 TagTeam 记录删除菜单");
	RegAdminCmd("sm_delteam", Command_DeleteTeam, ADMFLAG_RCON, "打开 TagTeam 记录删除菜单");

	AddCommandListener(Command_CP_Hook, "sm_cp");
	AddCommandListener(Command_CP_Hook, "sm_cpmenu");
	AddCommandListener(Command_CP_Hook, "sm_checkpoints");
	AddCommandListener(Command_CP_Hook, "sm_checkpoint");
	
	// [NEW] Block spectator commands in TagTeam
	AddCommandListener(Command_Spectate_Hook, "sm_r");
	AddCommandListener(Command_Spectate_Hook, "spec_next");
	AddCommandListener(Command_Spectate_Hook, "spec_prev");
	AddCommandListener(Command_Spectate_Hook, "spec_mode");
	
	// [NEW] Hook say for team name input
	AddCommandListener(Command_Say_Hook, "say");
	AddCommandListener(Command_Say_Hook, "say_team");

	for (int i = 0; i < MAX_TEAMS; i++)
	{
		g_aTeamRunHistory[i] = new ArrayList(ByteCountToCells(68));
		g_aTeamRunAuthHistory[i] = new ArrayList();
		g_bHasLastPassCheckpoint[i] = false;
	}

	GetCurrentMap(g_cMapName, sizeof(g_cMapName));
	
	if (g_hHUDSynchronizer == null)
		g_hHUDSynchronizer = CreateHudSynchronizer();
	
	delete g_hTeamHudTimer;
	g_hTeamHudTimer = CreateTimer(0.2, Timer_UpdateTeamHUD, _, TIMER_REPEAT);

	if(LibraryExists("shavit")) Shavit_OnDatabaseLoaded();
}

	// [FIX] Cleanup handles on plugin unload to prevent memory leaks
public void OnPluginEnd()
{
	// Cleanup all stored checkpoint handles
	for (int i = 0; i < MAX_TEAMS; i++)
	{
		if (g_bHasLastPassCheckpoint[i])
		{
			if (g_LastPassCheckpoint[i].aFrames != null) delete g_LastPassCheckpoint[i].aFrames;
			if (g_LastPassCheckpoint[i].aEvents != null) delete g_LastPassCheckpoint[i].aEvents;
			if (g_LastPassCheckpoint[i].aOutputWaits != null) delete g_LastPassCheckpoint[i].aOutputWaits;
			if (g_LastPassCheckpoint[i].customdata != null) delete g_LastPassCheckpoint[i].customdata;
			g_bHasLastPassCheckpoint[i] = false;
		}
		
		// [FIX] Cleanup team run history ArrayLists
		delete g_aTeamRunHistory[i];
		delete g_aTeamRunAuthHistory[i];
	}
	
	// [FIX] Cleanup player ArrayLists
	for (int i = 1; i <= MaxClients; i++)
	{
		delete g_aInvitedPlayers[i];
		delete g_aAcceptedPlayers[i];
	}
	
	// [NEW] Cleanup WR cache
	for (int style = 0; style < STYLE_LIMIT; style++)
	{
		for (int track = 0; track < TRACKS_SIZE; track++)
		{
			delete g_aCachedWRMembers[style][track];
		}
	}
}

public void OnClientConnected(int client)
{
	g_iTeamIndex[client] = -1;
	g_iLastTeamIndex[client] = -1;
	g_bCreatingTeam[client] = false;
	g_cPlayerTeamName[client][0] = '\0';
	g_iPendingPassId[client] = 0;
	g_bPendingFinishCleanup[client] = false;
	g_hFinishCleanupTimer[client] = null;

	// [FIX] Bug #1: Initialize ArrayLists to prevent NULL crashes
	delete g_aInvitedPlayers[client];
	g_aInvitedPlayers[client] = new ArrayList();
	delete g_aAcceptedPlayers[client];
	g_aAcceptedPlayers[client] = new ArrayList();
	delete g_aReplayRunners[client];
	g_aReplayRunners[client] = null; // Will be created when needed
}

public void OnMapStart()
{
	GetCurrentMap(g_cMapName, sizeof(g_cMapName));
	PrecacheSound(SOUND_INVITE);
	PrecacheSound(SOUND_PASS);
	PrecacheSound(SOUND_UNDO);
	PrecacheSound(SOUND_SWITCH);
	
	if (g_hHUDSynchronizer != null) CloseHandle(g_hHUDSynchronizer);
	g_hHUDSynchronizer = CreateHudSynchronizer();
	
	// [NEW] Clear WR cache for new map
	for (int style = 0; style < STYLE_LIMIT; style++)
	{
		for (int track = 0; track < TRACKS_SIZE; track++)
		{
			g_cCachedWRTeamName[style][track][0] = '\0';
			delete g_aCachedWRMembers[style][track];
			g_aCachedWRMembers[style][track] = null;
			g_bWRCacheLoaded[style][track] = false;
		}
	}
	
	// Load TagTeam WR cache
	if (gH_SQL != null)
	{
		LoadTagTeamWRCache();
	}
}

public void OnClientDisconnect(int client)
{
	if (g_aReplayRunners[client] != null)
	{
		delete g_aReplayRunners[client];
		g_aReplayRunners[client] = null;
	}
}

public void OnMapEnd()
{
	delete g_hTeamHudTimer;
	
	for (int i = 0; i < MAX_TEAMS; i++)
	{
		if (g_bHasLastPassCheckpoint[i])
		{
			if (g_LastPassCheckpoint[i].aFrames != null) delete g_LastPassCheckpoint[i].aFrames;
			if (g_LastPassCheckpoint[i].aEvents != null) delete g_LastPassCheckpoint[i].aEvents;
			if (g_LastPassCheckpoint[i].aOutputWaits != null) delete g_LastPassCheckpoint[i].aOutputWaits;
			if (g_LastPassCheckpoint[i].customdata != null) delete g_LastPassCheckpoint[i].customdata;
			g_bHasLastPassCheckpoint[i] = false;
		}
	}
}
// --------------------------------------------------------------------------------
//  菜单劫持逻辑
// --------------------------------------------------------------------------------

public Action Command_CP_Hook(int client, const char[] command, int args)
{
	if (!IsValidClient(client)) return Plugin_Continue;
	
	if (g_iTeamIndex[client] != -1)
	{
		OpenTagTeamMenu(client);
		return Plugin_Handled; 
	}
	else
	{
		int style = Shavit_GetBhopStyle(client);
		if (Shavit_GetStyleSettingBool(style, "tagteam"))
		{
			OpenTagTeamMenu(client);
			return Plugin_Handled; 
		}
	}
	
	return Plugin_Continue;
}

// [NEW] Block spectator commands for TagTeam members
public Action Command_Spectate_Hook(int client, const char[] command, int args)
{
	if (!IsValidClient(client)) return Plugin_Continue;
	
	// If player is in TagTeam and not the current runner, block spectator changes
	if (g_iTeamIndex[client] != -1)
	{
		int teamIdx = g_iTeamIndex[client];
		if (teamIdx >= 0 && teamIdx < MAX_TEAMS)
		{
			int currentRunner = g_iCurrentPlayer[teamIdx];
			if (client != currentRunner && IsClientInGame(currentRunner))
			{
				// Force spectate current runner
				if (!IsClientObserver(client)) ChangeClientTeam(client, CS_TEAM_SPECTATOR);
				SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", currentRunner);
				SetEntProp(client, Prop_Send, "m_iObserverMode", 4);
				
				Shavit_PrintToChat(client, " \x04[TagTeam]\x01 在队伍中只能观察当前跑手。使用 \x04!exitteam\x01 退出队伍后才能自由观察。");
				return Plugin_Handled;
			}
		}
	}
	
	return Plugin_Continue;
}

// [NEW] Handle chat input for team name
public Action Command_Say_Hook(int client, const char[] command, int args)
{
	if (!IsValidClient(client)) return Plugin_Continue;
	
	// Check if waiting for team name input
	if (g_bCreatingTeam[client])
	{
		char text[256];
		GetCmdArgString(text, sizeof(text));
		
		// Remove quotes
		if (text[0] == '"')
		{
			strcopy(text, sizeof(text), text[1]);
			int len = strlen(text);
			if (len > 0 && text[len-1] == '"')
				text[len-1] = '\0';
		}
		
		// Trim whitespace
		TrimString(text);
		
		// Ignore empty or command inputs
		if (text[0] == '\0' || text[0] == '/' || text[0] == '!' || text[0] == '.')
			return Plugin_Continue;
		
		// Set team name
		//strcopy(g_cPlayerTeamName[client], sizeof(g_cPlayerTeamName[]), text);
		//Shavit_PrintToChat(client, " \x04[TagTeam]\x01 队名已设置为: \x03%s", text);
		
		// Reset flag - no longer waiting for input
		// But keep g_bCreatingTeam true if they're still in invite flow
		
		// Reopen lobby menu
		//RequestFrame(Frame_ReopenLobby, GetClientSerial(client));
		
		// Set team name
        strcopy(g_cPlayerTeamName[client], sizeof(g_cPlayerTeamName[]), text);
        Shavit_PrintToChat(client, " \x04[TagTeam]\x01 队名已设置为: \x03%s", text);
        
        g_bCreatingTeam[client] = false; 
        
        // Reopen lobby menu
        RequestFrame(Frame_ReopenLobby, GetClientSerial(client));
		
		return Plugin_Handled; // Block the chat message
	}
	
	return Plugin_Continue;
}

public void Frame_ReopenLobby(int serial)
{
	int client = GetClientFromSerial(serial);
	if (client > 0 && IsClientInGame(client))
	{
		OpenLobbyMenu(client);
	}
}

void OpenTagTeamMenu(int client)
{
	Menu menu = new Menu(TagTeamMenu_Handler);
	
	int teamIdx = g_iTeamIndex[client];
	
	if (teamIdx != -1)
	{
		int runner = g_iCurrentPlayer[teamIdx];
		char sRunnerName[MAX_NAME_LENGTH];
		GetClientName(runner, sRunnerName, sizeof(sRunnerName));
		
		menu.SetTitle("TagTeam 接力菜单\n队伍: %s\n当前跑手: %s\n ", g_cTeamName[teamIdx], sRunnerName);
		
		bool isRunner = (runner == client);
		
		char sPassInfo[64];
		Format(sPassInfo, sizeof(sPassInfo), "★ 接力/保存 (Pass) [%s]", isRunner ? "可用" : "禁用");
		menu.AddItem("pass", sPassInfo, isRunner ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
		
		bool canTeleport = isRunner && (Shavit_GetTotalCheckpoints(client) > 0);
		char sTeleInfo[64];
		Format(sTeleInfo, sizeof(sTeleInfo), "★ 传送 (Teleport) [%s]", canTeleport ? "可用" : "无存档");
		menu.AddItem("tele", sTeleInfo, canTeleport ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
		
		char sUndoInfo[64];
		Format(sUndoInfo, sizeof(sUndoInfo), "★ 撤销 (Undo) [%s]", isRunner ? "可用" : "禁用");
		menu.AddItem("undo", sUndoInfo, isRunner ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
		
		// [NEW] Steal Baton feature - only for non-runners
		char sStealInfo[64];
		Format(sStealInfo, sizeof(sStealInfo), "★ 抢棒 (Steal Baton) [%s]", !isRunner ? "可用" : "你是跑手");
		menu.AddItem("steal", sStealInfo, !isRunner ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
		
		menu.AddItem("", "", ITEMDRAW_SPACER);
		// [CHANGE] 游戏中不能改名，此处提示或禁用
		menu.AddItem("rename", "修改队名 (游戏中禁止)", ITEMDRAW_DISABLED);
		menu.AddItem("exit", "退出队伍 (Exit Team)");
	}
	else
	{
		menu.SetTitle("TagTeam 模式\n您当前不在队伍中\n ");
		menu.AddItem("create", "★ 创建队伍 (Create Team)");
		menu.AddItem("help", "★ 玩法说明");
	}

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int TagTeamMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[32];
		menu.GetItem(param2, info, sizeof(info));

		if (StrEqual(info, "pass"))
		{
			Command_Pass(param1, 0);
			OpenTagTeamMenu(param1);
		}
		else if (StrEqual(info, "tele"))
		{
			// [FIX] 增加安全检查：确保玩家在真正点击菜单时依然有存档，防止异步报错
			if (Shavit_GetTotalCheckpoints(param1) > 0)
			{
				cp_cache_t cpcache;
				if (Shavit_GetCheckpoint(param1, 1, cpcache, sizeof(cp_cache_t)))
				{
					Shavit_LoadCheckpointCache(param1, cpcache, 1, sizeof(cp_cache_t), true); 
					Shavit_ResumeTimer(param1);
				}
			}
			else
			{
				Shavit_PrintToChat(param1, " \x04[TagTeam]\x01 传送失败，找不到你的存档。");
			}
			OpenTagTeamMenu(param1);
		}
		else if (StrEqual(info, "undo"))
		{
			Command_Undo(param1, 0);
			OpenTagTeamMenu(param1);
		}
		else if (StrEqual(info, "steal"))
		{
			Command_StealBaton(param1);
			OpenTagTeamMenu(param1);
		}
		else if (StrEqual(info, "create"))
		{
			OpenInviteSelectMenu(param1, 0, true, Shavit_GetBhopStyle(param1));
		}
		else if (StrEqual(info, "help"))
		{
			Shavit_PrintToChat(param1, " \x04[TagTeam]\x01 玩法:\n1. 组建队伍 (至少2人)。\n2. 跑到交接点按 \x04!save\x01 换人。\n3. 接棒者可按 \x04!cp\x01->\x04传送\x01 练习。\n4. 失误可按 \x04!undo\x01。\n5. 队友可用 \x04抢棒\x01 成为下一棒。");
			OpenTagTeamMenu(param1);
		}
		else if (StrEqual(info, "exit"))
		{
			Command_ExitTeam(param1, 0);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

// --------------------------------------------------------------------------------
//  核心逻辑：样式切换自动退队 & 禁止单人游玩
// --------------------------------------------------------------------------------

public void Shavit_OnStyleChanged(int client, int oldstyle, int newstyle, int track, bool manual)
{
	if (!Shavit_GetStyleSettingBool(newstyle, "tagteam"))
	{
		if (g_iTeamIndex[client] != -1)
		{
			ExitTeam(client, true); 
			Shavit_PrintToChat(client, "切换至非接力样式，已自动退出队伍。");
		}
	}
	else if (Shavit_GetStyleSettingBool(newstyle, "tagteam"))
	{
		// 进入 TagTeam 样式，提示组队
		RequestFrame(Frame_AutoOpenMenu, GetClientSerial(client));
	}
}

public void Frame_AutoOpenMenu(int serial)
{
	int client = GetClientFromSerial(serial);
	if (client != 0) OpenTagTeamMenu(client);
}

// [NEW] 阻止单人开始计时
public Action Shavit_OnStart(int client, int track)
{
	// [FIX] 完成者正在等待录像保存，阻止计时器重启但不调用 StopTimer（StopTimer 会取消 floppy 异步写入）
	if (g_bPendingFinishCleanup[client])
		return Plugin_Handled;

	int style = Shavit_GetBhopStyle(client);

	// 如果是 TagTeam 样式
	if (Shavit_GetStyleSettingBool(style, "tagteam"))
	{
		// 如果不在队伍中
		if (g_iTeamIndex[client] == -1)
		{
			Shavit_PrintToChat(client, " \x02[TagTeam]\x01 禁止单人游玩此模式！请使用 \x04!tt\x01 创建或加入队伍。");
			Shavit_StopTimer(client); // 停止计时
			return Plugin_Handled; // 阻止开始
		}
		
		// 如果队伍只有1人
		int teamIdx = g_iTeamIndex[client];
		if (g_nTeamPlayerCount[teamIdx] < 2)
		{
			Shavit_PrintToChat(client, " \x02[TagTeam]\x01 队伍人数不足 (至少2人)，无法开始！");
			Shavit_StopTimer(client);
			return Plugin_Handled;
		}
	}
	
	return Plugin_Continue;
}

// 【新增】拦截原版的单人通关消息，防止刷屏
public Action Shavit_OnFinishMessage(int client, bool &bEveryone, timer_snapshot_t snapshot, int overwrite, int rank, char[] message, int maxlen, char[] message2, int maxlen2)
{
	if (Shavit_GetStyleSettingBool(snapshot.bsStyle, "tagteam"))
	{
		return Plugin_Handled; // 拦截消息
	}
	return Plugin_Continue;
}

// --------------------------------------------------------------------------------
//  数据库逻辑 (更新)
// --------------------------------------------------------------------------------

public void Shavit_OnDatabaseLoaded()
{
	gH_SQL = Shavit_GetDatabase();
	if (gH_SQL != null)
	{
		GetTimerSQLPrefix(g_sSQLPrefix, sizeof(g_sSQLPrefix));
		char driver[16];
		gH_SQL.Driver.GetIdentifier(driver, sizeof(driver));
		bool isSQLite = StrEqual(driver, "sqlite");
		
		// 创建原有的 tagteam_log 表 (用于segment记录)
		char query[1024];
		Format(query, sizeof(query), 
			"CREATE TABLE IF NOT EXISTS `tagteam_log` (" ...
			"`id` INTEGER PRIMARY KEY %s, " ...
			"`map` VARCHAR(128) NOT NULL, " ...
			"`style` INT NOT NULL, " ...
			"`time` FLOAT NOT NULL, " ...
			"`date` INT NOT NULL, " ...
			"`segment_idx` INT NOT NULL, " ...
			"`auth` INT NOT NULL, " ...
			"`name` VARCHAR(64) NOT NULL, " ...
			"`teamname` VARCHAR(64) NOT NULL DEFAULT '');",
			isSQLite ? "AUTOINCREMENT" : "AUTO_INCREMENT"
		);
		SQL_TQuery(gH_SQL, SQL_CreateTable_Callback, query);
		
		// 添加 teamname 列 (兼容旧版本)
		char alterQuery[512];
		Format(alterQuery, sizeof(alterQuery), "ALTER TABLE `tagteam_log` ADD COLUMN `teamname` VARCHAR(64) DEFAULT '';");
		SQL_TQuery(gH_SQL, SQL_Void_Callback, alterQuery);
		
		// [NEW] 创建 tagteam_times 表 (用于WR记录)
		Format(query, sizeof(query),
			"CREATE TABLE IF NOT EXISTS `tagteam_times` (" ...
			"`id` INTEGER PRIMARY KEY %s, " ...
			"`map` VARCHAR(255) NOT NULL, " ...
			"`style` TINYINT NOT NULL, " ...
			"`track` TINYINT NOT NULL, " ...
			"`time` FLOAT NOT NULL, " ...
			"`team_name` VARCHAR(64) NOT NULL, " ...
			"`jumps` INT, " ...
			"`strafes` INT, " ...
			"`sync` FLOAT, " ...
			"`perfs` FLOAT, " ...
			"`date` INT NOT NULL, " ...
			"INDEX idx_map_style_track (`map`, `style`, `track`, `time`));",
			isSQLite ? "AUTOINCREMENT" : "AUTO_INCREMENT"
		);
		SQL_TQuery(gH_SQL, SQL_CreateTable_Callback, query);
		
		// [NEW] 创建 tagteam_members 表 (用于存储队伍成员)
		Format(query, sizeof(query),
			"CREATE TABLE IF NOT EXISTS `tagteam_members` (" ...
			"`team_id` INT NOT NULL, " ...
			"`auth` INT NOT NULL, " ...
			"`name` VARCHAR(32) NOT NULL, " ...
			"`position` TINYINT NOT NULL%s);",
			isSQLite ? "" : ", FOREIGN KEY (`team_id`) REFERENCES `tagteam_times`(`id`) ON DELETE CASCADE"
		);
		SQL_TQuery(gH_SQL, SQL_CreateTable_Callback, query);
	}
}

public void SQL_CreateTable_Callback(Handle owner, Handle hndl, const char[] error, any data)
{
	if (hndl == INVALID_HANDLE) LogError("TagTeam Table Creation Failed: %s", error);
}

public void SQL_Void_Callback(Handle owner, Handle hndl, const char[] error, any data)
{
	// 忽略错误
}

// --------------------------------------------------------------------------------
//  HUD 显示逻辑 (加强版)
// --------------------------------------------------------------------------------

// [FIX] HUD 回调，支持回放显示队名+人名
public Action Shavit_OnTopLeftHUD(int client, int target, char[] topleft, int topleftlength, int track, int style)
{
	// 显示回放机器人的 TagTeam 信息
	if (target > 0 && target <= MaxClients && IsFakeClient(target) && Shavit_IsReplayEntity(target))
	// if (IsFakeClient(target) && Shavit_IsReplayEntity(target))
	{
		if (g_aReplayRunners[target] != null && g_aReplayRunners[target].Length > 0)
		{
			int idx = g_iReplayCurrentIndex[target];
			if (idx >= g_aReplayRunners[target].Length) idx = g_aReplayRunners[target].Length - 1;
			if (idx < 0) idx = 0;

			char runnerName[64];
			g_aReplayRunners[target].GetString(idx, runnerName, sizeof(runnerName));
			
			char teamStr[128];
			if (g_cReplayTeamName[target][0] != '\0')
			{
				Format(teamStr, sizeof(teamStr), "\nTeam: %s", g_cReplayTeamName[target]);
			}
			else
			{
				teamStr[0] = '\0';
			}

			Format(topleft, topleftlength, "%s\n[TagTeam Replay]%s\nRunner: %s (%d/%d)", topleft, teamStr, runnerName, idx + 1, g_aReplayRunners[target].Length);
			return Plugin_Changed;
		}
	}
	// 显示当前队伍的实时信息
	else if (g_iTeamIndex[target] != -1)
	{
		int teamIdx = g_iTeamIndex[target];
		int runner = g_iCurrentPlayer[teamIdx];
		
		char sRunnerName[MAX_NAME_LENGTH];
		// [FIX] 增加 runner > 0 检查，防止 IsClientInGame(0) 崩溃
		if (runner > 0 && IsClientInGame(runner)) 
			GetClientName(runner, sRunnerName, sizeof(sRunnerName));
		else 
			Format(sRunnerName, sizeof(sRunnerName), "Waiting...");

		char sNextRunner[MAX_NAME_LENGTH];
		int next = g_iNextTeamMember[runner];
		
		// [FIX] 增加 next <= 0 检查
		if (next <= 0 || !IsClientInGame(next) || g_iTeamIndex[next] != teamIdx)
		{
			for (int i = 1; i <= MaxClients; i++)
			{
				if (i != runner && g_iTeamIndex[i] == teamIdx)
				{
					next = i;
					break;
				}
			}
			if (!IsClientInGame(next)) next = runner;
		}

		if (IsClientInGame(next)) GetClientName(next, sNextRunner, sizeof(sNextRunner));
		else sNextRunner = "Unknown";

		char sPassText[32], sUndoText[32];
		int maxPasses = g_cvMaxPasses.IntValue;
		int maxUndos = g_cvMaxUndos.IntValue;
		
		if (maxPasses == -1) Format(sPassText, sizeof(sPassText), "%d", g_nPassCount[teamIdx]);
		else Format(sPassText, sizeof(sPassText), "%d/%d", g_nPassCount[teamIdx], maxPasses);
		
		if (maxUndos == -1) Format(sUndoText, sizeof(sUndoText), "%d", g_nUndoCount[teamIdx]);
		else Format(sUndoText, sizeof(sUndoText), "%d/%d", g_nUndoCount[teamIdx], maxUndos);
		
		Format(topleft, topleftlength, "%s\n[Team: %s]\nRunner: %s\nNext: %s\nPasses: %s | Undos: %s", 
			topleft, g_cTeamName[teamIdx], sRunnerName, sNextRunner, sPassText, sUndoText);
		
		return Plugin_Changed;
	}
	
	return Plugin_Continue;
}

public Action Timer_UpdateTeamHUD(Handle timer)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i)) continue;

		if (g_iTeamIndex[i] != -1)
		{
			if (!(Shavit_GetHUDSettings(i) & HUD_TOPLEFT))
			{
				ShowTeamHUD(i);
			}
			ForceSpectateRunner(i);
		}
		else if (IsClientObserver(i))
		{
			int target = GetEntPropEnt(i, Prop_Send, "m_hObserverTarget");
			if (target > 0 && target <= MaxClients && IsFakeClient(target) && Shavit_IsReplayEntity(target) && !(Shavit_GetHUDSettings(i) & HUD_TOPLEFT))
			{
				ShowReplayHUD(i, target);
			}
		}
	}
	return Plugin_Continue;
}

void ForceSpectateRunner(int client)
{
	int teamIdx = g_iTeamIndex[client];
	if (teamIdx == -1) return;

	int runner = g_iCurrentPlayer[teamIdx];
	
	if (!IsClientInGame(runner))
	{
		int newRunner = -1;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (g_iTeamIndex[i] == teamIdx && IsClientInGame(i) && IsPlayerAlive(i))
			{
				newRunner = i;
				break;
			}
		}
		if (newRunner != -1) 
		{
			g_iCurrentPlayer[teamIdx] = newRunner;
			runner = newRunner;
		}
	}
	
	if (runner == client) return;

	if (GetClientTeam(client) != 1)
	{
		ChangeClientTeam(client, 1);
	}

	if (IsPlayerAlive(runner))
	{
		int currentTarget = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
		int observerMode = GetEntProp(client, Prop_Send, "m_iObserverMode");
		
		if (currentTarget != runner || (observerMode != 4 && observerMode != 5))
		{
			SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", runner);
			SetEntProp(client, Prop_Send, "m_iObserverMode", 4);
		}
	}
}

void ShowTeamHUD(int client)
{
	int teamIdx = g_iTeamIndex[client];
	int runner = g_iCurrentPlayer[teamIdx];
	
	char sRunnerName[MAX_NAME_LENGTH];
	if (IsClientInGame(runner)) 
		GetClientName(runner, sRunnerName, sizeof(sRunnerName));
	else 
		Format(sRunnerName, sizeof(sRunnerName), "Waiting...");

	char sNextRunner[MAX_NAME_LENGTH];
	int next = g_iNextTeamMember[runner];
	
	if (!IsClientInGame(next) || g_iTeamIndex[next] != teamIdx)
	{
		bool found = false;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (i != runner && g_iTeamIndex[i] == teamIdx)
			{
				next = i;
				g_iNextTeamMember[runner] = i; 
				found = true;
				break;
			}
		}
		if (!found) next = runner; 
	}

	if (IsClientInGame(next)) GetClientName(next, sNextRunner, sizeof(sNextRunner));
	else sNextRunner = "Unknown";

	char sPassText[32], sUndoText[32];
	int maxPasses = g_cvMaxPasses.IntValue;
	int maxUndos = g_cvMaxUndos.IntValue;
	
	if (maxPasses == -1) Format(sPassText, sizeof(sPassText), "%d", g_nPassCount[teamIdx]);
	else Format(sPassText, sizeof(sPassText), "%d/%d", g_nPassCount[teamIdx], maxPasses);
	
	if (maxUndos == -1) Format(sUndoText, sizeof(sUndoText), "%d", g_nUndoCount[teamIdx]);
	else Format(sUndoText, sizeof(sUndoText), "%d/%d", g_nUndoCount[teamIdx], maxUndos);

	SetHudTextParams(-1.0, 0.15, 0.5, 0, 255, 255, 255, 0, 0.0, 0.0, 0.0);
	
	if (g_hHUDSynchronizer != null)
	{
		ShowSyncHudText(client, g_hHUDSynchronizer, "【队伍: %s】\n跑手: %s\n下一棒: %s\n接力: %s | 撤销: %s", 
			g_cTeamName[teamIdx], sRunnerName, sNextRunner, sPassText, sUndoText);
	}
}

void ShowReplayHUD(int client, int bot)
{
	if (g_aReplayRunners[bot] == null || g_aReplayRunners[bot].Length == 0) return;

	int idx = g_iReplayCurrentIndex[bot];
	if (idx >= g_aReplayRunners[bot].Length) idx = g_aReplayRunners[bot].Length - 1;
	if (idx < 0) idx = 0;

	char runnerName[64];
	g_aReplayRunners[bot].GetString(idx, runnerName, sizeof(runnerName));

	char teamStr[128];
	if (g_cReplayTeamName[bot][0] != '\0')
	{
		Format(teamStr, sizeof(teamStr), "\n队伍: %s", g_cReplayTeamName[bot]);
	}
	else
	{
		teamStr[0] = '\0';
	}

	SetHudTextParams(0.05, 0.4, 0.5, 0, 255, 0, 255, 0, 0.0, 0.0, 0.0);
	
	if (g_hHUDSynchronizer != null)
	{
		ShowSyncHudText(client, g_hHUDSynchronizer, "► TagTeam 回放%s\n当前跑手: %s\n接力棒: %d/%d", teamStr, runnerName, idx + 1, g_aReplayRunners[bot].Length);
	}
}

// --------------------------------------------------------------------------------
//  菜单逻辑
// --------------------------------------------------------------------------------

public Action Command_TagTeamMenu(int client, int args)
{
	if (client == 0) return Plugin_Handled;
	OpenTagTeamMenu(client);
	return Plugin_Handled;
}

// --------------------------------------------------------------------------------
//  Replay 事件监听 & 数据加载
// --------------------------------------------------------------------------------

public void Shavit_OnReplayStart(int entity, int type, bool delay_elapsed)
{
	if (entity > MaxClients) return;
	if (!IsFakeClient(entity)) return;
	if (!delay_elapsed) return;
	
	int style = Shavit_GetReplayBotStyle(entity);
	if (!Shavit_GetStyleSettingBool(style, "tagteam")) return;

	if (g_aReplayRunners[entity] != null) delete g_aReplayRunners[entity];
	g_aReplayRunners[entity] = new ArrayList(ByteCountToCells(64));
	g_iReplayCurrentIndex[entity] = 0;
	g_iLastReplayButton[entity] = 0;
	g_cReplayTeamName[entity][0] = '\0'; 

	char query[512];
	char escMap[513];
	gH_SQL.Escape(g_cMapName, escMap, sizeof(escMap));
	
	Format(query, sizeof(query), 
		"SELECT time, segment_idx, name, teamname FROM `tagteam_log` WHERE map = '%s' AND style = %d ORDER BY time ASC, date DESC, segment_idx ASC", 
		escMap, style
	);
	
	DataPack pack = new DataPack();
	pack.WriteCell(entity);
	pack.WriteFloat(Shavit_GetReplayCacheLength(entity));
	
	SQL_TQuery(gH_SQL, SQL_LoadReplayData_Callback, query, pack);
}

// [NEW] 更新回放机器人名字 (Shavit Core Display)
void UpdateReplayBotName(int bot)
{
    if (g_aReplayRunners[bot] == null || g_aReplayRunners[bot].Length == 0) return;
    
    int idx = g_iReplayCurrentIndex[bot];
    char runner[MAX_NAME_LENGTH];
    g_aReplayRunners[bot].GetString(idx, runner, sizeof(runner));
    
    char team[MAX_NAME_LENGTH];
    if (g_cReplayTeamName[bot][0] != '\0')
        strcopy(team, sizeof(team), g_cReplayTeamName[bot]);
    else
        Format(team, sizeof(team), "Unknown");
        
    char displayName[MAX_NAME_LENGTH];
    // 格式化为 "Team: xxx Player: xxx"，注意 MAX_NAME_LENGTH (32) 限制
    Format(displayName, sizeof(displayName), "Team: %s Player: %s", team, runner);
    
    // 更新 Shavit 核心缓存的 Replay 名字 (计分板和 HUD 第二行)
    Shavit_SetReplayCacheName(bot, displayName);
}

public void SQL_LoadReplayData_Callback(Handle owner, Handle hndl, const char[] error, DataPack pack)
{
	pack.Reset();
	int bot = pack.ReadCell();
	float replayTime = pack.ReadFloat();
	delete pack;

	if (hndl == null || !IsValidEntity(bot)) return;
	
	if (g_aReplayRunners[bot] == null) g_aReplayRunners[bot] = new ArrayList(ByteCountToCells(64));
	else g_aReplayRunners[bot].Clear();

	bool teamNameFound = false;

	while (SQL_FetchRow(hndl))
	{
		float dbTime = SQL_FetchFloat(hndl, 0);
		char name[64];
		SQL_FetchString(hndl, 2, name, sizeof(name));
		
		if (FloatAbs(dbTime - replayTime) < 0.1)
		{
			g_aReplayRunners[bot].PushString(name);
			
			// [NEW] 读取队名
			if (!teamNameFound)
			{
				char tName[64];
				SQL_FetchString(hndl, 3, tName, sizeof(tName));
				if (tName[0] != '\0')
				{
					strcopy(g_cReplayTeamName[bot], sizeof(g_cReplayTeamName[]), tName);
					teamNameFound = true;
				}
			}
		}
	}
	
	// [NEW] 数据加载完毕后，立刻更新一次名字
	if (g_aReplayRunners[bot].Length > 0)
	{
		UpdateReplayBotName(bot);
	}
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (!IsFakeClient(client) || !Shavit_IsReplayEntity(client)) return Plugin_Continue;

	if ((buttons & IN_SCORE) && !(g_iLastReplayButton[client] & IN_SCORE))
	{
		if (g_aReplayRunners[client] != null && g_aReplayRunners[client].Length > 0)
		{
			if (g_iReplayCurrentIndex[client] < g_aReplayRunners[client].Length - 1)
			{
				g_iReplayCurrentIndex[client]++;
				NotifyReplaySpectators(client);
				// [NEW] 切换跑手时更新 Bot 名字
				UpdateReplayBotName(client);
			}
		}
	}
	
	g_iLastReplayButton[client] = buttons;
	return Plugin_Continue;
}

void NotifyReplaySpectators(int bot)
{
	char newName[64];
	g_aReplayRunners[bot].GetString(g_iReplayCurrentIndex[bot], newName, sizeof(newName));
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			int target = GetEntPropEnt(i, Prop_Send, "m_hObserverTarget");
			int observerMode = GetEntProp(i, Prop_Send, "m_iObserverMode");

			if (target == bot && (observerMode == 4 || observerMode == 5))
			{
				PrintHintText(i, ">>> 换人: %s <<<", newName);
				EmitSoundToClient(i, SOUND_SWITCH);
			}
		}
	}
}

// --------------------------------------------------------------------------------
//  队伍逻辑 & 数据库保存 & !save 逻辑
// --------------------------------------------------------------------------------

void RecordHistory(int teamIdx, int client)
{
	int steamid = GetSteamAccountID(client);
	char name[64];
	GetClientName(client, name, sizeof(name));

	g_aTeamRunHistory[teamIdx].PushString(name);
	g_aTeamRunAuthHistory[teamIdx].Push(steamid);
}

public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, ArrayList replaypaths, ArrayList frames, int preframes, int postframes, const char[] name)
{
	if (!Shavit_GetStyleSettingBool(style, "tagteam")) return;
	
	int teamIdx = g_iTeamIndex[client];
	if (teamIdx == -1) teamIdx = g_iLastTeamIndex[client];
	
	if (teamIdx == -1) return;
	
	char escMap[513];
	gH_SQL.Escape(g_cMapName, escMap, sizeof(escMap));
	
	char escTeamName[128];
	gH_SQL.Escape(g_cTeamName[teamIdx], escTeamName, sizeof(escTeamName));
	
	int len = g_aTeamRunHistory[teamIdx].Length;
	for (int i = 0; i < len; i++)
	{
		char runnerName[64];
		g_aTeamRunHistory[teamIdx].GetString(i, runnerName, sizeof(runnerName));
		char escName[128];
		gH_SQL.Escape(runnerName, escName, sizeof(escName));

		int runnerAuth = (i < g_aTeamRunAuthHistory[teamIdx].Length) ? g_aTeamRunAuthHistory[teamIdx].Get(i) : 0;

		char query[1024];
		Format(query, sizeof(query),
			"INSERT INTO `tagteam_log` (map, style, time, date, segment_idx, auth, name, teamname) " ...
			"VALUES ('%s', %d, %f, %d, %d, %d, '%s', '%s');",
			escMap, style, time, timestamp, i, runnerAuth, escName, escTeamName
		);
		SQL_TQuery(gH_SQL, SQL_Insert_Callback, query);
	}

	// [FIX] 录像已确认保存，现在安全地重置完成者的计时器
	if (g_bPendingFinishCleanup[client])
	{
		g_bPendingFinishCleanup[client] = false;
		delete g_hFinishCleanupTimer[client];
		if (IsClientInGame(client))
		{
			Shavit_ChangeClientStyle(client, 0);
			Shavit_RestartTimer(client, Track_Main);
		}
	}
}

public void SQL_Insert_Callback(Handle owner, Handle hndl, const char[] error, any data)
{
	if (hndl == INVALID_HANDLE) LogError("Insert TagTeam Log Failed: %s", error);
}

// 兜底：若 Shavit_OnReplaySaved 3 秒内未触发（录像未保存），仍重置完成者计时器
public Action Timer_FinishCleanup(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client) && g_bPendingFinishCleanup[client])
	{
		g_bPendingFinishCleanup[client] = false;
		g_hFinishCleanupTimer[client] = null;
		Shavit_ChangeClientStyle(client, 0);
		Shavit_RestartTimer(client, Track_Main);
	}
	return Plugin_Stop;
}

public Action Shavit_OnSave(int client, int idx)
{
	if (g_cvSaveToPass.BoolValue && g_iTeamIndex[client] != -1)
	{
		int teamidx = g_iTeamIndex[client];
		
		// [FIX] Bug #2: Add bounds checking
		if (teamidx < 0 || teamidx >= MAX_TEAMS) return Plugin_Continue;
		
		if (g_iCurrentPlayer[teamidx] == client)
		{
			cp_cache_t cpcache;
			if (Shavit_GetCheckpoint(client, idx, cpcache, sizeof(cp_cache_t)))
			{
				ArrayList frames = Shavit_GetReplayData(client, false); 
				if (frames != null)
				{
					cpcache.aFrames = frames.Clone(); 
					cpcache.iPreFrames = Shavit_GetPlayerPreFrames(client);
					delete frames;
				}
				else if (cpcache.aFrames != null)
				{
					cpcache.aFrames = cpcache.aFrames.Clone();
				}
				
				if (cpcache.aEvents != null) cpcache.aEvents = cpcache.aEvents.Clone();
				if (cpcache.aOutputWaits != null) cpcache.aOutputWaits = cpcache.aOutputWaits.Clone();
				if (cpcache.customdata != null) cpcache.customdata = view_as<StringMap>(CloneHandle(cpcache.customdata));
				
				// [NEW] Store checkpoint for proper undo functionality
				// First, clean up old checkpoint data
				if (g_bHasLastPassCheckpoint[teamidx])
				{
					if (g_LastPassCheckpoint[teamidx].aFrames != null) delete g_LastPassCheckpoint[teamidx].aFrames;
					if (g_LastPassCheckpoint[teamidx].aEvents != null) delete g_LastPassCheckpoint[teamidx].aEvents;
					if (g_LastPassCheckpoint[teamidx].aOutputWaits != null) delete g_LastPassCheckpoint[teamidx].aOutputWaits;
					if (g_LastPassCheckpoint[teamidx].customdata != null) delete g_LastPassCheckpoint[teamidx].customdata;
				}
				
				// Clone checkpoint for storage
				g_LastPassCheckpoint[teamidx] = cpcache;
				if (cpcache.aFrames != null) g_LastPassCheckpoint[teamidx].aFrames = cpcache.aFrames.Clone();
				if (cpcache.aEvents != null) g_LastPassCheckpoint[teamidx].aEvents = cpcache.aEvents.Clone();
				if (cpcache.aOutputWaits != null) g_LastPassCheckpoint[teamidx].aOutputWaits = cpcache.aOutputWaits.Clone();
				if (cpcache.customdata != null) g_LastPassCheckpoint[teamidx].customdata = view_as<StringMap>(CloneHandle(cpcache.customdata));
				g_bHasLastPassCheckpoint[teamidx] = true;
				
				int next = g_iNextTeamMember[client];
				
				g_nPassCount[teamidx]++;
				RecordHistory(teamidx, next);
				
				PassToNext(client, next, cpcache);

				EmitSoundToClient(client, SOUND_PASS);
				EmitSoundToClient(next, SOUND_PASS);
				PrintToTeam(teamidx, "已存档 -> 自动接力给 %N", next);
			}
		}
	}
	return Plugin_Continue;
}

// --------------------------------------------------------------------------------
//  Pass / Undo / Create 逻辑
// --------------------------------------------------------------------------------

void CreateTeam(int[] members, int memberCount, int style)
{
	int teamindex = -1;
	for(int i = 0; i < MAX_TEAMS; i++) { if(!g_bTeamTaken[i]) { teamindex = i; break; } }
	if(teamindex == -1) return;

	g_nUndoCount[teamindex] = 0;
	g_nPassCount[teamindex] = 0;
	g_nRelayCount[teamindex] = 0;
	g_bTeamTaken[teamindex] = true;
	g_nTeamPlayerCount[teamindex] = memberCount;
	
	// [FIX] Cleanup old checkpoint handles when reusing team slot
	if (g_bHasLastPassCheckpoint[teamindex])
	{
		if (g_LastPassCheckpoint[teamindex].aFrames != null) delete g_LastPassCheckpoint[teamindex].aFrames;
		if (g_LastPassCheckpoint[teamindex].aEvents != null) delete g_LastPassCheckpoint[teamindex].aEvents;
		if (g_LastPassCheckpoint[teamindex].aOutputWaits != null) delete g_LastPassCheckpoint[teamindex].aOutputWaits;
		if (g_LastPassCheckpoint[teamindex].customdata != null) delete g_LastPassCheckpoint[teamindex].customdata;
		g_bHasLastPassCheckpoint[teamindex] = false;
	}
	
	if (g_cPlayerTeamName[members[0]][0] != '\0')
		strcopy(g_cTeamName[teamindex], sizeof(g_cTeamName[]), g_cPlayerTeamName[members[0]]);
	else
		GetClientName(members[0], g_cTeamName[teamindex], sizeof(g_cTeamName[]));

	g_aTeamRunHistory[teamindex].Clear();
	g_aTeamRunAuthHistory[teamindex].Clear();
	RecordHistory(teamindex, members[0]);

	// [FIX] 提前设置 g_iCurrentPlayer，防止后续 Shavit_ChangeClientStyle 触发 HUD 时读到 0
	g_iCurrentPlayer[teamindex] = members[0];

	// 第一步：先建立完整的队伍链接关系
	int next = members[0];
	for(int i = memberCount - 1; i >= 0; i--)
	{
		g_iNextTeamMember[members[i]] = next;
		next = members[i];
		g_iTeamIndex[members[i]] = teamindex;
		g_bAllowStyleChange[members[i]] = true;
		Shavit_ClearCheckpoints(members[i]);
	}
	
	// 第二步：再触发样式变更 (这会触发 HUD 刷新，但此时数据已就绪)
	for(int i = memberCount - 1; i >= 0; i--)
	{
		// 强制切换所有队员到 TagTeam 样式
		Shavit_ChangeClientStyle(members[i], style);
	}

	Shavit_RestartTimer(members[0], Track_Main);
	// g_iCurrentPlayer[teamindex] = members[0]; // [FIX] 已移动到上方

	for(int i = 1; i < memberCount; i++)
	{
		ChangeClientTeam(members[i], CS_TEAM_SPECTATOR);
		SetEntPropEnt(members[i], Prop_Send, "m_hObserverTarget", members[0]);
		SetEntProp(members[i], Prop_Send, "m_iObserverMode", 4);
	}
	
	PrintToTeam(teamindex, "队伍 [%s] 已创建！", g_cTeamName[teamindex]);
}

public Action Command_Pass(int client, int args)
{
	if(g_iTeamIndex[client] == -1) return Plugin_Handled;
	int teamidx = g_iTeamIndex[client];
	
	// [FIX] Bug #2: Add bounds checking
	if (teamidx < 0 || teamidx >= MAX_TEAMS) return Plugin_Handled;
	
	if(g_iCurrentPlayer[teamidx] != client) return Plugin_Handled;
	
	if (Shavit_InsideZone(client, Zone_Start, -1))
	{
		ReplyToCommand(client, "不能在起点接力！");
		return Plugin_Handled;
	}

	g_nPassCount[teamidx]++;

	cp_cache_t cpcache;
	Shavit_SaveCheckpointCache(client, client, cpcache, -1, sizeof(cp_cache_t), true); 
	
	// [NEW] Store checkpoint for proper undo functionality
	// First, clean up old checkpoint data
	if (g_bHasLastPassCheckpoint[teamidx])
	{
		if (g_LastPassCheckpoint[teamidx].aFrames != null) delete g_LastPassCheckpoint[teamidx].aFrames;
		if (g_LastPassCheckpoint[teamidx].aEvents != null) delete g_LastPassCheckpoint[teamidx].aEvents;
		if (g_LastPassCheckpoint[teamidx].aOutputWaits != null) delete g_LastPassCheckpoint[teamidx].aOutputWaits;
		if (g_LastPassCheckpoint[teamidx].customdata != null) delete g_LastPassCheckpoint[teamidx].customdata;
	}
	
	// Clone checkpoint for storage
	g_LastPassCheckpoint[teamidx] = cpcache;
	if (cpcache.aFrames != null) g_LastPassCheckpoint[teamidx].aFrames = cpcache.aFrames.Clone();
	if (cpcache.aEvents != null) g_LastPassCheckpoint[teamidx].aEvents = cpcache.aEvents.Clone();
	if (cpcache.aOutputWaits != null) g_LastPassCheckpoint[teamidx].aOutputWaits = cpcache.aOutputWaits.Clone();
	if (cpcache.customdata != null) g_LastPassCheckpoint[teamidx].customdata = view_as<StringMap>(CloneHandle(cpcache.customdata));
	g_bHasLastPassCheckpoint[teamidx] = true;
	
	int next = g_iNextTeamMember[client];
	RecordHistory(teamidx, next);
	
	PassToNext(client, next, cpcache);

	EmitSoundToClient(client, SOUND_PASS);
	EmitSoundToClient(next, SOUND_PASS);
	PrintToTeam(teamidx, "%N 接力成功 -> %N", client, next);

	return Plugin_Handled;
}

public Action Command_Undo(int client, int args)
{
	if(g_iTeamIndex[client] == -1) return Plugin_Handled;
	int teamidx = g_iTeamIndex[client];
	
	// [FIX] Bug #2: Add bounds checking
	if (teamidx < 0 || teamidx >= MAX_TEAMS) return Plugin_Handled;
	
	if(g_iCurrentPlayer[teamidx] != client) return Plugin_Handled;
	if(g_nRelayCount[teamidx] == 0 && g_nPassCount[teamidx] == 0) return Plugin_Handled;

	int maxUndos = g_cvMaxUndos.IntValue;
	if(maxUndos > -1 && g_nUndoCount[teamidx] >= maxUndos)
	{
		ReplyToCommand(client, "撤销次数已用尽 (%d/%d)", g_nUndoCount[teamidx], maxUndos);
		return Plugin_Handled;
	}
	
	if(g_bDidUndo[teamidx])
	{
		ReplyToCommand(client, "本回合已经撤销过了，不能连续撤销。");
		return Plugin_Handled;
	}
	
	// [FIX] Bug #5: Safe ArrayList access
	if (g_aTeamRunHistory[teamidx].Length > 1)
	{
		g_aTeamRunHistory[teamidx].Erase(g_aTeamRunHistory[teamidx].Length - 1);
		if (g_aTeamRunAuthHistory[teamidx].Length > 1)
			g_aTeamRunAuthHistory[teamidx].Erase(g_aTeamRunAuthHistory[teamidx].Length - 1);
	}

	int last = -1;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(g_iNextTeamMember[i] == client)
		{
			last = i;
			break;
		}
	}

	if(last == -1) return Plugin_Handled;
	
	// [FIX] Undo logic: Use stored checkpoint from when baton was passed
	if (!g_bHasLastPassCheckpoint[teamidx])
	{
		ReplyToCommand(client, "找不到上次接力的恢复点，无法撤销。");
		return Plugin_Handled;
	}

	// [FIX] Bug #3: Clone the stored checkpoint properly
	cp_cache_t cpcache;
	
	// Copy array fields element by element
	for (int i = 0; i < 3; i++)
	{
		cpcache.fPosition[i] = g_LastPassCheckpoint[teamidx].fPosition[i];
		cpcache.fAngles[i] = g_LastPassCheckpoint[teamidx].fAngles[i];
		cpcache.fVelocity[i] = g_LastPassCheckpoint[teamidx].fVelocity[i];
		cpcache.vecLadderNormal[i] = g_LastPassCheckpoint[teamidx].vecLadderNormal[i];
		cpcache.m_lastStandingPos[i] = g_LastPassCheckpoint[teamidx].m_lastStandingPos[i];
		cpcache.m_lastLadderNormal[i] = g_LastPassCheckpoint[teamidx].m_lastLadderNormal[i];
		cpcache.m_lastLadderPos[i] = g_LastPassCheckpoint[teamidx].m_lastLadderPos[i];
	}
	
	// Copy basic fields
	cpcache.iMoveType = g_LastPassCheckpoint[teamidx].iMoveType;
	cpcache.fGravity = g_LastPassCheckpoint[teamidx].fGravity;
	cpcache.fSpeed = g_LastPassCheckpoint[teamidx].fSpeed;
	cpcache.fStamina = g_LastPassCheckpoint[teamidx].fStamina;
	cpcache.bDucked = g_LastPassCheckpoint[teamidx].bDucked;
	cpcache.bDucking = g_LastPassCheckpoint[teamidx].bDucking;
	cpcache.fDucktime = g_LastPassCheckpoint[teamidx].fDucktime;
	cpcache.fDuckSpeed = g_LastPassCheckpoint[teamidx].fDuckSpeed;
	cpcache.iFlags = g_LastPassCheckpoint[teamidx].iFlags;
	
	// Copy timer snapshot (contains iJumps, iStrafes, etc)
	cpcache.aSnapshot = g_LastPassCheckpoint[teamidx].aSnapshot;
	
	// Copy strings
	strcopy(cpcache.sTargetname, 64, g_LastPassCheckpoint[teamidx].sTargetname);
	strcopy(cpcache.sClassname, 64, g_LastPassCheckpoint[teamidx].sClassname);
	
	// Copy other fields
	cpcache.iPreFrames = g_LastPassCheckpoint[teamidx].iPreFrames;
	cpcache.bSegmented = g_LastPassCheckpoint[teamidx].bSegmented;
	cpcache.iGroundEntity = g_LastPassCheckpoint[teamidx].iGroundEntity;
	cpcache.iSteamID = g_LastPassCheckpoint[teamidx].iSteamID;
	cpcache.m_bHasWalkMovedSinceLastJump = g_LastPassCheckpoint[teamidx].m_bHasWalkMovedSinceLastJump;
	cpcache.m_ignoreLadderJumpTime = g_LastPassCheckpoint[teamidx].m_ignoreLadderJumpTime;
	cpcache.m_ladderSurpressionTimer[0] = g_LastPassCheckpoint[teamidx].m_ladderSurpressionTimer[0];
	cpcache.m_ladderSurpressionTimer[1] = g_LastPassCheckpoint[teamidx].m_ladderSurpressionTimer[1];
	cpcache.m_afButtonDisabled = g_LastPassCheckpoint[teamidx].m_afButtonDisabled;
	
	// Clone ArrayList handles
	if (g_LastPassCheckpoint[teamidx].aFrames != null) 
		cpcache.aFrames = g_LastPassCheckpoint[teamidx].aFrames.Clone();
	if (g_LastPassCheckpoint[teamidx].aEvents != null) 
		cpcache.aEvents = g_LastPassCheckpoint[teamidx].aEvents.Clone();
	if (g_LastPassCheckpoint[teamidx].aOutputWaits != null) 
		cpcache.aOutputWaits = g_LastPassCheckpoint[teamidx].aOutputWaits.Clone();
	
	// Clone StringMap handle
	if (g_LastPassCheckpoint[teamidx].customdata != null) 
		cpcache.customdata = view_as<StringMap>(CloneHandle(g_LastPassCheckpoint[teamidx].customdata));
	
	PassToNext(client, last, cpcache); 
	g_bDidUndo[teamidx] = true;
	g_nUndoCount[teamidx]++;
	EmitSoundToClient(client, SOUND_UNDO);
	EmitSoundToClient(last, SOUND_UNDO);
	PrintToTeam(teamidx, "撤销! 回到 %N 上次接力点", last);

	return Plugin_Handled;
}

// [NEW] Steal Baton - Change next order, not immediate takeover
void Command_StealBaton(int client)
{
	if (!IsClientInGame(client)) return;
	
	int teamidx = g_iTeamIndex[client];
	if (teamidx == -1)
	{
		Shavit_PrintToChat(client, "你不在队伍中！");
		return;
	}
	
	// [FIX] Bug #2: Add bounds checking
	if (teamidx < 0 || teamidx >= MAX_TEAMS) return;
	
	int currentRunner = g_iCurrentPlayer[teamidx];
	if (currentRunner == client)
	{
		Shavit_PrintToChat(client, "你已经是当前跑手了！");
		return;
	}
	
	// [CHANGED] Don't take over immediately - just become next in line
	// Find who is currently set to be next after currentRunner
	int oldNext = g_iNextTeamMember[currentRunner];
	
	// Find who points to client in the chain
	int prev = -1;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_iTeamIndex[i] == teamidx && g_iNextTeamMember[i] == client)
		{
			prev = i;
			break;
		}
	}
	
	// If client is already next, nothing to do
	if (oldNext == client)
	{
		Shavit_PrintToChat(client, "你已经是下一棒了！");
		return;
	}
	
	// Reorder the chain:
	// 1. Remove client from their current position
	if (prev != -1)
	{
		g_iNextTeamMember[prev] = g_iNextTeamMember[client];
	}
	
	// 2. Insert client after currentRunner
	g_iNextTeamMember[currentRunner] = client;
	g_iNextTeamMember[client] = oldNext;
	
	PrintToTeam(teamidx, "%N 将成为下一棒接手者！", client);
	EmitSoundToClient(client, SOUND_SWITCH);
	EmitSoundToClient(currentRunner, SOUND_SWITCH);
}

void PassToNext(int client, int next, cp_cache_t cpcache, bool usecp = true)
{
	// [FIX] Bug #4: Add client validation
	if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return;
	if (next <= 0 || next > MaxClients || !IsClientInGame(next)) return;
	
	int teamidx = g_iTeamIndex[client];
	// [FIX] Bug #2: Add bounds checking
	if (teamidx < 0 || teamidx >= MAX_TEAMS) return;
	
	Shavit_ClearCheckpoints(client);
	Shavit_ClearCheckpoints(next);

	if(usecp)
	{
		if(cpcache.aFrames != null && cpcache.aFrames.Length > 0)
		{
			int lastFrameIdx = cpcache.aFrames.Length - 1;
			frame_t frame;
			cpcache.aFrames.GetArray(lastFrameIdx, frame, sizeof(frame_t));
			frame.buttons |= IN_SCORE; 
			cpcache.aFrames.SetArray(lastFrameIdx, frame, sizeof(frame_t));
		}
		
		cpcache.iSteamID = GetSteamAccountID(next);
		cpcache.aSnapshot.bPracticeMode = false;
		cpcache.bSegmented = true; 
		
		Shavit_SetCheckpoint(next, -1, cpcache, sizeof(cp_cache_t), false);
		
		Shavit_SetPracticeMode(next, false, false);
	}

	// [FIX] Bug #3: Delete clones to prevent memory leak
	if(cpcache.aFrames != null) delete cpcache.aFrames;
	if(cpcache.aEvents != null) delete cpcache.aEvents;
	if(cpcache.aOutputWaits != null) delete cpcache.aOutputWaits;
	if(cpcache.customdata != null) delete cpcache.customdata;

	ChangeClientTeam(client, CS_TEAM_SPECTATOR);
	ChangeClientTeam(next, CS_TEAM_T);
	CS_RespawnPlayer(next);
	
	if(usecp)
	{
		// [FIX] Generate unique ID to prevent race condition with restart
		static int s_iPassIdCounter = 0;
		s_iPassIdCounter++;
		g_iPendingPassId[next] = s_iPassIdCounter;
		
		DataPack pack = new DataPack();
		pack.WriteCell(next);
		pack.WriteCell(1); 
		pack.WriteCell(s_iPassIdCounter); // Store the pass ID
		CreateTimer(0.1, Timer_DelayedTeleport, pack);
	}

	g_iCurrentPlayer[teamidx] = next;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsFakeClient(i) && g_iTeamIndex[i] == teamidx)
		{
			if (i != next)
			{
				if (!IsClientObserver(i)) ChangeClientTeam(i, CS_TEAM_SPECTATOR);
				SetEntPropEnt(i, Prop_Send, "m_hObserverTarget", next);
				SetEntProp(i, Prop_Send, "m_iObserverMode", 4);
			}
		}
	}
}

public Action Timer_DelayedTeleport(Handle timer, DataPack pack)
{
	pack.Reset();
	int client = pack.ReadCell();
	int index = pack.ReadCell();
	int passId = pack.ReadCell(); // Read the pass ID
	delete pack;
	
	// [FIX] Check if this teleport is still valid (not cancelled by restart)
	if (!IsClientInGame(client) || !IsPlayerAlive(client) || g_iTeamIndex[client] == -1)
	{
		return Plugin_Stop;
	}
	
	// [FIX] If player restarted, pending pass ID would be reset to 0
	if (g_iPendingPassId[client] != passId)
	{
		// Teleport was cancelled (likely due to restart)
		return Plugin_Stop;
	}
	
	cp_cache_t cpcache;
	if (Shavit_GetCheckpoint(client, index, cpcache, sizeof(cp_cache_t)))
	{
		Shavit_LoadCheckpointCache(client, cpcache, index, sizeof(cp_cache_t), true);
		Shavit_ResumeTimer(client);
		Shavit_SetPracticeMode(client, false, false);
		
		OpenTagTeamMenu(client);
	}
	
	// Clear pending pass ID after successful teleport
	g_iPendingPassId[client] = 0;
	
	return Plugin_Stop;
}

// --------------------------------------------------------------------------------
//  其他命令
// --------------------------------------------------------------------------------

public Action Command_TeamName(int client, int args) {
	if (g_iTeamIndex[client] != -1)
	{
		ReplyToCommand(client, "游戏进行中禁止修改队名！");
		return Plugin_Handled;
	}
	
	GetCmdArgString(g_cPlayerTeamName[client], sizeof(g_cPlayerTeamName[]));
	ReplyToCommand(client, "预设队名已设置为: %s", g_cPlayerTeamName[client]);
	return Plugin_Handled;
}

public Action Command_ExitTeam(int client, int args) {
	if(!ExitTeam(client)) ReplyToCommand(client, "你不在队伍中");
	return Plugin_Handled;
}

public Action Command_TeamChat(int client, int args) {
	if (g_iTeamIndex[client] == -1) return Plugin_Handled;
	char msg[256]; GetCmdArgString(msg, sizeof(msg));
	PrintToTeam(g_iTeamIndex[client], "\x04[Team] \x01%N: %s", client, msg);
	return Plugin_Handled;
}

public Action Command_RefreshHUD(int client, int args)
{
	if (client == 0) return Plugin_Handled;

	if (g_iTeamIndex[client] != -1)
	{
		ShowTeamHUD(client);
		ForceSpectateRunner(client);
		Shavit_PrintToChat(client, "TagTeam HUD 已刷新。");
	}
	else
	{
		Shavit_PrintToChat(client, "你不在 TagTeam 队伍中。");
	}
	return Plugin_Handled;
}

void OpenInviteSelectMenu(int client, int firstItem, bool reset = false, int style = 0) {
	if(reset) {
        for(int i = 1; i <= MaxClients; i++) g_bInvitedPlayer[client][i] = false;
        // 【修复 2】建队初期不要拦截聊天，将其设为 false
        g_bCreatingTeam[client] = false; 
        g_iInviteStyle[client] = style; 
        g_nDeclinedPlayers[client] = 0;
        delete g_aAcceptedPlayers[client]; g_aAcceptedPlayers[client] = new ArrayList();
        delete g_aInvitedPlayers[client]; g_aInvitedPlayers[client] = new ArrayList();
    }
    Menu menu = new Menu(InviteSelectMenu_Handler);
    menu.SetTitle("邀请玩家:\n ");
    for(int i = 1; i <= MaxClients; i++) {
        if(i == client || !IsClientInGame(i) || IsFakeClient(i) || g_iTeamIndex[i] != -1) continue;
        char name[64], userid[8]; Format(name, sizeof(name), "[%s] %N", g_bInvitedPlayer[client][i]?"X":" ", i); IntToString(GetClientUserId(i), userid, sizeof(userid));
        menu.AddItem(userid, name);
    }
    menu.AddItem("send", "发送", g_aInvitedPlayers[client].Length == 0 ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
    menu.DisplayAt(client, firstItem, MENU_TIME_FOREVER);
}

public int InviteSelectMenu_Handler(Menu menu, MenuAction action, int param1, int param2) {
    if(action == MenuAction_Select) {
        char info[8]; menu.GetItem(param2, info, sizeof(info));
        if(StrEqual(info, "send")) {
             for(int i = 0; i < g_aInvitedPlayers[param1].Length; i++) SendInvite(param1, GetClientOfUserId(g_aInvitedPlayers[param1].Get(i)));
             OpenLobbyMenu(param1);
        } else {
             int u = StringToInt(info); int t = GetClientOfUserId(u);
             if(t>0) { g_bInvitedPlayer[param1][t] = !g_bInvitedPlayer[param1][t]; if(g_bInvitedPlayer[param1][t]) g_aInvitedPlayers[param1].Push(u); else { int idx = g_aInvitedPlayers[param1].FindValue(u); if(idx!=-1) g_aInvitedPlayers[param1].Erase(idx); } }
             OpenInviteSelectMenu(param1, (param2/6)*6);
        }
    } else if(action==MenuAction_End) delete menu;
    return 0;
}

void SendInvite(int client, int target) {
    Menu menu = new Menu(InviteMenu_Handler);
    menu.SetTitle("%N 邀请你加入 TagTeam!\n ", client);
    char s[8]; IntToString(GetClientUserId(client), s, 8);
    menu.AddItem(s, "接受"); menu.AddItem(s, "拒绝");
    menu.Display(target, 20);
}

public int InviteMenu_Handler(Menu menu, MenuAction action, int param1, int param2) {
    if(action == MenuAction_Select) {
        char s[8]; menu.GetItem(param2, s, 8); int host = GetClientOfUserId(StringToInt(s));
        if(host>0) {
            // 处理接受或拒绝
            if(param2==0) { 
                g_aAcceptedPlayers[host].Push(GetClientUserId(param1)); 
                Shavit_PrintToChat(host, " \x04[TagTeam]\x01 %N 接受了邀请。", param1); 
            }
            else { 
                g_nDeclinedPlayers[host]++;
                Shavit_PrintToChat(host, " \x04[TagTeam]\x01 %N 拒绝了邀请。", param1); 
            }
            
            // [FIX] 无论如何都只刷新菜单，不再自动开始
            // 之前的代码：if(all_handled) FinishInvite(host);
            // 现在的代码：仅刷新
            OpenLobbyMenu(host);
        }
    } else if(action==MenuAction_End) delete menu;
    return 0;
}

void OpenLobbyMenu(int client) {
    Menu menu = new Menu(LobbyMenu_Handler);
    
    char tName[64];
    if (g_cPlayerTeamName[client][0] != '\0') 
        strcopy(tName, sizeof(tName), g_cPlayerTeamName[client]);
    else 
        strcopy(tName, sizeof(tName), "未命名 (必须设置队名)");
    
    menu.SetTitle("队伍大厅\n队名: %s\n ", tName);
    
    for(int i=0; i<g_aAcceptedPlayers[client].Length; i++) {
        char n[64]; Format(n, 64, "%N", GetClientOfUserId(g_aAcceptedPlayers[client].Get(i)));
        menu.AddItem("", n, ITEMDRAW_DISABLED);
    }
    
    // [ConVar] 检查最少人数要求
    int minPlayers = g_cvMinPlayers.IntValue;
    int requiredTeammates = (minPlayers == 0) ? 0 : 1; // 0=solo allowed, 1=need 1 teammate (2 total)
    bool canStart = (g_cPlayerTeamName[client][0] != '\0' && g_aAcceptedPlayers[client].Length >= requiredTeammates);
    menu.AddItem("start", "开始", canStart ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    
    menu.AddItem("setname", "设置队名");
    menu.AddItem("cancel", "取消");
    menu.Display(client, MENU_TIME_FOREVER);
}

public int LobbyMenu_Handler(Menu menu, MenuAction action, int param1, int param2) {
    if(action==MenuAction_Select) { 
        char info[32];
        menu.GetItem(param2, info, sizeof(info));
        
        if (StrEqual(info, "start"))
        {
            FinishInvite(param1);
        }
        else if (StrEqual(info, "setname"))
        {
            // [NEW] Use ChatCallback for direct input
            Shavit_PrintToChat(param1, " \x04[TagTeam]\x01 请在聊天框输入队伍名称:");
            g_bCreatingTeam[param1] = true; // Reuse this flag to indicate waiting for team name
        }
        else if (StrEqual(info, "cancel"))
        {
            CancelInvite(param1);
        }
    }
    else if(action==MenuAction_End) delete menu;
    return 0;
}

void CancelInvite(int client) { g_bCreatingTeam[client] = false; }
void FinishInvite(int client) {
    g_bCreatingTeam[client] = false; 
    
    int len = g_aAcceptedPlayers[client].Length;
    // [ConVar] 检查最少人数要求
    int minPlayers = g_cvMinPlayers.IntValue;
    int requiredTeammates = (minPlayers == 0) ? 0 : 1; // 0=solo allowed, 1=need 1 teammate
    
    if(len < requiredTeammates) 
    {
        if (minPlayers == 0)
            Shavit_PrintToChat(client, "队伍创建失败！");
        else
            Shavit_PrintToChat(client, "队伍人数不足！至少需要 2 人 (你 + 1个队友)。");
        return;
    }
    int[] m = new int[len+1]; m[0]=client;
    for(int i=0; i<len; i++) m[i+1] = GetClientOfUserId(g_aAcceptedPlayers[client].Get(i));
    CreateTeam(m, len+1, g_iInviteStyle[client]);
}

bool ExitTeam(int client, bool silent = false, bool skipTimerReset = false) {
	// [FIX] Bug #6: Add client validation
	if (!IsClientInGame(client)) return false;
	
	if(g_iTeamIndex[client] == -1) { 
		Shavit_ChangeClientStyle(client, 0); 
		Shavit_RestartTimer(client, Track_Main); 
		return false; 
	}
	
	int teamidx = g_iTeamIndex[client];
	// [FIX] Bug #2: Add bounds checking
	if (teamidx < 0 || teamidx >= MAX_TEAMS) return false;
	
	g_iLastTeamIndex[client] = teamidx;
	
	g_iTeamIndex[client] = -1; 
	g_nTeamPlayerCount[teamidx]--;
	
	if(g_nTeamPlayerCount[teamidx] <= 1) {
		g_bTeamTaken[teamidx] = false;
		
		// Clean up stored checkpoint data
		if (g_bHasLastPassCheckpoint[teamidx])
		{
			if (g_LastPassCheckpoint[teamidx].aFrames != null) delete g_LastPassCheckpoint[teamidx].aFrames;
			if (g_LastPassCheckpoint[teamidx].aEvents != null) delete g_LastPassCheckpoint[teamidx].aEvents;
			if (g_LastPassCheckpoint[teamidx].aOutputWaits != null) delete g_LastPassCheckpoint[teamidx].aOutputWaits;
			if (g_LastPassCheckpoint[teamidx].customdata != null) delete g_LastPassCheckpoint[teamidx].customdata;
			g_bHasLastPassCheckpoint[teamidx] = false;
		}
		
		for(int i = 1; i <= MaxClients; i++) 
		{
			if(i != client && g_iTeamIndex[i] == teamidx) 
			{
				if(!silent) Shavit_PrintToChat(i, "队友都跑光了，队伍解散!");
				ExitTeam(i, true);
			}
		}
	} else {
		for(int i = 1; i <= MaxClients; i++) if(g_iNextTeamMember[i] == client) g_iNextTeamMember[i] = g_iNextTeamMember[client];
		if (g_iCurrentPlayer[teamidx] == client) {
			int next = g_iNextTeamMember[client];
			if (IsClientInGame(next))
			{
				ChangeClientTeam(next, CS_TEAM_T); 
				CS_RespawnPlayer(next); 
				g_iCurrentPlayer[teamidx] = next;
				if(!silent) PrintToTeam(teamidx, "当前跑手退出了，轮到 %N 了!", next);
			}
		}
	}
	g_iNextTeamMember[client] = -1;
	if (!skipTimerReset)
	{
		Shavit_ChangeClientStyle(client, 0);
		Shavit_RestartTimer(client, Track_Main);
	}
	return true;
}

void PrintToTeam(int teamidx, char[] message, any ...) {
	char buffer[512]; VFormat(buffer, sizeof(buffer), message, 3);
	Format(buffer, sizeof(buffer), "\x04[TagTeam]\x01 %s", buffer);
	for(int i = 1; i <= MaxClients; i++)
		if(g_iTeamIndex[i] == teamidx && IsClientInGame(i)) Shavit_PrintToChat(i, "%s", buffer);
}

public void Shavit_OnRestart(int client, int track)
{
	// [FIX] Cancel pending pass teleport to prevent race condition
	g_iPendingPassId[client] = 0;
	
	if (g_iTeamIndex[client] != -1)
	{
		int teamIdx = g_iTeamIndex[client];
		if (g_iCurrentPlayer[teamIdx] == client)
		{
			g_nPassCount[teamIdx] = 0;
			g_nUndoCount[teamIdx] = 0;
			g_aTeamRunHistory[teamIdx].Clear();
			g_aTeamRunAuthHistory[teamIdx].Clear();
			RecordHistory(teamIdx, client);
			PrintToTeam(teamIdx, "跑手重置！接力次数已清零。");
		}
	}
}

// ===== Shavit_OnFinish: 完成后自动离队并保存WR =====
/*
public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp)
{
	int teamidx = g_iTeamIndex[client];
	if (teamidx == -1) return; // 不在队伍中
	if (teamidx < 0 || teamidx >= MAX_TEAMS) return; // 安全检查
	
	// Phase 2: 保存队伍WR到数据库
	SaveTeamWR(teamidx, style, track, time, jumps, strafes, sync, perfs, timestamp);
	
	// 所有队员强制离队并清除状态，阻止读取存档继续刷TagTeam记录
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_iTeamIndex[i] == teamidx)
		{
			// 离队
			ExitTeam(i, true); // silent exit
			
			// 清除所有存档点，防止玩家读档继续刷TagTeam记录
			Shavit_ClearCheckpoints(i);
			
			// 停止计时器并重置到起点
			Shavit_StopTimer(i);
			Shavit_RestartTimer(i, Track_Main);
		}
	}
	
	// 向完成者显示离队消息
	Shavit_PrintToChat(client, " \x04[TagTeam]\x01 队伍完成记录！所有队员已自动离队并清除存档。");
}
*/

// ===== Shavit_OnFinish_Post: 核心和 WR 插件一切处理完毕后触发，绝对安全的过河拆桥 =====
public void Shavit_OnFinish_Post(int client, int style, float time, int jumps, int strafes, float sync, int rank, int overwrite, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp)
{
	if (!Shavit_GetStyleSettingBool(style, "tagteam")) return;
	int teamidx = g_iTeamIndex[client];
	if (teamidx == -1 || teamidx < 0 || teamidx >= MAX_TEAMS) return;

	// 1. 正常保存队伍 WR 到自定义表
	SaveTeamWR(teamidx, style, track, time, jumps, strafes, sync, perfs, timestamp);

	// 2. 【核心修改】过河拆桥：异步删除 Shavit 核心刚刚在后台插入的单人幽灵记录！
	// 因为同用一个 gH_SQL 句柄，这里的 DELETE 会排在核心的 INSERT 之后执行，完美消除幽灵记录。
	char escMap[513];
	gH_SQL.Escape(g_cMapName, escMap, sizeof(escMap));
	
	char query[512];
	FormatEx(query, sizeof(query), "DELETE FROM %splayertimes WHERE auth = %d AND map = '%s' AND style = %d AND track = %d;", 
		g_sSQLPrefix, GetSteamAccountID(client), escMap, style, track);
	SQL_TQuery(gH_SQL, SQL_Void_Callback, query);

	// 3. 所有队员强制离队并清除状态
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_iTeamIndex[i] == teamidx)
		{
			if (i == client)
			{
				// 完成者：离队但跳过计时器重置，等录像保存后再清理
				ExitTeam(i, true, true);
				Shavit_ClearCheckpoints(i);
				g_bPendingFinishCleanup[i] = true;
				delete g_hFinishCleanupTimer[i];
				g_hFinishCleanupTimer[i] = CreateTimer(3.0, Timer_FinishCleanup, GetClientUserId(i));
			}
			else
			{
				ExitTeam(i, true);
				Shavit_ClearCheckpoints(i);
				Shavit_StopTimer(i);
				Shavit_RestartTimer(i, Track_Main);
			}
		}
	}
	
	// 4. 播报真正的队伍通关消息
	Shavit_PrintToChatAll(" \x04[TagTeam]\x01 恭喜！队伍 \x03%s\x01 完成了接力记录！用时: \x04%.2f", g_cTeamName[teamidx], time);
}

// ===== 保存队伍WR到数据库 =====
void SaveTeamWR(int teamidx, int style, int track, float time, int jumps, int strafes, float sync, float perfs, int timestamp)
{
	if (gH_SQL == null) return;
	if (teamidx < 0 || teamidx >= MAX_TEAMS) return;
	
	char map[192];
	GetCurrentMap(map, sizeof(map));
	GetMapDisplayName(map, map, sizeof(map));
	
	char escMap[513];
	gH_SQL.Escape(map, escMap, sizeof(escMap));
	
	char teamname[65];
	strcopy(teamname, sizeof(teamname), g_cTeamName[teamidx]);
	
	// 转义队伍名称防止SQL注入
	char escaped_teamname[129];
	gH_SQL.Escape(teamname, escaped_teamname, sizeof(escaped_teamname));
	
	// 插入WR记录
	char query[1024];
	FormatEx(query, sizeof(query),
		"INSERT INTO tagteam_times (map, style, track, time, team_name, jumps, strafes, sync, perfs, date) "...
		"VALUES ('%s', %d, %d, %.3f, '%s', %d, %d, %.2f, %.2f, %d)",
		map, style, track, time, escaped_teamname, jumps, strafes, sync, perfs, timestamp);
	
	DataPack pack = new DataPack();
	pack.WriteCell(teamidx);
	gH_SQL.Query(SQL_SaveTeamWR_Callback, query, pack);
}

// ===== WR保存回调 =====
public void SQL_SaveTeamWR_Callback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	pack.Reset();
	int teamidx = pack.ReadCell();
	delete pack;
	
	if (results == null)
	{
		LogError("TagTeam WR保存失败: %s", error);
		return;
	}
	
	// 获取插入的记录ID
	int teamTimeId = results.InsertId;
	
	// 保存队伍成员
	SaveTeamMembers(teamidx, teamTimeId);
}

// ===== 保存队伍成员 =====
void SaveTeamMembers(int teamidx, int teamTimeId)
{
	if (gH_SQL == null) return;
	if (teamidx < 0 || teamidx >= MAX_TEAMS) return;
	
	Transaction txn = new Transaction();
	
	int position = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (g_iLastTeamIndex[i] != teamidx) continue; // 使用LastTeamIndex因为已经离队
		
		int auth = GetSteamAccountID(i);
		if (auth == 0) continue;
		
		char name[33];
		GetClientName(i, name, sizeof(name));
		
		//char escaped_name[65];
		char escaped_name[MAX_NAME_LENGTH * 2 + 1];
		gH_SQL.Escape(name, escaped_name, sizeof(escaped_name));
		
		char query[512];
		FormatEx(query, sizeof(query),
			"INSERT INTO tagteam_members (team_id, auth, name, position) VALUES (%d, %d, '%s', %d)",
			teamTimeId, auth, escaped_name, position);
		
		txn.AddQuery(query);
		position++;
	}
	
	gH_SQL.Execute(txn, SQL_SaveMembers_Success, SQL_SaveMembers_Failure);
}

// ===== 成员保存成功 =====
public void SQL_SaveMembers_Success(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	// 成功保存后，立即重新读取数据库，刷新当前地图的 TagTeam WR 缓存！
	LoadTagTeamWRCache();
	PrintToServer("[TagTeam] 新的接力记录已诞生，WR缓存已刷新！");
}

// ===== 成员保存失败 =====
public void SQL_SaveMembers_Failure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("TagTeam成员保存失败 (query %d/%d): %s", failIndex, numQueries, error);
}

// ===============================
// WR Cache Loading
// ===============================

/**
 * Loads TagTeam WR cache for all styles/tracks on map start
 */
void LoadTagTeamWRCache()
{
	if (gH_SQL == null) return;
	
	char escMap[513];
	gH_SQL.Escape(g_cMapName, escMap, sizeof(escMap));
	
	char query[1024];
	FormatEx(query, sizeof(query),
		"SELECT t1.style, t1.track, t1.team_name, t1.id " ...
		"FROM tagteam_times t1 " ...
		"INNER JOIN ( " ...
		"    SELECT style, track, MIN(time) as min_time " ...
		"    FROM tagteam_times " ...
		"    WHERE map = '%s' " ...
		"    GROUP BY style, track " ...
		") t2 ON t1.style = t2.style AND t1.track = t2.track AND t1.time = t2.min_time " ...
		"WHERE t1.map = '%s'",
		//g_cMapName, g_cMapName);
		escMap, escMap);
	
	gH_SQL.Query(SQL_LoadWRCache_Callback, query);
}

public void SQL_LoadWRCache_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		LogError("LoadTagTeamWRCache error: %s", error);
		return;
	}
	
	while (results.FetchRow())
	{
		int style = results.FetchInt(0);
		int track = results.FetchInt(1);
		int teamId = results.FetchInt(3);
		
		if (style < 0 || style >= STYLE_LIMIT || track < 0 || track >= TRACKS_SIZE)
			continue;
		
		results.FetchString(2, g_cCachedWRTeamName[style][track], 64);
		
		// Now load members for this team
		char memberQuery[256];
		FormatEx(memberQuery, sizeof(memberQuery),
			"SELECT name FROM tagteam_members WHERE team_id = %d ORDER BY position ASC",
			teamId);
		
		DataPack pack = new DataPack();
		pack.WriteCell(style);
		pack.WriteCell(track);
		
		gH_SQL.Query(SQL_LoadWRMembers_Callback, memberQuery, pack);
	}
}

public void SQL_LoadWRMembers_Callback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	pack.Reset();
	int style = pack.ReadCell();
	int track = pack.ReadCell();
	delete pack;
	
	if (results == null)
	{
		LogError("LoadWRMembers error: %s", error);
		return;
	}
	
	if (style < 0 || style >= STYLE_LIMIT || track < 0 || track >= TRACKS_SIZE)
		return;
	
	// Create ArrayList for members
	delete g_aCachedWRMembers[style][track];
	g_aCachedWRMembers[style][track] = new ArrayList(ByteCountToCells(MAX_NAME_LENGTH));
	
	while (results.FetchRow())
	{
		char name[MAX_NAME_LENGTH];
		results.FetchString(0, name, sizeof(name));
		g_aCachedWRMembers[style][track].PushString(name);
	}
	
	g_bWRCacheLoaded[style][track] = true;
}

// ===============================
// Natives for other plugins
// ===============================

/**
 * Native: Shavit_GetTagTeamWRInfo
 * 
 * Retrieves TagTeam WR information from cache
 */
public int Native_GetTagTeamWRInfo(Handle plugin, int numParams)
{
	// Get parameters
	int maxlen_map = 0;
	GetNativeStringLength(1, maxlen_map);
	maxlen_map++;
	char[] map = new char[maxlen_map];
	GetNativeString(1, map, maxlen_map);
	
	int style = GetNativeCell(2);
	int track = GetNativeCell(3);
	int nameLen = GetNativeCell(5);
	ArrayList members = GetNativeCell(6);
	
	// Validate parameters
	if (style < 0 || style >= STYLE_LIMIT || track < 0 || track >= TRACKS_SIZE)
	{
		return false;
	}
	
	if (members == null)
	{
		return false;
	}
	
	// Check if we're querying current map
	if (!StrEqual(map, g_cMapName))
	{
		return false; // Only support current map for now
	}
	
	// Check if cache is loaded
	if (!g_bWRCacheLoaded[style][track])
	{
		return false;
	}
	
	// Check if WR exists
	if (g_cCachedWRTeamName[style][track][0] == '\0')
	{
		return false;
	}
	
	// Return team name
	SetNativeString(4, g_cCachedWRTeamName[style][track], nameLen);
	
	// Copy members to provided ArrayList
	members.Clear();
	if (g_aCachedWRMembers[style][track] != null)
	{
		int count = g_aCachedWRMembers[style][track].Length;
		for (int i = 0; i < count; i++)
		{
			char name[MAX_NAME_LENGTH];
			g_aCachedWRMembers[style][track].GetString(i, name, sizeof(name));
			members.PushString(name);
		}
	}
	
	return true;
}

public Action Command_DeleteTeam(int client, int args)
{
	if (!IsValidClient(client)) return Plugin_Handled;

	if (gH_SQL == null)
	{
		Shavit_PrintToChat(client, " \x02[错误]\x01 数据库尚未连接。");
		return Plugin_Handled;
	}

	char escMap[513];
	gH_SQL.Escape(g_cMapName, escMap, sizeof(escMap));

	// 查询当前地图的所有 TagTeam 记录
	char query[512];
	FormatEx(query, sizeof(query), "SELECT id, style, track, team_name, time FROM tagteam_times WHERE map = '%s' ORDER BY style ASC, track ASC, time ASC LIMIT 50;", escMap);
	
	gH_SQL.Query(SQL_DeleteTeamMenu_Callback, query, GetClientSerial(client));
	return Plugin_Handled;
}

public void SQL_DeleteTeamMenu_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientFromSerial(data);
	if (client == 0) return;

	if (results == null)
	{
		LogError("[TagTeam] Delete Menu Query Failed: %s", error);
		return;
	}

	Menu menu = new Menu(DeleteTeamMenu_Handler);
	menu.SetTitle("删除 TagTeam 记录\n当前地图: %s\n ", g_cMapName);

	if (results.RowCount == 0)
	{
		menu.AddItem("-1", "当前地图没有 TagTeam 记录", ITEMDRAW_DISABLED);
	}
	else
	{
		while (results.FetchRow())
		{
			int id = results.FetchInt(0);
			int style = results.FetchInt(1);
			int track = results.FetchInt(2);
			
			char teamName[64];
			results.FetchString(3, teamName, sizeof(teamName));
			
			float time = results.FetchFloat(4);
			char sTime[16];
			FormatSeconds(time, sTime, sizeof(sTime));

			// 【修复 1】使用正确的结构体获取模式名称，解决 Error 450
			stylestrings_t styleStrings;
			Shavit_GetStyleStringsStruct(style, styleStrings);

			// 【修复 2】把闲置的 track 用上，标明是 Main 还是 Bonus
			char szTrack[16];
			if (track == 0) strcopy(szTrack, sizeof(szTrack), "Main");
			else Format(szTrack, sizeof(szTrack), "Bonus %d", track);

			char display[128];
			// 格式: [Style | Main] 队名 - 00:00.00
			FormatEx(display, sizeof(display), "[%s | %s] %s - %s", styleStrings.sStyleName, szTrack, teamName, sTime);

			char info[16];
			IntToString(id, info, sizeof(info));
			menu.AddItem(info, display);
		}
	}
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int DeleteTeamMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(param2, info, sizeof(info));
		// 【修复 3】直接删除了多余的 id 声明，消除 Warning

		// 防呆设计：二次确认菜单
		Menu confirm = new Menu(DeleteTeamConfirm_Handler);
		confirm.SetTitle("【警告】确认要彻底删除这条队伍记录吗？\n删除后不可恢复！\n ");
		confirm.AddItem("no", "取消 (Cancel)");
		confirm.AddItem(info, "确认删除 (Confirm Delete)");
		confirm.ExitButton = false;
		confirm.Display(param1, MENU_TIME_FOREVER);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

public int DeleteTeamConfirm_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(param2, info, sizeof(info));

		if (StrEqual(info, "no"))
		{
			Shavit_PrintToChat(param1, " \x04[TagTeam]\x01 已取消删除操作。");
		}
		else
		{
			int id = StringToInt(info);
			
			// 使用事务 (Transaction) 确保成员表和时间表同时被删除，防止数据孤岛
			Transaction txn = new Transaction();
			
			char query[256];
			FormatEx(query, sizeof(query), "DELETE FROM tagteam_members WHERE team_id = %d;", id);
			txn.AddQuery(query);
			
			FormatEx(query, sizeof(query), "DELETE FROM tagteam_times WHERE id = %d;", id);
			txn.AddQuery(query);

			DataPack pack = new DataPack();
			pack.WriteCell(GetClientSerial(param1));

			gH_SQL.Execute(txn, SQL_DeleteTeam_Success, SQL_DeleteTeam_Failure, pack);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

public void SQL_DeleteTeam_Success(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int client = GetClientFromSerial(pack.ReadCell());
	delete pack;

	if (client > 0) 
		Shavit_PrintToChat(client, " \x04[TagTeam]\x01 队伍记录彻底删除成功！排行榜正在重新计算...");

	// 1. 刷新 TagTeam 自身的 WR 缓存
	LoadTagTeamWRCache();
	
	// 2. 通知 shavit-wr 重新执行 UNION 查询，立刻更新游戏内 !wr 榜单
	Shavit_ReloadLeaderboards();
}

public void SQL_DeleteTeam_Failure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	DataPack pack = view_as<DataPack>(data);
	delete pack;
	LogError("[TagTeam] Delete Record Failed (Query %d): %s", failIndex, error);
}