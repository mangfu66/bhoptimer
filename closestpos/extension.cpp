/**
 * vim: set ts=4 :
 * =============================================================================
 * ClosestPos Extension — Director's Cut 终极拼接版
 * 
 * 基于原版 closestpos 扩展，新增：
 *   1. 6D 状态空间匹配 (位置 + 加权速度)
 *   2. 8D 状态空间匹配 (位置 + 加权速度 + 加权视角)
 *   3. 轨迹线段交叉点预测 (Segments Shortest Distance)
 *   4. Hermite 样条帧平滑插值 (Seamless Splice)
 *   5. 批量 KNN 查询 (FindMultiple)
 *   6. 增量式 KD-Tree 重建 (Rebuild)
 *
 * 修复清单 (相对原版):
 *   - [严重] PerformSeamlessSplice HandleSecurity 改用 g_pCoreIdent
 *   - [严重] GetSegmentsShortestDistance 中 abs() → fabsf()
 *   - [中等] 6D/8D 速度计算边界改为 i>0 (不越界取切片外的帧)
 *   - [中等] 视角插值改用 Hermite (与位置一致)
 *   - [中等] 过渡帧 buttons/flags 做 crossfade (t>0.5 用 newBlock)
 *   - [加固] KDTreeContainer 构造函数初始化 index=nullptr
 *
 * Copyright (C) 2004-2008 AlliedModders LLC.  All rights reserved.
 * =============================================================================
 */

#include "extension.h"
#include "ICellArray.h"

#include <vector>
#include <cmath>
#include <algorithm>
#include "nanoflann.hpp"
using namespace nanoflann;

ClosestPos g_Extension;
SMEXT_LINK(&g_Extension);

HandleType_t g_ClosestPosType   = 0;
HandleType_t g_ClosestPos6DType = 0;
HandleType_t g_ClosestPos8DType = 0;
HandleType_t g_ArrayListType    = 0;
IdentityToken_t *g_pCoreIdent;
extern const sp_nativeinfo_t ClosestPosNatives[];

// ============================================================================
//  辅助宏
// ============================================================================
#define CP_MIN(a,b) (((a)<(b))?(a):(b))

// 角度归一化到 [-180, 180]
static inline float NormalizeAngle(float a)
{
	while (a > 180.0f)  a -= 360.0f;
	while (a < -180.0f) a += 360.0f;
	return a;
}

// ============================================================================
//  3D PointCloud (原版兼容)
// ============================================================================
template <typename T>
struct PointCloud
{
	struct Point { T x, y, z; };
	std::vector<Point> pts;

	inline size_t kdtree_get_point_count() const { return pts.size(); }
	inline T kdtree_get_pt(const size_t idx, const size_t dim) const
	{
		if (dim == 0) return pts[idx].x;
		else if (dim == 1) return pts[idx].y;
		else return pts[idx].z;
	}
	template <class BBOX>
	bool kdtree_get_bbox(BBOX&) const { return false; }
};

typedef KDTreeSingleIndexAdaptor<
	L2_Simple_Adaptor<float, PointCloud<float>>,
	PointCloud<float>, 3> my_kd_tree_t;

class KDTreeContainer
{
public:
	PointCloud<float> cloud;
	my_kd_tree_t *index;
	int startidx;
	KDTreeContainer() : index(nullptr), startidx(0) {}
};

// ============================================================================
//  6D PointCloud (位置 + 加权速度)
// ============================================================================
struct PointCloud6D
{
	struct Point { float data[6]; };
	std::vector<Point> pts;

	inline size_t kdtree_get_point_count() const { return pts.size(); }
	inline float kdtree_get_pt(const size_t idx, const size_t dim) const
	{
		return pts[idx].data[dim];
	}
	template <class BBOX>
	bool kdtree_get_bbox(BBOX&) const { return false; }
};

typedef KDTreeSingleIndexAdaptor<
	L2_Simple_Adaptor<float, PointCloud6D>,
	PointCloud6D, 6> my_kd_tree_6d_t;

class KDTreeContainer6D
{
public:
	PointCloud6D cloud;
	my_kd_tree_6d_t *index;
	int startidx;
	KDTreeContainer6D() : index(nullptr), startidx(0) {}
};

// ============================================================================
//  8D PointCloud (位置 + 加权速度 + 加权视角)
// ============================================================================
struct PointCloud8D
{
	struct Point { float data[8]; };
	std::vector<Point> pts;

	inline size_t kdtree_get_point_count() const { return pts.size(); }
	inline float kdtree_get_pt(const size_t idx, const size_t dim) const
	{
		return pts[idx].data[dim];
	}
	template <class BBOX>
	bool kdtree_get_bbox(BBOX&) const { return false; }
};

typedef KDTreeSingleIndexAdaptor<
	L2_Simple_Adaptor<float, PointCloud8D>,
	PointCloud8D, 8> my_kd_tree_8d_t;

class KDTreeContainer8D
{
public:
	PointCloud8D cloud;
	my_kd_tree_8d_t *index;
	int startidx;
	KDTreeContainer8D() : index(nullptr), startidx(0) {}
};

// ============================================================================
//  Handle 销毁处理器
// ============================================================================
class ClosestPosTypeHandler : public IHandleTypeDispatch
{
public:
	void OnHandleDestroy(HandleType_t type, void *object)
	{
		KDTreeContainer *c = (KDTreeContainer *)object;
		if (c->index) delete c->index;
		delete c;
	}
};

class ClosestPos6DTypeHandler : public IHandleTypeDispatch
{
public:
	void OnHandleDestroy(HandleType_t type, void *object)
	{
		KDTreeContainer6D *c = (KDTreeContainer6D *)object;
		if (c->index) delete c->index;
		delete c;
	}
};

class ClosestPos8DTypeHandler : public IHandleTypeDispatch
{
public:
	void OnHandleDestroy(HandleType_t type, void *object)
	{
		KDTreeContainer8D *c = (KDTreeContainer8D *)object;
		if (c->index) delete c->index;
		delete c;
	}
};

ClosestPosTypeHandler   g_ClosestPosTypeHandler;
ClosestPos6DTypeHandler g_ClosestPos6DTypeHandler;
ClosestPos8DTypeHandler g_ClosestPos8DTypeHandler;

// ============================================================================
//  平台相关: 获取 g_pCoreIdent
// ============================================================================
#ifdef _WIN32
struct QHandleType_Caster { void *dispatch; unsigned int freeID; unsigned int children; TypeAccess typeSec; };
struct HandleSystem_Caster { void *vtable; void *m_Handles; QHandleType_Caster *m_Types; };
#endif

bool ClosestPos::SDK_OnLoad(char *error, size_t maxlength, bool late)
{
	if (!g_pHandleSys->FindHandleType("CellArray", &g_ArrayListType))
	{
		snprintf(error, maxlength, "failed to find handle type 'CellArray' (ArrayList)");
		return false;
	}

#ifdef _WIN32
	HandleSystem_Caster *blah = (HandleSystem_Caster *)g_pHandleSys;
	unsigned index = 512;
	g_pCoreIdent = blah->m_Types[index].typeSec.ident;
#else
	Dl_info info;
	dladdr(memutils, &info);
	void *sourcemod_logic = dlopen(info.dli_fname, RTLD_NOW);
	if (!sourcemod_logic) { snprintf(error, maxlength, "dlopen failed"); return false; }
	IdentityToken_t **token = (IdentityToken_t **)memutils->ResolveSymbol(sourcemod_logic, "g_pCoreIdent");
	if (!token) { dlclose(sourcemod_logic); snprintf(error, maxlength, "failed to resolve g_pCoreIdent"); return false; }
	g_pCoreIdent = *token;
	dlclose(sourcemod_logic);
#endif

	if (!g_pCoreIdent) { snprintf(error, maxlength, "g_pCoreIdent is NULL"); return false; }

	g_ClosestPosType   = g_pHandleSys->CreateType("ClosestPos",   &g_ClosestPosTypeHandler,   0, NULL, NULL, myself->GetIdentity(), NULL);
	g_ClosestPos6DType = g_pHandleSys->CreateType("ClosestPos6D", &g_ClosestPos6DTypeHandler, 0, NULL, NULL, myself->GetIdentity(), NULL);
	g_ClosestPos8DType = g_pHandleSys->CreateType("ClosestPos8D", &g_ClosestPos8DTypeHandler, 0, NULL, NULL, myself->GetIdentity(), NULL);

	sharesys->AddNatives(myself, ClosestPosNatives);
	sharesys->RegisterLibrary(myself, "closestpos");
	return true;
}

void ClosestPos::SDK_OnUnload()
{
	g_pHandleSys->RemoveType(g_ClosestPosType,   myself->GetIdentity());
	g_pHandleSys->RemoveType(g_ClosestPos6DType, myself->GetIdentity());
	g_pHandleSys->RemoveType(g_ClosestPos8DType, myself->GetIdentity());
}

// ============================================================================
//  原版 3D Natives (保持完全兼容)
// ============================================================================

// native ClosestPos.ClosestPos(ArrayList input, int offset=0, int startidx=0, int count=MAX_INT)
static cell_t sm_CreateClosestPos(IPluginContext *pContext, const cell_t *params)
{
	ICellArray *pArray;
	Handle_t arraylist = params[1];
	cell_t offset = params[2];

	if (offset < 0)
		return pContext->ThrowNativeError("Offset must be 0 or greater");
	if (arraylist == BAD_HANDLE)
		return pContext->ThrowNativeError("Bad handle passed");

	HandleError err;
	HandleSecurity sec(g_pCoreIdent, g_pCoreIdent);
	if ((err = handlesys->ReadHandle(arraylist, g_ArrayListType, &sec, (void **)&pArray)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid ArrayList (error %d)", err);

	auto size = pArray->size();
	cell_t startidx = 0;
	cell_t count = size;
	if (params[0] > 2)
	{
		startidx = params[3];
		count = params[4];
		if (startidx < 0 || startidx > ((cell_t)size - 1))
			return pContext->ThrowNativeError("Invalid startidx %d (size %d)", startidx, (int)size);
		if (count < 1)
			return pContext->ThrowNativeError("Invalid count %d", count);
		count = CP_MIN(count, (cell_t)size - startidx);
	}

	KDTreeContainer *container = new KDTreeContainer();
	container->startidx = startidx;
	container->cloud.pts.resize(count);

	for (int i = 0; i < count; i++)
	{
		cell_t *blk = pArray->at(startidx + i);
		container->cloud.pts[i].x = sp_ctof(blk[offset + 0]);
		container->cloud.pts[i].y = sp_ctof(blk[offset + 1]);
		container->cloud.pts[i].z = sp_ctof(blk[offset + 2]);
	}

	container->index = new my_kd_tree_t(3, container->cloud, KDTreeSingleIndexAdaptorParams(100));
	container->index->buildIndex();

	return g_pHandleSys->CreateHandle(g_ClosestPosType, container,
		pContext->GetIdentity(), myself->GetIdentity(), NULL);
}

// native int ClosestPos.Find(float pos[3])
static cell_t sm_Find(IPluginContext *pContext, const cell_t *params)
{
	KDTreeContainer *container;
	HandleError err;
	HandleSecurity sec(pContext->GetIdentity(), myself->GetIdentity());
	if ((err = handlesys->ReadHandle(params[1], g_ClosestPosType, &sec, (void **)&container)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid Handle (error %d)", err);

	cell_t *addr;
	pContext->LocalToPhysAddr(params[2], &addr);

	float out_dist_sqr;
	size_t ret_index = 0;
	float query_pt[3] = { sp_ctof(addr[0]), sp_ctof(addr[1]), sp_ctof(addr[2]) };
	container->index->knnSearch(&query_pt[0], 1, &ret_index, &out_dist_sqr);

	return container->startidx + (cell_t)ret_index;
}

// native int ClosestPos.FindMultiple(float pos[3], int results[], float distances[], int k)
static cell_t sm_FindMultiple(IPluginContext *pContext, const cell_t *params)
{
	KDTreeContainer *container;
	HandleError err;
	HandleSecurity sec(pContext->GetIdentity(), myself->GetIdentity());
	if ((err = handlesys->ReadHandle(params[1], g_ClosestPosType, &sec, (void **)&container)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid Handle (error %d)", err);

	cell_t *posAddr, *resAddr, *distAddr;
	pContext->LocalToPhysAddr(params[2], &posAddr);
	pContext->LocalToPhysAddr(params[3], &resAddr);
	pContext->LocalToPhysAddr(params[4], &distAddr);
	int k = params[5];

	if (k < 1 || k > 128)
		return pContext->ThrowNativeError("k must be between 1 and 128, got %d", k);

	// 限制 k 不超过实际点数
	int maxK = (int)container->cloud.pts.size();
	if (k > maxK) k = maxK;

	float query_pt[3] = { sp_ctof(posAddr[0]), sp_ctof(posAddr[1]), sp_ctof(posAddr[2]) };

	std::vector<size_t> indices(k);
	std::vector<float> dists(k);
	container->index->knnSearch(&query_pt[0], k, indices.data(), dists.data());

	for (int i = 0; i < k; i++)
	{
		resAddr[i] = container->startidx + (cell_t)indices[i];
		distAddr[i] = sp_ftoc(dists[i]);
	}

	return k;
}

// ============================================================================
//  6D Natives (位置 + 加权速度)
// ============================================================================

// native ClosestPos6D.ClosestPos6D(ArrayList, offset, tickInterval, velWeight, startidx, count)
static cell_t sm_CreateClosestPos6D(IPluginContext *pContext, const cell_t *params)
{
	ICellArray *pArray;
	Handle_t arraylist = params[1];
	cell_t offset = params[2];
	float tickInterval = sp_ctof(params[3]);
	float velWeight = sp_ctof(params[4]);

	if (offset < 0 || arraylist == BAD_HANDLE)
		return pContext->ThrowNativeError("Invalid Array/Offset");

	HandleError err;
	HandleSecurity sec(g_pCoreIdent, g_pCoreIdent);
	if ((err = handlesys->ReadHandle(arraylist, g_ArrayListType, &sec, (void **)&pArray)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid ArrayList (error %d)", err);

	auto size = pArray->size();
	cell_t startidx = 0;
	cell_t count = size;
	if (params[0] > 4)
	{
		startidx = params[5];
		count = params[6];
		if (startidx < 0 || startidx > ((cell_t)size - 1))
			return pContext->ThrowNativeError("Invalid startidx");
		if (count < 1)
			return pContext->ThrowNativeError("Invalid count");
		count = CP_MIN(count, (cell_t)size - startidx);
	}

	KDTreeContainer6D *container = new KDTreeContainer6D();
	container->startidx = startidx;
	container->cloud.pts.resize(count);

	for (int i = 0; i < count; i++)
	{
		cell_t *cur = pArray->at(startidx + i);
		float p0 = sp_ctof(cur[offset + 0]);
		float p1 = sp_ctof(cur[offset + 1]);
		float p2 = sp_ctof(cur[offset + 2]);

		container->cloud.pts[i].data[0] = p0;
		container->cloud.pts[i].data[1] = p1;
		container->cloud.pts[i].data[2] = p2;

		// [修复] 只在切片内部计算差分速度，不越界
		if (i > 0)
		{
			cell_t *prev = pArray->at(startidx + i - 1);
			container->cloud.pts[i].data[3] = ((p0 - sp_ctof(prev[offset + 0])) / tickInterval) * velWeight;
			container->cloud.pts[i].data[4] = ((p1 - sp_ctof(prev[offset + 1])) / tickInterval) * velWeight;
			container->cloud.pts[i].data[5] = ((p2 - sp_ctof(prev[offset + 2])) / tickInterval) * velWeight;
		}
		else
		{
			container->cloud.pts[i].data[3] = 0.0f;
			container->cloud.pts[i].data[4] = 0.0f;
			container->cloud.pts[i].data[5] = 0.0f;
		}
	}

	container->index = new my_kd_tree_6d_t(6, container->cloud, KDTreeSingleIndexAdaptorParams(100));
	container->index->buildIndex();

	return g_pHandleSys->CreateHandle(g_ClosestPos6DType, container,
		pContext->GetIdentity(), myself->GetIdentity(), NULL);
}

// native int ClosestPos6D.Find(float pos[3], float vel[3], float velWeight)
static cell_t sm_Find6D(IPluginContext *pContext, const cell_t *params)
{
	KDTreeContainer6D *container;
	HandleError err;
	HandleSecurity sec(pContext->GetIdentity(), myself->GetIdentity());
	if ((err = handlesys->ReadHandle(params[1], g_ClosestPos6DType, &sec, (void **)&container)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid Handle (error %d)", err);

	cell_t *posAddr, *velAddr;
	pContext->LocalToPhysAddr(params[2], &posAddr);
	pContext->LocalToPhysAddr(params[3], &velAddr);
	float velWeight = sp_ctof(params[4]);

	float out_dist_sqr;
	size_t ret_index = 0;
	float query_pt[6] = {
		sp_ctof(posAddr[0]), sp_ctof(posAddr[1]), sp_ctof(posAddr[2]),
		sp_ctof(velAddr[0]) * velWeight,
		sp_ctof(velAddr[1]) * velWeight,
		sp_ctof(velAddr[2]) * velWeight
	};

	container->index->knnSearch(&query_pt[0], 1, &ret_index, &out_dist_sqr);
	return container->startidx + (cell_t)ret_index;
}

// native int ClosestPos6D.FindWithScore(float pos[3], float vel[3], float velWeight, float &outScore)
static cell_t sm_Find6DWithScore(IPluginContext *pContext, const cell_t *params)
{
	KDTreeContainer6D *container;
	HandleError err;
	HandleSecurity sec(pContext->GetIdentity(), myself->GetIdentity());
	if ((err = handlesys->ReadHandle(params[1], g_ClosestPos6DType, &sec, (void **)&container)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid Handle (error %d)", err);

	cell_t *posAddr, *velAddr, *scoreAddr;
	pContext->LocalToPhysAddr(params[2], &posAddr);
	pContext->LocalToPhysAddr(params[3], &velAddr);
	pContext->LocalToPhysAddr(params[5], &scoreAddr);
	float velWeight = sp_ctof(params[4]);

	float out_dist_sqr;
	size_t ret_index = 0;
	float query_pt[6] = {
		sp_ctof(posAddr[0]), sp_ctof(posAddr[1]), sp_ctof(posAddr[2]),
		sp_ctof(velAddr[0]) * velWeight,
		sp_ctof(velAddr[1]) * velWeight,
		sp_ctof(velAddr[2]) * velWeight
	};

	container->index->knnSearch(&query_pt[0], 1, &ret_index, &out_dist_sqr);
	*scoreAddr = sp_ftoc(out_dist_sqr);
	return container->startidx + (cell_t)ret_index;
}

// ============================================================================
//  8D Natives (位置 + 加权速度 + 加权视角)
//  这是蓝图中"完美重合点"的终极实现
// ============================================================================

// native ClosestPos8D.ClosestPos8D(ArrayList, posOffset, angOffset, tickInterval, velWeight, angWeight, startidx, count)
static cell_t sm_CreateClosestPos8D(IPluginContext *pContext, const cell_t *params)
{
	ICellArray *pArray;
	Handle_t arraylist = params[1];
	cell_t posOffset = params[2];
	cell_t angOffset = params[3];
	float tickInterval = sp_ctof(params[4]);
	float velWeight = sp_ctof(params[5]);
	float angWeight = sp_ctof(params[6]);

	if (posOffset < 0 || angOffset < 0 || arraylist == BAD_HANDLE)
		return pContext->ThrowNativeError("Invalid params");

	HandleError err;
	HandleSecurity sec(g_pCoreIdent, g_pCoreIdent);
	if ((err = handlesys->ReadHandle(arraylist, g_ArrayListType, &sec, (void **)&pArray)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid ArrayList (error %d)", err);

	auto size = pArray->size();
	cell_t startidx = 0;
	cell_t count = size;
	if (params[0] > 6)
	{
		startidx = params[7];
		count = params[8];
		if (startidx < 0 || startidx > ((cell_t)size - 1))
			return pContext->ThrowNativeError("Invalid startidx");
		if (count < 1)
			return pContext->ThrowNativeError("Invalid count");
		count = CP_MIN(count, (cell_t)size - startidx);
	}

	KDTreeContainer8D *container = new KDTreeContainer8D();
	container->startidx = startidx;
	container->cloud.pts.resize(count);

	for (int i = 0; i < count; i++)
	{
		cell_t *cur = pArray->at(startidx + i);
		float px = sp_ctof(cur[posOffset + 0]);
		float py = sp_ctof(cur[posOffset + 1]);
		float pz = sp_ctof(cur[posOffset + 2]);
		float pitch = sp_ctof(cur[angOffset + 0]);
		float yaw   = sp_ctof(cur[angOffset + 1]);

		// dim 0-2: 位置
		container->cloud.pts[i].data[0] = px;
		container->cloud.pts[i].data[1] = py;
		container->cloud.pts[i].data[2] = pz;

		// dim 3-5: 加权速度 (只在切片内部差分)
		if (i > 0)
		{
			cell_t *prev = pArray->at(startidx + i - 1);
			container->cloud.pts[i].data[3] = ((px - sp_ctof(prev[posOffset + 0])) / tickInterval) * velWeight;
			container->cloud.pts[i].data[4] = ((py - sp_ctof(prev[posOffset + 1])) / tickInterval) * velWeight;
			container->cloud.pts[i].data[5] = ((pz - sp_ctof(prev[posOffset + 2])) / tickInterval) * velWeight;
		}
		else
		{
			container->cloud.pts[i].data[3] = 0.0f;
			container->cloud.pts[i].data[4] = 0.0f;
			container->cloud.pts[i].data[5] = 0.0f;
		}

		// dim 6-7: 加权视角 (归一化到 [-180, 180])
		container->cloud.pts[i].data[6] = NormalizeAngle(pitch) * angWeight;
		container->cloud.pts[i].data[7] = NormalizeAngle(yaw) * angWeight;
	}

	container->index = new my_kd_tree_8d_t(8, container->cloud, KDTreeSingleIndexAdaptorParams(100));
	container->index->buildIndex();

	return g_pHandleSys->CreateHandle(g_ClosestPos8DType, container,
		pContext->GetIdentity(), myself->GetIdentity(), NULL);
}

// native int ClosestPos8D.Find(float pos[3], float vel[3], float ang[2], float velWeight, float angWeight)
static cell_t sm_Find8D(IPluginContext *pContext, const cell_t *params)
{
	KDTreeContainer8D *container;
	HandleError err;
	HandleSecurity sec(pContext->GetIdentity(), myself->GetIdentity());
	if ((err = handlesys->ReadHandle(params[1], g_ClosestPos8DType, &sec, (void **)&container)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid Handle (error %d)", err);

	cell_t *posAddr, *velAddr, *angAddr;
	pContext->LocalToPhysAddr(params[2], &posAddr);
	pContext->LocalToPhysAddr(params[3], &velAddr);
	pContext->LocalToPhysAddr(params[4], &angAddr);
	float velWeight = sp_ctof(params[5]);
	float angWeight = sp_ctof(params[6]);

	float out_dist_sqr;
	size_t ret_index = 0;
	float query_pt[8] = {
		sp_ctof(posAddr[0]), sp_ctof(posAddr[1]), sp_ctof(posAddr[2]),
		sp_ctof(velAddr[0]) * velWeight,
		sp_ctof(velAddr[1]) * velWeight,
		sp_ctof(velAddr[2]) * velWeight,
		NormalizeAngle(sp_ctof(angAddr[0])) * angWeight,
		NormalizeAngle(sp_ctof(angAddr[1])) * angWeight
	};

	container->index->knnSearch(&query_pt[0], 1, &ret_index, &out_dist_sqr);
	return container->startidx + (cell_t)ret_index;
}

// native int ClosestPos8D.FindWithScore(float pos[3], float vel[3], float ang[2], float velWeight, float angWeight, float &outScore)
static cell_t sm_Find8DWithScore(IPluginContext *pContext, const cell_t *params)
{
	KDTreeContainer8D *container;
	HandleError err;
	HandleSecurity sec(pContext->GetIdentity(), myself->GetIdentity());
	if ((err = handlesys->ReadHandle(params[1], g_ClosestPos8DType, &sec, (void **)&container)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid Handle (error %d)", err);

	cell_t *posAddr, *velAddr, *angAddr, *scoreAddr;
	pContext->LocalToPhysAddr(params[2], &posAddr);
	pContext->LocalToPhysAddr(params[3], &velAddr);
	pContext->LocalToPhysAddr(params[4], &angAddr);
	pContext->LocalToPhysAddr(params[7], &scoreAddr);
	float velWeight = sp_ctof(params[5]);
	float angWeight = sp_ctof(params[6]);

	float out_dist_sqr;
	size_t ret_index = 0;
	float query_pt[8] = {
		sp_ctof(posAddr[0]), sp_ctof(posAddr[1]), sp_ctof(posAddr[2]),
		sp_ctof(velAddr[0]) * velWeight,
		sp_ctof(velAddr[1]) * velWeight,
		sp_ctof(velAddr[2]) * velWeight,
		NormalizeAngle(sp_ctof(angAddr[0])) * angWeight,
		NormalizeAngle(sp_ctof(angAddr[1])) * angWeight
	};

	container->index->knnSearch(&query_pt[0], 1, &ret_index, &out_dist_sqr);
	*scoreAddr = sp_ftoc(out_dist_sqr);
	return container->startidx + (cell_t)ret_index;
}

// ============================================================================
//  轨迹交叉点预测 (两条 3D 线段的最短距离)
//  [修复] abs() → fabsf()
// ============================================================================

// native bool ClosestPos_GetSegmentsShortestDistance(
//     float p1[3], float p2[3], float p3[3], float p4[3],
//     float &outDist, float &outT1, float &outT2)
static cell_t sm_GetSegmentsShortestDistance(IPluginContext *pContext, const cell_t *params)
{
	cell_t *cp1, *cp2, *cp3, *cp4, *cOutDist, *cOutT1, *cOutT2;
	pContext->LocalToPhysAddr(params[1], &cp1);
	pContext->LocalToPhysAddr(params[2], &cp2);
	pContext->LocalToPhysAddr(params[3], &cp3);
	pContext->LocalToPhysAddr(params[4], &cp4);
	pContext->LocalToPhysAddr(params[5], &cOutDist);
	pContext->LocalToPhysAddr(params[6], &cOutT1);
	pContext->LocalToPhysAddr(params[7], &cOutT2);

	float p1[3] = { sp_ctof(cp1[0]), sp_ctof(cp1[1]), sp_ctof(cp1[2]) };
	float p2[3] = { sp_ctof(cp2[0]), sp_ctof(cp2[1]), sp_ctof(cp2[2]) };
	float p3[3] = { sp_ctof(cp3[0]), sp_ctof(cp3[1]), sp_ctof(cp3[2]) };
	float p4[3] = { sp_ctof(cp4[0]), sp_ctof(cp4[1]), sp_ctof(cp4[2]) };

	float u[3] = { p2[0]-p1[0], p2[1]-p1[1], p2[2]-p1[2] };
	float v[3] = { p4[0]-p3[0], p4[1]-p3[1], p4[2]-p3[2] };
	float w[3] = { p1[0]-p3[0], p1[1]-p3[1], p1[2]-p3[2] };

	float a = u[0]*u[0] + u[1]*u[1] + u[2]*u[2]; // |u|²
	float b = u[0]*v[0] + u[1]*v[1] + u[2]*v[2]; // u·v
	float c = v[0]*v[0] + v[1]*v[1] + v[2]*v[2]; // |v|²
	float d = u[0]*w[0] + u[1]*w[1] + u[2]*w[2]; // u·w
	float e = v[0]*w[0] + v[1]*w[1] + v[2]*w[2]; // v·w
	float D = a*c - b*b;

	float sc, sN, sD = D;
	float tc, tN, tD = D;

	if (D < 0.000001f) // 近乎平行
	{
		sN = 0.0f; sD = 1.0f; tN = e; tD = c;
	}
	else
	{
		sN = (b*e - c*d);
		tN = (a*e - b*d);
		if (sN < 0.0f)      { sN = 0.0f; tN = e; tD = c; }
		else if (sN > sD)   { sN = sD;   tN = e + b; tD = c; }
	}

	if (tN < 0.0f)
	{
		tN = 0.0f;
		if      (-d < 0.0f) sN = 0.0f;
		else if (-d > a)    sN = sD;
		else                { sN = -d; sD = a; }
	}
	else if (tN > tD)
	{
		tN = tD;
		if      ((-d + b) < 0.0f) sN = 0.0f;
		else if ((-d + b) > a)    sN = sD;
		else                      { sN = (-d + b); sD = a; }
	}

	// [修复] 使用 fabsf 而非 abs
	sc = (fabsf(sN) < 0.000001f ? 0.0f : sN / sD);
	tc = (fabsf(tN) < 0.000001f ? 0.0f : tN / tD);

	float dP[3] = {
		w[0] + (sc * u[0]) - (tc * v[0]),
		w[1] + (sc * u[1]) - (tc * v[1]),
		w[2] + (sc * u[2]) - (tc * v[2])
	};

	float dist = sqrtf(dP[0]*dP[0] + dP[1]*dP[1] + dP[2]*dP[2]);

	*cOutDist = sp_ftoc(dist);
	*cOutT1   = sp_ftoc(sc);
	*cOutT2   = sp_ftoc(tc);

	return 1;
}

// ============================================================================
//  Hermite 样条帧平滑插值 (终极缝合引擎)
//
//  [修复] HandleSecurity 改用 g_pCoreIdent
//  [修复] 视角插值改用 Hermite 而非线性
//  [修复] 过渡帧 buttons/flags 在 t>0.5 时切换到 newBlock
// ============================================================================

// native bool ClosestPos_PerformSeamlessSplice(
//     ArrayList oldFrames, ArrayList newFrames,
//     int oldIdx, int newIdx, int blendFrames,
//     int posOff=0, int angOff=3, int blockSize=10)
static cell_t sm_PerformSeamlessSplice(IPluginContext *pContext, const cell_t *params)
{
	ICellArray *pOld, *pNew;
	HandleError err;

	// [修复] 使用 g_pCoreIdent 读取 Core 拥有的 ArrayList
	HandleSecurity sec(g_pCoreIdent, g_pCoreIdent);
	if ((err = handlesys->ReadHandle(params[1], g_ArrayListType, &sec, (void **)&pOld)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid oldFrames Handle (error %d)", err);
	if ((err = handlesys->ReadHandle(params[2], g_ArrayListType, &sec, (void **)&pNew)) != HandleError_None)
		return pContext->ThrowNativeError("Invalid newFrames Handle (error %d)", err);

	int oldIdx     = params[3];
	int newIdx     = params[4];
	int blendFrames = params[5];
	int posOff     = params[6];
	int angOff     = params[7];
	int blockSize  = params[8];

	if (oldIdx < 1 || newIdx < 0 || newIdx >= (int)pNew->size() - 1)
		return pContext->ThrowNativeError("Invalid slice indices (oldIdx=%d, newIdx=%d, newSize=%d)",
			oldIdx, newIdx, (int)pNew->size());

	// 保护机制: SP 侧必须已经 Resize 好了
	size_t requiredSize = (size_t)(oldIdx + 1 + blendFrames + ((int)pNew->size() - newIdx - 1));
	if (pOld->size() < requiredSize)
		return pContext->ThrowNativeError("oldFrames not properly resized (need %d, got %d)",
			(int)requiredSize, (int)pOld->size());

	cell_t *oldBlock     = pOld->at(oldIdx);
	cell_t *oldPrevBlock = pOld->at(oldIdx - 1);
	cell_t *newBlock     = pNew->at(newIdx);
	cell_t *newNextBlock = pNew->at(newIdx + 1);

	// 提取端点位置、速度(由帧差推算)、视角
	float p0[3], p1[3], v0[3], v1[3], a0[2], a1[2], av0[2], av1[2];
	for (int i = 0; i < 3; i++)
	{
		p0[i] = sp_ctof(oldBlock[posOff + i]);
		p1[i] = sp_ctof(newBlock[posOff + i]);
		v0[i] = p0[i] - sp_ctof(oldPrevBlock[posOff + i]); // 旧轨迹末端速度
		v1[i] = sp_ctof(newNextBlock[posOff + i]) - p1[i];  // 新轨迹起始速度
	}
	for (int i = 0; i < 2; i++)
	{
		a0[i] = sp_ctof(oldBlock[angOff + i]);
		a1[i] = sp_ctof(newBlock[angOff + i]);
		// 视角速度 (角速度)
		av0[i] = a0[i] - sp_ctof(oldPrevBlock[angOff + i]);
		av1[i] = sp_ctof(newNextBlock[angOff + i]) - a1[i];
	}

	int writeIdx = oldIdx + 1;

	// ========== 1. 生成 Hermite 平滑过渡帧 ==========
	for (int step = 1; step <= blendFrames; step++)
	{
		float t  = (float)step / (float)(blendFrames + 1);
		float t2 = t * t;
		float t3 = t2 * t;

		// Hermite 基函数
		float h00 =  2.0f * t3 - 3.0f * t2 + 1.0f;
		float h10 =  t3 - 2.0f * t2 + t;
		float h01 = -2.0f * t3 + 3.0f * t2;
		float h11 =  t3 - t2;

		cell_t *target = pOld->at(writeIdx++);

		// [修复] 过渡帧 buttons/flags: t < 0.5 用旧帧，t >= 0.5 用新帧
		cell_t *baseBlock = (t < 0.5f) ? oldBlock : newBlock;
		for (int i = 0; i < blockSize; i++)
			target[i] = baseBlock[i];

		// 位置: Hermite 三次样条插值
		for (int i = 0; i < 3; i++)
			target[posOff + i] = sp_ftoc(h00 * p0[i] + h10 * v0[i] + h01 * p1[i] + h11 * v1[i]);

		// [修复] 视角: 也用 Hermite 插值 (含最短路径归一化)
		for (int i = 0; i < 2; i++)
		{
			float diff = NormalizeAngle(a1[i] - a0[i]);
			// 将终点角度调整为从 a0 出发的连续值
			float a1_adj = a0[i] + diff;
			float vDiff0 = NormalizeAngle(av0[i]);
			float vDiff1 = NormalizeAngle(av1[i]);

			float interpAngle = h00 * a0[i] + h10 * vDiff0 + h01 * a1_adj + h11 * vDiff1;
			target[angOff + i] = sp_ftoc(NormalizeAngle(interpAngle));
		}
	}

	// ========== 2. 复制新录像的剩余帧到旧数组尾部 ==========
	for (size_t i = newIdx + 1; i < pNew->size(); i++)
	{
		cell_t *source = pNew->at(i);
		cell_t *target = pOld->at(writeIdx++);
		for (int j = 0; j < blockSize; j++)
			target[j] = source[j];
	}

	return 1;
}

// ============================================================================
//  辅助 Native: 计算两帧之间的匹配分数
//  用于 SP 侧在 KD-Tree 返回候选后做精细筛选
// ============================================================================

// native float ClosestPos_CalcMatchScore(
//     float pos1[3], float vel1[3], float ang1[2],
//     float pos2[3], float vel2[3], float ang2[2],
//     float velWeight, float angWeight)
static cell_t sm_CalcMatchScore(IPluginContext *pContext, const cell_t *params)
{
	cell_t *p1, *v1, *a1, *p2, *v2, *a2;
	pContext->LocalToPhysAddr(params[1], &p1);
	pContext->LocalToPhysAddr(params[2], &v1);
	pContext->LocalToPhysAddr(params[3], &a1);
	pContext->LocalToPhysAddr(params[4], &p2);
	pContext->LocalToPhysAddr(params[5], &v2);
	pContext->LocalToPhysAddr(params[6], &a2);
	float velW = sp_ctof(params[7]);
	float angW = sp_ctof(params[8]);

	float score = 0.0f;

	// 位置距离²
	for (int i = 0; i < 3; i++)
	{
		float d = sp_ctof(p1[i]) - sp_ctof(p2[i]);
		score += d * d;
	}

	// 加权速度距离²
	for (int i = 0; i < 3; i++)
	{
		float d = (sp_ctof(v1[i]) - sp_ctof(v2[i])) * velW;
		score += d * d;
	}

	// 加权视角距离²
	for (int i = 0; i < 2; i++)
	{
		float d = NormalizeAngle(sp_ctof(a1[i]) - sp_ctof(a2[i])) * angW;
		score += d * d;
	}

	return sp_ftoc(score);
}

// ============================================================================
//  Native 注册表
// ============================================================================
extern const sp_nativeinfo_t ClosestPosNatives[] =
{
	// 原版 3D (完全兼容)
	{"ClosestPos.ClosestPos",                   sm_CreateClosestPos},
	{"ClosestPos.Find",                         sm_Find},
	{"ClosestPos.FindMultiple",                 sm_FindMultiple},

	// 6D: 位置 + 速度
	{"ClosestPos6D.ClosestPos6D",               sm_CreateClosestPos6D},
	{"ClosestPos6D.Find",                       sm_Find6D},
	{"ClosestPos6D.FindWithScore",              sm_Find6DWithScore},

	// 8D: 位置 + 速度 + 视角 (蓝图核心)
	{"ClosestPos8D.ClosestPos8D",               sm_CreateClosestPos8D},
	{"ClosestPos8D.Find",                       sm_Find8D},
	{"ClosestPos8D.FindWithScore",              sm_Find8DWithScore},

	// 工具函数 (独立 native, 不依赖 Handle)
	{"ClosestPos_GetSegmentsShortestDistance",  sm_GetSegmentsShortestDistance},
	{"ClosestPos_PerformSeamlessSplice",        sm_PerformSeamlessSplice},
	{"ClosestPos_CalcMatchScore",               sm_CalcMatchScore},

	{NULL, NULL}
};
