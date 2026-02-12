/*
 * shavit's Timer - Map Zones (JSON) - 本地优先优化版 (最终修复版)
 *
 * 修改日志:
 * 1. 适配 sm-json (clugg版) 的正确 API (JSON_Object/JSON_Array)。
 * 2. 修复了 undefined symbol 错误。
 * 3. 修复了内存管理逻辑（防止 Double Free）。
 * 4. Zone 逻辑：仅读取本地文件，且优先检查数据库 (数据库有则跳过 JSON)。
 * 5. Tier 逻辑：
 * - 加载时：优先读取本地 JSON (JSON 有则覆盖数据库)，忽略数据库检查。
 * - 修改时：监听 !settier 命令，自动生成/更新本地 JSON 文件。
 * 6. 迁移逻辑：使用 RequestFrame 分批异步处理 i 文件夹中的文件，防止超时崩溃。
 * 7. sm_json 命令修复：切换回 SQL 模式时使用 Native 调用，解决不生效的问题。
 */

#include <sourcemod>
#include <convar_class>

// Shavit 核心库
#include <shavit/core>
#include <shavit/zones>

#undef REQUIRE_PLUGIN
#undef REQUIRE_EXTENSIONS
// 需要 sm-json: https://github.com/clugg/sm-json
#include <json> 

#pragma semicolon 1
#pragma newdecls required

// Zone 类型字符串映射
static char gS_ZoneTypes[ZONETYPES_SIZE][18] = {
	"start", "end", "respawn", "stop", "slay", "freestyle",
	"customspeedlimit", "teleport", "customspawn", "easybhop",
	"slide", "airaccel", "stage", "notimergravity", "gravity",
	"speedmod", "nojump", "autobhop"
};

bool gB_Late = false;
char gS_Map[PLATFORM_MAX_PATH];
char gS_EngineName[16];

// 数据库句柄
Database gH_SQL = null;
char gS_MySQLPrefix[32];

// ConVars
Convar gCV_Enable = null;
Convar gCV_Source = null;

public Plugin myinfo =
{
	name = "[shavit] Map Zones (JSON)",
	author = "rtldg",
	description = "Zone: 数据库优先; Tier: JSON 优先且自动保存; 提供异步迁移工具; 手动源选择(预览/覆盖)。",
	version = "1.0.14-ReloadFix",
	url = "https://github.com/shavitush/bhoptimer"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	gB_Late = late;
	
	switch (GetEngineVersion())
	{
		case Engine_CSGO: gS_EngineName = "csgo";
		case Engine_CSS:  gS_EngineName = "cstrike";
		case Engine_TF2:  gS_EngineName = "tf2";
		default: gS_EngineName = "cstrike";
	}

	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "data/zones-%s", gS_EngineName);
	if (!DirExists(dir)) CreateDirectory(dir, 511);
	
	// 确保 z (zones) 文件夹存在
	StrCat(dir, sizeof(dir), "/z");
	if (!DirExists(dir)) CreateDirectory(dir, 511);
	
	// 确保 i (info/tier) 文件夹存在
	dir[strlen(dir)-1] = 'i'; // 把 /z 变成 /i
	if (!DirExists(dir)) CreateDirectory(dir, 511);

	RegPluginLibrary("shavit-zones-json");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("shavit-common.phrases");
	
	gCV_Enable = new Convar("shavit_zones_json_enable", "1", "是否启用 JSON 区域/Tier 加载。", 0, true, 0.0, true, 1.0);
	gCV_Source = new Convar("shavit_zones_json_src", "json", "通过此插件加载的 Zone 的来源标识字符串。");
	
	Convar.AutoExecConfig();

	RegAdminCmd("sm_dumpzones", Command_DumpZones, ADMFLAG_RCON, "将当前地图的 Zone 转存为 JSON 文件");
	RegAdminCmd("sm_savezones", Command_DumpZones, ADMFLAG_RCON, "将当前地图的 Zone 转存为 JSON 文件");

	// 新增迁移命令 (异步版)
	RegAdminCmd("sm_json_migrate_tiers", Command_MigrateTiers, ADMFLAG_ROOT, "将 i 文件夹中的所有 JSON Tier 数据批量迁移到数据库");

	// 新增源选择命令
	RegAdminCmd("sm_json", Command_SelectSource, ADMFLAG_RCON, "打开菜单选择加载 Zone 的来源 (强制 JSON 或 标准 SQL)");

	// 监听 Tier 设置命令，以便自动更新 JSON
	AddCommandListener(OnSetTierCommand, "sm_settier");
	AddCommandListener(OnSetTierCommand, "sm_setmaptier");
	
	if (gB_Late)
	{
		Shavit_OnDatabaseLoaded();
	}
}

public void OnConfigsExecuted()
{
	GetLowercaseMapName(gS_Map);
}

public void Shavit_OnDatabaseLoaded()
{
	GetTimerSQLPrefix(gS_MySQLPrefix, 32);
	gH_SQL = Shavit_GetDatabase();
}

public void Shavit_LoadZonesHere()
{
	if (!gCV_Enable.BoolValue || gH_SQL == null)
		return;

	// 1. 检查并加载 Zones (保持原逻辑：优先数据库)
	CheckDatabaseForZones();
	
	// 2. 加载 Tier (MapInfo) (保持原逻辑：优先本地 JSON)
	LoadTierFromJSON();
}

// =============================================================================
// 手动选择源 (sm_json) - 包含二级菜单
// =============================================================================

public Action Command_SelectSource(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "此命令仅限游戏内使用。");
		return Plugin_Handled;
	}

	Menu menu = new Menu(MenuHandler_SelectSource);
	menu.SetTitle("选择区域(Zone)加载来源\n当前地图: %s", gS_Map);

	menu.AddItem("json", "从本地 JSON 文件加载");
	menu.AddItem("sql", "从 SQL 数据库加载 (标准模式)");

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);

	return Plugin_Handled;
}

public int MenuHandler_SelectSource(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[32];
		menu.GetItem(param2, info, sizeof(info));

		if (StrEqual(info, "json"))
		{
			// 弹出二级菜单：询问操作类型
			Menu subMenu = new Menu(MenuHandler_ConfirmJSONAction);
			subMenu.SetTitle("JSON 加载选项\n警告: 覆盖数据库将清空当前地图原有 Zone！");
			
			subMenu.AddItem("preview", "临时预览 (仅加载到内存，不保存)");
			subMenu.AddItem("overwrite", "覆盖数据库 (清空DB并导入JSON)");
			
			subMenu.ExitBackButton = true;
			subMenu.Display(param1, MENU_TIME_FOREVER);
		}
		else if (StrEqual(info, "sql"))
		{
			// SQL 模式：调用 Shavit Native 进行重载
			// 这种方式比 ServerCommand 更可靠，能确保内存被清理并重新触发加载流程
			Shavit_UnloadZones(); // 先显式清空内存中的 Zone，以防万一
			Shavit_ReloadZones(); // 触发标准加载流程 (shavit-zones 会执行 LoadZonesHere -> RefreshZones)
			
			Shavit_PrintToChat(param1, "已触发标准 SQL 重载 (正在查询数据库...)。");
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public int MenuHandler_ConfirmJSONAction(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[32];
		menu.GetItem(param2, info, sizeof(info));

		if (StrEqual(info, "preview"))
		{
			// 临时预览：unload -> load json (save=false)
			Shavit_UnloadZones();
			LoadTierFromJSON();
			LoadZonesFromJSON(false);
			Shavit_PrintToChat(param1, "已加载 JSON Zone (预览模式)。数据库未被修改。");
		}
		else if (StrEqual(info, "overwrite"))
		{
			// 覆盖数据库：unload -> load json (save=true)
			Shavit_UnloadZones();
			LoadTierFromJSON();
			LoadZonesFromJSON(true);
			Shavit_PrintToChat(param1, "已加载 JSON Zone 并覆盖到数据库！");
		}
	}
	else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		// 返回上一级
		Command_SelectSource(param1, 0);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

// =============================================================================
// Zone 加载逻辑
// =============================================================================

void CheckDatabaseForZones()
{
	char sQuery[256];
	FormatEx(sQuery, sizeof(sQuery), "SELECT id FROM %smapzones WHERE map = '%s' LIMIT 1;", gS_MySQLPrefix, gS_Map);
	gH_SQL.Query(SQL_CheckZones_Callback, sQuery);
}

public void SQL_CheckZones_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		LogError("JSON Zone 加载器: 数据库检查失败: %s", error);
		return;
	}

	if (results.RowCount > 0)
	{
		PrintToServer("[shavit-zones-json] 数据库中已存在 %s 的 Zone。跳过 JSON 加载。", gS_Map);
	}
	else
	{
		// 自动加载时，仅加载到内存（不保存到 DB，防止意外覆盖）
		LoadZonesFromJSON(false);
	}
}

void LoadZonesFromJSON(bool save_to_db = false)
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/zones-%s/z/%s.json", gS_EngineName, gS_Map);

	if (!FileExists(path))
		return;

	// API 修正：使用 json_read_from_file 全局函数
	JSON_Object root = json_read_from_file(path);
	if (root == null) return;
	
	if (!root.IsArray) {
		json_cleanup_and_delete(root);
		LogError("[shavit-zones-json] Zone JSON 文件格式错误 (根元素不是数组): %s", path);
		return;
	}

	JSON_Array records = view_as<JSON_Array>(root);

	if (records != null)
	{
		char source[16];
		gCV_Source.GetString(source, sizeof(source));
		
		// 如果需要保存到数据库，先清空当前地图的 Zone
		if (save_to_db && gH_SQL != null)
		{
			char sQuery[512];
			char sEscapedMap[PLATFORM_MAX_PATH * 2 + 1];
			gH_SQL.Escape(gS_Map, sEscapedMap, sizeof(sEscapedMap));
			FormatEx(sQuery, sizeof(sQuery), "DELETE FROM %smapzones WHERE map = '%s';", gS_MySQLPrefix, sEscapedMap);
			gH_SQL.Query(SQL_DeleteZones_Callback, sQuery);
		}

		int count = ProcessJsonZones(records, source, save_to_db);
		if (count > 0)
		{
			PrintToServer("[shavit-zones-json] 从 %s 加载了 %d 个 Zone (SaveDB=%s)。", path, count, save_to_db ? "Yes" : "No");
		}
		
		json_cleanup_and_delete(root);
	}
	else
	{
		LogError("[shavit-zones-json] 解析 JSON 文件失败或文件为空: %s", path);
	}
}

public void SQL_DeleteZones_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null) LogError("Failed to delete zones for overwrite: %s", error);
}

int ProcessJsonZones(JSON_Array records, const char source[16], bool save_to_db)
{
	int count = 0;
	int length = records.Length;

	Transaction trans = null;
	if (save_to_db && gH_SQL != null)
	{
		trans = new Transaction();
	}

	for (int i = 0; i < length; i++)
	{
		JSON_Object json = records.GetObject(i);
		if (json == null) continue;
		
		char typeStr[32];
		json.GetString("type", typeStr, sizeof(typeStr));
		
		int zoneType = -1;
		for (int j = 0; j < ZONETYPES_SIZE; j++)
		{
			if (StrEqual(typeStr, gS_ZoneTypes[j]))
			{
				zoneType = j;
				break;
			}
		}

		if (zoneType == -1) continue;

		zone_cache_t cache;
		cache.iType = zoneType;
		cache.iTrack = json.GetInt("track");
		cache.iDatabaseID = -1;
		
		if (json.HasKey("flags")) cache.iFlags = json.GetInt("flags");
		if (json.HasKey("data")) cache.iData = json.GetInt("data");
		
		if (zoneType == Zone_Stage && json.HasKey("index")) 
			cache.iData = json.GetInt("index");

		if (json.HasKey("point_a")) GetVecFromJson(json, "point_a", cache.fCorner1);
		if (json.HasKey("point_b")) GetVecFromJson(json, "point_b", cache.fCorner2);
		if (json.HasKey("dest")) GetVecFromJson(json, "dest", cache.fDestination);
		
		if (json.HasKey("form")) cache.iForm = json.GetInt("form");
		if (json.HasKey("target")) json.GetString("target", cache.sTarget, sizeof(cache.sTarget));
		
		strcopy(cache.sSource, sizeof(cache.sSource), source);
		
		// 加载到内存
		Shavit_AddZone(cache);
		count++;
		
		// 准备 SQL 插入语句
		if (save_to_db && trans != null)
		{
			char sQuery[2048];
			char sEscapedMap[PLATFORM_MAX_PATH * 2 + 1];
			char sEscapedTarget[128]; // target 64 * 2
			gH_SQL.Escape(gS_Map, sEscapedMap, sizeof(sEscapedMap));
			gH_SQL.Escape(cache.sTarget, sEscapedTarget, sizeof(sEscapedTarget));

			FormatEx(sQuery, sizeof(sQuery),
				"INSERT INTO %smapzones (map, type, corner1_x, corner1_y, corner1_z, corner2_x, corner2_y, corner2_z, destination_x, destination_y, destination_z, track, flags, data, form, target) " ...
				"VALUES ('%s', %d, %f, %f, %f, %f, %f, %f, %f, %f, %f, %d, %d, %d, %d, '%s');",
				gS_MySQLPrefix,
				sEscapedMap,
				cache.iType,
				cache.fCorner1[0], cache.fCorner1[1], cache.fCorner1[2],
				cache.fCorner2[0], cache.fCorner2[1], cache.fCorner2[2],
				cache.fDestination[0], cache.fDestination[1], cache.fDestination[2],
				cache.iTrack,
				cache.iFlags,
				cache.iData,
				cache.iForm,
				sEscapedTarget
			);
			trans.AddQuery(sQuery);
		}
	}
	
	if (save_to_db && trans != null)
	{
		gH_SQL.Execute(trans, SQL_ImportZones_Success, SQL_ImportZones_Failure);
	}
	
	return count;
}

public void SQL_ImportZones_Success(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	// 成功导入
}

public void SQL_ImportZones_Failure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("JSON Zone 导入数据库失败: %s", error);
}

void GetVecFromJson(JSON_Object json, const char[] key, float vec[3])
{
	JSON_Array arr = view_as<JSON_Array>(json.GetObject(key));
	if (arr != null)
	{
		vec[0] = arr.GetFloat(0);
		vec[1] = arr.GetFloat(1);
		vec[2] = arr.GetFloat(2);
	}
}

// =============================================================================
// MapInfo / Tier 加载逻辑
// =============================================================================

void LoadTierFromJSON()
{
	char path[PLATFORM_MAX_PATH];
	// 路径: data/zones-csgo/i/mapname.json
	BuildPath(Path_SM, path, sizeof(path), "data/zones-%s/i/%s.json", gS_EngineName, gS_Map);

	if (!FileExists(path))
		return;

	JSON_Object root = json_read_from_file(path);
	if (root == null) return;

	if (!root.IsArray) {
		json_cleanup_and_delete(root);
		LogError("[shavit-zones-json] MapInfo JSON 文件格式错误 (根元素不是数组): %s", path);
		return;
	}

	JSON_Array tracks = view_as<JSON_Array>(root);
	
	if (tracks.Length > 0)
	{
		JSON_Object mainTrackInfo = tracks.GetObject(0);
		if (mainTrackInfo != null)
		{
			if (mainTrackInfo.HasKey("tier"))
			{
				int tier = mainTrackInfo.GetInt("tier");
				
				if (tier > 0)
				{
					// 使用 ServerCommand 更新，覆盖数据库设置
					ServerCommand("sm_settier %d", tier);
					PrintToServer("[shavit-zones-json] 从 JSON 设置了 %s 的 Tier 为 %d。", gS_Map, tier);
				}
			}
		}
	}

	json_cleanup_and_delete(root);
}

// =============================================================================
// Tier 自动保存逻辑 (Command Listener)
// =============================================================================

public Action OnSetTierCommand(int client, const char[] command, int args)
{
	// 防止死循环：如果是 Server (client 0) 发出的命令（例如来自 LoadTierFromJSON），则忽略
	if (client == 0) return Plugin_Continue;

	// 检查权限
	if (!CheckCommandAccess(client, "sm_settier", ADMFLAG_RCON)) return Plugin_Continue;

	if (args < 1) return Plugin_Continue;

	char sTier[8];
	GetCmdArg(1, sTier, sizeof(sTier));
	int tier = StringToInt(sTier);
	
	if (tier < 0) return Plugin_Continue;

	char sMap[PLATFORM_MAX_PATH];
	if (args >= 2)
	{
		GetCmdArg(2, sMap, sizeof(sMap));
		TrimString(sMap);
		LowercaseString(sMap);
	}
	else
	{
		strcopy(sMap, sizeof(sMap), gS_Map);
	}

	// 保存到 JSON
	SaveTierToJSON(sMap, tier);

	return Plugin_Continue;
}

void SaveTierToJSON(const char[] map, int tier)
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/zones-%s/i/%s.json", gS_EngineName, map);

	JSON_Array root = null;
	JSON_Object mainTrack = null;

	// 尝试读取现有文件，保留其他数据
	if (FileExists(path))
	{
		JSON_Object existing = json_read_from_file(path);
		if (existing != null)
		{
			if (existing.IsArray)
			{
				root = view_as<JSON_Array>(existing);
			}
			else
			{
				json_cleanup_and_delete(existing);
			}
		}
	}

	if (root == null)
	{
		root = new JSON_Array();
	}

	// 确保 Track 0 (Main) 对象存在
	if (root.Length > 0)
	{
		mainTrack = root.GetObject(0);
	}
	
	if (mainTrack == null)
	{
		mainTrack = new JSON_Object();
		if (root.Length == 0) root.PushObject(mainTrack);
		else root.SetObject(0, mainTrack);
	}

	// 更新 Tier
	mainTrack.SetInt("tier", tier);

	// 写入文件
	root.WriteToFile(path, JSON_ENCODE_PRETTY);
	
	// 清理
	JSON_Object rootObj = view_as<JSON_Object>(root);
	json_cleanup_and_delete(rootObj);
	
	PrintToServer("[shavit-zones-json] 地图 %s 的 Tier (%d) 已更新并保存至 JSON。", map, tier);
}

// =============================================================================
// Tier 批量迁移逻辑 (Migrate Tiers) - 异步处理防止超时
// =============================================================================

public Action Command_MigrateTiers(int client, int args)
{
	if (gH_SQL == null)
	{
		ReplyToCommand(client, "[shavit-zones-json] 数据库未连接，无法执行迁移。");
		return Plugin_Handled;
	}

	char dirPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dirPath, sizeof(dirPath), "data/zones-%s/i", gS_EngineName);

	if (!DirExists(dirPath))
	{
		ReplyToCommand(client, "[shavit-zones-json] 目录不存在: %s", dirPath);
		return Plugin_Handled;
	}

	DirectoryListing dir = OpenDirectory(dirPath);
	if (dir == null)
	{
		ReplyToCommand(client, "[shavit-zones-json] 无法打开目录: %s", dirPath);
		return Plugin_Handled;
	}

	// 准备数据包
	DataPack pack = new DataPack();
	pack.WriteCell(client == 0 ? 0 : GetClientUserId(client)); // 0: UserId
	pack.WriteCell(dir);                                       // 1: Directory Handle
	pack.WriteCell(new Transaction());                         // 2: Transaction Handle
	pack.WriteCell(0);                                         // 3: Count
	pack.WriteString(dirPath);                                 // 4: Path string

	ReplyToCommand(client, "[shavit-zones-json] 开始后台处理 Tier 迁移...");
	
	// 开始异步循环
	RequestFrame(ProcessMigrationBatch, pack);

	return Plugin_Handled;
}

public void ProcessMigrationBatch(DataPack pack)
{
	// 1. 读取数据
	pack.Reset();
	int userid = pack.ReadCell();
	DirectoryListing dir = view_as<DirectoryListing>(pack.ReadCell());
	Transaction trans = view_as<Transaction>(pack.ReadCell());
	int count = pack.ReadCell();
	char dirPath[PLATFORM_MAX_PATH];
	pack.ReadString(dirPath, sizeof(dirPath));

	int client = (userid == 0) ? 0 : GetClientOfUserId(userid);
	
	// 2. 批量处理逻辑
	int batchCount = 0;
	int BATCH_SIZE = 5; // 每次只处理5个文件，防止超时
	char filename[PLATFORM_MAX_PATH];
	FileType type;
	bool finished = false;

	while (batchCount < BATCH_SIZE)
	{
		if (!dir.GetNext(filename, sizeof(filename), type))
		{
			finished = true;
			break;
		}

		if (type == FileType_File)
		{
			int len = strlen(filename);
			if (len > 5 && StrEqual(filename[len - 5], ".json", false))
			{
				char mapName[PLATFORM_MAX_PATH];
				strcopy(mapName, len - 4, filename); 
				
				char fullPath[PLATFORM_MAX_PATH];
				FormatEx(fullPath, sizeof(fullPath), "%s/%s", dirPath, filename);
				
				JSON_Object root = json_read_from_file(fullPath);
				if (root != null)
				{
					if (root.IsArray)
					{
						JSON_Array tracks = view_as<JSON_Array>(root);
						if (tracks.Length > 0)
						{
							JSON_Object mainTrack = tracks.GetObject(0);
							if (mainTrack != null)
							{
								if (mainTrack.HasKey("tier"))
								{
									int tier = mainTrack.GetInt("tier");
									if (tier > 0)
									{
										char sQuery[512];
										char sEscapedMap[PLATFORM_MAX_PATH * 2 + 1];
										gH_SQL.Escape(mapName, sEscapedMap, sizeof(sEscapedMap));
										
										FormatEx(sQuery, sizeof(sQuery), "REPLACE INTO %smaptiers (map, tier) VALUES ('%s', %d);", gS_MySQLPrefix, sEscapedMap, tier);
										trans.AddQuery(sQuery);
										count++;
									}
								}
							}
						}
					}
					json_cleanup_and_delete(root);
				}
			}
		}
		batchCount++;
	}

	// 3. 结果判断
	if (finished)
	{
		if (count > 0)
		{
			gH_SQL.Execute(trans, SQL_MigrateTiers_Success, SQL_MigrateTiers_Failure, userid);
			if (client != 0 || userid == 0) ReplyToCommand(client, "[shavit-zones-json] 扫描完成，共找到 %d 条数据，正在写入数据库...", count);
		}
		else
		{
			delete trans;
			if (client != 0 || userid == 0) ReplyToCommand(client, "[shavit-zones-json] 没有在 i 文件夹中找到任何有效的 Tier 数据。");
		}
		delete dir;
		delete pack;
	}
	else
	{
		// 4. 更新状态并继续下一帧
		pack.Position = 0; // 回到开头
		pack.WriteCell(userid);
		pack.WriteCell(dir);
		pack.WriteCell(trans);
		pack.WriteCell(count); // 更新计数
		// 字符串在最后，无需重写
		
		RequestFrame(ProcessMigrationBatch, pack);
	}
}

public void SQL_MigrateTiers_Success(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	int client = (data == 0) ? 0 : GetClientOfUserId(data);
	if (client == 0 && data != 0) return; // User disconnected
	if (client == 0 || IsClientInGame(client))
	{
		ReplyToCommand(client, "[shavit-zones-json] 成功迁移了 %d 条 Tier 数据到数据库。", numQueries);
	}
}

public void SQL_MigrateTiers_Failure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	int client = (data == 0) ? 0 : GetClientOfUserId(data);
	LogError("[shavit-zones-json] Tier 迁移失败 (查询索引 %d/%d): %s", failIndex, numQueries, error);
	if (client == 0 || IsClientInGame(client))
	{
		ReplyToCommand(client, "[shavit-zones-json] 迁移失败，详细信息请查看服务器错误日志。");
	}
}

// =============================================================================
// 转存逻辑 (Dump Zones)
// =============================================================================

void FillBoxMinMax(float point1[3], float point2[3], float boxmin[3], float boxmax[3])
{
	for (int i = 0; i < 3; i++)
	{
		if (point1[i] < point2[i])
		{
			boxmin[i] = point1[i];
			boxmax[i] = point2[i];
		}
		else
		{
			boxmin[i] = point2[i];
			boxmax[i] = point1[i];
		}
	}
}

bool EmptyVector(float vec[3])
{
	return vec[0] == 0.0 && vec[1] == 0.0 && vec[2] == 0.0;
}

JSON_Array CreateJsonVec(float vec[3])
{
	JSON_Array arr = new JSON_Array();
	arr.PushFloat(vec[0]);
	arr.PushFloat(vec[1]);
	arr.PushFloat(vec[2]);
	return arr;
}

JSON_Object CacheToJsonObject(zone_cache_t cache)
{
	FillBoxMinMax(cache.fCorner1, cache.fCorner2, cache.fCorner1, cache.fCorner2);
	
	JSON_Object obj = new JSON_Object();
	obj.SetString("type", gS_ZoneTypes[cache.iType]);
	obj.SetInt("track", cache.iTrack);
	obj.SetInt("id", cache.iDatabaseID);
	
	if (cache.iFlags) obj.SetInt("flags", cache.iFlags);
	if (cache.iData) obj.SetInt("data", cache.iData);
	
	if (!EmptyVector(cache.fCorner1)) {
		JSON_Array a = CreateJsonVec(cache.fCorner1);
		obj.SetObject("point_a", a); 
	}
	
	if (!EmptyVector(cache.fCorner2)) {
		JSON_Array b = CreateJsonVec(cache.fCorner2);
		obj.SetObject("point_b", b);
	}
	
	if (!EmptyVector(cache.fDestination)) {
		JSON_Array c = CreateJsonVec(cache.fDestination);
		obj.SetObject("dest", c);
	}
	
	if (cache.iForm) obj.SetInt("form", cache.iForm);
	if (cache.sTarget[0]) obj.SetString("target", cache.sTarget);
	
	return obj;
}

public Action Command_DumpZones(int client, int args)
{
	int count = Shavit_GetZoneCount();

	if (!count)
	{
		ReplyToCommand(client, "当前地图没有任何 Zone...");
		return Plugin_Handled;
	}

	JSON_Array root = new JSON_Array();

	for (int i = 0; i < count; i++)
	{
		zone_cache_t cache;
		Shavit_GetZone(i, cache);
		JSON_Object obj = CacheToJsonObject(cache);
		
		root.PushObject(obj);
	}

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/zones-%s/z/%s.json", gS_EngineName, gS_Map);
	
	if (root.WriteToFile(path, JSON_ENCODE_PRETTY))
	{
		Shavit_PrintToChat(client, "已将 %d 个 Zone 转存至: %s", count, path);
	}
	else
	{
		Shavit_PrintToChat(client, "转存失败! 无法写入文件: %s", path);
	}
	
	JSON_Object rootObj = view_as<JSON_Object>(root);
	json_cleanup_and_delete(rootObj);

	return Plugin_Handled;
}