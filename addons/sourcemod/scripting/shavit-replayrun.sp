#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <shavit/core>
#include <shavit/wr>
#include <shavit/replay-playback>
#include <shavit/replay-recorder>

#undef REQUIRE_EXTENSIONS
#include <cstrike>

public Plugin myinfo = 
{
	name = "shavit-replayrun",
	author = "fri-end",
	description = "回放你最近的一次录像记录。",
	version = "1.0.1",
	url = "https://github.com/zamboniguy"
};

frame_cache_t aReplayData[MAXPLAYERS + 1];
int gI_PlayerFinishFrame[MAXPLAYERS + 1];

public void OnPluginStart()
{
	// 注册指令
	RegConsoleCmd("sm_replayrun", SM_ReplayRun, "回放你最近的一次记录。");
}

public void OnClientPutInServer(int client)
{
	char sReplayName[MAX_NAME_LENGTH];
	GetClientName(client, sReplayName, sizeof(sReplayName));
	Format(sReplayName, MAX_NAME_LENGTH, "*%s", sReplayName);

	char sAuthID[32];
	GetClientAuthId(client, AuthId_Steam3, sAuthID, sizeof(sAuthID));
	ReplaceString(sAuthID, 32, "[U:1:", "");
	ReplaceString(sAuthID, 32, "]", "");

	aReplayData[client].fTickrate = (1.0 / GetTickInterval());
	aReplayData[client].iPreFrames = 0;
	aReplayData[client].iPostFrames = RoundFloat(FindConVar("shavit_replay_postruntime").FloatValue * aReplayData[client].fTickrate);
	aReplayData[client].iFrameCount = 0;
	aReplayData[client].fTime = -1.0;
	aReplayData[client].bNewFormat = true;
	aReplayData[client].iReplayVersion = 0x09;
	aReplayData[client].sReplayName = sReplayName;
	aReplayData[client].aFrames = new ArrayList(ByteCountToCells(32), 0); 
	aReplayData[client].iSteamID = StringToInt(sAuthID);
}

public void OnClientDisconnect(int client)
{
	aReplayData[client].iPreFrames = 0;
	aReplayData[client].iPostFrames = 0;
	aReplayData[client].iFrameCount = 0;
	aReplayData[client].fTime = -1.0;
	aReplayData[client].bNewFormat = false;
	aReplayData[client].iReplayVersion = 0x09;
	aReplayData[client].sReplayName = "error";
	delete aReplayData[client].aFrames;
	aReplayData[client].fTickrate = -1.0;
	aReplayData[client].iSteamID = 0;
}

public Action SM_ReplayRun(int client, int args)
{
	if(client == 0) return Plugin_Handled;

	ChangeClientTeam(client, CS_TEAM_SPECTATOR);
	RequestFrame(ReplayRun, GetClientSerial(client));

	return Plugin_Handled;
}

public void ReplayRun(any data)
{
	int client = GetClientFromSerial(data);
	if(client == 0) return;

	// 检查中央回放机器人是否空闲
	if (Shavit_GetReplayStatus(Shavit_GetReplayBotIndex(-1, -1)) == Replay_Idle)
	{
		// 检查是否有可播放的帧数据
		if (aReplayData[client].aFrames != null && aReplayData[client].aFrames.Length > 0)
		{
			Shavit_StartReplayFromFrameCache(Shavit_GetBhopStyle(client), Shavit_GetClientTrack(client), -1.0, client, Shavit_GetReplayBotIndex(-1, -1), Replay_Central, false, aReplayData[client]);
			// \x02 = 暗红, \x01 = 默认, \x10 = 橙色/橄榄色
			PrintToChat(client, " \x02[个人回放]\x01 正在播放你 \x10最近一次\x01 的完成记录。");
		}
		else
		{
			PrintToChat(client, " \x02[个人回放]\x01 没有找到录像数据... \x10无可回放内容\x01。");
		}
	}
	else
	{
		PrintToChat(client, " \x02[个人回放]\x01 请 \x10等待\x01 当前录像机器人停止播放。");
	}
}

public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp)
{
	gI_PlayerFinishFrame[client] = Shavit_GetClientFrameCount(client);
}

public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, ArrayList replaypaths, ArrayList frames, int preframes, int postframes, const char[] name)
{
	if (istoolong || !IsValidClient(client)) return;

	delete aReplayData[client].aFrames;
	aReplayData[client].aFrames = frames.Clone(); 
	aReplayData[client].iPreFrames = preframes;
	aReplayData[client].iPostFrames = postframes;
	aReplayData[client].iFrameCount = frames.Length - preframes - postframes;
	aReplayData[client].fTime = time;

	// \x04 = 绿色
	PrintToChat(client, " \x02[个人回放]\x01 你的 \x10个人录像数据\x01 已保存。输入 \x04!replayrun\x01 即可观看。");
}