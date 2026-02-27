#if defined _closestpos_included
 #endinput
#endif
#define _closestpos_included

// =============================================================================
//  ClosestPos Extension — Director's Cut 终极拼接版
//  Include 文件
//
//  功能总览:
//    ClosestPos   — 原版 3D 空间最近邻查询 (完全向后兼容)
//    ClosestPos6D — 6D 状态匹配 (位置 + 加权速度)
//    ClosestPos8D — 8D 状态匹配 (位置 + 加权速度 + 加权视角)
//    工具函数     — 线段交叉预测 / Hermite 帧拼接 / 匹配分数计算
// =============================================================================


// =============================================
//  1. 原版 3D 接口 (完全保留向后兼容)
// =============================================
methodmap ClosestPos < Handle {
    /**
     * 从 ArrayList 的帧数据构建 3D KD-Tree
     *
     * @param input      包含帧数据的 ArrayList (blocksize >= offset+3)
     * @param offset     位置数据在每个 block 中的起始偏移量
     * @param startidx   起始索引 (用于子区间查询)
     * @param count      要索引的帧数量
     */
    public native ClosestPos(ArrayList input, int offset = 0, int startidx = 0, int count = 2147483646);

    /**
     * 查找最近的帧索引
     *
     * @param pos        查询的 3D 坐标
     * @return           最近帧在原始 ArrayList 中的索引
     */
    public native int Find(float pos[3]);

    /**
     * 批量 KNN 查询：返回 k 个最近邻
     *
     * @param pos        查询的 3D 坐标
     * @param results    输出数组，存放 k 个最近帧的索引
     * @param distances  输出数组，存放对应的距离平方值
     * @param k          要查询的近邻数量 (1~128)
     * @return           实际返回的结果数量 (可能小于 k)
     */
    public native int FindMultiple(float pos[3], int[] results, float[] distances, int k);
};


// =============================================
//  2. 6D 高维状态匹配 (位置 + 加权速度)
//
//  用途: 在 mid-stage 拼接时，同时匹配空间位置和运动方向
//        速度权重 velWeight 控制速度维度在距离计算中的影响力
//        典型值: velWeight = 0.01 ~ 0.05
// =============================================
methodmap ClosestPos6D < Handle {
    /**
     * 从 ArrayList 构建 6D KD-Tree
     * 自动从相邻帧差分计算速度，并乘以 velWeight
     *
     * @param input         帧数据 ArrayList
     * @param offset        位置数据偏移量
     * @param tickInterval  服务器 tick 间隔 (GetTickInterval())
     * @param velWeight     速度维度权重
     * @param startidx      起始索引
     * @param count         帧数量
     */
    public native ClosestPos6D(ArrayList input, int offset, float tickInterval, float velWeight,
                                int startidx = 0, int count = 2147483646);

    /**
     * 6D 最近邻查询
     *
     * @param pos        当前 3D 位置
     * @param vel        当前 3D 速度矢量
     * @param velWeight  查询时使用的速度权重 (应与构建时一致)
     * @return           最匹配帧的索引
     */
    public native int Find(float pos[3], float vel[3], float velWeight);

    /**
     * 6D 最近邻查询 (带匹配分数输出)
     * outScore 是 6D 欧氏距离的平方，越小越匹配
     *
     * @param pos        当前 3D 位置
     * @param vel        当前 3D 速度矢量
     * @param velWeight  速度权重
     * @param outScore   输出: 匹配分数 (距离²)
     * @return           最匹配帧的索引
     */
    public native int FindWithScore(float pos[3], float vel[3], float velWeight, float &outScore);
};


// =============================================
//  3. 8D 完美状态匹配 (位置 + 速度 + 视角)
//
//  这是蓝图中"运动状态完美重合点"的终极实现
//  同时考虑空间位置、运动速度和玩家视角
//
//  典型权重:
//    velWeight = 0.02   (速度差 50 u/s ≈ 位置差 1 unit)
//    angWeight = 0.1    (视角差 10° ≈ 位置差 1 unit)
// =============================================
methodmap ClosestPos8D < Handle {
    /**
     * 从 ArrayList 构建 8D KD-Tree
     *
     * @param input         帧数据 ArrayList
     * @param posOffset     位置数据偏移量 (通常是 0, 对应 frame_t.pos)
     * @param angOffset     视角数据偏移量 (通常是 3, 对应 frame_t.ang)
     * @param tickInterval  tick 间隔
     * @param velWeight     速度权重
     * @param angWeight     视角权重
     * @param startidx      起始索引
     * @param count         帧数量
     */
    public native ClosestPos8D(ArrayList input, int posOffset, int angOffset,
                                float tickInterval, float velWeight, float angWeight,
                                int startidx = 0, int count = 2147483646);

    /**
     * 8D 最近邻查询
     *
     * @param pos        当前位置 [3]
     * @param vel        当前速度 [3]
     * @param ang        当前视角 [2] (pitch, yaw)
     * @param velWeight  速度权重
     * @param angWeight  视角权重
     * @return           最匹配帧索引
     */
    public native int Find(float pos[3], float vel[3], float ang[2], float velWeight, float angWeight);

    /**
     * 8D 最近邻查询 (带匹配分数)
     *
     * @param pos        当前位置 [3]
     * @param vel        当前速度 [3]
     * @param ang        当前视角 [2]
     * @param velWeight  速度权重
     * @param angWeight  视角权重
     * @param outScore   输出: 8D 距离²
     * @return           最匹配帧索引
     */
    public native int FindWithScore(float pos[3], float vel[3], float ang[2],
                                     float velWeight, float angWeight, float &outScore);
};


// =============================================
//  4. 工具函数 (独立 native, 不依赖任何 Handle)
// =============================================

/**
 * 轨迹线段交叉分析：计算两条 3D 线段的最短距离
 *
 * 用途: 检测"失败前的轨迹"与"重新起跳的轨迹"在空间中是否交叉
 *       当 outDist < threshold 且速度差小时，即为理想拼接点
 *
 * @param p1       线段1起点
 * @param p2       线段1终点
 * @param p3       线段2起点
 * @param p4       线段2终点
 * @param outDist  输出: 最短距离 (units)
 * @param outT1    输出: 线段1上最近点的参数 (0.0~1.0)
 * @param outT2    输出: 线段2上最近点的参数 (0.0~1.0)
 * @return         始终返回 true
 */
native bool ClosestPos_GetSegmentsShortestDistance(
    float p1[3], float p2[3], float p3[3], float p4[3],
    float &outDist, float &outT1, float &outT2);

/**
 * 内存级 Hermite 样条帧平滑拼接引擎
 *
 * 将 oldFrames[0..oldIdx] + blendFrames个过渡帧 + newFrames[newIdx+1..end]
 * 写入 oldFrames 中。过渡帧使用三次 Hermite 样条在位置和视角上做平滑插值。
 *
 * ⚠️ 调用前必须在 SP 中执行:
 *   oldFrames.Resize(oldIdx + 1 + blendFrames + (newFrames.Length - newIdx - 1));
 *
 * @param oldFrames    旧录像帧数组 (将被就地修改)
 * @param newFrames    新录像帧数组 (只读)
 * @param oldIdx       旧录像的拼接点帧索引 (≥1)
 * @param newIdx       新录像的拼接点帧索引
 * @param blendFrames  过渡帧数量 (推荐 3~8)
 * @param posOff       位置字段在 block 中的偏移 (默认 0)
 * @param angOff       视角字段在 block 中的偏移 (默认 3)
 * @param blockSize    每帧的总 cell 数 (默认 10, 即 sizeof(frame_t))
 * @return             成功返回 true
 */
native bool ClosestPos_PerformSeamlessSplice(
    ArrayList oldFrames, ArrayList newFrames,
    int oldIdx, int newIdx, int blendFrames,
    int posOff = 0, int angOff = 3, int blockSize = 10);

/**
 * 计算两个运动状态之间的综合匹配分数
 *
 * 返回值是加权后的 8D 欧氏距离平方:
 *   score = Σ(pos_diff²) + Σ((vel_diff * velW)²) + Σ((ang_diff * angW)²)
 *
 * 用于在 KD-Tree 返回的多个候选中做精细二次筛选
 *
 * @param pos1, vel1, ang1   状态 A
 * @param pos2, vel2, ang2   状态 B
 * @param velWeight          速度权重
 * @param angWeight          视角权重
 * @return                   匹配分数 (越小越好)
 */
native float ClosestPos_CalcMatchScore(
    float pos1[3], float vel1[3], float ang1[2],
    float pos2[3], float vel2[3], float ang2[2],
    float velWeight, float angWeight);


// =============================================
//  5. 扩展信息
// =============================================
public Extension __ext_closestpos =
{
    name = "ClosestPos",
    file = "closestpos.ext",
#if defined AUTOLOAD_EXTENSIONS
    autoload = 1,
#else
    autoload = 0,
#endif
#if defined REQUIRE_EXTENSIONS
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_EXTENSIONS
public void __ext_closestpos_SetNTVOptional()
{
    // 3D (原版兼容)
    MarkNativeAsOptional("ClosestPos.ClosestPos");
    MarkNativeAsOptional("ClosestPos.Find");
    MarkNativeAsOptional("ClosestPos.FindMultiple");

    // 6D
    MarkNativeAsOptional("ClosestPos6D.ClosestPos6D");
    MarkNativeAsOptional("ClosestPos6D.Find");
    MarkNativeAsOptional("ClosestPos6D.FindWithScore");

    // 8D
    MarkNativeAsOptional("ClosestPos8D.ClosestPos8D");
    MarkNativeAsOptional("ClosestPos8D.Find");
    MarkNativeAsOptional("ClosestPos8D.FindWithScore");

    // 工具函数
    MarkNativeAsOptional("ClosestPos_GetSegmentsShortestDistance");
    MarkNativeAsOptional("ClosestPos_PerformSeamlessSplice");
    MarkNativeAsOptional("ClosestPos_CalcMatchScore");
}
#endif
