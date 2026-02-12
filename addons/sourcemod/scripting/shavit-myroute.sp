#include <sourcemod>
#include <shavit/core>
#include <shavit/replay-playback>
#include <convar_class>
#include <clientprefs>
#include <closestpos>
#include <sdktools>
#include <mycolors>
#include <myreplay>

#pragma newdecls required
#pragma semicolon 1

#define MAX_BEAM_WIDTH  10
#define MAX_JUMP_SIZE   16
#define MAX_JUMPS_AHEAD 5
#define DRAW_DELAY      0.5

enum RouteType
{
    RouteType_Auto,             // 自动模式：优先使用个人录像，否则使用当前风格的服务器记录
    RouteType_PersonalReplay,   // 仅限个人录像
    RouteType_ServerRecord,     // 仅限服务器记录（可在菜单中选择风格）
    RouteType_ServerRecordAuto, // 服务器记录自动匹配：匹配玩家当前的风格
    RouteType_Size
};

enum struct JumpMarker
{
    int id;
    int frameNum;

    float line1[3];
    float line2[3];
    float line3[3];
    float line4[3];

    void Initialize(frame_t frame, int size, int id, int frameNum)
    {
        float jumpSize = float(size);

        this.id = id;
        this.frameNum = frameNum;

        this.line1[0] = frame.pos[0] + jumpSize;
        this.line1[1] = frame.pos[1] + jumpSize;
        this.line1[2] = frame.pos[2];

        this.line2[0] = frame.pos[0] + jumpSize;
        this.line2[1] = frame.pos[1] - jumpSize;
        this.line2[2] = frame.pos[2];

        this.line3[0] = frame.pos[0] - jumpSize;
        this.line3[1] = frame.pos[1] - jumpSize;
        this.line3[2] = frame.pos[2];

        this.line4[0] = frame.pos[0] - jumpSize;
        this.line4[1] = frame.pos[1] + jumpSize;
        this.line4[2] = frame.pos[2];
    }

    void Draw(int client, int color[4])
    {
        BeamEffect(client, this.line1, this.line2, 0.7, 1.0, color);
        BeamEffect(client, this.line2, this.line3, 0.7, 1.0, color);
        BeamEffect(client, this.line3, this.line4, 0.7, 1.0, color);
        BeamEffect(client, this.line4, this.line1, 0.7, 1.0, color);
    }
}

Convar gCV_NumAheadFrames = null;
Convar gCV_VelDiffScalar = null;

Cookie gH_ShowRouteCookie = null;
Cookie gH_RouteTypeCookie = null;
Cookie gH_StyleCookie = null;
Cookie gH_ShowPathCookie = null;
Cookie gH_PathSizeCookie = null;
Cookie gH_PathColorCookie = null;
Cookie gH_PathOpacityCookie = null;
Cookie gH_ShowJumpsCookie = null;
Cookie gH_JumpSizeCookie = null;
Cookie gH_JumpMarkerColorCookie = null;
Cookie gH_JumpsAheadCookie = null;

float gF_Delay[MAXPLAYERS + 1];
int gI_Style[MAXPLAYERS + 1] = {-1, ...};
ArrayList gA_Styles[TRACKS_SIZE];

int gI_PathColorIndex[MAXPLAYERS + 1] = {-1, ...};
int gI_PathSize[MAXPLAYERS + 1] = {MAX_BEAM_WIDTH, ...};
int gI_PathOpacity[MAXPLAYERS + 1] = {250, ...};

int gI_JumpColorIndex[MAXPLAYERS + 1];
int gI_JumpSize[MAXPLAYERS + 1] = {MAX_JUMP_SIZE, ...};
int gI_JumpsAhead[MAXPLAYERS + 1] = {1, ...};
int gI_JumpsIndex[MAXPLAYERS + 1];
ArrayList gA_JumpMarkerCache[MAXPLAYERS + 1];

int gI_BeamSprite = -1;
int gI_PrevStep[MAXPLAYERS + 1];
int gI_Color[MAXPLAYERS + 1][4];
int gI_PrevFrame[MAXPLAYERS + 1];

RouteType gRT_RouteType[MAXPLAYERS + 1] = {RouteType_Auto, ...};

char gS_Map[PLATFORM_MAX_PATH];
char gS_ReplayFolder[PLATFORM_MAX_PATH];
char gS_ReplayPath[MAXPLAYERS + 1][PLATFORM_MAX_PATH];

frame_cache_t gA_FrameCache[MAXPLAYERS + 1];

ClosestPos gH_ClosestPos[MAXPLAYERS + 1];

bool gB_Debug;
bool gB_Late;
bool gB_MyReplay;
bool gB_ReplayRecorder;
bool gB_ReplayPlayback;
bool gB_ClosestPos;
bool gB_LoadedReplay[MAXPLAYERS + 1];
bool gB_ShowRoute[MAXPLAYERS + 1] = {true, ...};
bool gB_ShowPath[MAXPLAYERS + 1] = {true, ...};
bool gB_ShowJumps[MAXPLAYERS + 1] = {true, ...};

public Plugin myinfo =
{
    name        = "shavit - 个人路径练习 (Personal Route)",
    author      = "BoomShot",
    description = "允许玩家创建自己的练习路径。",
    version     = "1.0.4",
    url         = "https://github.com/BoomShotKapow/shavit-myroute"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    gB_Late = late;

    return APLRes_Success;
}

public void OnPluginStart()
{
    gH_ShowRouteCookie = new Cookie("sm_myroute_enabled", "开启/关闭个人路径显示。", CookieAccess_Protected);
    gH_RouteTypeCookie = new Cookie("sm_myroute_type", "路径回放类型。", CookieAccess_Protected);
    gH_StyleCookie = new Cookie("sm_myroute_style", "服务器记录路径风格。", CookieAccess_Protected);
    gH_ShowPathCookie = new Cookie("sm_myroute_path", "显示/隐藏路径光束。", CookieAccess_Protected);
    gH_PathSizeCookie = new Cookie("sm_myroute_path_size", "路径光束粗细。", CookieAccess_Protected);
    gH_PathColorCookie = new Cookie("sm_myroute_path_color", "路径光束颜色。", CookieAccess_Protected);
    gH_PathOpacityCookie = new Cookie("sm_myroute_path_opacity", "路径光束透明度。", CookieAccess_Protected);
    gH_ShowJumpsCookie = new Cookie("sm_myroute_jump", "显示/隐藏跳跃标记。", CookieAccess_Protected);
    gH_JumpSizeCookie = new Cookie("sm_myroute_jump_size", "跳跃标记大小。", CookieAccess_Protected);
    gH_JumpMarkerColorCookie = new Cookie("sm_myroute_jump_color", "跳跃标记颜色。", CookieAccess_Protected);
    gH_JumpsAheadCookie = new Cookie("sm_myroute_jumps_ahead", "预显示跳跃标记数量。", CookieAccess_Protected);

    RegConsoleCmd("sm_route", Command_Route, "显示路径设置菜单。");
    RegConsoleCmd("sm_path", Command_Route, "显示路径设置菜单。");
    RegConsoleCmd("sm_botpath", Command_Route, "显示路径设置菜单。");
    RegConsoleCmd("sm_routepath", Command_Route, "显示路径设置菜单。");
    RegConsoleCmd("sm_line", Command_Route, "显示路径设置菜单。");

    RegConsoleCmd("sm_resetroute", Command_ResetRoute, "重置练习路径。");

    RegAdminCmd("sm_myroute_debug", Command_Debug, ADMFLAG_ROOT);

    gB_MyReplay = LibraryExists("shavit-myreplay");
    gB_ReplayRecorder = LibraryExists("shavit-replay-recorder");
    gB_ReplayPlayback = LibraryExists("shavit-replay-playback");
    gB_ClosestPos = LibraryExists("closestpos");

    if(gB_ReplayPlayback)
    {
        Shavit_GetReplayFolderPath_Stock(gS_ReplayFolder);
    }

    gCV_NumAheadFrames = new Convar("smr_ahead_frames", "75", "要在玩家前方绘制的帧数。", 0, true, 0.0);
    gCV_VelDiffScalar = new Convar("smr_veldiff_scalar", "1", "速度差动态颜色的缩放比例。", 0, true, 0.0);

    Convar.AutoExecConfig();
}

public void OnAllPluginsLoaded()
{
    gB_MyReplay = LibraryExists("shavit-myreplay");
    gB_ReplayRecorder = LibraryExists("shavit-replay-recorder");
    gB_ReplayPlayback = LibraryExists("shavit-replay-playback");
    gB_ClosestPos = LibraryExists("closestpos");

    if(!gB_MyReplay)
    {
        SetFailState("此插件需要 shavit-myreplay！");
    }
    else if(!gB_ReplayRecorder)
    {
        SetFailState("此插件需要 shavit-replay-recorder！");
    }
    else if(!gB_ReplayPlayback)
    {
        SetFailState("此插件需要 shavit-replay-playback！");
    }
    else if(!gB_ClosestPos)
    {
        SetFailState("此插件需要 closestpos 扩展/插件！");
    }

    Shavit_GetReplayFolderPath(gS_ReplayFolder, sizeof(gS_ReplayFolder));
}

public void OnLibraryAdded(const char[] name)
{
    if(StrEqual(name, "shavit-myreplay"))
    {
        gB_MyReplay = true;
    }
    else if(StrEqual(name, "shavit-replay-recorder"))
    {
        gB_ReplayRecorder = true;
    }
    else if(StrEqual(name, "shavit-replay-playback"))
    {
        gB_ReplayPlayback = true;
    }
    else if(StrEqual(name, "closestpos"))
    {
        gB_ClosestPos = true;
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if(StrEqual(name, "shavit-myreplay"))
    {
        gB_MyReplay = false;
    }
    else if(StrEqual(name, "shavit-replay-recorder"))
    {
        gB_ReplayRecorder = false;
    }
    else if(StrEqual(name, "shavit-replay-playback"))
    {
        gB_ReplayPlayback = false;
    }
    else if(StrEqual(name, "closestpos"))
    {
        gB_ClosestPos = false;
    }
}

public void OnMapStart()
{
    GetLowercaseMapName(gS_Map);

    GetStylesWithServerRecord();

    if(gB_Late)
    {
        gB_Late = false;

        for(int i = 1; i <= MaxClients; i++)
        {
            if(IsValidClient(i))
            {
                OnClientPutInServer(i);
            }
        }
    }
}

public void OnMapEnd()
{
    for(int i = 1; i <= MaxClients; i++)
    {
        if(gA_JumpMarkerCache[i] != null)
        {
            gA_JumpMarkerCache[i].Clear();
        }
    }
}

public void OnConfigsExecuted()
{
    gI_BeamSprite = PrecacheModel("sprites/laserbeam.vmt");
}

public void OnClientPutInServer(int client)
{
    if(IsFakeClient(client))
    {
        return;
    }

    gF_Delay[client] = 0.0;
    gB_LoadedReplay[client] = false;
    gRT_RouteType[client] = RouteType_Auto;
    gI_Style[client] = -1;
    gB_ShowRoute[client] = true;
    gB_ShowPath[client] = true;
    gB_ShowJumps[client] = true;

    if(gA_JumpMarkerCache[client] == null)
    {
        gA_JumpMarkerCache[client] = new ArrayList(sizeof(JumpMarker));
    }
    else
    {
        gA_JumpMarkerCache[client].Clear();
    }

    if(AreClientCookiesCached(client))
    {
        OnClientCookiesCached(client);
    }

    if(IsClientAuthorized(client))
    {
        OnClientAuthorized(client, "");
    }
}

public void OnClientAuthorized(int client, const char[] auth)
{
    if(IsFakeClient(client))
    {
        return;
    }

    LoadMyRoute(client);
}

public void OnClientDisconnect(int client)
{
    gB_LoadedReplay[client] = false;

    if(gA_JumpMarkerCache[client] != null)
    {
        gA_JumpMarkerCache[client].Clear();
    }
}

public void OnClientCookiesCached(int client)
{
    char cookie[4];

    gH_ShowRouteCookie.Get(client, cookie, sizeof(cookie));
    gB_ShowRoute[client] = (strlen(cookie) > 0) ? view_as<bool>(StringToInt(cookie)) : true;

    gH_RouteTypeCookie.Get(client, cookie, sizeof(cookie));
    gRT_RouteType[client] = (strlen(cookie) > 0) ? view_as<RouteType>(StringToInt(cookie)) : RouteType_Auto;

    gH_StyleCookie.Get(client, cookie, sizeof(cookie));
    gI_Style[client] = (strlen(cookie) > 0) ? StringToInt(cookie) : -1;

    if(gRT_RouteType[client] != RouteType_ServerRecord)
    {
        gI_Style[client] = -1;
    }
    else
    {
        char tempPath[PLATFORM_MAX_PATH];
        Shavit_GetReplayFilePath(gI_Style[client], Shavit_GetClientTrack(client), gS_Map, gS_ReplayFolder, tempPath);

        if(!FileExists(tempPath))
        {
            gI_Style[client] = GetClosestStyle(client);
        }
    }

    gH_ShowPathCookie.Get(client, cookie, sizeof(cookie));
    gB_ShowPath[client] = (strlen(cookie) > 0) ? view_as<bool>(StringToInt(cookie)) : true;

    gH_PathSizeCookie.Get(client, cookie, sizeof(cookie));
    gI_PathSize[client] = (strlen(cookie) > 0) ? StringToInt(cookie) : MAX_BEAM_WIDTH;

    gH_PathColorCookie.Get(client, cookie, sizeof(cookie));
    gI_PathColorIndex[client] = (strlen(cookie) > 0) ? StringToInt(cookie) : -1;

    gH_PathOpacityCookie.Get(client, cookie, sizeof(cookie));
    gI_PathOpacity[client] = (strlen(cookie) > 0) ? StringToInt(cookie) : 250;

    gH_ShowJumpsCookie.Get(client, cookie, sizeof(cookie));
    gB_ShowJumps[client] = (strlen(cookie) > 0) ? view_as<bool>(StringToInt(cookie)) : true;

    gH_JumpSizeCookie.Get(client, cookie, sizeof(cookie));
    gI_JumpSize[client] = (strlen(cookie) > 0) ? StringToInt(cookie) : MAX_JUMP_SIZE;

    gH_JumpMarkerColorCookie.Get(client, cookie, sizeof(cookie));
    gI_JumpColorIndex[client] = (strlen(cookie) > 0) ? StringToInt(cookie) : view_as<int>(WHITE);

    gH_JumpsAheadCookie.Get(client, cookie, sizeof(cookie));
    gI_JumpsAhead[client] = (strlen(cookie) > 0) ? StringToInt(cookie) : 1;
}

void GetStylesWithServerRecord()
{
    char tempPath[PLATFORM_MAX_PATH];

    for(int track = 0; track < TRACKS_SIZE; track++)
    {
        if(gA_Styles[track] == null)
        {
            gA_Styles[track] = new ArrayList(ByteCountToCells(64));
        }
        else
        {
            gA_Styles[track].Clear();
        }

        for(int style = 0; style < Shavit_GetStyleCount(); style++)
        {
            Shavit_GetReplayFilePath(style, track, gS_Map, gS_ReplayFolder, tempPath);

            if(FileExists(tempPath))
            {
                char styleName[64];
                Shavit_GetStyleStrings(style, sStyleName, styleName, sizeof(styleName));
                gA_Styles[track].PushString(styleName);
            }
        }
    }
}

int GetClosestStyle(int client)
{
    int track = Shavit_GetClientTrack(client);
    char styleName[64];
    int loopCount = 0;

    for(int i = gI_Style[client] == -1 ? 0 : gI_Style[client]; i < Shavit_GetStyleCount(); i++)
    {
        if(i == Shavit_GetStyleCount() - 1)
        {
            i = 0;
            if(++loopCount > 1)
            {
                break;
            }
        }

        Shavit_GetStyleStrings(i, sStyleName, styleName, sizeof(styleName));
        if(gA_Styles[track].FindString(styleName) != -1)
        {
            return i;
        }
    }

    return -1;
}

bool GetMyRoute(int client)
{
    if(gS_ReplayFolder[0] == '\0')
    {
        Shavit_GetReplayFolderPath(gS_ReplayFolder, sizeof(gS_ReplayFolder));
    }

    char steamID[64];
    if(!GetClientAuthId(client, AuthId_Steam3, steamID, sizeof(steamID)))
    {
        return false;
    }

    FormatEx(gS_ReplayPath[client], PLATFORM_MAX_PATH, "%s/copy/%d_%s.replay", gS_ReplayFolder, SteamIDToAccountID(steamID), gS_Map);

    RouteType routeType = gRT_RouteType[client];

    PersonalReplay replay;
    Shavit_GetPersonalReplay(client, replay, sizeof(replay));

    replay_header_t header;
    replay.GetHeader(header);

    if(routeType == RouteType_ServerRecord || routeType == RouteType_ServerRecordAuto || (!FileExists(gS_ReplayPath[client]) && routeType == RouteType_Auto) || header.iTrack != Shavit_GetClientTrack(client))
    {
        Shavit_GetReplayFilePath(gI_Style[client] == -1 ? Shavit_GetBhopStyle(client) : gI_Style[client], Shavit_GetClientTrack(client), gS_Map, gS_ReplayFolder, gS_ReplayPath[client]);

        if(!FileExists(gS_ReplayPath[client]))
        {
            return false;
        }
    }

    return true;
}

bool LoadMyRoute(int client)
{
    gB_LoadedReplay[client] = false;

    if(gA_FrameCache[client].aFrames != null)
    {
        gA_FrameCache[client].aFrames.Clear();
    }

    if(!IsValidClient(client) || IsFakeClient(client) || !GetMyRoute(client))
    {
        return false;
    }

    if(FileExists(gS_ReplayPath[client]) && !LoadReplayCache2(gA_FrameCache[client], Shavit_GetClientTrack(client), gS_ReplayPath[client], gS_Map))
    {
        return false;
    }

    if(gA_JumpMarkerCache[client] == null)
    {
        gA_JumpMarkerCache[client] = new ArrayList(sizeof(JumpMarker));
    }
    else
    {
        gA_JumpMarkerCache[client].Clear();
    }

    if(gA_FrameCache[client].aFrames != null && gA_FrameCache[client].aFrames.Length > 0)
    {
        gH_ClosestPos[client] = new ClosestPos(gA_FrameCache[client].aFrames, 0, gA_FrameCache[client].iPreFrames, gA_FrameCache[client].iFrameCount);

        int markerId;

        for(int i = 0; i < gA_FrameCache[client].aFrames.Length; i++)
        {
            int lookAhead = (i + 1) < gA_FrameCache[client].aFrames.Length ? (i + 1) : i;

            frame_t prev, cur;
            gA_FrameCache[client].aFrames.GetArray(lookAhead, cur, sizeof(frame_t));
            gA_FrameCache[client].aFrames.GetArray(lookAhead <= 0 ? 0 : lookAhead - 1, prev, sizeof(frame_t));

            if(IsJump(prev, cur))
            {
                JumpMarker marker;
                marker.Initialize(cur, gI_JumpSize[client], markerId, i);

                markerId++;

                gA_JumpMarkerCache[client].PushArray(marker, sizeof(marker));
            }
        }
    }

    ResetMyRoute(client, Shavit_GetTimerStatus(client) == Timer_Running && gH_ClosestPos[client] != null);

    gB_LoadedReplay[client] = true;

    return true;
}

int GetClientClosestFrame(int client)
{
    float clientPos[3];
    GetClientAbsOrigin(client, clientPos);

    return gH_ClosestPos[client].Find(clientPos);
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
    if(!IsValidClient(client, true) || !gB_LoadedReplay[client] || !gB_ShowRoute[client])
    {
        return;
    }
    else if(gA_FrameCache[client].aFrames == null || (gA_FrameCache[client].aFrames.Length < 1) || gH_ClosestPos[client] == null)
    {
        return;
    }

    int iClosestFrame = GetClientClosestFrame(client);
    int iEndFrame = gA_FrameCache[client].aFrames.Length - 1;

    if(iClosestFrame == gI_PrevFrame[client])
    {
        return;
    }

    if((iClosestFrame - gI_PrevFrame[client]) > 1)
    {
        iClosestFrame = gI_PrevFrame[client] + 1;
    }

    gI_PrevFrame[client] = iClosestFrame;

    int lookAhead = iClosestFrame + gCV_NumAheadFrames.IntValue;

    if(iClosestFrame == iEndFrame)
    {
        return;
    }
    else if(lookAhead >= iEndFrame)
    {
        lookAhead -= (lookAhead - iEndFrame) + 1;
    }

    frame_t replay_prevframe, replay_frame;
    gA_FrameCache[client].aFrames.GetArray(lookAhead, replay_frame, sizeof(frame_t));
    gA_FrameCache[client].aFrames.GetArray(lookAhead <= 0 ? 0 : lookAhead - 1, replay_prevframe, sizeof(frame_t));

    DrawMyRoute(client, replay_prevframe, replay_frame, GetVelocityDifference(client, iClosestFrame));
}

void DrawMyRoute(int client, frame_t prev, frame_t cur, float velDiff)
{
    UpdateColor(client, velDiff);

    if(gB_ShowPath[client])
    {
        BeamEffect(client, prev.pos, cur.pos, 0.7, gI_PathSize[client] / float(MAX_BEAM_WIDTH), gI_PathColorIndex[client] == -1 ? gI_Color[client] : gI_ColorIndex[gI_PathColorIndex[client]]);
    }

    if(!gB_ShowJumps[client] || (gA_JumpMarkerCache[client] != null && gA_JumpMarkerCache[client].Length < 1))
    {
        return;
    }

    int iClosestFrame = GetClientClosestFrame(client);

    for(int i = 0; i < gA_JumpMarkerCache[client].Length; i++)
    {
        JumpMarker current;
        gA_JumpMarkerCache[client].GetArray(i, current, sizeof(current));

        if(current.frameNum >= iClosestFrame)
        {
            gI_JumpsIndex[client] = current.id;
            break;
        }
    }

    if(gI_JumpsIndex[client] >= gA_JumpMarkerCache[client].Length)
    {
        return;
    }
    else if(gF_Delay[client] && (GetEngineTime() - gF_Delay[client]) < DRAW_DELAY)
    {
        return;
    }

    gF_Delay[client] = GetEngineTime();

    JumpMarker marker;
    gA_JumpMarkerCache[client].GetArray(gI_JumpsIndex[client], marker, sizeof(marker));
    marker.Draw(client, gI_ColorIndex[gI_JumpColorIndex[client]]);

    int max = gA_JumpMarkerCache[client].Length;

    if(gI_JumpsAhead[client] >= 1 && gI_JumpsIndex[client] + 1 < max)
    {
        gA_JumpMarkerCache[client].GetArray(gI_JumpsIndex[client] + 1, marker, sizeof(marker));
        marker.Draw(client, gI_ColorIndex[gI_JumpColorIndex[client]]);
    }

    if(gI_JumpsAhead[client] >= 2 && (gI_JumpsIndex[client] + 2 < max))
    {
        gA_JumpMarkerCache[client].GetArray(gI_JumpsIndex[client] + 2, marker, sizeof(marker));
        marker.Draw(client, gI_ColorIndex[gI_JumpColorIndex[client]]);
    }

    if(gI_JumpsAhead[client] >= 3 && (gI_JumpsIndex[client] + 3 < max))
    {
        gA_JumpMarkerCache[client].GetArray(gI_JumpsIndex[client] + 3, marker, sizeof(marker));
        marker.Draw(client, gI_ColorIndex[gI_JumpColorIndex[client]]);
    }

    if(gI_JumpsAhead[client] >= 4 && (gI_JumpsIndex[client] + 4 < max))
    {
        gA_JumpMarkerCache[client].GetArray(gI_JumpsIndex[client] + 4, marker, sizeof(marker));
        marker.Draw(client, gI_ColorIndex[gI_JumpColorIndex[client]]);
    }

    if(gI_JumpsAhead[client] >= 5 && (gI_JumpsIndex[client] + 5 < max))
    {
        gA_JumpMarkerCache[client].GetArray(gI_JumpsIndex[client] + 5, marker, sizeof(marker));
        marker.Draw(client, gI_ColorIndex[gI_JumpColorIndex[client]]);
    }
}

bool IsJump(frame_t prev, frame_t cur)
{
    return (!(cur.flags & FL_ONGROUND) && (prev.flags & FL_ONGROUND));
}

public void Shavit_OnTrackChanged(int client, int oldtrack, int newtrack)
{
    LoadMyRoute(client);
}

public void Shavit_OnStyleChanged(int client, int oldstyle, int newstyle, int track, bool manual)
{
    if(gRT_RouteType[client] == RouteType_ServerRecordAuto)
    {
        gI_Style[client] = newstyle;
    }

    LoadMyRoute(client);
}

public Action Shavit_OnTeleport(int client, int index)
{
    if(Shavit_GetTimerStatus(client) != Timer_Running || !gH_ClosestPos[client])
    {
        return Plugin_Continue;
    }

    ResetMyRoute(client, true);

    return Plugin_Continue;
}

public void Shavit_OnPersonalReplaySaved(int client, int style, int track, const char[] path)
{
    strcopy(gS_ReplayPath[client], PLATFORM_MAX_PATH, path);
    LoadMyRoute(client);
}

public void Shavit_OnPersonalReplayDeleted(int client)
{
    LoadMyRoute(client);
}

public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, bool iscopy, const char[] replaypath, ArrayList frames, int preframes, int postframes, const char[] name)
{
    if(isbestreplay)
    {
        GetStylesWithServerRecord();

        for(int i = 1; i <= MaxClients; i++)
        {
            if(!IsValidClient(i) || IsFakeClient(i))
            {
                continue;
            }
            else if(style != Shavit_GetBhopStyle(i) && track != Shavit_GetClientTrack(i))
            {
                continue;
            }
            else if(gRT_RouteType[i] == RouteType_PersonalReplay && i != client)
            {
                continue;
            }

            LoadMyRoute(i);
        }
    }
}

public void Shavit_OnWRDeleted(int style, int id, int track, int accountid, const char[] mapname)
{
    GetStylesWithServerRecord();

    for(int i = 1; i <= MaxClients; i++)
    {
        if(!IsValidClient(i) || IsFakeClient(i))
        {
            continue;
        }
        else if(style != Shavit_GetBhopStyle(i) && track != Shavit_GetClientTrack(i))
        {
            continue;
        }
        else if(gRT_RouteType[i] == RouteType_PersonalReplay)
        {
            continue;
        }

        LoadMyRoute(i);
    }
}

public void Shavit_OnRestart(int client, int track)
{
    ResetMyRoute(client);
}

void ResetMyRoute(int client, bool closestFrame = false)
{
    int iClosestFrame = -1;

    if(gB_ClosestPos && gH_ClosestPos[client] != null)
    {
        iClosestFrame = GetClientClosestFrame(client);
    }

    gI_Color[client] = gI_ColorIndex[view_as<int>(GREEN)];

    if(closestFrame)
    {
        UpdateColor(client, GetVelocityDifference(client, iClosestFrame));

        return;
    }

    gI_PrevStep[client] = 0;
    gI_PrevFrame[client] = iClosestFrame;
    gI_JumpsIndex[client] = 0;
}

public void BeamEffect(int client, float start[3], float end[3], float duration, float width, const int color[4])
{
    TE_SetupBeamPoints(start, end, gI_BeamSprite, 0, 0, 5, duration, width, width, 0, 0.0, color, 0);
    TE_SendToClient(client);
}

void UpdateColor(int client, float velDiff)
{
    int stepsize = RoundToFloor(velDiff * gCV_VelDiffScalar.FloatValue);

    if((gI_PrevStep[client] - stepsize) == 0)
    {
        return;
    }

    gI_PrevStep[client] = stepsize;

    gI_Color[client][0] -= stepsize;
    gI_Color[client][1] += stepsize;
    gI_Color[client][2] = 0;
    gI_Color[client][3] = gI_PathOpacity[client];

    if(gI_Color[client][0] <= 0)
    {
        gI_Color[client][0] = 0;
    }
    else if(gI_Color[client][0] >= 255)
    {
        gI_Color[client][0] = 255;
    }

    if(gI_Color[client][1] <= 0)
    {
        gI_Color[client][1] = 0;
    }
    else if(gI_Color[client][1] >= 255)
    {
        gI_Color[client][1] = 255;
    }
}

float GetVelocityDifference(int client, int frame)
{
    if(gA_FrameCache[client].aFrames.Length <= 0)
    {
        return 0.0;
    }

    float clientVel[3];
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", clientVel);

    float fReplayPrevPos[3], fReplayClosestPos[3];
    gA_FrameCache[client].aFrames.GetArray(frame, fReplayClosestPos, 3);
    gA_FrameCache[client].aFrames.GetArray(frame <= 0 ? 0 : frame - 1, fReplayPrevPos, 3);

    int style = Shavit_GetBhopStyle(client);

    float replayVel[3];
    MakeVectorFromPoints(fReplayClosestPos, fReplayPrevPos, replayVel);
    ScaleVector(replayVel, (1.0 / GetTickInterval()) / Shavit_GetStyleSettingFloat(style, "speed") / Shavit_GetStyleSettingFloat(style, "timescale"));

    return (SquareRoot(Pow(clientVel[0], 2.0) + Pow(clientVel[1], 2.0))) - (SquareRoot(Pow(replayVel[0], 2.0) + Pow(replayVel[1], 2.0)));
}

void GetClientRouteType(int client, char[] buffer, int length)
{
    switch(gRT_RouteType[client])
    {
        case RouteType_Auto:
        {
            strcopy(buffer, length, "全自动 (自动匹配数据)");
        }

        case RouteType_PersonalReplay:
        {
            strcopy(buffer, length, "仅个人录像");
        }

        case RouteType_ServerRecord:
        {
            strcopy(buffer, length, "指定服务器记录");
        }

        case RouteType_ServerRecordAuto:
        {
            strcopy(buffer, length, "自动匹配服务器记录");
        }
    }
}

void GetPathType(int client, char[] buffer, int length)
{
    switch(gI_PathColorIndex[client])
    {
        case -1:
        {
            strcopy(buffer, length, "速度差 (根据速度变色)");
        }

        default:
        {
            strcopy(buffer, length, "固定颜色模式");
        }
    }
}

bool UpdateClientCookie(int client, Cookie cookie, const char[] newvalue = "")
{
    char value[4];
    cookie.Get(client, value, sizeof(value));

    if(newvalue[0] == '\0')
    {
        cookie.Set(client, (value[0] == '1') ? "0" : "1");
    }
    else
    {
        cookie.Set(client, newvalue);
    }

    return (value[0] == '1') ? false : true;
}

bool CreateMyRouteMenu(int client, int page = 0)
{
    Menu menu = new Menu(MyRoute_MenuHandler);
    menu.SetTitle("个人路径设置：\n");

    menu.AddItem("enabled", gB_ShowRoute[client] ? "[X] 已启用" : "[ ] 已启用");
    menu.AddItem("-1", "", ITEMDRAW_SPACER);

    char type[64], display[128];
    GetClientRouteType(client, type, sizeof(type));
    FormatEx(display, sizeof(display), "数据源类型: [%s]", type);
    menu.AddItem("type", display);

    if(gRT_RouteType[client] == RouteType_ServerRecord || gRT_RouteType[client] == RouteType_ServerRecordAuto)
    {
        if(gA_Styles[Shavit_GetClientTrack(client)].Length <= 0)
        {
            display = "当前赛道无记录";
        }
        else
        {
            char styleName[64];
            Shavit_GetStyleStrings(gI_Style[client] == -1 ? Shavit_GetBhopStyle(client) : gI_Style[client], sStyleName, styleName, sizeof(styleName));

            int index = gA_Styles[Shavit_GetClientTrack(client)].FindString(styleName);

            if(index != -1)
            {
                gA_Styles[Shavit_GetClientTrack(client)].GetString(index, styleName, sizeof(styleName));
            }

            FormatEx(display, sizeof(display), "记录风格: [%s]", styleName);
        }

        if(gRT_RouteType[client] == RouteType_ServerRecord)
        {
            menu.AddItem("style", display, gA_Styles[Shavit_GetClientTrack(client)].Length <= 0 ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
        }
        else
        {
            menu.AddItem("style", display, ITEMDRAW_DISABLED);
        }
    }

    menu.AddItem("-1", "", ITEMDRAW_SPACER);

    menu.AddItem("pathsettings", "[光束轨迹线设置]");
    menu.AddItem("jumpmarker", "[跳跃标记设置]");

    return menu.DisplayAt(client, page, MENU_TIME_FOREVER);
}

public int MyRoute_MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            char info[64];
            menu.GetItem(param2, info, sizeof(info));

            if(StrEqual(info, "enabled"))
            {
                gB_ShowRoute[param1] = UpdateClientCookie(param1, gH_ShowRouteCookie);
            }
            else if(StrEqual(info, "type"))
            {
                if(++gRT_RouteType[param1] >= RouteType_Size)
                {
                    gRT_RouteType[param1] = RouteType_Auto;
                }

                gI_Style[param1] = (gRT_RouteType[param1] == RouteType_ServerRecord) ? 0 : -1;

                char newvalue[4];
                IntToString(view_as<int>(gRT_RouteType[param1]), newvalue, sizeof(newvalue));
                UpdateClientCookie(param1, gH_RouteTypeCookie, newvalue);

                LoadMyRoute(param1);
            }
            else if(StrEqual(info, "style"))
            {
                if(++gI_Style[param1] >= Shavit_GetStyleCount())
                {
                    gI_Style[param1] = 0;
                }

                gI_Style[param1] = GetClosestStyle(param1);

                char newvalue[4];
                IntToString(view_as<int>(gI_Style[param1]), newvalue, sizeof(newvalue));
                UpdateClientCookie(param1, gH_StyleCookie, newvalue);

                LoadMyRoute(param1);
            }
            else if(StrEqual(info, "pathsettings"))
            {
                CreatePathSettingsMenu(param1);
            }
            else if(StrEqual(info, "jumpmarker"))
            {
                CreateJumpMarkersMenu(param1);
            }

            if(StrEqual(info, "enabled") || StrEqual(info, "type") || StrEqual(info, "style"))
            {
                CreateMyRouteMenu(param1);
            }
        }
    }

    return 0;
}

bool CreatePathSettingsMenu(int client, int page = 0)
{
    Menu menu = new Menu(PathSettings_MenuHandler);
    menu.SetTitle("光束轨迹设置：\n");

    char display[64];

    menu.AddItem("enabled", gB_ShowPath[client] ? "[X] 显示轨迹" : "[ ] 显示轨迹");
    menu.AddItem("-1", "", ITEMDRAW_SPACER);

    char type[64];
    GetPathType(client, type, sizeof(type));

    FormatEx(display, sizeof(display), "着色模式: [%s]", type);
    menu.AddItem("path_type", display);

    if(gI_PathColorIndex[client] != -1)
    {
        menu.AddItem("path_color", "[固定颜色选择]");
    }

    menu.AddItem("-1", "", ITEMDRAW_SPACER);

    FormatEx(display, sizeof(display), "轨迹粗细: [%d]", gI_PathSize[client]);
    menu.AddItem("path_size", display, ITEMDRAW_DISABLED);
    menu.AddItem("increment", "++ 增加粗细 ++");
    menu.AddItem("decrement", "-- 减小粗细 --");

    FormatEx(display, sizeof(display), "光束透明度: [%d]", gI_PathOpacity[client]);
    menu.AddItem("path_opacity", display, ITEMDRAW_DISABLED);
    menu.AddItem("opacity_increment", "++ 增加不透明度 ++");
    menu.AddItem("opacity_decrement", "-- 降低不透明度 --");

    menu.ExitBackButton = true;
    return menu.DisplayAt(client, page, MENU_TIME_FOREVER);
}

public int PathSettings_MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            char info[64];
            menu.GetItem(param2, info, sizeof(info));

            char newvalue[4];

            if(StrEqual(info, "enabled"))
            {
                gB_ShowPath[param1] = UpdateClientCookie(param1, gH_ShowPathCookie);
            }
            else if(StrEqual(info, "increment") || StrEqual(info, "decrement"))
            {
                int value = (StrEqual(info, "increment")) ? 1 : -1;

                gI_PathSize[param1] += value;

                if(gI_PathSize[param1] > MAX_BEAM_WIDTH)
                {
                    gI_PathSize[param1] = 1;
                }
                else if(gI_PathSize[param1] <= 0)
                {
                    gI_PathSize[param1] = MAX_BEAM_WIDTH;
                }

                IntToString(gI_PathSize[param1], newvalue, sizeof(newvalue));
                UpdateClientCookie(param1, gH_PathSizeCookie, newvalue);
            }
            else if(StrEqual(info, "path_type"))
            {
                gI_PathColorIndex[param1] = (gI_PathColorIndex[param1] == -1) ? 0 : -1;

                IntToString(gI_PathColorIndex[param1], newvalue, sizeof(newvalue));
                UpdateClientCookie(param1, gH_PathColorCookie, newvalue);
            }
            else if(StrEqual(info, "path_color"))
            {
                CreateColorMenu(param1, view_as<Color>(gI_PathColorIndex[param1]), PathColor_MenuHandler);

                return 0;
            }
            else if(StrEqual(info, "opacity_increment") || StrEqual(info, "opacity_decrement"))
            {
                int value = (StrEqual(info, "opacity_increment")) ? 50 : -50;

                gI_PathOpacity[param1] += value;

                if(gI_PathOpacity[param1] > 250)
                {
                    gI_PathOpacity[param1] = 0;
                }
                else if(gI_PathOpacity[param1] < 0)
                {
                    gI_PathOpacity[param1] = 250;
                }

                IntToString(gI_PathOpacity[param1], newvalue, sizeof(newvalue));
                UpdateClientCookie(param1, gH_PathOpacityCookie, newvalue);
            }

            CreatePathSettingsMenu(param1, menu.Selection);
        }

        case MenuAction_Cancel:
        {
            if(param2 == MenuCancel_ExitBack)
            {
                CreateMyRouteMenu(param1);
            }
        }
    }

    return 0;
}

public int PathColor_MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            char info[64];
            menu.GetItem(param2, info, sizeof(info));

            int color = StringToInt(info);

            char data[4];
            IntToString(color, data, sizeof(data));

            gI_PathColorIndex[param1] = color;
            gH_PathColorCookie.Set(param1, data);

            CreateColorMenu(param1, view_as<Color>(color), PathColor_MenuHandler);
        }

        case MenuAction_Cancel:
        {
            if(param2 == MenuCancel_ExitBack)
            {
                CreatePathSettingsMenu(param1);
            }
        }
    }

    return 0;
}

bool CreateJumpMarkersMenu(int client, int page = 0)
{
    Menu menu = new Menu(JumpMarkers_MenuHandler);
    menu.SetTitle("跳跃标记设置：\n");

    char display[64];

    menu.AddItem("enabled", gB_ShowJumps[client] ? "[X] 显示标记" : "[ ] 显示标记");
    menu.AddItem("-1", "", ITEMDRAW_SPACER);

    FormatEx(display, sizeof(display), "标记大小: [%d]", gI_JumpSize[client]);
    menu.AddItem("marker_size", display, ITEMDRAW_DISABLED);
    menu.AddItem("increment", "++ 增加标记大小 ++");
    menu.AddItem("decrement", "-- 减小标记大小 --");

    menu.AddItem("-1", "", ITEMDRAW_SPACER);

    menu.AddItem("marker_color", "[修改标记颜色]");

    FormatEx(display, sizeof(display), "前方显示跳跃数: [%d]", gI_JumpsAhead[client]);
    menu.AddItem("jumps_ahead", display);

    menu.ExitBackButton = true;
    return menu.DisplayAt(client, page, MENU_TIME_FOREVER);
}

public int JumpMarkers_MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            char info[64];
            menu.GetItem(param2, info, sizeof(info));

            char newvalue[4];

            if(StrEqual(info, "enabled"))
            {
                gB_ShowJumps[param1] = UpdateClientCookie(param1, gH_ShowJumpsCookie);
            }
            else if(StrEqual(info, "increment") || StrEqual(info, "decrement"))
            {
                int value = (StrEqual(info, "increment")) ? 1 : -1;

                gI_JumpSize[param1] += value;

                if(gI_JumpSize[param1] > MAX_JUMP_SIZE)
                {
                    gI_JumpSize[param1] = 1;
                }
                else if(gI_JumpSize[param1] <= 0)
                {
                    gI_JumpSize[param1] = MAX_JUMP_SIZE;
                }

                IntToString(gI_JumpSize[param1], newvalue, sizeof(newvalue));
                UpdateClientCookie(param1, gH_JumpSizeCookie, newvalue);
            }
            else if(StrEqual(info, "marker_color"))
            {
                CreateColorMenu(param1, view_as<Color>(gI_JumpColorIndex[param1]), JumpMarkerColor_MenuHandler);

                return 0;
            }
            else if(StrEqual(info, "jumps_ahead"))
            {
                if(++gI_JumpsAhead[param1] > MAX_JUMPS_AHEAD)
                {
                    gI_JumpsAhead[param1] = 1;
                }

                IntToString(gI_JumpsAhead[param1], newvalue, sizeof(newvalue));
                UpdateClientCookie(param1, gH_JumpsAheadCookie, newvalue);
            }

            CreateJumpMarkersMenu(param1, menu.Selection);
        }

        case MenuAction_Cancel:
        {
            if(param2 == MenuCancel_ExitBack)
            {
                CreateMyRouteMenu(param1);
            }
        }
    }

    return 0;
}

public int JumpMarkerColor_MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            char info[64];
            menu.GetItem(param2, info, sizeof(info));

            int color = StringToInt(info);

            char data[4];
            IntToString(color, data, sizeof(data));

            gI_JumpColorIndex[param1] = color;
            gH_JumpMarkerColorCookie.Set(param1, data);

            CreateColorMenu(param1, view_as<Color>(color), JumpMarkerColor_MenuHandler);
        }

        case MenuAction_Cancel:
        {
            if(param2 == MenuCancel_ExitBack)
            {
                CreateJumpMarkersMenu(param1);
            }
        }
    }

    return 0;
}

public Action Command_Route(int client, int args)
{
    if(!IsValidClient(client))
    {
        return Plugin_Handled;
    }

    if(!CreateMyRouteMenu(client))
    {
        LogError("无法为 %N 创建菜单", client);
    }

    return Plugin_Handled;
}

public Action Command_ResetRoute(int client, int args)
{
    if(!IsValidClient(client, true))
    {
        return Plugin_Handled;
    }

    ResetMyRoute(client);

    return Plugin_Handled;
}

public Action Command_Debug(int client, int args)
{
    gB_Debug = !gB_Debug;
    ReplyToCommand(client, "路径插件调试模式: %s", gB_Debug ? "开启" : "关闭");

    return Plugin_Handled;
}

bool LoadReplayCache2(frame_cache_t cache, int track, const char[] path, const char[] mapname)
{
    bool success = false;
    replay_header_t header;
    File fFile = ReadReplayHeader(path, header);

    if (fFile != null)
    {
        if (header.iReplayVersion <= REPLAY_FORMAT_SUBVERSION)
        {
            if (header.iReplayVersion < 0x03 || (StrEqual(header.sMap, mapname, false) && header.iTrack == track))
            {
                success = ReadReplayFrames(fFile, header, cache);
            }
        }

        delete fFile;
    }

    return success;
}