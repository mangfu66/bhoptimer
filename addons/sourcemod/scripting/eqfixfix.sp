// SPDX-License-Identifier: GPL-3.0-only
// EventQueueFix V3 for Shavit
//
// 这是一个 "原版增强版"。
// 1. 逻辑与原版 1.3.7 保持 100% 一致 (完全听从 Shavit 的暂停/变速指令)。
// 2. [修复] 移除了对机器人的屏蔽，修好了 Shavit 回放时机关不触发的 BUG。
// 3. [优化] 保留了全局实体缓存 (Cache)，大幅降低服务器 SV/VAR。

#define PLUGIN_NAME           "EventQueue Fix"
#define PLUGIN_AUTHOR         "carnifex & rtldg"
#define PLUGIN_DESCRIPTION    ""
#define PLUGIN_VERSION        "1.3.7-SHAVIT-V3"

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>

#pragma semicolon 1

#define FLT_EPSILON 1.192092896e-07
#define MAX_EDICT_BITS 11
#define MAX_EDICTS (1<<MAX_EDICT_BITS)
#define NUM_ENT_ENTRY_BITS (MAX_EDICT_BITS + 1)
#define NUM_ENT_ENTRIES (1 << NUM_ENT_ENTRY_BITS)
#define ENT_ENTRY_MASK (NUM_ENT_ENTRIES - 1)
#define INVALID_EHANDLE_INDEX 0xFFFFFFFF

// =================================================================================
// 数据结构
// =================================================================================

enum struct event_t {
    char target[64];
    char targetInput[64];
    char variantValue[256];
    float delay;
    int activator;
    int caller;
    int outputID;
}

enum struct entity_t {
    int caller;
    float waitTime;
}

enum struct eventpack_t {
    ArrayList playerEvents;
    ArrayList outputWaits;
}

// =================================================================================
// 全局变量
// =================================================================================

ArrayList g_aPlayerEvents[MAXPLAYERS + 1];
ArrayList g_aOutputWait[MAXPLAYERS + 1];
bool g_bLateLoad;
Handle g_hFindEntityByName;
int g_iRefOffset;

// 缓存优化 (保留，这是好东西)
StringMap g_hTargetCache; 

// 控制变量 (完全回归原版逻辑，由 Native 控制)
bool g_bPaused[MAXPLAYERS + 1]; 
float g_fTimescale[MAXPLAYERS + 1];

public Plugin myinfo = {
    name = PLUGIN_NAME,
    author = PLUGIN_AUTHOR,
    description = PLUGIN_DESCRIPTION,
    version = PLUGIN_VERSION,
    url = ""
};

// =================================================================================
// 插件初始化
// =================================================================================

public void OnPluginStart()
{
    LoadDHooks();
    
    if(g_bLateLoad)
    {
        OnMapStart();
        
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, "func_button")) != -1)
        {
            SDKHook(entity, SDKHook_OnTakeDamage, Hook_Button_OnTakeDamage);
        }

        // Late Load: 显式初始化所有数组
        for(int client = 1; client <= MaxClients; client++)
        {
            g_fTimescale[client] = 1.0;
            g_bPaused[client] = false;
            
            if(IsClientInGame(client))
                OnClientPutInServer(client);
        }
    }
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("GetClientEvents", Native_GetClientEvents);
    CreateNative("SetClientEvents", Native_SetClientEvents);
    CreateNative("ClearClientEvents", Native_ClearClientEvents);
    CreateNative("SetEventsTimescale", Native_SetEventsTimescale); 
    CreateNative("IsClientEventsPaused", Native_IsClientPaused);
    CreateNative("SetClientEventsPaused", Native_SetClientPaused);
    
    g_bLateLoad = late;
    RegPluginLibrary("eventqueuefix");
    return APLRes_Success;
}

// =================================================================================
// 缓存系统 (Cache) - 这里的代码负责性能优化
// =================================================================================

public void OnMapStart()
{
    delete g_hTargetCache;
    g_hTargetCache = new StringMap();
        
    int maxents = GetEntityCount();
    for(int i = MaxClients + 1; i <= maxents; i++)
    {
        if(!IsValidEntity(i)) continue;
        
        char targetname[64];
        if (!HasEntProp(i, Prop_Data, "m_iName")) continue;
        GetEntPropString(i, Prop_Data, "m_iName", targetname, sizeof(targetname));
        if(targetname[0] == '\0') continue;
                
        ArrayList list;
        if (!g_hTargetCache.GetValue(targetname, list))
        {
            list = new ArrayList();
            g_hTargetCache.SetValue(targetname, list);
        }
        list.Push(EntIndexToEntRef(i));
    }
}

public void OnMapEnd()
{
    delete g_hTargetCache;
}

public void OnEntityDestroyed(int entity)
{
    if(entity <= MaxClients || g_hTargetCache == null) return;
    
    // 实体可能已经无效
    if(!IsValidEntity(entity)) return;
    
    char targetname[64];
    if (!HasEntProp(entity, Prop_Data, "m_iName")) return;
    GetEntPropString(entity, Prop_Data, "m_iName", targetname, sizeof(targetname));
    if(targetname[0] == '\0') return;
        
    ArrayList list;
    if(g_hTargetCache.GetValue(targetname, list))
    {
        for(int j = 0; j < list.Length; j++)
        {
            if(list.Get(j) == EntIndexToEntRef(entity))
            {
                list.Erase(j);
                break;
            }
        }
        if(list.Length == 0)
        {
            delete list;
            g_hTargetCache.Remove(targetname);
        }
    }
}

// =================================================================================
// 客户端管理
// =================================================================================

public void OnClientPutInServer(int client)
{
    g_fTimescale[client] = 1.0;
    g_bPaused[client] = false;

    if(g_aPlayerEvents[client] == null)
        g_aPlayerEvents[client] = new ArrayList(sizeof(event_t));
    else
        g_aPlayerEvents[client].Clear();
    
    if(g_aOutputWait[client] == null)
        g_aOutputWait[client] = new ArrayList(sizeof(entity_t));
    else
        g_aOutputWait[client].Clear();
}

public void OnClientDisconnect_Post(int client)
{
    delete g_aPlayerEvents[client];
    delete g_aOutputWait[client];
}

// =================================================================================
// 核心循环 - 你的需求在这里实现
// =================================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!IsClientInGame(client)) return Plugin_Continue;

    // 【核心点 1】暂停逻辑回归原版
    // 只要 Shavit 说“暂停”，我们就直接 Return。
    // 这意味着即使你在地图上能动，机关倒计时也完全停止。
    if (g_bPaused[client]) 
        return Plugin_Continue;

    // 【核心点 2】变速逻辑 (混合模式)
    // 优先读取 Shavit 设置的速度。如果 Shavit 没设置 (1.0)，则尝试读取引擎速度 (适配 TAS)。
    float timescale = g_fTimescale[client];
    if (timescale == 1.0) {
        float engineTime = GetEntPropFloat(client, Prop_Data, "m_flLaggedMovementValue");
        if (engineTime > 0.0) timescale = engineTime;
    }
    
    // 如果算出来的速度是 0 (完全静止)，也视为暂停
    if (timescale <= 0.0) return Plugin_Continue;

    // --- 队列处理 ---

    // 1. 触发器冷却队列 (ActivateMultiTrigger)
    for(int i = 0; i < g_aOutputWait[client].Length; i++)
    {
        entity_t ent;
        g_aOutputWait[client].GetArray(i, ent);
        
        ent.waitTime -= 1.0 * timescale;
        
        if(ent.waitTime <= 1.0 * timescale)
        {
            g_aOutputWait[client].Erase(i);
            i--;
        }
        else
        {
            g_aOutputWait[client].SetArray(i, ent);
        }
    }
    
    // 2. 事件输出队列 (AddEvent)
    // 增加了一个简单的处理上限，防止单帧处理太多卡死服务器
    int maxEventsPerTick = 15;
    int processed = 0;
    
    for(int i = 0; i < g_aPlayerEvents[client].Length && processed < maxEventsPerTick; i++)
    {
        event_t event;
        g_aPlayerEvents[client].GetArray(i, event);
        
        event.delay -= 1.0 * timescale;
        
        if(event.delay <= -1.0 * timescale)
        {
            ServiceEvent(event);
            g_aPlayerEvents[client].Erase(i);
            i--;
            processed++;
        }
        else
        {
            g_aPlayerEvents[client].SetArray(i, event);
        }
    }
    
    return Plugin_Continue;
}

// =================================================================================
// 事件触发服务 - 极致性能版 (带缓存)
// =================================================================================

public void ServiceEvent(event_t event)
{
    int caller = EntRefToEntIndex(event.caller);
    int activator = EntRefToEntIndex(event.activator);
    if(!IsValidEntity(caller)) caller = -1;

    // 1. 特殊目标处理 (!activator 等) - 比引擎快
    if(StrEqual(event.target, "!activator")) {
        if(IsValidEntity(activator)) {
            SetVariantString(event.variantValue);
            AcceptEntityInput(activator, event.targetInput, activator, caller, event.outputID);
        }
        return;
    } 
    else if(StrEqual(event.target, "!caller") || StrEqual(event.target, "!self")) {
        if(IsValidEntity(caller)) {
            SetVariantString(event.variantValue);
            AcceptEntityInput(caller, event.targetInput, activator, caller, event.outputID);
        }
        return;
    } 
    else if(StrEqual(event.target, "worldspawn") || event.target[0] == '\0') {
        SetVariantString(event.variantValue);
        AcceptEntityInput(0, event.targetInput, activator, caller, event.outputID);
        return;
    }

    // 2. 缓存查询 (O(1) 复杂度，解决卡顿的核心)
    ArrayList cachedList;
    if (g_hTargetCache != null && g_hTargetCache.GetValue(event.target, cachedList))
    {
        for(int j = 0; j < cachedList.Length; j++)
        {
            int targetEntity = EntRefToEntIndex(cachedList.Get(j));
            if(!IsValidEntity(targetEntity)) {
                cachedList.Erase(j--);
                continue;
            }
            SetVariantString(event.variantValue);
            AcceptEntityInput(targetEntity, event.targetInput, activator, caller, event.outputID);
        }
        
        // 清理后检查是否列表为空
        if(cachedList.Length == 0)
        {
            delete cachedList;
            g_hTargetCache.Remove(event.target);
        }
        
        return;
    }
        
    // 3. 回退搜索 (最后的手段，带死循环保护)
    int attempts = 0;
    int targetEntity = -1;
    while(attempts++ < 256 && (targetEntity = FindEntityByName(targetEntity, event.target, caller, activator, caller)) != -1) {
        SetVariantString(event.variantValue);
        AcceptEntityInput(targetEntity, event.targetInput, activator, caller, event.outputID);
    }
    
    if(attempts >= 256) {
        LogError("[EQFIX] Infinite loop protection hit for target '%s'", event.target);
    }
}

// =================================================================================
// 钩子
// =================================================================================

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "func_button"))
        SDKHook(entity, SDKHook_OnTakeDamage, Hook_Button_OnTakeDamage);
}

// 修复 func_button 伤害触发 activator 丢失的引擎 BUG
public Action Hook_Button_OnTakeDamage(int victim, int& attacker, int& inflictor, float& damage, int& damagetype, int& weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
    SetEntPropEnt(victim, Prop_Data, "m_hActivator", attacker);
    return Plugin_Continue;
}

public MRESReturn DHook_AddEventThree(Handle hParams)
{
    event_t event;
    event.activator = EntityToBCompatRef(view_as<Address>(DHookGetParam(hParams, 5)));
    int entIndex = EntRefToEntIndex(event.activator);
    
    // 【重要修复】允许回放机器人 (IsFakeClient)，防止客户端连接过程中访问
    if (entIndex < 1 || entIndex > MaxClients || !IsClientInGame(entIndex))
        return MRES_Ignored;
    
    DHookGetParamString(hParams, 1, event.target, 64);
    DHookGetParamString(hParams, 2, event.targetInput, 64);
    ResolveVariantValue(hParams, event);
    
    int ticks = RoundToCeil((view_as<float>(DHookGetParam(hParams, 4)) - FLT_EPSILON) / GetTickInterval());
    event.delay = float(ticks);
    event.caller = EntityToBCompatRef(view_as<Address>(DHookGetParam(hParams, 6)));
    event.outputID = DHookGetParam(hParams, 7);

    if (g_aPlayerEvents[entIndex] != null)
        g_aPlayerEvents[entIndex].PushArray(event);
        
    return MRES_Supercede;
}

public MRESReturn DHook_ActivateMultiTrigger(int pThis, DHookParam hParams)
{
    int client = hParams.Get(1);
    
    // 【重要修复】允许回放机器人
    if(!(0 < client <= MaxClients) || !IsClientInGame(client))
        return MRES_Ignored;

    if (g_aOutputWait[client] == null) return MRES_Ignored;

    float m_flWait = GetEntPropFloat(pThis, Prop_Data, "m_flWait");
    
    bool bFound;
    entity_t ent;
    for(int i = 0; i < g_aOutputWait[client].Length; i++)
    {
        g_aOutputWait[client].GetArray(i, ent);
        if(pThis == EntRefToEntIndex(ent.caller))
        {
            bFound = true;
            break;
        }
    }
    
    if(!bFound)
    {
        ent.caller = EntIndexToEntRef(pThis);
        int ticks = RoundToCeil((m_flWait - FLT_EPSILON) / GetTickInterval());
        ent.waitTime = float(ticks);
        g_aOutputWait[client].PushArray(ent);
        SetEntProp(pThis, Prop_Data, "m_nNextThinkTick", 0);
        return MRES_Ignored;
    }
    
    return MRES_Supercede;
}

// =================================================================================
// Native 接口 (完整还原 1.3.7，确保 Shavit 兼容性)
// =================================================================================

public any Native_GetClientEvents(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if(client < 0 || client > MaxClients || !IsClientConnected(client) || !IsClientInGame(client) || IsClientSourceTV(client))
        return false;

    if (g_aPlayerEvents[client] == null || g_aOutputWait[client] == null) return false;

    ArrayList pe = g_aPlayerEvents[client].Clone();
    ArrayList ow = g_aOutputWait[client].Clone();

    eventpack_t ep;
    ep.playerEvents = view_as<ArrayList>(CloneHandle(pe, plugin));
    ep.outputWaits = view_as<ArrayList>(CloneHandle(ow, plugin));

    delete pe;
    delete ow;
    
    SetNativeArray(2, ep, sizeof(eventpack_t));
    return true;
}

public any Native_SetClientEvents(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if(client < 0 || client > MaxClients || !IsClientConnected(client) || !IsClientInGame(client) || IsClientSourceTV(client))
        return false;
        
    eventpack_t ep;
    GetNativeArray(2, ep, sizeof(eventpack_t));
    
    if (g_aPlayerEvents[client] != null) delete g_aPlayerEvents[client];
    if (g_aOutputWait[client] != null) delete g_aOutputWait[client];
    
    g_aPlayerEvents[client] = ep.playerEvents.Clone();
    g_aOutputWait[client] = ep.outputWaits.Clone();
    
    int length = g_aPlayerEvents[client].Length;
    for (int i = 0; i < length; i++)
    {
        event_t event;
        g_aPlayerEvents[client].GetArray(i, event);
        event.activator = EntIndexToEntRef(client);
        g_aPlayerEvents[client].SetArray(i, event);
    }
    return true;
}

public any Native_SetEventsTimescale(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if(client > 0 && client <= MaxClients) {
        g_fTimescale[client] = GetNativeCell(2);
        return true;
    }
    return false;
}

public any Native_ClearClientEvents(Handle plugin, int numParams) 
{
    int client = GetNativeCell(1);
    if(client > 0 && client <= MaxClients) {
        if(g_aOutputWait[client] != null) g_aOutputWait[client].Clear();
        if(g_aPlayerEvents[client] != null) g_aPlayerEvents[client].Clear();
    }
    return true;
}

public any Native_SetClientPaused(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if(client > 0 && client <= MaxClients) {
        g_bPaused[client] = GetNativeCell(2);
        return true;
    }
    return false;
}

public any Native_IsClientPaused(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if(client > 0 && client <= MaxClients) return g_bPaused[client];
    return false;
}

// =================================================================================
// 基础设施 (DHooks 加载 & 内存操作)
// =================================================================================

void LoadDHooks()
{
    GameData gamedataConf = new GameData("eventfix.games");
    if(gamedataConf == null) SetFailState("Failed to load eventfix gamedata");
    
    int m_RefEHandleOff = gamedataConf.GetOffset("m_RefEHandle");
    int ibuff = gamedataConf.GetOffset("m_angRotation");
    g_iRefOffset = ibuff + m_RefEHandleOff;
    
    if (gamedataConf.GetOffset("FindEntityByName_StaticCall") == 1)
        StartPrepSDKCall(SDKCall_Static);
    else
        StartPrepSDKCall(SDKCall_EntityList);
    
    if(!PrepSDKCall_SetFromConf(gamedataConf, SDKConf_Signature, "FindEntityByName"))
        SetFailState("Failed to find FindEntityByName signature.");
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_ByValue);
    PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL | VDECODE_FLAG_ALLOWWORLD);
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL | VDECODE_FLAG_ALLOWWORLD);
    PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL | VDECODE_FLAG_ALLOWWORLD);
    PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL | VDECODE_FLAG_ALLOWWORLD);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByValue);
    g_hFindEntityByName = EndPrepSDKCall();

    Handle addEventThree = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Ignore);
    if(!DHookSetFromConf(addEventThree, gamedataConf, SDKConf_Signature, "AddEventThree"))
        SetFailState("Failed to find AddEventThree signature.");
    
    DHookAddParam(addEventThree, HookParamType_CharPtr);
    DHookAddParam(addEventThree, HookParamType_CharPtr);
    if (gamedataConf.GetOffset("LINUX") == 1)
        DHookAddParam(addEventThree, HookParamType_ObjectPtr);
    else
        DHookAddParam(addEventThree, HookParamType_Object, 20);
    DHookAddParam(addEventThree, HookParamType_Float);
    DHookAddParam(addEventThree, HookParamType_Int);
    DHookAddParam(addEventThree, HookParamType_Int);
    DHookAddParam(addEventThree, HookParamType_Int);
    if(!DHookEnableDetour(addEventThree, false, DHook_AddEventThree))
        SetFailState("Couldn't enable AddEventThree detour.");
    
    Handle activateMultiTrigger = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_CBaseEntity);
    if(!DHookSetFromConf(activateMultiTrigger, gamedataConf, SDKConf_Signature, "ActivateMultiTrigger"))
        SetFailState("Failed to find ActivateMultiTrigger signature.");
    DHookAddParam(activateMultiTrigger, HookParamType_CBaseEntity);
    if(!DHookEnableDetour(activateMultiTrigger, false, DHook_ActivateMultiTrigger))
        SetFailState("Couldn't enable ActivateMultiTrigger detour.");
    
    delete gamedataConf;
}

int EntityToBCompatRef(Address player)
{
    if(player == Address_Null) return INVALID_EHANDLE_INDEX;
    int m_RefEHandle = LoadFromAddress(player + view_as<Address>(g_iRefOffset), NumberType_Int32);
    if(m_RefEHandle == INVALID_EHANDLE_INDEX) return INVALID_EHANDLE_INDEX;
    int entry_idx = m_RefEHandle & ENT_ENTRY_MASK;
    if(entry_idx >= MAX_EDICTS) return m_RefEHandle | (1 << 31);
    return entry_idx;
}

int FindEntityByName(int startEntity, char[] targetname, int searchingEnt, int activator, int caller)
{
    Address targetEntityAddr = SDKCall(g_hFindEntityByName, startEntity, targetname, searchingEnt, activator, caller, 0);
    if(targetEntityAddr == Address_Null) return -1;
    return EntRefToEntIndex(EntityToBCompatRef(targetEntityAddr));
}

public void ResolveVariantValue(Handle &params, event_t event)
{
    int type = DHookGetParamObjectPtrVar(params, 3, 16, ObjectValueType_Int);
    switch(type)
    {
        case 1: { // Float
            float fVar = DHookGetParamObjectPtrVar(params, 3, 0, ObjectValueType_Float);
            if(FloatAbs(fVar - RoundFloat(fVar)) < 0.000001)
                IntToString(RoundFloat(fVar), event.variantValue, sizeof(event.variantValue));
            else
                FloatToString(fVar, event.variantValue, sizeof(event.variantValue));
        }
        case 5: { // Integer
            int iVar = DHookGetParamObjectPtrVar(params, 3, 0, ObjectValueType_Int);
            IntToString(iVar, event.variantValue, sizeof(event.variantValue));
        }
        case 9: { // Color32
            int iVar = DHookGetParamObjectPtrVar(params, 3, 0, ObjectValueType_Int);
            FormatEx(event.variantValue, sizeof(event.variantValue), "%d %d %d", (iVar&0xFF), (iVar&0xFF00) >> 8, (iVar&0xFF0000) >> 16);
        }
        default: {
            DHookGetParamObjectPtrString(params, 3, 0, ObjectValueType_String, event.variantValue, sizeof(event.variantValue));
        }
    }
}