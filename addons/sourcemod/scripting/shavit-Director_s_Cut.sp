#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <shavit/core>
#include <shavit/replay-file>
#include <shavit/replay-playback>
#include <shavit/replay-stocks.sp>
#include <shavit/zones>


#undef REQUIRE_EXTENSIONS
#include <closestpos>
#if !defined CLOSESTPOS_EXTENDED
#define CLOSESTPOS_EXTENDED
#endif
#include <srcwr/floppy>

#pragma newdecls required
#pragma semicolon 1


#define DC_VERSION          "2.3-Ultimate"
#define DC_FILE_MAGIC       0x44435246
#define DC_FILE_VERSION     2


#define MAX_ENTITY_INDEX    4096


#define AFK_MIN_DURATION    1.5


#define AFK_TAIL_BUFFER     0.5

public Plugin myinfo =
{
    name        = "shavit - 导演剪辑版 (Director's Cut)",
    author      = "mangfu66",
    description = "",
    version     = "2.3",
    url         = "https://github.com/mangfu66/bhoptimer"
};


char gS_DirectorFolder[PLATFORM_MAX_PATH];
bool gB_Floppy = false;
bool gB_ClosestPos = false;
bool gB_ClosestPosExtended = false;


ArrayList g_aPendingQueue;
bool gB_IsProcessing = false;

StringMap g_smCutMarkers;
StringMap g_smStageBounds; // stage 边界帧索引，用于按 stage 汇总播报
ConVar g_cvDebug;
ConVar g_cvEndzoneProtect;
ConVar g_cvAfkThreshold;
ConVar g_cvStageRadiusXY;
ConVar g_cvStageRadiusZ;
ConVar g_cvTeleportDist;
ConVar g_cvFallbackRadiusXY;
ConVar g_cvFallbackRadiusZ;
ConVar g_cvMaxOps;
ConVar g_cvBacktrackScanDepth;
ConVar g_cvBacktrackScanStep;
ConVar g_cvBacktrackMinSpan;
ConVar g_cvBacktrackMinFrames;
ConVar g_cvBacktrackSpeed;
ConVar g_cvTailSpeed;
ConVar g_cvTailAngDelta;
ConVar g_cvAnchorDedup;
ConVar g_cvWhitelistDedup;
ConVar g_cvEscapeRadius;
ConVar g_cvBoxPadding;
ConVar g_cvNextScanDelay;
ConVar g_cvAfkMinDuration;
ConVar g_cvAfkTailBuffer;
ConVar g_cvAfkMinSpeed;
ConVar g_cvAirborneSpeed;
ConVar g_cvBouncePadSpeed;
ConVar g_cvHighSpeedFilter;
ConVar g_cvEscapeZ;
ConVar g_cvEscapeTime;
ConVar g_cvMaxVirtualAnchors;
ConVar g_cvRespawnScanLimit;
ConVar g_cvAfkScanStep;
ConVar g_cvVelWeight;
ConVar g_cvAngWeight;
ConVar g_cv8DScoreThreshold;
ConVar g_cvBlendFrames;
ConVar g_cvForceOldMode;


int g_TeleportDestinations[MAX_ENTITY_INDEX + 1] = {-1, ...};


ArrayList g_aStageEntryPositions[MAXPLAYERS + 1];


ArrayList g_aMapStageCache = null;
bool g_bMapStageCacheOrdered = false;


void GetNormalizedMapName(char[] buffer, int maxlength)
{
    GetCurrentMap(buffer, maxlength);
    GetMapDisplayName(buffer, buffer, maxlength);

    int len = strlen(buffer);
    for (int i = 0; i < len; i++)
        buffer[i] = CharToLower(buffer[i]);
}


void GetNormalizedSteamID(int client, char[] buffer, int maxlength)
{
    GetClientAuthId(client, AuthId_Steam2, buffer, maxlength);
    ReplaceString(buffer, maxlength, ":", "_");
}


public void OnPluginStart()
{
    g_cvDebug = CreateConVar("sm_dc_debug", "0", "1=开启控制台Debug播报, 0=关闭", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvEndzoneProtect = CreateConVar("sm_dc_endzone_protect", "3.0", "终点保护时长（秒），此范围内的瞬移不被剪辑", FCVAR_NONE, true, 1.0, true, 30.0);
    g_cvAfkThreshold = CreateConVar("sm_dc_afk_speed", "5.0", "低于此速度视为发呆（units/s）", FCVAR_NONE, true, 0.5, true, 20.0);
	g_cvStageRadiusXY = CreateConVar("sm_dc_stage_radius_xy", "280.0", "合法 stage 进站 XY 平面匹配半径", FCVAR_NONE, true, 100.0, true, 600.0);
	g_cvStageRadiusZ  = CreateConVar("sm_dc_stage_radius_z",  "900.0", "合法 stage 进站允许的最大 Z 高度差（掉很深时用）", FCVAR_NONE, true, 300.0, true, 1500.0);
	g_cvTeleportDist     = CreateConVar("sm_dc_teleport_dist",       "64.0",  "判定为瞬间传送的最小直线距离阈值（单位）", FCVAR_NONE, true, 10.0, true, 300.0);
	g_cvFallbackRadiusXY = CreateConVar("sm_dc_fallback_radius_xy",  "80.0",  "位置回退检测的XY平面容差半径（单位）", FCVAR_NONE, true, 10.0, true, 300.0);
	g_cvFallbackRadiusZ  = CreateConVar("sm_dc_fallback_radius_z",   "100.0", "位置回退检测的Z高度容差（单位）", FCVAR_NONE, true, 10.0, true, 500.0);
	g_cvMaxOps           = CreateConVar("sm_dc_max_ops",             "4000",  "每tick最大运算步数，越小sv越稳，越大剪辑越快", FCVAR_NONE, true, 200.0, true, 50000.0);
	g_cvBacktrackScanDepth = CreateConVar("sm_dc_bt_scan_depth",     "1200",  "位置回退检测往前扫多少帧（默认1200≈9秒，加强对弹跳板/长空中浮空失误的覆盖）", FCVAR_NONE, true, 64.0, true, 5000.0);
	g_cvBacktrackScanStep  = CreateConVar("sm_dc_bt_scan_step",      "2",     "位置回退扫描步长，1=逐帧精确，4=跳帧省CPU", FCVAR_NONE, true, 1.0, true, 16.0);
	g_cvBacktrackMinSpan   = CreateConVar("sm_dc_bt_min_span",       "64",    "位置回退触发所需最小历史跨度（帧），防原地起跳误剪", FCVAR_NONE, true, 16.0, true, 512.0);
	g_cvBacktrackMinFrames = CreateConVar("sm_dc_bt_min_frames",     "64",    "关卡内至少积累多少帧才开始位置回退检测", FCVAR_NONE, true, 16.0, true, 512.0);
	g_cvBacktrackSpeed     = CreateConVar("sm_dc_bt_speed",          "150.0", "位置回退落地速度阈值，低于此值才检测（units/s）", FCVAR_NONE, true, 10.0, true, 500.0);
	g_cvTailSpeed          = CreateConVar("sm_dc_tail_speed",        "5.0",   "末尾残帧清理速度阈值，低于此的帧视为站立废片（units/s）", FCVAR_NONE, true, 0.0, true, 50.0);
	g_cvTailAngDelta       = CreateConVar("sm_dc_tail_ang_delta",    "0.2",   "末尾残帧清理视角变化阈值（度/帧），超过则保留", FCVAR_NONE, true, 0.0, true, 10.0);
	g_cvAnchorDedup        = CreateConVar("sm_dc_anchor_dedup",      "72.0",  "自学习锚点去重半径（单位）", FCVAR_NONE, true, 10.0, true, 200.0);
	g_cvWhitelistDedup     = CreateConVar("sm_dc_whitelist_dedup",   "64.0",  "白名单生成时坐标去重半径（单位）", FCVAR_NONE, true, 10.0, true, 200.0);
	g_cvEscapeRadius       = CreateConVar("sm_dc_escape_radius",     "80.0",  "空间逃逸校验半径：中点帧必须超出此距离才判定为真实失误", FCVAR_NONE, true, 10.0, true, 500.0);
	g_cvBoxPadding         = CreateConVar("sm_dc_box_padding",       "16.0",  "包围盒判定膨胀余量（单位），补偿 tick 精度误差", FCVAR_NONE, true, 0.0, true, 64.0);
	g_cvNextScanDelay      = CreateConVar("sm_dc_next_scan_delay",   "16",    "位置回退命中后跳过多少帧再检测，防重复触发", FCVAR_NONE, true, 0.0, true, 128.0);
	g_cvAfkMinDuration     = CreateConVar("sm_dc_afk_min_duration", "1.5",   "AFK检测最小持续时间（秒），低于此时长不算挂机", FCVAR_NONE, true, 0.5, true, 10.0);
	g_cvAfkTailBuffer      = CreateConVar("sm_dc_afk_tail_buffer",  "0.5",   "AFK段末尾保留缓冲时间（秒），保留恢复运动前的过渡帧", FCVAR_NONE, true, 0.0, true, 3.0);
	g_cvAfkMinSpeed        = CreateConVar("sm_dc_afk_min_speed",    "15.0",  "AFK检测最低水平速度（units/s），低于此值且腾空也视为静止", FCVAR_NONE, true, 1.0, true, 50.0);
	g_cvAirborneSpeed      = CreateConVar("sm_dc_airborne_speed",   "50.0",  "空中运动判定速度（units/s），离地时超过此速度视为真实移动", FCVAR_NONE, true, 10.0, true, 200.0);
	g_cvBouncePadSpeed     = CreateConVar("sm_dc_bouncepad_speed",  "450.0", "弹跳板过滤速度（units/s），传送后速度超过此值拒绝建立锚点", FCVAR_NONE, true, 200.0, true, 1000.0);
	g_cvHighSpeedFilter    = CreateConVar("sm_dc_highspeed_filter", "280.0", "高速空中过滤（units/s），回退检测时跳过高速空中帧", FCVAR_NONE, true, 100.0, true, 600.0);
	g_cvEscapeZ            = CreateConVar("sm_dc_escape_z",         "150.0", "Z轴逃逸判定高度差（单位），超过此值视为真实逃离", FCVAR_NONE, true, 50.0, true, 500.0);
	g_cvEscapeTime         = CreateConVar("sm_dc_escape_time",      "2.5",   "时间强制逃逸（秒），超过此时间不管距离直接判定逃逸", FCVAR_NONE, true, 1.0, true, 10.0);
	g_cvMaxVirtualAnchors  = CreateConVar("sm_dc_max_virtual_anchors", "64", "最大虚拟锚点数量", FCVAR_NONE, true, 8.0, true, 256.0);
	g_cvRespawnScanLimit   = CreateConVar("sm_dc_respawn_scan_limit", "2000", "重生扫描最大运算次数", FCVAR_NONE, true, 500.0, true, 10000.0);
	g_cvAfkScanStep        = CreateConVar("sm_dc_afk_scan_step",    "33",    "AFK扫描初始步长（帧数）", FCVAR_NONE, true, 1.0, true, 128.0);
	g_cvVelWeight          = CreateConVar("sm_dc_vel_weight",       "0.03",  "6D/8D速度匹配权重", FCVAR_NONE, true, 0.001, true, 0.2);
	g_cvAngWeight          = CreateConVar("sm_dc_ang_weight",        "0.1",   "8D视角匹配权重", FCVAR_NONE, true, 0.001, true, 1.0);
	g_cv8DScoreThreshold   = CreateConVar("sm_dc_8d_score_threshold","400.0", "8D匹配分数阈值（距离²），低于此值才接受8D锚点", FCVAR_NONE, true, 10.0, true, 5000.0);
	g_cvBlendFrames        = CreateConVar("sm_dc_blend_frames",      "5",     "无缝拼接过渡帧数（0=禁用）", FCVAR_NONE, true, 0.0, true, 16.0);
	g_cvForceOldMode       = CreateConVar("sm_dc_midstage",          "0",     "0=启用8D精化+SeamlessSplice，1=原版行为", FCVAR_NONE, true, 0.0, true, 1.0);

    AutoExecConfig(true, "shavit-director-cut");

    RegConsoleCmd("sm_dc", Command_PlayDC, "观看我的导演剪辑版录像");
    RegConsoleCmd("sm_mycut", Command_PlayDC, "观看我的导演剪辑版录像");
    RegConsoleCmd("sm_deletedc", Command_DeleteDC, "删除录像");
    RegConsoleCmd("sm_removedc", Command_DeleteDC, "删除录像");
    RegConsoleCmd("sm_redc", Command_ReDC, "重新生成录像");
    RegConsoleCmd("sm_refine", Command_Refine, "对已有DC录像再次提纯剪辑");
    RegAdminCmd("sm_refreshstages", Command_RefreshStages, ADMFLAG_RCON, "强制刷新地图 Stage 缓存");

    BuildPath(Path_SM, gS_DirectorFolder, sizeof(gS_DirectorFolder), "data/replaybot/director_cut");
    if (!DirExists(gS_DirectorFolder))
        CreateDirectory(gS_DirectorFolder, 511);

    g_smCutMarkers = new StringMap();
    g_smStageBounds = new StringMap();
    g_aPendingQueue = new ArrayList();


    gB_Floppy = LibraryExists("srcwr") || LibraryExists("srcwr💾") || LibraryExists("SRCWRFloppy") || LibraryExists("SRCWR");
    if (gB_Floppy) PrintToServer("[DC] Floppy 扩展已检测到，将使用异步写入。");
    else PrintToServer("[DC] 未检测到 Floppy，将使用原生写入。");


    gB_ClosestPos = LibraryExists("closestpos");
    if (gB_ClosestPos) PrintToServer("[DC] ClosestPos 扩展已检测到，空间溯源将使用 KD-Tree 极速查找。");
    else PrintToServer("[DC] 未检测到 ClosestPos，空间溯源将使用原生线性扫描。");
#if defined CLOSESTPOS_EXTENDED
    if (gB_ClosestPos)
        gB_ClosestPosExtended = (GetFeatureStatus(FeatureType_Native, "ClosestPos8D.ClosestPos8D") == FeatureStatus_Available);
    if (gB_ClosestPosExtended) PrintToServer("[DC] ClosestPos 新版扩展已检测到，8D精化+SeamlessSplice 可用。");
#endif
}

void DebugPrint(const char[] format, any ...)
{
    if (g_cvDebug != null && g_cvDebug.BoolValue)
    {
        char buffer[512];
        VFormat(buffer, sizeof(buffer), format, 2);
        PrintToServer("[DC] %s", buffer);
    }
}

public void OnPluginEnd()
{

    if (g_smCutMarkers != null)
    {
        StringMapSnapshot snap = g_smCutMarkers.Snapshot();
        for (int i = 0; i < snap.Length; i++)
        {
            char key[64];
            snap.GetKey(i, key, sizeof(key));
            ArrayList list;
            if (g_smCutMarkers.GetValue(key, list)) delete list;
        }
        delete snap;
        delete g_smCutMarkers;
    }


    ClearPendingQueueSafely();
    delete g_aPendingQueue;


    if (g_aMapStageCache != null)
    {
        delete g_aMapStageCache;
        g_aMapStageCache = null;
    }
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "srcwr💾") || StrEqual(name, "srcwr") || StrEqual(name, "SRCWRFloppy") || StrEqual(name, "SRCWR"))
        gB_Floppy = true;
    if (StrEqual(name, "closestpos"))
    {
        gB_ClosestPos = true;
#if defined CLOSESTPOS_EXTENDED
        gB_ClosestPosExtended = (GetFeatureStatus(FeatureType_Native, "ClosestPos8D.ClosestPos8D") == FeatureStatus_Available);
#endif
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "srcwr💾") || StrEqual(name, "srcwr") || StrEqual(name, "SRCWRFloppy") || StrEqual(name, "SRCWR"))
        gB_Floppy = false;
    if (StrEqual(name, "closestpos"))
    {
        gB_ClosestPos = false;
        gB_ClosestPosExtended = false;
    }
}

public void OnMapStart()
{
    gB_IsProcessing = false;


    if (g_aPendingQueue != null)
        ClearPendingQueueSafely();

    char map[PLATFORM_MAX_PATH];
    GetNormalizedMapName(map, sizeof(map));

    char mapFolder[PLATFORM_MAX_PATH];
    FormatEx(mapFolder, sizeof(mapFolder), "%s/%s", gS_DirectorFolder, map);
    if (!DirExists(mapFolder)) CreateDirectory(mapFolder, 511);


    if (g_smCutMarkers != null)
    {
        StringMapSnapshot snap = g_smCutMarkers.Snapshot();
        for (int i = 0; i < snap.Length; i++)
        {
            char key[64];
            snap.GetKey(i, key, sizeof(key));
            ArrayList list;
            if (g_smCutMarkers.GetValue(key, list)) delete list;
        }
        delete snap;
        delete g_smCutMarkers;
        g_smCutMarkers = new StringMap();
    }

    if (g_smStageBounds != null)
    {
        StringMapSnapshot snap2 = g_smStageBounds.Snapshot();
        for (int i = 0; i < snap2.Length; i++)
        {
            char key[64];
            snap2.GetKey(i, key, sizeof(key));
            ArrayList list;
            if (g_smStageBounds.GetValue(key, list)) delete list;
        }
        delete snap2;
        delete g_smStageBounds;
        g_smStageBounds = new StringMap();
    }

    for (int i = 0; i <= MAX_ENTITY_INDEX; i++)
        g_TeleportDestinations[i] = -1;


    if (g_aMapStageCache != null)
    {
        delete g_aMapStageCache;
        g_aMapStageCache = null;
    }
    g_bMapStageCacheOrdered = false;
    g_aMapStageCache = LoadMapStageCache();
    if (g_aMapStageCache != null)
        DebugPrint("🗺️ 从磁盘加载了地图 Stage 缓存：%d 个点", g_aMapStageCache.Length);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_aStageEntryPositions[client] == null)
            g_aStageEntryPositions[client] = new ArrayList(3);
        else
            g_aStageEntryPositions[client].Clear();
    }

    FindAndMarkTeleportDestinations();
}

public void OnClientPutInServer(int client)
{
    if (g_aStageEntryPositions[client] == null)
        g_aStageEntryPositions[client] = new ArrayList(3);
}

public void OnClientDisconnect(int client)
{
	if (g_aStageEntryPositions[client] != null)
        g_aStageEntryPositions[client].Clear();
}

public Action Shavit_OnStart(int client, int track)
{
    if (g_aStageEntryPositions[client] != null)
        g_aStageEntryPositions[client].Clear();
    return Plugin_Continue;
}


stock void FormatTimeString(float time, char[] buffer, int maxlength)
{
    if (time < 0.0) time = 0.0;
    int hours = RoundToFloor(time / 3600.0);
    time -= float(hours) * 3600.0;
    int minutes = RoundToFloor(time / 60.0);
    float seconds = time - (float(minutes) * 60.0);
    if (hours > 0)
        Format(buffer, maxlength, "%d:%02d:%05.2f", hours, minutes, seconds);
    else
        Format(buffer, maxlength, "%02d:%05.2f", minutes, seconds);
}

stock float GetFrameSpeed2D(ArrayList frames, int index, float tickInterval)
{
    if (index <= 0 || index >= frames.Length) return 0.0;
    frame_t cur, prev;
    frames.GetArray(index, cur, sizeof(frame_t));
    frames.GetArray(index - 1, prev, sizeof(frame_t));
    float dx = cur.pos[0] - prev.pos[0];
    float dy = cur.pos[1] - prev.pos[1];
    return SquareRoot(dx * dx + dy * dy) / tickInterval;
}

stock float GetFrameSpeed3D(ArrayList frames, int index, float tickInterval)
{
    if (index <= 0 || index >= frames.Length) return 0.0;
    frame_t cur, prev;
    frames.GetArray(index, cur, sizeof(frame_t));
    frames.GetArray(index - 1, prev, sizeof(frame_t));
    float dx = cur.pos[0] - prev.pos[0];
    float dy = cur.pos[1] - prev.pos[1];
    float dz = cur.pos[2] - prev.pos[2];
    return SquareRoot(dx * dx + dy * dy + dz * dz) / tickInterval;
}

// 从帧数组中计算指定帧的 3D 速度矢量 (units/s)
stock void GetFrameVelocity3D(ArrayList frames, int index, float tickInterval, float vel[3])
{
    vel[0] = 0.0; vel[1] = 0.0; vel[2] = 0.0;
    if (index <= 0 || index >= frames.Length) return;
    frame_t cur, prev;
    frames.GetArray(index, cur, sizeof(frame_t));
    frames.GetArray(index - 1, prev, sizeof(frame_t));
    vel[0] = (cur.pos[0] - prev.pos[0]) / tickInterval;
    vel[1] = (cur.pos[1] - prev.pos[1]) / tickInterval;
    vel[2] = (cur.pos[2] - prev.pos[2]) / tickInterval;
}

stock float GetFrameAngularDelta(ArrayList frames, int index)
{
    if (index <= 0 || index >= frames.Length) return 0.0;
    frame_t cur, prev;
    frames.GetArray(index, cur, sizeof(frame_t));
    frames.GetArray(index - 1, prev, sizeof(frame_t));


    float dYaw = FloatAbs(cur.ang[1] - prev.ang[1]);
    if (dYaw > 180.0) dYaw = 360.0 - dYaw;


    float dPitch = FloatAbs(cur.ang[0] - prev.ang[0]);

    return dYaw + dPitch;
}


public Action Timer_DeleteMassiveArray(Handle timer, ArrayList arr)
{
    if (arr == null) return Plugin_Stop;
    int len = arr.Length;
    if (len > 20000)
    {
        arr.Resize(len - 20000);
        return Plugin_Continue;
    }
    delete arr;
    return Plugin_Stop;
}


void ClearPendingQueueSafely()
{
    if (g_aPendingQueue == null) return;

    for (int i = 0; i < g_aPendingQueue.Length; i++)
    {
        DataPack dp = view_as<DataPack>(g_aPendingQueue.Get(i));
        dp.Reset();


        dp.ReadCell(); dp.ReadCell(); dp.ReadCell(); dp.ReadFloat();
        dp.ReadCell(); dp.ReadCell(); dp.ReadCell();
        char dummy[128]; dp.ReadString(dummy, sizeof(dummy)); dp.ReadString(dummy, sizeof(dummy));


        ArrayList a1 = view_as<ArrayList>(dp.ReadCell()); if (a1 != null) delete a1;
        ArrayList a2 = view_as<ArrayList>(dp.ReadCell()); if (a2 != null) delete a2;
        ArrayList a3 = view_as<ArrayList>(dp.ReadCell()); if (a3 != null) delete a3;
        ArrayList a4 = view_as<ArrayList>(dp.ReadCell()); if (a4 != null) delete a4;
        ArrayList a5 = view_as<ArrayList>(dp.ReadCell()); if (a5 != null) delete a5;
        ArrayList a6 = view_as<ArrayList>(dp.ReadCell()); if (a6 != null) delete a6;

        delete dp;
    }
    g_aPendingQueue.Clear();
}


int TrimTailFrames(ArrayList cutFrames, int safeAnchor, float tickInterval, float speedThreshold, float angThreshold, int &opsCount)
{
    int newTail = cutFrames.Length - 1;
    while (newTail > safeAnchor)
    {
        opsCount++;
        float tSpeed = GetFrameSpeed2D(cutFrames, newTail, tickInterval);
        float tAngDelta = GetFrameAngularDelta(cutFrames, newTail);
        if (tSpeed < speedThreshold && tAngDelta < angThreshold)
            newTail--;
        else break;
    }
    int poppedFrames = 0;
    if (newTail < cutFrames.Length - 1)
    {
        poppedFrames = (cutFrames.Length - 1 - newTail);
        cutFrames.Resize(newTail + 1);
    }
    return poppedFrames;
}


void MergeCutMarkers(ArrayList cutMarkers, int loopStartIndex, int mergeRadius, int &accumulatedSkipped, int &localFalls, int &localAfks)
{
    for (int m = cutMarkers.Length - 1; m >= 0; m--)
    {
        int marker[5];
        cutMarkers.GetArray(m, marker, sizeof(marker));
        if (marker[0] >= loopStartIndex - mergeRadius)
        {
            accumulatedSkipped += marker[1];
            localFalls += marker[2];
            localAfks += marker[3];
            cutMarkers.Erase(m);
        }
    }
}


void EnqueueOrStart(DataPack dp, int client)
{
    if (!gB_IsProcessing)
    {
        gB_IsProcessing = true;
        Shavit_PrintToChat(client, "正在为您生成导演剪辑版录像，请稍候...");
        CreateTimer(0.01, Timer_ProcessCut, dp);
    }
    else
    {

        g_aPendingQueue.Push(dp);
        int queuePos = g_aPendingQueue.Length;
        Shavit_PrintToChat(client, "剪辑任务已排队，您前面还有 \x04%d\x01 个任务。", queuePos);
        DebugPrint("任务已排队，当前队列长度: %d", queuePos);
    }
}

void TryProcessNext()
{
    gB_IsProcessing = false;

    if (g_aPendingQueue != null && g_aPendingQueue.Length > 0)
    {
        DataPack nextDp = view_as<DataPack>(g_aPendingQueue.Get(0));
        g_aPendingQueue.Erase(0);
        gB_IsProcessing = true;


        nextDp.Reset();
        int serial = nextDp.ReadCell();
        int client = GetClientFromSerial(serial);
        if (client > 0 && IsClientInGame(client))
            Shavit_PrintToChat(client, "轮到您了，正在极速处理导演剪辑...");

        CreateTimer(0.01, Timer_ProcessCut, nextDp);
    }
}


ArrayList LoadStagePositions(const char[] steamID, const char[] map, int style, int track)
{
    char filePath[PLATFORM_MAX_PATH];
    FormatEx(filePath, sizeof(filePath), "%s/%s/%s_style%d_track%d.stages", gS_DirectorFolder, map, steamID, style, track);

    if (!FileExists(filePath)) return null;

    File file = OpenFile(filePath, "rb");
    if (file == null) return null;

    int count;
    file.ReadInt32(count);
    if (count <= 0 || count > 10000)
    {
        delete file;
        return null;
    }

    ArrayList positions = new ArrayList(3);
    for (int i = 0; i < count; i++)
    {
        float pos[3];
        if (file.Read(pos, 3, 4) != 3) break;
        positions.PushArray(pos);
    }
    delete file;
    return positions;
}


void SaveMapStageCache(ArrayList positions, bool ordered = false)
{
    if (positions == null || positions.Length == 0) return;

    char map[PLATFORM_MAX_PATH];
    GetNormalizedMapName(map, sizeof(map));

    char filePath[PLATFORM_MAX_PATH];
    if (ordered)
        FormatEx(filePath, sizeof(filePath), "%s/%s/_map_stages_ordered.cache", gS_DirectorFolder, map);
    else
        FormatEx(filePath, sizeof(filePath), "%s/%s/_map_stages.cache", gS_DirectorFolder, map);

    File file = OpenFile(filePath, "wb+");
    if (file != null)
    {
        int count = positions.Length;
        int blocksize = positions.BlockSize; // 3 or 9
        file.WriteInt32(count);
        file.WriteInt32(blocksize);
        for (int i = 0; i < count; i++)
        {
            float data[9];
            positions.GetArray(i, data);
            file.Write(data, blocksize, 4);
        }
        delete file;
        DebugPrint("💾 地图 Stage 缓存已保存：%d 个点 (blocksize=%d) -> %s", count, blocksize, filePath);
    }
}

ArrayList LoadMapStageCache()
{
    char map[PLATFORM_MAX_PATH];
    GetNormalizedMapName(map, sizeof(map));

    char filePath[PLATFORM_MAX_PATH];
    // Priority: touch (player finish) > ordered (replay) > normal (nearest-neighbor)
    char touchPath[PLATFORM_MAX_PATH];
    FormatEx(touchPath, sizeof(touchPath), "%s/%s/_map_stages_touch.cache", gS_DirectorFolder, map);
    char orderedPath[PLATFORM_MAX_PATH];
    FormatEx(orderedPath, sizeof(orderedPath), "%s/%s/_map_stages_ordered.cache", gS_DirectorFolder, map);

    if (FileExists(touchPath))
    {
        filePath = touchPath;
        g_bMapStageCacheOrdered = true;
    }
    else if (FileExists(orderedPath))
    {
        filePath = orderedPath;
        g_bMapStageCacheOrdered = true;
    }
    else
    {
        FormatEx(filePath, sizeof(filePath), "%s/%s/_map_stages.cache", gS_DirectorFolder, map);
        g_bMapStageCacheOrdered = false;
    }

    if (!FileExists(filePath)) return null;

    File file = OpenFile(filePath, "rb");
    if (file == null) return null;

    int count;
    file.ReadInt32(count);
    if (count <= 0 || count > 10000)
    {
        delete file;
        return null;
    }

    // New format has blocksize header; old format doesn't
    int blocksize = 3;
    int readBlock;
    if (file.ReadInt32(readBlock) && (readBlock == 3 || readBlock == 9))
    {
        blocksize = readBlock;
    }
    else
    {
        file.Seek(4, SEEK_SET);
    }

    ArrayList positions = new ArrayList(blocksize);
    for (int i = 0; i < count; i++)
    {
        float data[9];
        if (file.Read(data, blocksize, 4) != blocksize) break;
        positions.PushArray(data);
    }
    delete file;
    return positions;
}

void RegenerateStageCache()
{
    // Collect teleport destinations with trigger bounding boxes
    ArrayList autoCache = new ArrayList(9); // [0-2]=destPos, [3-5]=triggerMins, [6-8]=triggerMaxs
    int maxEnts = GetMaxEntities();
    if (maxEnts > MAX_ENTITY_INDEX) maxEnts = MAX_ENTITY_INDEX;
    for (int e = MaxClients; e < maxEnts; e++)
    {
        if (g_TeleportDestinations[e] == -1) continue;
        int destE = g_TeleportDestinations[e];
        if (!IsValidEntity(destE)) continue;
        float dPos[3];
        GetEntPropVector(destE, Prop_Data, "m_vecAbsOrigin", dPos);

        bool dup = false;
        for (int d = 0; d < autoCache.Length; d++)
        {
            float ex[9]; autoCache.GetArray(d, ex);
            float exPos[3]; exPos[0] = ex[0]; exPos[1] = ex[1]; exPos[2] = ex[2];
            if (GetVectorDistance(dPos, exPos) < g_cvWhitelistDedup.FloatValue) { dup = true; break; }
        }
        if (!dup)
        {
            float entry[9];
            entry[0] = dPos[0]; entry[1] = dPos[1]; entry[2] = dPos[2];
            // Store trigger_teleport's world-space bounding box
            float origin[3], mins[3], maxs[3];
            GetEntPropVector(e, Prop_Send, "m_vecOrigin", origin);
            GetEntPropVector(e, Prop_Send, "m_vecMins", mins);
            GetEntPropVector(e, Prop_Send, "m_vecMaxs", maxs);
            entry[3] = origin[0] + mins[0]; entry[4] = origin[1] + mins[1]; entry[5] = origin[2] + mins[2];
            entry[6] = origin[0] + maxs[0]; entry[7] = origin[1] + maxs[1]; entry[8] = origin[2] + maxs[2];
            autoCache.PushArray(entry);
        }
    }

    if (autoCache.Length > 0)
    {
        ArrayList ordered = SortStagesByNearestNeighbor(autoCache);
        delete autoCache;

        char map[PLATFORM_MAX_PATH];
        GetNormalizedMapName(map, sizeof(map));
        char path[PLATFORM_MAX_PATH];
        FormatEx(path, sizeof(path), "%s/%s/_map_stages.cache", gS_DirectorFolder, map);
        if (FileExists(path)) DeleteFile(path);
        FormatEx(path, sizeof(path), "%s/%s/_map_stages_ordered.cache", gS_DirectorFolder, map);
        if (FileExists(path)) DeleteFile(path);
        FormatEx(path, sizeof(path), "%s/%s/_map_stages_touch.cache", gS_DirectorFolder, map);
        if (FileExists(path)) DeleteFile(path);

        SaveMapStageCache(ordered, false);
        if (g_aMapStageCache != null) delete g_aMapStageCache;
        g_aMapStageCache = ordered;
        DebugPrint("🔄 Stage 缓存已刷新（已排序）：%d 个传送目的地", ordered.Length);
    }
    else
    {
        delete autoCache;
        DebugPrint("🔄 Stage 缓存刷新失败：未找到传送目的地");
    }
}

public Action Command_RefreshStages(int client, int args)
{
    RegenerateStageCache();
    if (client > 0)
        Shavit_PrintToChat(client, "Stage 缓存已刷新，共 %d 个点", g_aMapStageCache != null ? g_aMapStageCache.Length : 0);
    else
        PrintToServer("[DC] Stage 缓存已刷新，共 %d 个点", g_aMapStageCache != null ? g_aMapStageCache.Length : 0);
    return Plugin_Handled;
}

public void Shavit_OnZonesLoaded()
{
    // 每次都重新扫描实体，与磁盘缓存对比，数量不一致则更新
    bool hasTeleports = false;
    int maxEnts = GetMaxEntities();
    if (maxEnts > MAX_ENTITY_INDEX) maxEnts = MAX_ENTITY_INDEX;
    for (int e = MaxClients; e < maxEnts; e++)
    {
        if (g_TeleportDestinations[e] != -1) { hasTeleports = true; break; }
    }

    if (hasTeleports)
    {
        int oldCount = (g_aMapStageCache != null) ? g_aMapStageCache.Length : 0;
        RegenerateStageCache();
        int newCount = (g_aMapStageCache != null) ? g_aMapStageCache.Length : 0;
        if (oldCount != newCount)
            DebugPrint("🔄 Stage 缓存已自动更新：%d → %d 个点", oldCount, newCount);
    }
}

public void Shavit_OnReplaysLoaded()
{
    // WR replay loaded — trace through frames to determine actual stage order
    OrderStagesByReplay();
}

void OrderStagesByReplay()
{
    // Collect all teleport destinations with trigger bounding boxes
    ArrayList destPositions = new ArrayList(9);
    int maxEnts = GetMaxEntities();
    if (maxEnts > MAX_ENTITY_INDEX) maxEnts = MAX_ENTITY_INDEX;
    for (int e = MaxClients; e < maxEnts; e++)
    {
        if (g_TeleportDestinations[e] == -1) continue;
        int destE = g_TeleportDestinations[e];
        if (!IsValidEntity(destE)) continue;
        float dPos[3];
        GetEntPropVector(destE, Prop_Data, "m_vecAbsOrigin", dPos);

        bool dup = false;
        for (int d = 0; d < destPositions.Length; d++)
        {
            float ex[9]; destPositions.GetArray(d, ex);
            float exPos[3]; exPos[0] = ex[0]; exPos[1] = ex[1]; exPos[2] = ex[2];
            if (GetVectorDistance(dPos, exPos) < g_cvWhitelistDedup.FloatValue) { dup = true; break; }
        }
        if (!dup)
        {
            float entry[9];
            entry[0] = dPos[0]; entry[1] = dPos[1]; entry[2] = dPos[2];
            float origin[3], mins[3], maxs[3];
            GetEntPropVector(e, Prop_Send, "m_vecOrigin", origin);
            GetEntPropVector(e, Prop_Send, "m_vecMins", mins);
            GetEntPropVector(e, Prop_Send, "m_vecMaxs", maxs);
            entry[3] = origin[0] + mins[0]; entry[4] = origin[1] + mins[1]; entry[5] = origin[2] + mins[2];
            entry[6] = origin[0] + maxs[0]; entry[7] = origin[1] + maxs[1]; entry[8] = origin[2] + maxs[2];
            destPositions.PushArray(entry);
        }
    }

    if (destPositions.Length == 0)
    {
        delete destPositions;
        return;
    }

    // Get WR replay frames (style 0, main track)
    ArrayList frames = Shavit_GetReplayFrames(0, Track_Main, false);
    if (frames == null || frames.Length == 0)
    {
        delete destPositions;
        delete frames;
        return;
    }

    float threshold = g_cvWhitelistDedup.FloatValue;
    float tpDist = g_cvTeleportDist.FloatValue;

    // 预扫描：从 replay 帧中学习传送目的地，补充实体扫描可能遗漏的 stage 点
    int learnedCount = 0;
    for (int f = 1; f < frames.Length; f++)
    {
        frame_t cur, prev;
        frames.GetArray(f, cur, sizeof(frame_t));
        frames.GetArray(f - 1, prev, sizeof(frame_t));

        if (GetVectorDistance(cur.pos, prev.pos, false) > tpDist)
        {
            // 检测到传送事件，cur.pos 是传送目的地
            bool dup = false;
            for (int d = 0; d < destPositions.Length; d++)
            {
                float ex[9]; destPositions.GetArray(d, ex);
                float exPos[3]; exPos[0] = ex[0]; exPos[1] = ex[1]; exPos[2] = ex[2];
                if (GetVectorDistance(cur.pos, exPos) < threshold) { dup = true; break; }
            }
            if (!dup)
            {
                float newEntry[9];
                newEntry[0] = cur.pos[0]; newEntry[1] = cur.pos[1]; newEntry[2] = cur.pos[2];
                // 没有 trigger 盒子数据，留零（运行时会 fallback 到圆柱体检测）
                destPositions.PushArray(newEntry);
                learnedCount++;
            }
        }
    }
    if (learnedCount > 0)
        DebugPrint("🎓 从 replay 中学习到 %d 个新传送目的地", learnedCount);

    int destCount = destPositions.Length;
    bool[] visited = new bool[destCount];
    ArrayList ordered = new ArrayList(9);

    // Walk through replay frames, record first encounter with each destination
    for (int f = 0; f < frames.Length; f++)
    {
        frame_t frame;
        frames.GetArray(f, frame, sizeof(frame_t));

        for (int d = 0; d < destCount; d++)
        {
            if (visited[d]) continue;
            float entry[9];
            destPositions.GetArray(d, entry);
            float entryPos[3]; entryPos[0] = entry[0]; entryPos[1] = entry[1]; entryPos[2] = entry[2];

            float dist = GetVectorDistance(frame.pos, entryPos);
            if (dist < threshold)
            {
                visited[d] = true;
                ordered.PushArray(entry);
                break;
            }
        }

        // All destinations found
        if (ordered.Length >= destCount) break;
    }

    delete frames;

    // replay 没经过的 stage 追加到末尾，保证不丢失
    for (int d = 0; d < destCount; d++)
    {
        if (!visited[d])
        {
            float entry[9];
            destPositions.GetArray(d, entry);
            ordered.PushArray(entry);
        }
    }

    delete destPositions;

    if (ordered.Length > 0)
    {
        char map[PLATFORM_MAX_PATH];
        GetNormalizedMapName(map, sizeof(map));
        char path[PLATFORM_MAX_PATH];
        FormatEx(path, sizeof(path), "%s/%s/_map_stages_ordered.cache", gS_DirectorFolder, map);
        if (FileExists(path)) DeleteFile(path);

        SaveMapStageCache(ordered, true);

        if (g_aMapStageCache != null) delete g_aMapStageCache;
        g_aMapStageCache = ordered;
        g_bMapStageCacheOrdered = true;
        DebugPrint("🎬 回放路径排序完成：%d 个 Stage 点 -> _map_stages_ordered.cache", ordered.Length);
    }
    else
    {
        delete ordered;
        DebugPrint("🎬 回放路径排序失败：回放未经过任何传送目的地");
    }
}


public int Sort_StageAscending(int index1, int index2, Handle array, Handle hndl)
{
    float item1[10], item2[10];
    view_as<ArrayList>(array).GetArray(index1, item1);
    view_as<ArrayList>(array).GetArray(index2, item2);

    if (item1[3] > item2[3]) return 1;
    if (item1[3] < item2[3]) return -1;
    return 0;
}

ArrayList GetShavitZoneStages(int track)
{
    int zoneCount = Shavit_GetZoneCount();
    if (zoneCount <= 0) return null;


    ArrayList tempArray = new ArrayList(10); // [0-2]=dest, [3]=stageNum, [4-6]=corner1, [7-9]=corner2

    for (int i = 0; i < zoneCount; i++)
    {
        zone_cache_t zone;
        Shavit_GetZone(i, zone);

        if (zone.iTrack == track && zone.iType == Zone_Stage)
        {
            float entry[10];
            entry[0] = zone.fDestination[0];
            entry[1] = zone.fDestination[1];
            entry[2] = zone.fDestination[2];
            entry[3] = float(zone.iData);
            entry[4] = zone.fCorner1[0];
            entry[5] = zone.fCorner1[1];
            entry[6] = zone.fCorner1[2];
            entry[7] = zone.fCorner2[0];
            entry[8] = zone.fCorner2[1];
            entry[9] = zone.fCorner2[2];
            tempArray.PushArray(entry);
        }
    }

    if (tempArray.Length == 0)
    {
        delete tempArray;
        return null;
    }


    tempArray.SortCustom(Sort_StageAscending);


    // Output format: float[9] = pos[3] + corner1[3] + corner2[3]
    ArrayList finalStages = new ArrayList(9);
    for (int i = 0; i < tempArray.Length; i++)
    {
        float entry[10];
        tempArray.GetArray(i, entry);

        float out[9];
        out[0] = entry[0]; out[1] = entry[1]; out[2] = entry[2]; // destination
        out[3] = entry[4]; out[4] = entry[5]; out[5] = entry[6]; // corner1
        out[6] = entry[7]; out[7] = entry[8]; out[8] = entry[9]; // corner2
        finalStages.PushArray(out);
    }

    delete tempArray;
    return finalStages;
}


ArrayList GetBestStagePositions(int client, const char[] steamID, const char[] map, int style, int track, bool &outOrdered = false)
{

    ArrayList zoneStages = GetShavitZoneStages(track);
    if (zoneStages != null && zoneStages.Length > 0)
    {
        DebugPrint("Stage 数据源：Shavit 原生 Zone 系统（%d 个点，绝对有序，含包围盒）", zoneStages.Length);
        outOrdered = true;
        return zoneStages;
    }
    if (zoneStages != null) delete zoneStages;


    if (g_aMapStageCache != null && g_aMapStageCache.Length > 0)
    {
        DebugPrint("Stage 数据源：地图级缓存（%d 个点）", g_aMapStageCache.Length);
        outOrdered = g_bMapStageCacheOrdered;
        return ExpandToStageFormat(g_aMapStageCache);
    }


    ArrayList personal = LoadStagePositions(steamID, map, style, track);
    if (personal != null && personal.Length > 0)
    {

        char stagesCleanPath[PLATFORM_MAX_PATH];
        FormatEx(stagesCleanPath, sizeof(stagesCleanPath), "%s/%s/%s_style%d_track%d.stages", gS_DirectorFolder, map, steamID, style, track);
        if (FileExists(stagesCleanPath)) DeleteFile(stagesCleanPath);

        DebugPrint("Stage 数据源：个人 .stages 文件（%d 个点，已清理磁盘文件）", personal.Length);
        outOrdered = true;
        ArrayList result = ExpandToStageFormat(personal);
        delete personal;
        return result;
    }
    if (personal != null) delete personal;


    if (client > 0 && client <= MaxClients && g_aStageEntryPositions[client] != null && g_aStageEntryPositions[client].Length > 0)
    {
        DebugPrint("Stage 数据源：玩家内存 Touch 记录（%d 个点）", g_aStageEntryPositions[client].Length);
        outOrdered = true;
        return ExpandToStageFormat(g_aStageEntryPositions[client]);
    }

    DebugPrint("Stage 数据源：无可用数据");
    return new ArrayList(9);
}

// Convert ArrayList(3) of float[3] positions to ArrayList(9) of float[9] with zero box data
ArrayList ExpandToStageFormat(ArrayList positions)
{
    ArrayList result = new ArrayList(9);
    for (int i = 0; i < positions.Length; i++)
    {
        float pos[3];
        positions.GetArray(i, pos);
        float entry[9];
        entry[0] = pos[0]; entry[1] = pos[1]; entry[2] = pos[2];
        // [3-8] = 0.0 (no box data)
        result.PushArray(entry);
    }
    return result;
}


public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp)
{
    if (client < 1 || client > MaxClients || IsFakeClient(client)) return;
    if (g_aStageEntryPositions[client] == null || g_aStageEntryPositions[client].Length == 0) return;

    int newCount = g_aStageEntryPositions[client].Length;
    int oldCount = (g_aMapStageCache != null) ? g_aMapStageCache.Length : 0;


    if (newCount > oldCount)
    {
        if (g_aMapStageCache != null)
            delete g_aMapStageCache;
        g_aMapStageCache = g_aStageEntryPositions[client].Clone();

        // Save as touch cache (not ordered — that's reserved for replay-based)
        char map[PLATFORM_MAX_PATH];
        GetNormalizedMapName(map, sizeof(map));
        char touchPath[PLATFORM_MAX_PATH];
        FormatEx(touchPath, sizeof(touchPath), "%s/%s/_map_stages_touch.cache", gS_DirectorFolder, map);

        File file = OpenFile(touchPath, "wb+");
        if (file != null)
        {
            file.WriteInt32(newCount);
            file.WriteInt32(3); // blocksize 头，与 LoadMapStageCache 读取格式对齐
            for (int i = 0; i < newCount; i++)
            {
                float pos[3];
                g_aMapStageCache.GetArray(i, pos);
                file.Write(pos, 3, 4);
            }
            delete file;
        }
        g_bMapStageCacheOrdered = true;
        DebugPrint("🏁 玩家通关！Stage 缓存已更新：%d → %d 个点 -> _map_stages_touch.cache", oldCount, newCount);
    }
    else
    {
        DebugPrint("🏁 玩家通关，Stage 缓存无需更新（现有 %d >= 新 %d）", oldCount, newCount);
    }
}


public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, ArrayList replaypaths, ArrayList frames, int preframes, int postframes, const char[] name)
{
    if (frames == null || frames.Length == 0 || istoolong) return;
    if (!isbestreplay) return;

    char map[PLATFORM_MAX_PATH];
    GetNormalizedMapName(map, sizeof(map));

    char steamID[32];
    GetNormalizedSteamID(client, steamID, sizeof(steamID));

    // Clean up any leftover personal .stages file
    char stagesPath[PLATFORM_MAX_PATH];
    FormatEx(stagesPath, sizeof(stagesPath), "%s/%s/%s_style%d_track%d.stages", gS_DirectorFolder, map, steamID, style, track);
    if (FileExists(stagesPath)) DeleteFile(stagesPath);

    // No longer auto-start clipping — prompt player to use sm_redc manually
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
    {
        Shavit_PrintToChat(client, "输入 \x04!redc\x01 生成导演剪辑版录像");
    }
}


public void Shavit_OnPersonalReplaySaved(int client, int style, int track, const char[] path)
{
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
    {
        Shavit_PrintToChat(client, "输入 \x04!redc\x01 生成导演剪辑版录像");
    }
}


public Action Command_Refine(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;
    int style = Shavit_GetBhopStyle(client);
    int track = Shavit_GetClientTrack(client);
    int accountId = GetSteamAccountID(client);
    char map[PLATFORM_MAX_PATH];
    GetNormalizedMapName(map, sizeof(map));
    char steamID[32];
    GetNormalizedSteamID(client, steamID, sizeof(steamID));
    char mapFolder[PLATFORM_MAX_PATH];
    FormatEx(mapFolder, sizeof(mapFolder), "%s/%s", gS_DirectorFolder, map);
    char recPath[PLATFORM_MAX_PATH];
    FormatEx(recPath, sizeof(recPath), "%s/%s_style%d_track%d.replay", mapFolder, steamID, style, track);
    if (!FileExists(recPath))
    {
        Shavit_PrintToChat(client, "未找到已有DC录像，请先使用 !redc 生成录像。");
        return Plugin_Handled;
    }
    Shavit_PrintToChat(client, "开始对DC录像进行二次提纯剪辑...");
    StartReDCProcess(client, recPath, style, track, map, accountId, true);
    return Plugin_Handled;
}

public Action Command_ReDC(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    DebugPrint("-----------------------------------------");
    DebugPrint("玩家触发 !redc 命令");

    int style = Shavit_GetBhopStyle(client);
    int track = Shavit_GetClientTrack(client);
    int accountId = GetSteamAccountID(client);

    char map[PLATFORM_MAX_PATH];
    GetNormalizedMapName(map, sizeof(map));

    char replayFolder[PLATFORM_MAX_PATH];
    Shavit_GetReplayFolderPath_Stock(replayFolder);

    char myReplayPath[PLATFORM_MAX_PATH];
    char wrPath[PLATFORM_MAX_PATH];

    FormatEx(myReplayPath, sizeof(myReplayPath), "%s/copy/%d_%s.replay", replayFolder, accountId, map);
    FormatEx(wrPath, sizeof(wrPath), "%s/%d/%s.replay", replayFolder, track, map);

    DebugPrint("寻找 MyReplay 路径: %s", myReplayPath);
    DebugPrint("寻找 WR 路径: %s", wrPath);

    bool hasMyReplay = FileExists(myReplayPath);
    bool hasWR = false;
    if (FileExists(wrPath))
    {
        replay_header_t h;
        File f = ReadReplayHeader(wrPath, h);
        if (f != null)
        {
            if (h.iSteamID == accountId) hasWR = true;
            delete f;
        }
    }

    if (!hasMyReplay && !hasWR)
    {
        DebugPrint("未找到任何符合的录像文件。");
        Shavit_PrintToChat(client, "未找到属于您的完整录像。");
        return Plugin_Handled;
    }

    if (hasMyReplay && !hasWR)
    {
        DebugPrint("自动选择 MyReplay 进行剪辑");
        StartReDCProcess(client, myReplayPath, style, track, map, accountId);
        return Plugin_Handled;
    }
    if (!hasMyReplay && hasWR)
    {
        DebugPrint("自动选择 WR 进行剪辑");
        StartReDCProcess(client, wrPath, style, track, map, accountId);
        return Plugin_Handled;
    }

    Menu menu = new Menu(MenuHandler_ReDC_Choice);
    menu.SetTitle("导演剪辑版 - 请选择录像源\n ");
    menu.AddItem(myReplayPath, "剪辑 MyReplay 存档");
    menu.AddItem(wrPath, "剪辑 最佳成绩 (WR/PB)");
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int MenuHandler_ReDC_Choice(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End) delete menu;
    else if (action == MenuAction_Select)
    {
        char targetPath[PLATFORM_MAX_PATH];
        menu.GetItem(param2, targetPath, sizeof(targetPath));
        int style = Shavit_GetBhopStyle(param1);
        int track = Shavit_GetClientTrack(param1);
        int accountId = GetSteamAccountID(param1);

        char map[PLATFORM_MAX_PATH];
        GetNormalizedMapName(map, sizeof(map));

        DebugPrint("玩家从菜单选择了路径: %s", targetPath);
        StartReDCProcess(param1, targetPath, style, track, map, accountId);
    }
    return 0;
}


void StartReDCProcess(int client, const char[] path, int style, int track, const char[] map, int accountId, bool isRefine = false)
{
    DebugPrint("使用官方 LoadReplayCache 安全读取录像...");

    frame_cache_t cache;
    bool loadResult = LoadReplayCache(cache, style, track, path, map);

    if (!loadResult || cache.aFrames == null || cache.aFrames.Length <= 0)
    {
        Shavit_PrintToChat(client, "无法读取录像文件或文件已损坏！");
        DebugPrint("LoadReplayCache 失败！");
        if (cache.aFrames != null) delete cache.aFrames;
        return;
    }

    int preFrames = cache.iPreFrames < 0 ? 0 : cache.iPreFrames;
    int postFrames = cache.iPostFrames;
    float fTime = cache.fTime;

    DebugPrint("LoadReplayCache 成功，总帧数: %d, time=%.3f", cache.aFrames.Length, fTime);

    char steamID[32];
    GetNormalizedSteamID(client, steamID, sizeof(steamID));

    ArrayList cutFrames = new ArrayList(sizeof(frame_t));
    ArrayList cutMarkers = new ArrayList(5);
    ArrayList stageBounds = new ArrayList(); // stage 边界帧索引

    DataPack cutDp = new DataPack();
    cutDp.WriteCell(GetClientSerial(client));
    cutDp.WriteCell(style);
    cutDp.WriteCell(track);
    cutDp.WriteFloat(fTime);
    cutDp.WriteCell(preFrames);
    cutDp.WriteCell(postFrames);
    cutDp.WriteCell(accountId);
    cutDp.WriteString(steamID);
    cutDp.WriteString(map);
    cutDp.WriteCell(cache.aFrames);
    cutDp.WriteCell(cutFrames);
    cutDp.WriteCell(cutMarkers);
    cutDp.WriteCell(stageBounds);


    bool stagesOrdered2 = false;
    ArrayList validTransitions = GetBestStagePositions(client, steamID, map, style, track, stagesOrdered2);

    cutDp.WriteCell(validTransitions);
	ArrayList aVirtualAnchors = new ArrayList(3);
	cutDp.WriteCell(aVirtualAnchors);
	ArrayList visitedStagePos = new ArrayList(4);
	cutDp.WriteCell(visitedStagePos);
    cutDp.WriteCell(0);
    cutDp.WriteCell(0);
    cutDp.WriteCell(0);
    cutDp.WriteFloat(0.0);
    cutDp.WriteFloat(0.0);
    cutDp.WriteCell(0);
    cutDp.WriteCell(0);
    cutDp.WriteCell(stagesOrdered2);

    cutDp.WriteFloat(280.0);
    cutDp.WriteFloat(900.0);
	cutDp.WriteCell(isRefine);

    DebugPrint("将数组移交至 C++ 切片计算引擎...");
    EnqueueOrStart(cutDp, client);
}


public Action Timer_ProcessCut(Handle timer, DataPack dp)
{
    dp.Reset();
    int serial     = dp.ReadCell();
    int style      = dp.ReadCell();
    int track      = dp.ReadCell();
    float time     = dp.ReadFloat();
    int preframes  = dp.ReadCell();
    int postframes = dp.ReadCell();
    int accountId  = dp.ReadCell();

    char steamID[32], map[PLATFORM_MAX_PATH];
    dp.ReadString(steamID, sizeof(steamID));
    dp.ReadString(map, sizeof(map));

    ArrayList clonedFrames           = view_as<ArrayList>(dp.ReadCell());
    ArrayList cutFrames              = view_as<ArrayList>(dp.ReadCell());
    ArrayList cutMarkers             = view_as<ArrayList>(dp.ReadCell());
    ArrayList stageBounds            = view_as<ArrayList>(dp.ReadCell());
    ArrayList clonedValidTransitions = view_as<ArrayList>(dp.ReadCell());
	ArrayList aVirtualAnchors = view_as<ArrayList>(dp.ReadCell());
	ArrayList visitedStagePos = view_as<ArrayList>(dp.ReadCell());

    int i                    = dp.ReadCell();
    int fallsCut             = dp.ReadCell();
    int afksCut              = dp.ReadCell();
    float totalCutSeconds    = dp.ReadFloat();
    float maxSingleCut       = dp.ReadFloat();
    int currentSafeAnchor    = dp.ReadCell();
    int nextExpectedStageIndex = dp.ReadCell();
    bool stagesOrdered = view_as<bool>(dp.ReadCell());


    float dynamicRadiusXY = dp.ReadFloat();
    float dynamicRadiusZ  = dp.ReadFloat();
	bool isRefine = view_as<bool>(dp.ReadCell());
	delete dp;


	float tpThreshold    = g_cvTeleportDist.FloatValue;
	float fbRadXY        = g_cvFallbackRadiusXY.FloatValue;
	float fbRadXYSq      = fbRadXY * fbRadXY;
	float fbRadZ         = g_cvFallbackRadiusZ.FloatValue;
	int   maxOps         = g_cvMaxOps.IntValue;
	int   btScanDepth    = g_cvBacktrackScanDepth.IntValue;
	int   btScanStep     = g_cvBacktrackScanStep.IntValue;
	int   btMinSpan      = g_cvBacktrackMinSpan.IntValue;
	int   btMinFrames    = g_cvBacktrackMinFrames.IntValue;
	float btSpeed        = g_cvBacktrackSpeed.FloatValue;
	float cvTailSpeed    = g_cvTailSpeed.FloatValue;
	float cvTailAngDelta = g_cvTailAngDelta.FloatValue;
	float anchorDedup    = g_cvAnchorDedup.FloatValue;
	float escapeRadius   = g_cvEscapeRadius.FloatValue;
	float escapeRadiusSq = escapeRadius * escapeRadius;
	int   nextScanDelay  = g_cvNextScanDelay.IntValue;

    int totalFrames = clonedFrames.Length;
    float tickInterval = GetTickInterval();


    if (i == 0)
    {
        ConVar cvGravity = FindConVar("sv_gravity");
        float mapGravity = (cvGravity != null) ? cvGravity.FloatValue : 800.0;
        float gravityMult = 800.0 / mapGravity;

        float totalSpeed = 0.0;
        int activeCount = 0;
        for (int s = 0; s < totalFrames; s += 10)
        {
            float spd = GetFrameSpeed2D(clonedFrames, s, tickInterval);
            if (spd > 120.0)
            {
                totalSpeed += spd;
                activeCount++;
            }
        }
        float avgActiveSpeed = (activeCount > 0) ? (totalSpeed / activeCount) : 250.0;

        dynamicRadiusXY = g_cvStageRadiusXY.FloatValue * (avgActiveSpeed / 250.0);
        if (dynamicRadiusXY < 200.0) dynamicRadiusXY = 200.0;
        if (dynamicRadiusXY > 420.0) dynamicRadiusXY = 420.0;

        dynamicRadiusZ = g_cvStageRadiusZ.FloatValue * gravityMult;
        if (dynamicRadiusZ > 1500.0) dynamicRadiusZ = 1500.0;

        DebugPrint("[环境自适应] 平均速度 %.1f | 重力倍率 %.2f → XY=%.1f | Z=%.1f",
            avgActiveSpeed, gravityMult, dynamicRadiusXY, dynamicRadiusZ);
    }


    int protectedFrames = preframes + RoundToFloor(2.0 / tickInterval);
    int activeEndFrame = totalFrames - postframes;
    if (activeEndFrame <= protectedFrames) activeEndFrame = totalFrames;

    int endzoneProtectFrames = RoundToFloor(g_cvEndzoneProtect.FloatValue / tickInterval);
    int afkProtectFrames = RoundToFloor(3.0 / tickInterval);
    int mergeRadius = RoundToFloor(3.0 / tickInterval);
    float afkSpeedThreshold = g_cvAfkThreshold.FloatValue;


    if (isRefine)
    {
        afkSpeedThreshold = 20.0;
        mergeRadius = RoundToFloor(5.0 / tickInterval);
    }

    int afkMinFrames = RoundToFloor(g_cvAfkMinDuration.FloatValue / tickInterval);
    int afkTailFrames = RoundToFloor(g_cvAfkTailBuffer.FloatValue / tickInterval);

    int ops = 0;
    int MAX_OPS = maxOps;

    if (i == 0)
    {
        if (g_cvForceOldMode.BoolValue)
            DebugPrint("═══ [DC 原版模式] 剪辑引擎启动 ═══ 帧数=%d", totalFrames);
        else
            DebugPrint("═══ [DC 8D模式] 剪辑引擎启动 ═══ 帧数=%d | 8D扩展=%s", totalFrames, gB_ClosestPosExtended ? "是" : "否");
    }

    int skipAfkCheckUntil = 0;
	int nextShortScanFrame = 0;

    while (i < totalFrames)
    {
        ops++;
        frame_t current;
        clonedFrames.GetArray(i, current, sizeof(frame_t));
        float curSpeed = GetFrameSpeed2D(clonedFrames, i, tickInterval);
        bool isOnGround = (current.flags & FL_ONGROUND) != 0;
        int bestJump = i;

        bool isEndzoneProtection = (i >= activeEndFrame - endzoneProtectFrames);

        // 无缝进站检测：玩家走/滑进下一个 stage 的包围盒，无传送事件
        if (stagesOrdered && clonedValidTransitions != null && nextExpectedStageIndex < clonedValidTransitions.Length)
        {
            float wlData[9];
            clonedValidTransitions.GetArray(nextExpectedStageIndex, wlData);
            bool hasBox = (wlData[3] != 0.0 || wlData[4] != 0.0 || wlData[5] != 0.0
                        || wlData[6] != 0.0 || wlData[7] != 0.0 || wlData[8] != 0.0);

            if (hasBox)
            {
                float pad = g_cvBoxPadding.FloatValue;
                float bMins[3], bMaxs[3];
                for (int ax = 0; ax < 3; ax++)
                {
                    bMins[ax] = ((wlData[3+ax] < wlData[6+ax]) ? wlData[3+ax] : wlData[6+ax]) - pad;
                    bMaxs[ax] = ((wlData[3+ax] > wlData[6+ax]) ? wlData[3+ax] : wlData[6+ax]) + pad;
                }

                if (current.pos[0] >= bMins[0] && current.pos[0] <= bMaxs[0] &&
                    current.pos[1] >= bMins[1] && current.pos[1] <= bMaxs[1] &&
                    current.pos[2] >= bMins[2] && current.pos[2] <= bMaxs[2])
                {
                    currentSafeAnchor = cutFrames.Length;
                    aVirtualAnchors.Clear();
                    stageBounds.Push(cutFrames.Length);

                    float visitEntry[4];
                    visitEntry[0] = wlData[0];
                    visitEntry[1] = wlData[1];
                    visitEntry[2] = wlData[2];
                    visitEntry[3] = float(currentSafeAnchor);
                    visitedStagePos.PushArray(visitEntry);

                    DebugPrint("无缝进站：帧%d 走入下一 Stage 包围盒", i);
                    nextExpectedStageIndex++;
                }
            }
        }

        if (i > protectedFrames && i < activeEndFrame)
        {
            frame_t prev;
            clonedFrames.GetArray(i - 1, prev, sizeof(frame_t));
            float tickDist = GetVectorDistance(current.pos, prev.pos, false);

            if (tickDist > tpThreshold && !isEndzoneProtection)
            {
                bool isAdvancingStage = false;
                bool isRespawn = false;
                float matchedStageDest[3];
                int exactTargetAnchor = -1; // 精确锚点帧索引（无缝进站记录）


                bool inWhitelist = false;
                float wlMatchedPos[3];


                if (clonedValidTransitions != null && clonedValidTransitions.Length > 0)
                {
                    int wlScanStart = 0;
                    if (stagesOrdered)
                    {
						// 允许往回扫描当前关和上一关，防止传送回去时错过！
                        wlScanStart = nextExpectedStageIndex - 2; 
                        if (wlScanStart < 0) wlScanStart = 0;
                    }
                    for (int wl = wlScanStart; wl < clonedValidTransitions.Length; wl++)
                    {
                        float wlData[9];
                        clonedValidTransitions.GetArray(wl, wlData);
                        // wlData[0-2] = position, [3-5] = corner1, [6-8] = corner2

                        bool hasBox = (wlData[3] != 0.0 || wlData[4] != 0.0 || wlData[5] != 0.0
                                    || wlData[6] != 0.0 || wlData[7] != 0.0 || wlData[8] != 0.0);

                        bool matched = false;
                        if (hasBox)
                        {
                            // point-in-box: check PREV position (pre-teleport) against trigger box
                            // because the box is the trigger area, not the destination
                            float pad = g_cvBoxPadding.FloatValue;
                            float mins[3], maxs[3];
                            for (int ax = 0; ax < 3; ax++)
                            {
                                mins[ax] = ((wlData[3+ax] < wlData[6+ax]) ? wlData[3+ax] : wlData[6+ax]) - pad;
                                maxs[ax] = ((wlData[3+ax] > wlData[6+ax]) ? wlData[3+ax] : wlData[6+ax]) + pad;
                            }
                            // For trigger_teleport boxes: prev is inside trigger, current is at destination
                            // For shavit zone boxes: current is inside zone (player walked in)
                            // Check both positions to cover both cases
                            matched = (current.pos[0] >= mins[0] && current.pos[0] <= maxs[0]
                                    && current.pos[1] >= mins[1] && current.pos[1] <= maxs[1]
                                    && current.pos[2] >= mins[2] && current.pos[2] <= maxs[2])
                                   || (prev.pos[0] >= mins[0] && prev.pos[0] <= maxs[0]
                                    && prev.pos[1] >= mins[1] && prev.pos[1] <= maxs[1]
                                    && prev.pos[2] >= mins[2] && prev.pos[2] <= maxs[2]);
                        }

                        // 盒子不存在或盒子匹配失败时，fallback 到圆柱体半径检测
                        if (!matched)
                        {
                            float wldx = current.pos[0] - wlData[0];
                            float wldy = current.pos[1] - wlData[1];
                            float wldz = FloatAbs(current.pos[2] - wlData[2]);
                            matched = ((wldx*wldx + wldy*wldy) < dynamicRadiusXY * dynamicRadiusXY && wldz < dynamicRadiusZ);
                        }

                        if (matched)
                        {
                            inWhitelist = true;
                            wlMatchedPos[0] = wlData[0];
                            wlMatchedPos[1] = wlData[1];
                            wlMatchedPos[2] = wlData[2];
                            break;
                        }
                    }
                }

                if (inWhitelist)
                {


                    bool visitedBefore = false;
                    float dynRadSq = dynamicRadiusXY * dynamicRadiusXY;
                    for (int h = 0; h < visitedStagePos.Length; h++)
                    {
                        float vsp[4];
                        visitedStagePos.GetArray(h, vsp);
                        float hdx = vsp[0] - wlMatchedPos[0];
                        float hdy = vsp[1] - wlMatchedPos[1];
                        float hdz = FloatAbs(vsp[2] - wlMatchedPos[2]);


                        if ((hdx*hdx + hdy*hdy) < dynRadSq && hdz < dynamicRadiusZ)
                        {
                            visitedBefore = true;
                            exactTargetAnchor = RoundToFloor(vsp[3]); // 提取进站瞬间的精准帧
                            break;
                        }
                    }

                    if (!visitedBefore)
                    {
                        // fake advance 检测：用 KD-Tree 检查 cutFrames 历史中是否已经到过这个目的地
                        bool fakeAdvance = false;
                        if (gB_ClosestPos && cutFrames.Length > 50)
                        {
                            // 锁 1：最多只回看 120 秒的历史
                            int maxRollback = RoundToFloor(120.0 / tickInterval);
                            int limitBack = cutFrames.Length - maxRollback;

                            // 锁 2：绝对不允许越过当前关卡的安全锚点
                            if (limitBack < currentSafeAnchor) limitBack = currentSafeAnchor;

                            int searchCount = cutFrames.Length - limitBack;
                            if (searchCount < 10) searchCount = 0; // 太短没意义

                            if (searchCount > 0)
                            {
                                ops += (searchCount / 50);
                                ClosestPos cpFake = new ClosestPos(cutFrames, 0, limitBack, searchCount);
                                int nearIdx = cpFake.Find(wlMatchedPos);
                                delete cpFake;

                                if (nearIdx >= 0 && nearIdx < cutFrames.Length)
                                {
                                    frame_t nearFrame;
                                    cutFrames.GetArray(nearIdx, nearFrame, sizeof(frame_t));
                                    float fdx = nearFrame.pos[0] - wlMatchedPos[0];
                                    float fdy = nearFrame.pos[1] - wlMatchedPos[1];
                                    float fdz = FloatAbs(nearFrame.pos[2] - wlMatchedPos[2]);
                                    float fdistSq = fdx * fdx + fdy * fdy;

                                    if (fdistSq < dynRadSq && fdz < dynamicRadiusZ)
                                    {
                                        fakeAdvance = true;
                                        exactTargetAnchor = nearIdx;
                                        DebugPrint("帧%d fake advance 检测命中！历史帧 %d 距离²=%.1f 已到过(%.0f,%.0f,%.0f)", i, nearIdx, fdistSq, wlMatchedPos[0], wlMatchedPos[1], wlMatchedPos[2]);
                                    }
                                }
                            }
                        }

                        if (fakeAdvance)
                        {
                            // 实际是重生，不是首次进站
                            isRespawn = true;
                            matchedStageDest[0] = wlMatchedPos[0];
                            matchedStageDest[1] = wlMatchedPos[1];
                            matchedStageDest[2] = wlMatchedPos[2];
                        }
                        else
                        {
                            isAdvancingStage = true;
                            currentSafeAnchor = cutFrames.Length;
                            aVirtualAnchors.Clear();
                            stageBounds.Push(cutFrames.Length); // 记录 stage 边界帧索引

                            float visitEntry[4];
                            visitEntry[0] = wlMatchedPos[0];
                            visitEntry[1] = wlMatchedPos[1];
                            visitEntry[2] = wlMatchedPos[2];
                            visitEntry[3] = float(currentSafeAnchor);
                            visitedStagePos.PushArray(visitEntry);

                            if (stagesOrdered)
                            {
                                for (int wlFind = nextExpectedStageIndex; wlFind < clonedValidTransitions.Length; wlFind++)
                                {
                                    float wlCheck[9];
                                    clonedValidTransitions.GetArray(wlFind, wlCheck);
                                    float wlcx = wlMatchedPos[0] - wlCheck[0];
                                    float wlcy = wlMatchedPos[1] - wlCheck[1];
                                    if ((wlcx*wlcx + wlcy*wlcy) < 100.0)
                                    {
                                        nextExpectedStageIndex = wlFind + 1;
                                        break;
                                    }
                                }
                            }
                            DebugPrint("帧%d 首次进站(%.0f,%.0f,%.0f) nextExpected=%d", i, wlMatchedPos[0], wlMatchedPos[1], wlMatchedPos[2], nextExpectedStageIndex);
                        }
                    }
                    else
                    {

                        isRespawn = true;
                        matchedStageDest[0] = wlMatchedPos[0];
                        matchedStageDest[1] = wlMatchedPos[1];
                        matchedStageDest[2] = wlMatchedPos[2];
                        DebugPrint("帧%d 重生回已访问(%.0f,%.0f,%.0f)", i, wlMatchedPos[0], wlMatchedPos[1], wlMatchedPos[2]);
                    }
                }

                else
                {
                    for (int va = 0; va < aVirtualAnchors.Length; va++)
                    {
                        float vDest[3];
                        aVirtualAnchors.GetArray(va, vDest);


                        if (GetVectorDistance(current.pos, vDest) < anchorDedup)
                        {


                            if (cutFrames.Length > currentSafeAnchor + btMinFrames)
                            {


                                float maxEscapeSq_va = 0.0;
								float maxEscapeZ_va = 0.0;
                                for (int scanIdx = currentSafeAnchor; scanIdx < cutFrames.Length; scanIdx += 4)
                                {
                                    ops++;
                                    frame_t scanFrame;
                                    cutFrames.GetArray(scanIdx, scanFrame, sizeof(frame_t));
                                    float sdx = vDest[0] - scanFrame.pos[0];
                                    float sdy = vDest[1] - scanFrame.pos[1];
									float sdz = FloatAbs(vDest[2] - scanFrame.pos[2]);
                                    float sdistSq = sdx*sdx + sdy*sdy;
                                    if (sdistSq > maxEscapeSq_va) maxEscapeSq_va = sdistSq;
									if (sdz > maxEscapeZ_va) maxEscapeZ_va = sdz;
                                }

                                // 时间强制逃逸
                                int framesElapsed_va = cutFrames.Length - currentSafeAnchor;
                                bool timeEscaped_va = (framesElapsed_va > RoundToFloor(g_cvEscapeTime.FloatValue / tickInterval));

                                if (maxEscapeSq_va > fbRadXYSq || maxEscapeZ_va > g_cvEscapeZ.FloatValue || timeEscaped_va)
                                {
                                    isRespawn = true;
                                    matchedStageDest[0] = vDest[0];
                                    matchedStageDest[1] = vDest[1];
                                    matchedStageDest[2] = vDest[2];
                                    break;
                                }
                                else
                                {


                                }
                            }
                        }
                    }


                    if (!isRespawn)
                    {
                        bool alreadyLearned = false;
                        for (int va2 = 0; va2 < aVirtualAnchors.Length; va2++)
                        {
                            float vCheck[3];
                            aVirtualAnchors.GetArray(va2, vCheck);
                            if (GetVectorDistance(current.pos, vCheck) < anchorDedup)
                            {
                                alreadyLearned = true;
                                break;
                            }
                        }
                        if (!alreadyLearned && aVirtualAnchors.Length < g_cvMaxVirtualAnchors.IntValue)
                        {
							// 弹跳板/加速门过滤：必须用 i+1 算速度，因为 i 跨越了传送门！
                            float vaSpeed2D = 0.0;
                            if (i + 1 < clonedFrames.Length)
                            {
                                vaSpeed2D = GetFrameSpeed2D(clonedFrames, i + 1, tickInterval);
                            }
                            
							if (vaSpeed2D < g_cvBouncePadSpeed.FloatValue || vaSpeed2D > 10000.0)
                            {
                                aVirtualAnchors.PushArray(current.pos);
                            }
                            else
                            {
                                DebugPrint("弹跳板过滤：拒绝建立虚拟锚点 (速度%.1f)", vaSpeed2D);
                            }
                        }
                    }
                }


				if (isRespawn)
				{
					int targetAnchor = -1;

					if (g_cvForceOldMode.BoolValue)
					{
						// === 原版行为 ===
						targetAnchor = exactTargetAnchor;

						if (targetAnchor == -1 && gB_ClosestPos && cutFrames.Length > 50)
						{
							ops += (cutFrames.Length / 50);
							ClosestPos cpRespawn = new ClosestPos(cutFrames, 0, 0, cutFrames.Length);
							int candidate = cpRespawn.Find(matchedStageDest);
							delete cpRespawn;

							if (candidate >= 1 && candidate < cutFrames.Length)
							{
								int scanLo = (candidate - 200 > 0) ? candidate - 200 : 1;
								int scanHi = (candidate + 200 < cutFrames.Length) ? candidate + 200 : cutFrames.Length - 1;
								float bestDist = 999999.0;
								for (int k = scanHi; k >= scanLo; k--)
								{
									ops++;
									frame_t past, prevFrame;
									cutFrames.GetArray(k, past, sizeof(frame_t));
									cutFrames.GetArray(k - 1, prevFrame, sizeof(frame_t));
									if (GetVectorDistance(past.pos, prevFrame.pos, false) > tpThreshold)
									{
										float d = GetVectorDistance(past.pos, matchedStageDest);
										if (d < dynamicRadiusXY && d < bestDist)
										{
											bestDist = d;
											targetAnchor = k;
										}
									}
								}
								if (targetAnchor != -1)
									DebugPrint("[原版] KD-Tree 重生锚点命中！候选帧 %d → 确认帧 %d", candidate, targetAnchor);
							}
						}

						if (targetAnchor == -1)
						{
							int respawnScanOps = 0;
							for (int k = cutFrames.Length - 1; k >= 1; k--)
							{
								ops++;
								respawnScanOps++;
								if (respawnScanOps >= g_cvRespawnScanLimit.IntValue) break;

								frame_t past, prevFrame;
								cutFrames.GetArray(k, past, sizeof(frame_t));
								cutFrames.GetArray(k - 1, prevFrame, sizeof(frame_t));
								if (GetVectorDistance(past.pos, prevFrame.pos, false) > tpThreshold)
								{
									float dx = past.pos[0] - matchedStageDest[0];
									float dy = past.pos[1] - matchedStageDest[1];
									float dz = FloatAbs(past.pos[2] - matchedStageDest[2]);
									if ((dx*dx + dy*dy) < dynamicRadiusXY * dynamicRadiusXY && dz < dynamicRadiusZ)
									{
										targetAnchor = k;
										break;
									}
								}
							}
						}
					}
else
					{
						// === 新版行为：8D优先，失败才fallback到exactTargetAnchor ===
						
						// 【核心修复】统一搜索底线！与 cpFake 的 120 秒保持绝对一致
						int searchFloor = currentSafeAnchor;
						int maxRollbackFrames = RoundToFloor(120.0 / tickInterval);
						if (cutFrames.Length - maxRollbackFrames > searchFloor)
							searchFloor = cutFrames.Length - maxRollbackFrames;

						// 优先用 8D/3D KD-Tree 搜索最近一次传送帧
						if (gB_ClosestPos && cutFrames.Length > searchFloor + 30)
						{
							// 必须用 i+1 来算速度，因为 i 和 i-1 之间跨越了传送门
							float respawnVel[3] = {0.0, 0.0, 0.0};
							if (i + 1 < clonedFrames.Length)
								GetFrameVelocity3D(clonedFrames, i + 1, tickInterval, respawnVel);
							float vw = g_cvVelWeight.FloatValue;
							int searchCount = cutFrames.Length - searchFloor;
							ops += (searchCount / 50);

							int candidate = -1;
#if defined CLOSESTPOS_EXTENDED
							if (gB_ClosestPosExtended)
							{
								float respawnAng[2];
								respawnAng[0] = current.ang[0];
								respawnAng[1] = current.ang[1];
								float aw = g_cvAngWeight.FloatValue;
								ClosestPos8D cp8D = new ClosestPos8D(cutFrames, 0, 3, tickInterval, vw, aw, searchFloor, searchCount);
								float score;
								candidate = cp8D.FindWithScore(matchedStageDest, respawnVel, respawnAng, vw, aw, score);
								delete cp8D;
								if (score > g_cv8DScoreThreshold.FloatValue) candidate = -1;
							}
							else
#endif
							{
								ClosestPos cp3D = new ClosestPos(cutFrames, 0, searchFloor, searchCount);
								candidate = cp3D.Find(matchedStageDest);
								delete cp3D;
							}

							if (candidate >= searchFloor && candidate < cutFrames.Length)
							{
								int scanLo = (candidate - 200 > searchFloor) ? candidate - 200 : searchFloor;
								int scanHi = (candidate + 200 < cutFrames.Length) ? candidate + 200 : cutFrames.Length - 1;
								float bestDist = 999999.0;
								for (int k = scanHi; k >= scanLo; k--)
								{
									ops++;
									if (k < 1) break;
									frame_t past, prevFrame;
									cutFrames.GetArray(k, past, sizeof(frame_t));
									cutFrames.GetArray(k - 1, prevFrame, sizeof(frame_t));
									if (GetVectorDistance(past.pos, prevFrame.pos, false) > tpThreshold)
									{
										float d = GetVectorDistance(past.pos, matchedStageDest);
										if (d < dynamicRadiusXY && d < bestDist)
										{
											bestDist = d;
											targetAnchor = k;
										}
									}
								}
								if (targetAnchor != -1)
									DebugPrint("8D重生锚点命中！候选帧 %d → 确认帧 %d (搜索起点=%d)", candidate, targetAnchor, searchFloor);
							}
						}

						// 8D 未命中，fallback 到 exactTargetAnchor
						if (targetAnchor == -1 && exactTargetAnchor >= searchFloor && exactTargetAnchor < cutFrames.Length)
						{
							targetAnchor = exactTargetAnchor;
							DebugPrint("8D未命中，fallback到精确锚点 帧 %d", targetAnchor);
						}

						// 【核心修复】线性兜底扫描的深度也必须同步到 searchFloor！不再受 2000 次限制
						if (targetAnchor == -1)
						{
							int respawnScanOps = 0;
							int maxLinearScan = cutFrames.Length - searchFloor; // 允许扫满整个 120 秒窗口
							
							for (int k = cutFrames.Length - 1; k >= searchFloor; k--)
							{
								ops++;
								respawnScanOps++;
								if (respawnScanOps > maxLinearScan) break;

								if (k < 1) break;
								frame_t past, prevFrame;
								cutFrames.GetArray(k, past, sizeof(frame_t));
								cutFrames.GetArray(k - 1, prevFrame, sizeof(frame_t));
								if (GetVectorDistance(past.pos, prevFrame.pos, false) > tpThreshold)
								{
									float dx = past.pos[0] - matchedStageDest[0];
									float dy = past.pos[1] - matchedStageDest[1];
									float dz = FloatAbs(past.pos[2] - matchedStageDest[2]);
									if ((dx*dx + dy*dy) < dynamicRadiusXY * dynamicRadiusXY && dz < dynamicRadiusZ)
									{
										targetAnchor = k;
										DebugPrint("线性兜底命中！帧 %d (遍历了 %d 帧)", targetAnchor, respawnScanOps);
										break;
									}
								}
							}
						}
					}

					if (targetAnchor != -1)
                    {
                        // === 锚点回推引擎 (Anchor Rewind) ===
                        // 目的：消除传送前多余的原地加速、发呆和多余移动
                        // 逻辑：只要前一帧还在当前锚点的极小范围内 (如 64 units)，就一直往前推，直到玩家“刚落地/刚进站”
                        float anchorPos[3];
                        frame_t tempFrame;
                        cutFrames.GetArray(targetAnchor, tempFrame, sizeof(frame_t));
                        anchorPos[0] = tempFrame.pos[0];
                        anchorPos[1] = tempFrame.pos[1];
                        anchorPos[2] = tempFrame.pos[2];

                        int rewindCount = 0;
                        int searchFloorLimit = currentSafeAnchor; // 防止回推越过当前关卡安全点
                        
                        while (targetAnchor > searchFloorLimit + 1)
                        {
                            cutFrames.GetArray(targetAnchor - 1, tempFrame, sizeof(frame_t));
                            
                            // 只要前一帧和最终锚点的距离还在 64 units (一个小平台) 以内
                            // 就说明这段时间玩家都在原地绕圈/加速，全部抹掉！
                            if (GetVectorDistance(tempFrame.pos, anchorPos) < 64.0)
                            {
                                targetAnchor--;
                                rewindCount++;
                            }
                            else
                            {
                                // 距离大于 64，说明这已经是玩家从天上掉下来/从远处飞过来的瞬间了，停止回推
                                break;
                            }
                        }
                        
                        if (rewindCount > 0)
                        {
                            DebugPrint("锚点回推生效！成功抹除 %d 帧多余的原地加速，最终锁定落地帧: %d", rewindCount, targetAnchor);
                        }
                        // === 锚点回推结束 ===

                        int loopStartIndex = targetAnchor;
                        int popped = cutFrames.Length - loopStartIndex;

                        if (loopStartIndex < cutFrames.Length)
                        {
                            cutFrames.Resize(loopStartIndex);

                            popped += TrimTailFrames(cutFrames, currentSafeAnchor, tickInterval, cvTailSpeed, cvTailAngDelta, ops);

                            int accumulatedSkipped = popped;
                            int localFalls = 1;
                            int localAfks = 0;
                            MergeCutMarkers(cutMarkers, loopStartIndex, mergeRadius, accumulatedSkipped, localFalls, localAfks);

                            fallsCut++;
                            totalCutSeconds += float(popped) * tickInterval;
                            float realSkippedSec = float(accumulatedSkipped) * tickInterval;
                            if (realSkippedSec > maxSingleCut) maxSingleCut = realSkippedSec;

                            int markerData[5];
                            markerData[0] = loopStartIndex;
                            markerData[1] = accumulatedSkipped;
                            markerData[2] = localFalls;
                            markerData[3] = localAfks;
                            markerData[4] = 0;
                            cutMarkers.PushArray(markerData);

                            DebugPrint("重生剪辑成功！精准回退至历史传送帧 %d，暴力切除 %d 帧废片！", loopStartIndex, popped);
                        }
                    }
                    else
                    {
                        DebugPrint("警告：未能找到回到 matchedStageDest(%.1f, %.1f, %.1f) 的历史传送锚点！", matchedStageDest[0], matchedStageDest[1], matchedStageDest[2]);
                    }
                }


				else if (!isAdvancingStage && (!stagesOrdered || clonedValidTransitions == null || clonedValidTransitions.Length == 0))
				{
					int closestIndex = -1;

					if (gB_ClosestPos && cutFrames.Length > currentSafeAnchor + 30)
					{
						int searchCount = cutFrames.Length - currentSafeAnchor;
						ops += (searchCount / 50);

						int rawIndex;
						if (!g_cvForceOldMode.BoolValue)
						{
#if defined CLOSESTPOS_EXTENDED
							if (gB_ClosestPosExtended)
							{
								float tpVel[3];
								GetFrameVelocity3D(clonedFrames, i, tickInterval, tpVel);
								float vw = g_cvVelWeight.FloatValue;
								float aw = g_cvAngWeight.FloatValue;
								float handleAng[2];
								handleAng[0] = current.ang[0];
								handleAng[1] = current.ang[1];
								ClosestPos8D cp8D = new ClosestPos8D(cutFrames, 0, 3, tickInterval, vw, aw, currentSafeAnchor, searchCount);
								float handleScore;
								rawIndex = cp8D.FindWithScore(current.pos, tpVel, handleAng, vw, aw, handleScore);
								delete cp8D;
								if (handleScore > g_cv8DScoreThreshold.FloatValue) rawIndex = -1;
							}
							else
#endif
							{
								ClosestPos cp3D = new ClosestPos(cutFrames, 0, currentSafeAnchor, searchCount);
								rawIndex = cp3D.Find(current.pos);
								delete cp3D;
							}
						}
						else
						{
							// 原版行为
							ClosestPos cpHandle = new ClosestPos(cutFrames, 0, currentSafeAnchor, searchCount);
							rawIndex = cpHandle.Find(current.pos);
							delete cpHandle;
						}

						if (rawIndex >= currentSafeAnchor && rawIndex < cutFrames.Length)
						{
							frame_t candidate;
							cutFrames.GetArray(rawIndex, candidate, sizeof(frame_t));
							float dz = FloatAbs(current.pos[2] - candidate.pos[2]);
							float dx = current.pos[0] - candidate.pos[0];
							float dy = current.pos[1] - candidate.pos[1];
							float distSq = dx * dx + dy * dy;
							float speed3D = GetFrameSpeed3D(cutFrames, rawIndex, tickInterval);

							if (dz < g_cvEscapeZ.FloatValue && distSq < 25600.0)
							{
								if (!((candidate.flags & FL_ONGROUND) == 0 && speed3D > g_cvHighSpeedFilter.FloatValue))
								{
									closestIndex = rawIndex;
									DebugPrint("%s 命中！帧 %d，距离² = %.1f", g_cvForceOldMode.BoolValue ? "[原版] KD-Tree" : "[8D] KD-Tree", rawIndex, distSq);
								}
							}

                            if (closestIndex == -1)
                            {
                                float minDistSq = 9999999.0;
                                int scanRadius = g_cvForceOldMode.BoolValue ? 100 : 50;
                                int scanStart = (rawIndex - scanRadius > currentSafeAnchor) ? rawIndex - scanRadius : currentSafeAnchor;
                                int scanEnd = (rawIndex + scanRadius < cutFrames.Length) ? rawIndex + scanRadius : cutFrames.Length - 1;

                                for (int k = scanEnd; k >= scanStart; k--)
                                {
                                    ops++;
                                    frame_t past;
                                    cutFrames.GetArray(k, past, sizeof(frame_t));
                                    float sSpeed3D = GetFrameSpeed3D(cutFrames, k, tickInterval);
                                    if ((past.flags & FL_ONGROUND) == 0 && sSpeed3D > 280.0)
                                        continue;

                                    float sdz = FloatAbs(current.pos[2] - past.pos[2]);
                                    if (sdz < g_cvEscapeZ.FloatValue)
                                    {
                                        float sdx = current.pos[0] - past.pos[0];
                                        float sdy = current.pos[1] - past.pos[1];
                                        float sDistSq = sdx * sdx + sdy * sdy;
                                        if (sDistSq < minDistSq)
                                        {
                                            minDistSq = sDistSq;
                                            closestIndex = k;
                                        }
                                    }
                                }

                                if (closestIndex != -1 && minDistSq >= 62500.0)
                                    closestIndex = -1;

                                if (closestIndex != -1)
                                    DebugPrint("%s 局部补救命中！帧 %d", g_cvForceOldMode.BoolValue ? "[原版]" : "[8D]", closestIndex);
                            }
                        }
                    }
                    else
                    {
                        float minDistSq = 9999999.0;
                        int backtraceOps = 0;

                        for (int k = cutFrames.Length - 1; k >= currentSafeAnchor; k -= 2)
                        {
                            ops++;
                            backtraceOps++;
                            if (backtraceOps >= 800) break;

                            frame_t past;
                            cutFrames.GetArray(k, past, sizeof(frame_t));

                            float speed3D = GetFrameSpeed3D(cutFrames, k, tickInterval);
                            if ((past.flags & FL_ONGROUND) == 0 && speed3D > g_cvHighSpeedFilter.FloatValue)
                                continue;

                            float dz = FloatAbs(current.pos[2] - past.pos[2]);
                            if (dz < g_cvEscapeZ.FloatValue)
                            {
                                float dx = current.pos[0] - past.pos[0];
                                float dy = current.pos[1] - past.pos[1];
                                float distSq = dx * dx + dy * dy;
                                if (distSq < minDistSq)
                                {
                                    minDistSq = distSq;
                                    closestIndex = k;
                                }
                            }
                        }

                        if (closestIndex != -1 && minDistSq >= 62500.0)
                            closestIndex = -1;
                    }

					if (closestIndex != -1)
                    {

                        int loopStartIndex = closestIndex;
                        int eraseLimit = currentSafeAnchor;

                        for (int k = closestIndex; k >= eraseLimit; k--)
                        {
                            ops++;
                            if (k == 0) break;

                            frame_t past, prevFrame;
                            cutFrames.GetArray(k, past, sizeof(frame_t));
                            cutFrames.GetArray(k - 1, prevFrame, sizeof(frame_t));


                            if (GetVectorDistance(past.pos, prevFrame.pos, false) > tpThreshold)
                            {
                                loopStartIndex = k;
                                break;
                            }
                        }


                        frame_t landFrame;
                        cutFrames.GetArray(loopStartIndex, landFrame, sizeof(frame_t));
                        int mergeLimit = (loopStartIndex - 128 > eraseLimit) ? (loopStartIndex - 128) : eraseLimit;
                        for (int k = loopStartIndex - 1; k >= mergeLimit; k--)
                        {
                            ops++;
                            frame_t checkFrame;
                            cutFrames.GetArray(k, checkFrame, sizeof(frame_t));


                            if (GetVectorDistance(landFrame.pos, checkFrame.pos, false) < 1.0)
                            {
                                loopStartIndex = k;
                            }
                            else
                            {
                                break;
                            }
                        }


                        int popped = cutFrames.Length - loopStartIndex;
                        if (loopStartIndex < cutFrames.Length && loopStartIndex >= eraseLimit)
                        {
                            cutFrames.Resize(loopStartIndex);
                        }

                        popped += TrimTailFrames(cutFrames, currentSafeAnchor, tickInterval, cvTailSpeed, cvTailAngDelta, ops);

                        int accumulatedSkipped = popped;
                        int localFalls = 1;
                        int localAfks = 0;
                        MergeCutMarkers(cutMarkers, loopStartIndex, mergeRadius, accumulatedSkipped, localFalls, localAfks);

                        fallsCut++;
                        totalCutSeconds += float(popped) * tickInterval;

                        float realSkippedSec = float(accumulatedSkipped) * tickInterval;
                        if (realSkippedSec > maxSingleCut) maxSingleCut = realSkippedSec;

                        int markerData[5];
                        markerData[0] = loopStartIndex;
                        markerData[1] = accumulatedSkipped;
                        markerData[2] = localFalls;
                        markerData[3] = localAfks;
                        markerData[4] = 0;
                        cutMarkers.PushArray(markerData);
                    }
                }
            }
        }


		bool btTriggerGround = (!isEndzoneProtection && isOnGround && curSpeed < btSpeed
            && cutFrames.Length > currentSafeAnchor + btMinFrames
            && i > protectedFrames && i < activeEndFrame
            && i >= nextShortScanFrame);


		bool btTriggerAir = (!isEndzoneProtection && !isOnGround
            && cutFrames.Length > currentSafeAnchor + btScanDepth * 2
            && i > protectedFrames && i < activeEndFrame
            && i >= nextShortScanFrame);
		if (btTriggerGround || btTriggerAir)
        {
            int backtrackAnchor = -1;


            int scanStart = cutFrames.Length - 1;
            int scanEnd   = (cutFrames.Length - btScanDepth > currentSafeAnchor)
                            ? cutFrames.Length - btScanDepth : currentSafeAnchor;

            for (int bk = scanStart; bk >= scanEnd; bk -= btScanStep)
            {
                ops++;
                frame_t bkFrame;
                cutFrames.GetArray(bk, bkFrame, sizeof(frame_t));


                if (btTriggerGround && (bkFrame.flags & FL_ONGROUND) == 0) continue;

                float bkdx = current.pos[0] - bkFrame.pos[0];
                float bkdy = current.pos[1] - bkFrame.pos[1];
                float bkdz = FloatAbs(current.pos[2] - bkFrame.pos[2]);

                if ((bkdx*bkdx + bkdy*bkdy) < fbRadXYSq && bkdz < fbRadZ)
                {
                    backtrackAnchor = bk;
                    break;
                }
            }

            if (backtrackAnchor != -1)
            {

                if (cutFrames.Length - backtrackAnchor > btMinSpan)
                {


                    float maxEscapeSq_bt = 0.0;
					float maxEscapeZ_bt = 0.0;
                    for (int scanIdx2 = backtrackAnchor; scanIdx2 < cutFrames.Length; scanIdx2 += 4)
                    {
                        ops++;
                        frame_t scanFrame2;
                        cutFrames.GetArray(scanIdx2, scanFrame2, sizeof(frame_t));
                        float sdx2 = current.pos[0] - scanFrame2.pos[0];
                        float sdy2 = current.pos[1] - scanFrame2.pos[1];
						float sdz2 = FloatAbs(current.pos[2] - scanFrame2.pos[2]);
                        float sdistSq2 = sdx2*sdx2 + sdy2*sdy2;
                        if (sdistSq2 > maxEscapeSq_bt) maxEscapeSq_bt = sdistSq2;
						if (sdz2 > maxEscapeZ_bt) maxEscapeZ_bt = sdz2;
                    }

                    // 时间强制逃逸：超过 2.5 秒不管空间距离直接算逃逸
                    int framesElapsed_bt = cutFrames.Length - backtrackAnchor;
                    bool timeEscaped_bt = (framesElapsed_bt > RoundToFloor(g_cvEscapeTime.FloatValue / tickInterval));

                    if (maxEscapeSq_bt > escapeRadiusSq || maxEscapeZ_bt > g_cvEscapeZ.FloatValue || timeEscaped_bt)
                    {
                        int refinedAnchor = backtrackAnchor;
#if defined CLOSESTPOS_EXTENDED
                        if (gB_ClosestPosExtended && !g_cvForceOldMode.BoolValue)
                        {
                            float cur8DVel[3];
                            GetFrameVelocity3D(clonedFrames, i, tickInterval, cur8DVel);
                            float cur8DAng[2];
                            cur8DAng[0] = current.ang[0];
                            cur8DAng[1] = current.ang[1];

                            int win8DLo = (backtrackAnchor - 100 > currentSafeAnchor) ? backtrackAnchor - 100 : currentSafeAnchor;
                            int win8DHi = backtrackAnchor;
                            int win8DCount = win8DHi - win8DLo + 1;

                            if (win8DCount >= 4)
                            {
                                ops += (win8DCount / 50);
                                float vw = g_cvVelWeight.FloatValue;
                                float aw = g_cvAngWeight.FloatValue;
                                ClosestPos8D cp8D = new ClosestPos8D(cutFrames, 0, 3, tickInterval, vw, aw, win8DLo, win8DCount);
                                float outScore8D;
                                int raw8D = cp8D.FindWithScore(current.pos, cur8DVel, cur8DAng, vw, aw, outScore8D);
                                delete cp8D;

                                if (raw8D >= win8DLo && raw8D <= win8DHi && outScore8D < g_cv8DScoreThreshold.FloatValue)
                                {
                                    refinedAnchor = raw8D;
                                    DebugPrint("8D精化命中！cylinder锚点 %d → 8D锚点 %d (score=%.1f)", backtrackAnchor, refinedAnchor, outScore8D);
                                }
                            }
                        }
#endif

                        int popped = cutFrames.Length - refinedAnchor;
                        cutFrames.Resize(refinedAnchor);

                        popped += TrimTailFrames(cutFrames, currentSafeAnchor, tickInterval, cvTailSpeed, cvTailAngDelta, ops);

                        fallsCut++;
                        totalCutSeconds += float(popped) * tickInterval;
                        int markerData[5];
                        markerData[0] = cutFrames.Length;
                        markerData[1] = popped;
                        markerData[2] = 1;
                        markerData[3] = 0;
                        markerData[4] = 0;
                        cutMarkers.PushArray(markerData);
                        DebugPrint("位置回退命中！逃逸验证成功，切除%d帧", popped);
                    }
                }
				nextShortScanFrame = i + nextScanDelay;
            }
        }


        // AFK 检测必须在 push 之前，避免 AFK 帧泄漏到输出
        // isOnGround 或水平速度极低（原地跳也算 AFK）
        if (i >= skipAfkCheckUntil && (isOnGround || curSpeed < g_cvAfkMinSpeed.FloatValue) && curSpeed < afkSpeedThreshold
            && GetFrameAngularDelta(clonedFrames, i) < cvTailAngDelta
            && i < activeEndFrame - afkProtectFrames && !isEndzoneProtection)
        {
            int moveFrame = i;
            bool startedMovingAgain = false;


            int step = g_cvAfkScanStep.IntValue;
            for (int k = i + 1; k < activeEndFrame; k += step)
            {
                ops++;
                frame_t fut;
                clonedFrames.GetArray(k, fut, sizeof(frame_t));
                float fSpeed = GetFrameSpeed2D(clonedFrames, k, tickInterval);


                // 恢复运动判定：速度超过阈值，或离地且速度>50（真正起跑的跳，不是原地跳）
                if (fSpeed > afkSpeedThreshold || ((fut.flags & FL_ONGROUND) == 0 && fSpeed > g_cvAirborneSpeed.FloatValue))
                {

                    int refineStart = k - step;
                    if (refineStart <= i) refineStart = i + 1;

                    for (int p = refineStart; p <= k; p++)
                    {
                        frame_t pFut;
                        clonedFrames.GetArray(p, pFut, sizeof(frame_t));
                        float pSpeed = GetFrameSpeed2D(clonedFrames, p, tickInterval);
                        if (pSpeed > afkSpeedThreshold || ((pFut.flags & FL_ONGROUND) == 0 && pSpeed > g_cvAirborneSpeed.FloatValue))
                        {
                            moveFrame = p;
                            break;
                        }
                    }
                    startedMovingAgain = true;
                    break;
                }


                if (k + step >= activeEndFrame)
                {
                    step = 1;
                }
            }


            if (!startedMovingAgain && (activeEndFrame - i) > afkMinFrames)
            {
                moveFrame = activeEndFrame;
                startedMovingAgain = true;
            }

            if (startedMovingAgain)
            {
                int skippedFrames = moveFrame - i;
                if (skippedFrames > afkMinFrames)
                {
                    bestJump = moveFrame - afkTailFrames;
                    if (bestJump <= i) bestJump = moveFrame;
                    skipAfkCheckUntil = moveFrame;
                }
            }
        }

        if (bestJump > i)
        {
            afksCut++;
            int skipped = bestJump - i;

            int accumulatedSkipped = skipped;
            int localFalls = 0;
            int localAfks = 1;
            MergeCutMarkers(cutMarkers, cutFrames.Length, mergeRadius, accumulatedSkipped, localFalls, localAfks);

            totalCutSeconds += float(skipped) * tickInterval;
            float realSkippedSec = float(accumulatedSkipped) * tickInterval;
            if (realSkippedSec > maxSingleCut) maxSingleCut = realSkippedSec;

            int markerData[5];
            markerData[0] = cutFrames.Length;
            markerData[1] = accumulatedSkipped;
            markerData[2] = localFalls;
            markerData[3] = localAfks;
            markerData[4] = 0;
            cutMarkers.PushArray(markerData);

            i = bestJump;
        }
        else
        {
            // 正常帧 push
            if (cutFrames.Length > 0)
            {
                frame_t spliceTail;
                cutFrames.GetArray(cutFrames.Length - 1, spliceTail, sizeof(frame_t));
                if (GetVectorDistance(current.pos, spliceTail.pos, false) > tpThreshold)
                {
                    current.ang[0] = spliceTail.ang[0];
                    current.ang[1] = spliceTail.ang[1];
                }
            }
            cutFrames.PushArray(current, sizeof(frame_t));
            i++;
        }

        if (ops >= MAX_OPS)
        {
            if (i % 25000 < 2000)
                DebugPrint("引擎处理进度: %d / %d 帧 (%.1f%%)", i, totalFrames, float(i) / float(totalFrames) * 100.0);

            DataPack nextDp = new DataPack();
            nextDp.WriteCell(serial);
            nextDp.WriteCell(style);
            nextDp.WriteCell(track);
            nextDp.WriteFloat(time);
            nextDp.WriteCell(preframes);
            nextDp.WriteCell(postframes);
            nextDp.WriteCell(accountId);
            nextDp.WriteString(steamID);
            nextDp.WriteString(map);
            nextDp.WriteCell(clonedFrames);
            nextDp.WriteCell(cutFrames);
            nextDp.WriteCell(cutMarkers);
            nextDp.WriteCell(stageBounds);
            nextDp.WriteCell(clonedValidTransitions);
			nextDp.WriteCell(aVirtualAnchors);
			nextDp.WriteCell(visitedStagePos);
            nextDp.WriteCell(i);
            nextDp.WriteCell(fallsCut);
            nextDp.WriteCell(afksCut);
            nextDp.WriteFloat(totalCutSeconds);
            nextDp.WriteFloat(maxSingleCut);
            nextDp.WriteCell(currentSafeAnchor);
            nextDp.WriteCell(nextExpectedStageIndex);
            nextDp.WriteCell(stagesOrdered);


            nextDp.WriteFloat(dynamicRadiusXY);
            nextDp.WriteFloat(dynamicRadiusZ);
			nextDp.WriteCell(isRefine);

            CreateTimer(0.01, Timer_ProcessCut, nextDp);
            return Plugin_Stop;
        }
    }

    DebugPrint("计算引擎处理完毕！进入保存流程...");
    if (clonedValidTransitions != null) delete clonedValidTransitions;
	if (aVirtualAnchors != null) delete aVirtualAnchors;
    if (visitedStagePos != null) delete visitedStagePos;
    int client = GetClientFromSerial(serial);
    FinishAsyncSaving(client, style, track, time, preframes, postframes, accountId, steamID, map, clonedFrames, cutFrames, cutMarkers, stageBounds, fallsCut, afksCut, totalCutSeconds, maxSingleCut);
    return Plugin_Stop;
}

#if defined CLOSESTPOS_EXTENDED
ArrayList ApplySeamlessSpliceAllCuts(ArrayList cutFrames, ArrayList cutMarkers, int blendFrames)
{
    if (!gB_ClosestPosExtended || g_cvForceOldMode.BoolValue) return null;
    int N = cutMarkers.Length;
    if (N == 0) return null;
    if (blendFrames < 2)  blendFrames = 2;
    if (blendFrames > 16) blendFrames = 16;
    int totalLen = cutFrames.Length;
    if (totalLen < 4) return null;

    ArrayList boundaries = new ArrayList();
    for (int i = 0; i < N; i++)
    {
        int marker[5];
        cutMarkers.GetArray(i, marker, 5);
        int bIdx = marker[0];
        if (bIdx >= 2 && bIdx < totalLen - 1)
        {
            bool dup = false;
            for (int j = 0; j < boundaries.Length; j++)
            {
                if (boundaries.Get(j) == bIdx) { dup = true; break; }
            }
            if (!dup) boundaries.Push(bIdx);
        }
    }
    if (boundaries.Length == 0) { delete boundaries; return null; }
    SortADTArray(boundaries, Sort_Ascending, Sort_Integer);

    ArrayList result = new ArrayList(sizeof(frame_t));
    int copyFrom = 0;
    int spliceCount = 0;

    for (int b = 0; b < boundaries.Length; b++)
    {
        int boundary = boundaries.Get(b);
        for (int fi = copyFrom; fi < boundary; fi++)
        {
            frame_t f;
            cutFrames.GetArray(fi, f, sizeof(frame_t));
            result.PushArray(f, sizeof(frame_t));
        }

        ArrayList tempNew = new ArrayList(sizeof(frame_t));
        frame_t fNew0, fNew1;
        cutFrames.GetArray(boundary,     fNew0, sizeof(frame_t));
        cutFrames.GetArray(boundary + 1, fNew1, sizeof(frame_t));
        tempNew.PushArray(fNew0, sizeof(frame_t));
        tempNew.PushArray(fNew1, sizeof(frame_t));

        int oldIdx = result.Length - 1;
        if (oldIdx >= 1)
        {
            int neededSize = oldIdx + 1 + blendFrames + 1;
            result.Resize(neededSize);
            bool ok = ClosestPos_PerformSeamlessSplice(result, tempNew, oldIdx, 0, blendFrames, 0, 3, sizeof(frame_t));
            if (ok)
            {
                result.Erase(result.Length - 1);
                spliceCount++;
                DebugPrint("SeamlessSplice 成功 boundary=%d", boundary);
            }
            else
            {
                result.Resize(oldIdx + 1);
                DebugPrint("SeamlessSplice 失败 boundary=%d，保持硬切", boundary);
            }
        }
        delete tempNew;
        copyFrom = boundary;
    }

    for (int fi = copyFrom; fi < totalLen; fi++)
    {
        frame_t f;
        cutFrames.GetArray(fi, f, sizeof(frame_t));
        result.PushArray(f, sizeof(frame_t));
    }

    delete boundaries;
    DebugPrint("SeamlessSplice 总计处理 %d/%d 个接缝", spliceCount, N);
    return result;
}
#endif


void FinishAsyncSaving(int client, int style, int track, float time, int preframes, int postframes, int accountId, const char[] steamID, const char[] map, ArrayList clonedFrames, ArrayList cutFrames, ArrayList cutMarkers, ArrayList stageBounds, int fallsCut, int afksCut, float totalCutSeconds, float maxSingleCut)
{
#if defined CLOSESTPOS_EXTENDED
    // === 无缝拼接所有切割点（仅 =0 时） ===
    int blendFrames = g_cvBlendFrames.IntValue;
    if (!g_cvForceOldMode.BoolValue && blendFrames > 0 && cutMarkers.Length > 0)
    {
        ArrayList splicedFrames = ApplySeamlessSpliceAllCuts(cutFrames, cutMarkers, blendFrames);
        if (splicedFrames != null)
        {
            CreateTimer(0.1, Timer_DeleteMassiveArray, cutFrames, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
            cutFrames = splicedFrames;
            DebugPrint("SeamlessSplice 全部完成，%d 个切点已平滑，新帧数: %d", cutMarkers.Length, cutFrames.Length);
        }
    }
#endif

    float tickInterval = GetTickInterval();
    int totalFrames = clonedFrames.Length;
    CreateTimer(0.1, Timer_DeleteMassiveArray, clonedFrames, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    char mapFolder[PLATFORM_MAX_PATH];
    FormatEx(mapFolder, sizeof(mapFolder), "%s/%s", gS_DirectorFolder, map);
    if (!DirExists(mapFolder)) CreateDirectory(mapFolder, 511);

    char filePath[PLATFORM_MAX_PATH];
    FormatEx(filePath, sizeof(filePath), "%s/%s_style%d_track%d.replay", mapFolder, steamID, style, track);

    char memKey[64];
    FormatEx(memKey, sizeof(memKey), "%s_%d_%d", steamID, style, track);

    ArrayList oldMarkers;
    if (g_smCutMarkers.GetValue(memKey, oldMarkers)) delete oldMarkers;
    g_smCutMarkers.SetValue(memKey, cutMarkers);

    ArrayList oldBounds;
    if (g_smStageBounds.GetValue(memKey, oldBounds)) delete oldBounds;
    g_smStageBounds.SetValue(memKey, stageBounds);

    int newTotalFrames = cutFrames.Length;
    DebugPrint("═══ [DC %s] 剪辑完成 ═══ 剩余 %d 帧", g_cvForceOldMode.BoolValue ? "原版模式" : "8D模式", newTotalFrames);


    float finalTime = float(newTotalFrames - preframes - postframes) * tickInterval;
    if (finalTime <= 0.0) finalTime = float(newTotalFrames) * tickInterval;


    char clientName[MAX_NAME_LENGTH] = "玩家";
    if (client > 0 && IsClientInGame(client))
    {
        GetClientName(client, clientName, sizeof(clientName));
    }

    if (gB_Floppy)
    {
        DebugPrint("识别到 Floppy 扩展，准备发起 SRCWRFloppy_AsyncSaveReplay");
        DataPack dp = new DataPack();
        dp.WriteCell(client > 0 ? GetClientSerial(client) : 0);
        dp.WriteFloat(time);
        dp.WriteCell(fallsCut);
        dp.WriteCell(afksCut);
        dp.WriteFloat(totalCutSeconds);
        dp.WriteFloat(maxSingleCut);
        dp.WriteCell(totalFrames);
        dp.WriteCell(newTotalFrames);
        dp.WriteFloat(tickInterval);
        dp.WriteCell(cutFrames);

        char headerbuf[512];
        float fZoneOffset[2] = {0.0, 0.0};

		int headersize = WriteReplayHeaderToBuffer(headerbuf, style, track, finalTime, accountId, preframes, postframes, fZoneOffset, newTotalFrames, tickInterval, map);

        ArrayList paths = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
        paths.PushString(filePath);
        SRCWRFloppy_AsyncSaveReplay(DC_AsyncSaveCallback, dp, paths, headerbuf, headersize, cutFrames, newTotalFrames);
    }
    else
    {
        DebugPrint("无 Floppy，使用原生异步写入...");
        char tmpPath[PLATFORM_MAX_PATH];
        FormatEx(tmpPath, sizeof(tmpPath), "%s.tmp", filePath);
        File fReplay = OpenFile(tmpPath, "wb+");
        if (fReplay != null)
        {
            float fZoneOffset[2] = {0.0, 0.0};

            WriteReplayHeader(fReplay, style, track, finalTime, accountId, preframes, postframes, fZoneOffset, newTotalFrames, tickInterval, map);

            DataPack wdp = new DataPack();
            wdp.WriteCell(client > 0 ? GetClientSerial(client) : 0);
            wdp.WriteCell(fReplay);
            wdp.WriteCell(cutFrames);
            wdp.WriteCell(newTotalFrames);
            wdp.WriteCell(0);
            wdp.WriteFloat(time);
            wdp.WriteCell(fallsCut);
            wdp.WriteCell(afksCut);
            wdp.WriteFloat(totalCutSeconds);
            wdp.WriteFloat(maxSingleCut);
            wdp.WriteCell(totalFrames);
            wdp.WriteFloat(tickInterval);
            wdp.WriteString(tmpPath);
            wdp.WriteString(filePath);
            CreateTimer(0.01, Timer_AsyncWriteReplay, wdp);
        }
        else
        {
            DebugPrint("文件流建立失败！");
            if (client > 0 && IsClientInGame(client))
                Shavit_PrintToChat(client, "严重错误：无法创建录像文件！");
            CreateTimer(0.1, Timer_DeleteMassiveArray, cutFrames, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
            TryProcessNext();
        }
    }
}

public Action Timer_AsyncWriteReplay(Handle timer, DataPack dp)
{
    dp.Reset();
    int clientSerial    = dp.ReadCell();
    File fReplay        = view_as<File>(dp.ReadCell());
    ArrayList cutFrames = view_as<ArrayList>(dp.ReadCell());
    int totalFrames     = dp.ReadCell();
    int currentFrame    = dp.ReadCell();
    float time          = dp.ReadFloat();
    int fallsCut        = dp.ReadCell();
    int afksCut         = dp.ReadCell();
    float totalCutSec   = dp.ReadFloat();
    float maxSingleCut  = dp.ReadFloat();
    int origTotalFrames = dp.ReadCell();
    float tickInterval  = dp.ReadFloat();
    char tmpFilePath[PLATFORM_MAX_PATH];
    char finalFilePath[PLATFORM_MAX_PATH];
    bool hasTmpPath = dp.IsReadable();
    if (hasTmpPath) { dp.ReadString(tmpFilePath, sizeof(tmpFilePath)); dp.ReadString(finalFilePath, sizeof(finalFilePath)); }
    delete dp;

    frame_t frame;
    int ops = 0;
    while (currentFrame < totalFrames)
    {
        cutFrames.GetArray(currentFrame, frame, sizeof(frame_t));
        fReplay.Write(frame, sizeof(frame_t), 4);
        currentFrame++;
        if (++ops >= 3000) break;
    }

    if (currentFrame < totalFrames)
    {
        DebugPrint("写入进度: %d / %d (%.1f%%)", currentFrame, totalFrames, float(currentFrame) / float(totalFrames) * 100.0);
        DataPack nextDp = new DataPack();
        nextDp.WriteCell(clientSerial);
        nextDp.WriteCell(fReplay);
        nextDp.WriteCell(cutFrames);
        nextDp.WriteCell(totalFrames);
        nextDp.WriteCell(currentFrame);
        nextDp.WriteFloat(time);
        nextDp.WriteCell(fallsCut);
        nextDp.WriteCell(afksCut);
        nextDp.WriteFloat(totalCutSec);
        nextDp.WriteFloat(maxSingleCut);
        nextDp.WriteCell(origTotalFrames);
        nextDp.WriteFloat(tickInterval);
        if (hasTmpPath)
        {
            nextDp.WriteString(tmpFilePath);
            nextDp.WriteString(finalFilePath);
        }
        CreateTimer(0.01, Timer_AsyncWriteReplay, nextDp);
        return Plugin_Stop;
    }

    DebugPrint("原生异步写入完成！");
    delete fReplay;

    if (hasTmpPath && tmpFilePath[0] != '\0' && finalFilePath[0] != '\0')
    {
        if (FileExists(finalFilePath)) DeleteFile(finalFilePath);
        RenameFile(finalFilePath, tmpFilePath);
    }
    int client = GetClientFromSerial(clientSerial);
    if (client > 0 && IsClientInGame(client))
        PrintDirectorReport(client, time, fallsCut, afksCut, totalCutSec, maxSingleCut, origTotalFrames, totalFrames, tickInterval);
    CreateTimer(0.1, Timer_DeleteMassiveArray, cutFrames, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    TryProcessNext();
    return Plugin_Stop;
}

public void DC_AsyncSaveCallback(bool saved, any data)
{
    DataPack dp = view_as<DataPack>(data);
    dp.Reset();
    int serial         = dp.ReadCell();
    float time         = dp.ReadFloat();
    int fallsCut       = dp.ReadCell();
    int afksCut        = dp.ReadCell();
    float totalCutSec  = dp.ReadFloat();
    float maxSingleCut = dp.ReadFloat();
    int totalFrames    = dp.ReadCell();
    int newTotalFrames = dp.ReadCell();
    float tickInterval = dp.ReadFloat();
    ArrayList cutFrames = view_as<ArrayList>(dp.ReadCell());
    delete dp;

    DebugPrint("收到 Floppy 异步写入回调！结果: %s", saved ? "成功" : "失败");

    int client = GetClientFromSerial(serial);
    if (saved && client != 0)
    {
        PrintDirectorReport(client, time, fallsCut, afksCut, totalCutSec, maxSingleCut, totalFrames, newTotalFrames, tickInterval);
    }
    else if (!saved && client != 0)
    {
        Shavit_PrintToChat(client, "异步保存失败！可能是磁盘空间不足或权限错误。");
    }

    if (cutFrames != null)
        CreateTimer(0.1, Timer_DeleteMassiveArray, cutFrames, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    TryProcessNext();
}


void PrintDirectorReport(int client, float time, int fallsCut, int afksCut, float totalCutSeconds, float maxSingleCut, int totalFrames, int newTotalFrames, float tickInterval)
{
#pragma unused time
    float originalSec = float(totalFrames) * tickInterval;
    float finalSec = float(newTotalFrames) * tickInterval;
    float cutPercent = (totalFrames > 0)
        ? (float(totalFrames - newTotalFrames) / float(totalFrames)) * 100.0
        : 0.0;

    char sOriginal[32], sFinal[32], sTotalCut[32], sMaxCut[32];
    FormatTimeString(originalSec, sOriginal, sizeof(sOriginal));
    FormatTimeString(finalSec, sFinal, sizeof(sFinal));
    FormatTimeString(totalCutSeconds, sTotalCut, sizeof(sTotalCut));
    FormatTimeString(maxSingleCut, sMaxCut, sizeof(sMaxCut));

    Shavit_PrintToChat(client, " ");
    Shavit_PrintToChat(client, "录像原片长：\x04%s\x01 → 缝合提纯后：\x04%s\x01", sOriginal, sFinal);
    Shavit_PrintToChat(client, "共剪去 \x04%d\x01 次失误与 \x04%d\x01 次挂机，缩减了 \x04%s\x01（\x04%.1f%%\x01）", fallsCut, afksCut, sTotalCut, cutPercent);
    Shavit_PrintToChat(client, "导演剪辑版录像已生成，输入 \x04!dc\x01 观看");

    DebugPrint("彻底完成剪辑！报告已发送给玩家。");
}


public Action Command_DeleteDC(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;
    int style = Shavit_GetBhopStyle(client);
    int track = Shavit_GetClientTrack(client);

    char map[PLATFORM_MAX_PATH];
    GetNormalizedMapName(map, sizeof(map));

    char steamID[32];
    GetNormalizedSteamID(client, steamID, sizeof(steamID));

    char filePath[PLATFORM_MAX_PATH];
    FormatEx(filePath, sizeof(filePath), "%s/%s/%s_style%d_track%d.replay", gS_DirectorFolder, map, steamID, style, track);

    char stagesPath[PLATFORM_MAX_PATH];
    FormatEx(stagesPath, sizeof(stagesPath), "%s/%s/%s_style%d_track%d.stages", gS_DirectorFolder, map, steamID, style, track);

    char memKey[64];
    FormatEx(memKey, sizeof(memKey), "%s_%d_%d", steamID, style, track);
    ArrayList oldMarkers;
    if (g_smCutMarkers.GetValue(memKey, oldMarkers))
    {
        delete oldMarkers;
        g_smCutMarkers.Remove(memKey);
    }

    if (FileExists(filePath)) DeleteFile(filePath);
    if (FileExists(stagesPath)) DeleteFile(stagesPath);

    Shavit_PrintToChat(client, "录像已删除。");
    return Plugin_Handled;
}


public Action Command_PlayDC(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    char map[PLATFORM_MAX_PATH];
    GetNormalizedMapName(map, sizeof(map));

    char steamID[32];
    GetNormalizedSteamID(client, steamID, sizeof(steamID));

    char mapFolder[PLATFORM_MAX_PATH];
    FormatEx(mapFolder, sizeof(mapFolder), "%s/%s", gS_DirectorFolder, map);

    Menu styleMenu = new Menu(MenuHandler_PlayDC_Style);
    styleMenu.SetTitle("导演剪辑版录像\n ");

    int foundStylesCount = 0;
    int styleCount = Shavit_GetStyleCount();
    for (int style = 0; style < styleCount; style++)
    {
        for (int track = 0; track <= 20; track++)
        {
            char filePath[PLATFORM_MAX_PATH];
            FormatEx(filePath, sizeof(filePath), "%s/%s_style%d_track%d.replay", mapFolder, steamID, style, track);

            if (FileExists(filePath))
            {
                char info[16];
                IntToString(style, info, sizeof(info));
                char styleName[64];
                Shavit_GetStyleStrings(style, sStyleName, styleName, sizeof(styleName));
                styleMenu.AddItem(info, styleName);
                foundStylesCount++;
                break;
            }
        }
    }

    if (foundStylesCount == 0)
    {
        Shavit_PrintToChat(client, "未找到录像。");
        delete styleMenu;
        return Plugin_Handled;
    }

    styleMenu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int MenuHandler_PlayDC_Style(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End) delete menu;
    else if (action == MenuAction_Select)
    {
        int client = param1;
        if (!IsValidClient(client)) return 0;

        char info[16];
        menu.GetItem(param2, info, sizeof(info));
        int style = StringToInt(info);

        Menu trackMenu = new Menu(MenuHandler_PlayDC_Track);

        char map[PLATFORM_MAX_PATH];
        GetNormalizedMapName(map, sizeof(map));

        char steamID[32];
        GetNormalizedSteamID(client, steamID, sizeof(steamID));

        char mapFolder[PLATFORM_MAX_PATH];
        FormatEx(mapFolder, sizeof(mapFolder), "%s/%s", gS_DirectorFolder, map);

        for (int track = 0; track <= 20; track++)
        {
            char filePath[PLATFORM_MAX_PATH];
            FormatEx(filePath, sizeof(filePath), "%s/%s_style%d_track%d.replay", mapFolder, steamID, style, track);

            if (FileExists(filePath))
            {
                char trackInfo[32];
                FormatEx(trackInfo, sizeof(trackInfo), "%d_%d", style, track);
                char display[64];
                if (track == 0) Format(display, sizeof(display), "主路线");
                else Format(display, sizeof(display), "奖励路线 %d", track);
                trackMenu.AddItem(trackInfo, display);
            }
        }

        trackMenu.ExitBackButton = true;
        trackMenu.Display(client, MENU_TIME_FOREVER);
    }
    return 0;
}

public int MenuHandler_PlayDC_Track(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End) delete menu;
    else if (action == MenuAction_Cancel) { if (param2 == MenuCancel_ExitBack) Command_PlayDC(param1, 0); }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        if (!IsValidClient(client)) return 0;

        char info[32];
        menu.GetItem(param2, info, sizeof(info));
        char parts[2][16];
        ExplodeString(info, "_", parts, 2, 16);
        int style = StringToInt(parts[0]);
        int track = StringToInt(parts[1]);

        char map[PLATFORM_MAX_PATH];
        GetNormalizedMapName(map, sizeof(map));

        char steamID[32];
        GetNormalizedSteamID(client, steamID, sizeof(steamID));

        char mapFolder[PLATFORM_MAX_PATH];
        FormatEx(mapFolder, sizeof(mapFolder), "%s/%s", gS_DirectorFolder, map);

        char filePath[PLATFORM_MAX_PATH];
        FormatEx(filePath, sizeof(filePath), "%s/%s_style%d_track%d.replay", mapFolder, steamID, style, track);

        if (!FileExists(filePath)) return 0;

        int bot = Shavit_StartReplayFromFile(style, track, -1.0, client, -1, Replay_Dynamic, true, filePath);
        if (bot > 0 && bot <= MaxClients && IsClientInGame(bot))
        {
			char clientName[MAX_NAME_LENGTH];
            GetClientName(client, clientName, sizeof(clientName));
            char botCustomName[128];
            FormatEx(botCustomName, sizeof(botCustomName), "导演剪辑版: %s", clientName);

			Shavit_SetReplayCacheName(bot, botCustomName);
			DataPack dp1 = new DataPack();
            dp1.WriteCell(GetClientSerial(bot));
            dp1.WriteString(botCustomName);
            CreateTimer(0.5, Timer_EnforceDCName, dp1, TIMER_FLAG_NO_MAPCHANGE);

			DataPack dp2 = new DataPack();
            dp2.WriteCell(GetClientSerial(bot));
            dp2.WriteString(botCustomName);
            CreateTimer(1.5, Timer_EnforceDCName, dp2, TIMER_FLAG_NO_MAPCHANGE);

			char memKey[64];
            FormatEx(memKey, sizeof(memKey), "%s_%d_%d", steamID, style, track);

            ArrayList markers;
            ArrayList bounds;
            bool hasMarkers = g_smCutMarkers.GetValue(memKey, markers);
            bool hasBounds = g_smStageBounds.GetValue(memKey, bounds);

            if (hasMarkers && hasBounds && bounds.Length > 0)
            {
                float tickInterval = GetTickInterval();

                // 按 stage 区间汇总 cutMarkers
                for (int s = 0; s < bounds.Length; s++)
                {
                    int stageStart = bounds.Get(s);
                    int stageEnd = (s + 1 < bounds.Length) ? bounds.Get(s + 1) : 999999999;

                    int totalSkipped = 0;
                    int totalFalls = 0;
                    int totalAfks = 0;

                    for (int m = 0; m < markers.Length; m++)
                    {
                        int markerData[5];
                        markers.GetArray(m, markerData, sizeof(markerData));
                        if (markerData[0] >= stageStart && markerData[0] < stageEnd)
                        {
                            totalSkipped += markerData[1];
                            totalFalls += markerData[2];
                            totalAfks += markerData[3];
                        }
                    }

                    // 无失误无挂机的 stage 不播报
                    if (totalFalls == 0 && totalAfks == 0) continue;

                    float delay = float(stageStart) * tickInterval;
                    DataPack tdp = new DataPack();
                    tdp.WriteCell(GetClientSerial(client));
                    tdp.WriteCell(GetClientSerial(bot));
                    tdp.WriteCell(totalSkipped);
                    tdp.WriteCell(totalFalls);
                    tdp.WriteCell(totalAfks);
                    tdp.WriteCell(s + 1); // stage 编号（从1开始）
                    CreateTimer(delay, Timer_PrintCutMarker, tdp, TIMER_FLAG_NO_MAPCHANGE);
                }
            }
            else if (hasMarkers)
            {
                // 没有 stage 边界数据时，fallback 到原来的逐条播报
                float tickInterval = GetTickInterval();
                for (int m = 0; m < markers.Length && m < 500; m++)
                {
                    int markerData[5];
                    markers.GetArray(m, markerData, sizeof(markerData));
                    float delay = float(markerData[0]) * tickInterval;
                    DataPack tdp = new DataPack();
                    tdp.WriteCell(GetClientSerial(client));
                    tdp.WriteCell(GetClientSerial(bot));
                    tdp.WriteCell(markerData[1]);
                    tdp.WriteCell(markerData[2]);
                    tdp.WriteCell(markerData[3]);
                    tdp.WriteCell(0); // stage 0 = 未知
                    CreateTimer(delay, Timer_PrintCutMarker, tdp, TIMER_FLAG_NO_MAPCHANGE);
                }
            }
        }
    }
    return 0;
}

public Action Timer_PrintCutMarker(Handle timer, DataPack dp)
{
    dp.Reset();
    int clientSerial = dp.ReadCell();
    int botSerial    = dp.ReadCell();
    int skippedFrames = dp.ReadCell();
    int localFalls   = dp.ReadCell();
    int localAfks    = dp.ReadCell();
    dp.ReadCell(); // stage 编号（保留兼容，不使用）
    delete dp;

    int client = GetClientFromSerial(clientSerial);
    int bot = GetClientFromSerial(botSerial);
    if (client > 0 && bot > 0 && IsClientInGame(client) && IsClientInGame(bot))
    {
        if (!IsPlayerAlive(client))
        {
            int target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
            if (target == bot)
            {
                float skippedSec = float(skippedFrames) * GetTickInterval();
                char sSkipped[32];
                FormatTimeString(skippedSec, sSkipped, sizeof(sSkipped));

                Shavit_PrintToChat(client, "此处区域共剔除 \x04%s\x01 (失误\x04%d\x01次/挂机\x04%d\x01次)", sSkipped, localFalls, localAfks);
            }
        }
    }
    return Plugin_Stop;
}


// Find start position for nearest-neighbor sort: shavit start zone > spawn point
void GetMapSpawnOrigin(float out[3])
{
    out[0] = out[1] = out[2] = 0.0;

    // Try shavit start zone first
    int zoneCount = Shavit_GetZoneCount();
    for (int i = 0; i < zoneCount; i++)
    {
        zone_cache_t zone;
        Shavit_GetZone(i, zone);
        if (zone.iType == Zone_Start && zone.iTrack == Track_Main)
        {
            // Use center of start zone
            out[0] = (zone.fCorner1[0] + zone.fCorner2[0]) * 0.5;
            out[1] = (zone.fCorner1[1] + zone.fCorner2[1]) * 0.5;
            out[2] = (zone.fCorner1[2] + zone.fCorner2[2]) * 0.5;
            return;
        }
    }

    // Fallback: map spawn point
    static char spawns[][] = { "info_player_terrorist", "info_player_counterterrorist", "info_player_start" };
    for (int s = 0; s < sizeof(spawns); s++)
    {
        int ent = FindEntityByClassname(-1, spawns[s]);
        if (ent > 0)
        {
            GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", out);
            return;
        }
    }
}

// Sort stage entries (float[9]) by nearest-neighbor chain starting from spawn
ArrayList SortStagesByNearestNeighbor(ArrayList unordered)
{
    int count = unordered.Length;
    if (count <= 1) return unordered.Clone();

    float current[3];
    GetMapSpawnOrigin(current);

    int blocksize = unordered.BlockSize;
    ArrayList result = new ArrayList(blocksize);
    bool[] visited = new bool[count];

    for (int step = 0; step < count; step++)
    {
        float bestDist = 999999999.0;
        int bestIdx = -1;

        for (int i = 0; i < count; i++)
        {
            if (visited[i]) continue;
            float entry[9];
            unordered.GetArray(i, entry);
            float pos[3]; pos[0] = entry[0]; pos[1] = entry[1]; pos[2] = entry[2];
            float dist = GetVectorDistance(current, pos);
            if (dist < bestDist)
            {
                bestDist = dist;
                bestIdx = i;
            }
        }

        if (bestIdx == -1) break;
        visited[bestIdx] = true;
        float bestEntry[9];
        unordered.GetArray(bestIdx, bestEntry);
        current[0] = bestEntry[0]; current[1] = bestEntry[1]; current[2] = bestEntry[2];
        result.PushArray(bestEntry);
    }

    return result;
}

void FindAndMarkTeleportDestinations()
{

    StringMap nameToEnt = new StringMap();
    char entName[228];
    int maxEnts = GetMaxEntities();

    if (maxEnts > MAX_ENTITY_INDEX) maxEnts = MAX_ENTITY_INDEX;

    for (int ent = MaxClients; ent < maxEnts; ent++)
    {
        if (!IsValidEntity(ent) || !IsValidEdict(ent)) continue;
        if (FindDataMapInfo(ent, "m_iName") == -1) continue;
        GetEntPropString(ent, Prop_Data, "m_iName", entName, sizeof(entName));
        if (entName[0] != '\0')
            nameToEnt.SetValue(entName, ent, true);
    }


    char className[64], targetname[228];
    for (int entity = MaxClients; entity < maxEnts; entity++)
    {
        if (!IsValidEntity(entity) || !IsValidEdict(entity)) continue;
        GetEntityClassname(entity, className, sizeof(className));
        if (!StrEqual(className, "trigger_teleport", false)) continue;

        GetEntPropString(entity, Prop_Data, "m_target", targetname, sizeof(targetname));
        if (targetname[0] == '\0') continue;

        int dest_ent;
        if (nameToEnt.GetValue(targetname, dest_ent))
        {
            if (entity <= MAX_ENTITY_INDEX)
            {
                g_TeleportDestinations[entity] = dest_ent;
                SDKHook(entity, SDKHook_StartTouch, OnTriggerTeleportTouch);
                SDKHook(entity, SDKHook_TouchPost, OnTriggerTeleportTouch);
            }
        }
    }
    delete nameToEnt;


    char map2[PLATFORM_MAX_PATH];
    GetNormalizedMapName(map2, sizeof(map2));
    char cachePathAuto[PLATFORM_MAX_PATH];
    FormatEx(cachePathAuto, sizeof(cachePathAuto), "%s/%s/_map_stages.cache", gS_DirectorFolder, map2);
    if (!FileExists(cachePathAuto))
    {

        ArrayList autoCache = new ArrayList(3);
        int maxEnts2 = GetMaxEntities();
        if (maxEnts2 > MAX_ENTITY_INDEX) maxEnts2 = MAX_ENTITY_INDEX;
        for (int e = MaxClients; e < maxEnts2; e++)
        {
            if (g_TeleportDestinations[e] == -1) continue;
            int destE = g_TeleportDestinations[e];
            if (!IsValidEntity(destE)) continue;
            float dPos[3];
            GetEntPropVector(destE, Prop_Data, "m_vecAbsOrigin", dPos);

            bool dup = false;
            for (int d = 0; d < autoCache.Length; d++)
            {
                float ex[3]; autoCache.GetArray(d, ex);
                if (GetVectorDistance(dPos, ex) < g_cvWhitelistDedup.FloatValue) { dup = true; break; }
            }
            if (!dup) autoCache.PushArray(dPos);
        }
        if (autoCache.Length > 0)
        {
            // nearest-neighbor sort: start from spawn, chain to closest unvisited destination
            ArrayList ordered = SortStagesByNearestNeighbor(autoCache);
            delete autoCache;

            SaveMapStageCache(ordered, false);
            if (g_aMapStageCache != null) delete g_aMapStageCache;
            g_aMapStageCache = ordered;
            DebugPrint("🗺️ 自动白名单缓存已生成（已排序）：%d 个传送目的地", ordered.Length);
        }
        else
            delete autoCache;
    }
}

public Action OnTriggerTeleportTouch(int entity, int client)
{
    if (client < 1 || client > MaxClients || IsFakeClient(client) || !IsPlayerAlive(client))
        return Plugin_Continue;
    if (entity < 0 || entity > MAX_ENTITY_INDEX || g_TeleportDestinations[entity] == -1)
        return Plugin_Continue;

    int destEnt = g_TeleportDestinations[entity];
    if (!IsValidEntity(destEnt)) return Plugin_Continue;

    float destPos[3];
    GetEntPropVector(destEnt, Prop_Data, "m_vecAbsOrigin", destPos);

    if (g_aStageEntryPositions[client] == null)
        g_aStageEntryPositions[client] = new ArrayList(3);

    int count = g_aStageEntryPositions[client].Length;
    bool alreadyRecent = false;
    if (count > 0)
    {
        float lastPos[3];
        g_aStageEntryPositions[client].GetArray(count - 1, lastPos);
        if (GetVectorDistance(lastPos, destPos) < 64.0)
            alreadyRecent = true;
    }

    if (!alreadyRecent)
    {
        g_aStageEntryPositions[client].PushArray(destPos);
        DebugPrint("SDKHook Touch: 玩家%d 经过传送门%d -> 目标%d 坐标(%.0f,%.0f,%.0f) 累计%d个stage",
            client, entity, destEnt, destPos[0], destPos[1], destPos[2],
            g_aStageEntryPositions[client].Length);
    }

    return Plugin_Continue;
}


public Action Timer_EnforceDCName(Handle timer, DataPack dp)
{
    dp.Reset();
    int bot = GetClientFromSerial(dp.ReadCell());
    char botCustomName[128];
    dp.ReadString(botCustomName, sizeof(botCustomName));
    delete dp;


    if (bot > 0 && IsClientInGame(bot))
    {
        Shavit_SetReplayCacheName(bot, botCustomName);
    }
    return Plugin_Stop;
}
