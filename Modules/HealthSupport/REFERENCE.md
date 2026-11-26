# 算法来源与实现边界

本目录源码独立编写，不包含提取的 Apple 二进制、机器码、系统框架或用户诊断。
只以本地精确静态分析建立的行为规格为参考；公开源码不能把它描述成原生执行验收。

## 精确参考

|组件|版本/build|image UUID|
|---|---|---|
|HealthKit|16.0 / 20A362|A0BC39E6-26DF-3D49-9475-BA98D40F186B|
|HealthDaemon|16.0 / 20A362|3983D225-BEBD-309A-9464-6CAE69E5FB14|
|HealthKit目标|15.4 / 19E241|5763C6BF-DFDD-3615-80F5-F709A77E83D9|
|HealthDaemon目标|15.4 / 19E241|5C7508EA-8D04-3313-BAD4-A5A30202A475|

UUID仅标识审阅的构建，不等于代码完整性或当前加载状态证明。核心不按地址跳转。

## 六槽 reducer

参考原生 `HDStatisticsSleepStages::addSample` / `prevailingSleepStage` 的有限输入规则：
类别 0…5，初始时长零、sequence 最大整数，首次加样赋递增 sequence。
累计时长严格大于 `DBL_MIN` 才参与；最大时长优先，精确同量时首次出现优先。
空结果与非法输入均可返回 sentinel，调用者必须检查 `valid()`；不能据 sentinel 推无数据。

自有实现主动拒绝非法类别、非有限/逆序时间和累计溢出，不复刻原生缺少本地检查的行为。
原生 bool 控制的额外计数、archive/reset 和内存布局不属于此类目标，不作为 ABI 替身。

## 兼容投影

原生 `surfaceSleepStages=false` 在来源选择/统计之后，将 {1,3,4,5} 投影到派生类别 1，
不输出 Awake2。其后同类段在默认 29 秒组合距离内合并，sampleIntervals 做 union，
连接空隙不会变成睡着时长。InBed0 独立处理。

`projectLegacySleepSummary` 仅接受已完成来源与阶段竞争、按日范围裁剪过的、正长度、有限有序且
互不重叠的非 InBed 统计输出；不自行从 raw sample 推导它们。区间采用同一连续时间坐标，
不按日历重算，不假定一天 86400 秒。重叠输出会拒绝，不偷偷挑来源或扣 Awake。

目前组合距离作为显式配置，默认值只对应上述精确参考；未读取设备偏好或用户资料。
该阶段不声称保留来源归因或 Apple tracking 标志，未来 native adapter 必须单独补齐。

拒绝零长度输出、非有限累计或段包围跨度是本模块的输入/输出约束，不宣称与原生对所有
异常浮点完全等价。reducer 的零时长首次出现仍参与 sequence，与投影层的拒绝规则不同。
`data()` 仅在投影成功时可取；reducer 推荐用 `decision()` 同时检查 valid/has_stage/category，
不要仅靠 no_stage sentinel 把非法结果误当成空统计。

## 未实现

原始样本的来源排序、完整多/单样本推进调度、60 秒桶、mask/有效标记、来源切换及 tie 排列。
不能把它们省略成跨来源 union。旧 HKStatistics 结构不具新版 category 结果字段，
也不强转其布局或加载新版框架来填补。

没有设备 runtime 或安装入口；`ModuleReadiness` 对所有类别和值均保持原生接受决策。

## 已实现的流水线局部原语

`SleepStageFragments` 在有限正长度输入、切点位于原区间内时，采用已核 0.01 秒阈值和
numeric0/1 检查顺序，保留有效侧 category/source；中间量使用 whole-left，不改成 end-time。
拒绝端点外和零长度属于模块加强约束，不是声称原生所有这些输入无效。
无效侧为不可消费的自有占位，与 Apple pair-return / in-place 的残留字节不作 ABI 等价。

`SleepSourceMergeAdvance` 仅实现多样本分支的网格公式：
max(g*floor(E/g), g*floor((current+g)/g))，原点为 reference-date 的数值0。
结果可越事件/目标，不 clamp；非有限算术、无实际前进及非有限推进时长均明确失败。
后者是便于接入 duration 统计的加强约束，不伪称原生所有异常输入语义一致。
60 秒 bucket、30 秒 source merge 和29 秒段组合是不同层，不能互换 anchor 或数值。

`SleepSourceSliceAccumulator` 接收上层已经排序/验证/切分的有效片段，实现单次推进
strategy0 的 total 贡献：首片 sourceID 被选，同 source 的阶段/Awake 进入 reducer，
异 source 仅不贡献本次 total，未来 per-source 账本不能因此直接丢弃它们。
输入顺序与有效性必须另证，类本身不会以数字 sourceID 或某个固定设备重排。
每次先复制现有 bucket，完整成功才发布结果，失败不改变 caller bucket。

短边阈值可保留完整片段，导致其跨出某 slice；本贡献器会拒绝该组合，不偷偷裁剪。
所以这些原语尚未组成完整 multi/single dispatch、mask、来源排名及60秒桶流水线。

`SleepAdvanceDispatch` 的目标计划只在g>0且bucketEnd>target时向下取整到网格，
到bucketEnd本身不取整、不以sleep-day anchor改原点，round后target<=current可无须推进。
单 pending子路径只支持空mask与TOTAL，numeric1切分，left有效即累计，current用target。
右片历史标记依原生更新；S即使关闭SeparateBySource也置true。native样本计数未实现，
仅报告该次count布尔参数，不假称counter字段等价。无右片时无pending可消费。
非空mask/按来源账本/目标区间外/异常值均返回显式不支持或失败，不进行raw值比例缩放。

`NumericPolicy`要求binary64且禁止fast-math/finite-math-only构建，以免优化吞掉有限性检查。
它不设置FPCR，主机编译仍不能证明所有目标浮点环境与native逐位一致。

## 统计桶边界

精确16 builder以morningIndex前一天的Gregorian18点构造anchor，components的calendar
另来自保存cache.currentCalendar，默认second60。_HKDateIntervalCollection按calendar加
components得到桶start/end，没有day-end参数，不能固定anchor+86400或1440桶。
统计输出边界来自完整collection桶，而非partial contribution的首尾；末桶也不按sample.end裁剪。
此bucket anchor与source merge reference-date数值0网格不同，不能混成同一坐标规则。

`SleepStatisticsBucketOutput`只接收外层提供的真实桶边界与已完成reducer结果，保留完整桶。
finalized布尔值只是前提，不证明完整推进/来源策略已实现；无prevailing结果与失败分开，
不制造category0/1。InBed分支仍单独处理。未决定无贡献桶是否输出，也不替原生日历做换算。

## 按来源账本与单pending联合更新

`SleepSourceLedger`接收同一稳定canonical mapping会话中的不透明token，不自行把raw sourceID
当bundle分组。每key独立阶段reducer，输入保持顺序；count=false仍加时长，仅报告布尔计数。
容量、非法输入或分配/累计失败不发布candidate map。没有native archive/counter字段ABI。
键不含会话身份，当前接口必须由未来adapter绑定同一桶映射历史；不能任意重编号或
将无关会话接到旧ledger。原生键可为代表sourceID，消费者视作不透明标识。
nil→nonnull或provider消失可让后续原source选另key，旧key统计不迁移，不因此重建账本。

`SleepSingleSourceLedgerAdvance`对同一有效左片同时更新TOTAL与来源ledger，不使用再次独立
切分推测片段；原pending的A/S分别决定native总/来源count参数，时长不被计数flags关闭。
更新全成功才发布TOTAL/ledger/pending/current，非空mask仍拒绝，不偷偷按比例改category。

## 新建睡眠builder的空mask范围

原生新建实现的maskedIntervals为空，桶构造/复制/换桶只传播既有mask；
本builder不调用setMaskedIntervals:error:，来源选择也不写mask，空applyMask在读sample前返回。
因此本专用路径可把mask处理视为identity，不实现比例缩放category。此不变量不能推广到
通用calculator复用/外部mutator/归档状态；模块的非空mask仍明确失败。

## 多pending及有界桶推进

multi先选严格位于current之后的最近start/end或target事件，再按粒度公式得到boundary；
排序由独立adapter提供source-rank sort再非稳定start-only sort的实际等价排列。
回调返回索引排列，验证完整性和唯一性，不能删/复制pending项。当前没有生产排序回调。
每轮TOTAL首有效raw source竞争；来源账本另按非nil bundle group选代表raw source，
只有代表来源更新长期ledger key；nil bundle多样本不贡献ledger但单样本仍可用其key。
H不在multi中被修改，A/S只在各自实际贡献时置true，剩余有效right保持遍历顺序。

`SleepBucketAdvance`有明确maximum_steps和事务性，仅成功后发布全部状态；
它不修复native sorting、外部lookup时点或跨桶calendar历史。默认mask关闭，
未证明ordering/mapping前提时失败，不构成装载或新stage接受许可。

## 已审排序骨架的实现接线

16原生source-rank sort和start-only sort为旧branchy libc++骨架，无depth/heapsort；
本机16.5 SDK libc++15006的sort.h相关控制流与其对应，但公开std::sort默认depth有heap回退。
PinnedSleepPendingOrder使用自定义比较器和trivial索引，直接外部__introsort depth=N，
保持插入阈值30、1000选枢轴分支、非稳定tie移动，depth不耗尽时排除新增heap分支。
不加index/category/end tie-break，provider缺失不做第一遍source排序。

sort.h SHA25633f739d139c79d5467aa69083e696b157c3d73e72711ff7552e6cd66e87d3f36，
独立测试驱动哈希不符时拒绝正向编译；头文件只检查调用者opt-in/版本，不自行认证来源。
版本/宏不是运行时安全证明；
外部工具链依赖未被完整内容寻址，主机parity只对同算法索引与记录一致性作证。
未复制SDK实现进仓库；真实生产build gate和source排名刷新时点仍需接入审查。
排序仅解决排列，不更新bundle/ledger映射；bucket集成仍要求预映射字段在推进期间有效，
或由外层按原生调用时点刷新。当前固定映射fixture不能证明动态lookup已经接通。

## 原始接纳与连续跨桶

原始stage先在桶start用numeric1取right，再在桶end按明确配置numeric0/1取left及raw carry。
collection普通配置用endNumeric1，不可误套multi-advance numeric0。raw在桶外仍按validity
决定，不先求几何交集；短边whole可让pending.start略早于bucket.start。
原生第二次split无条件；自有表示在第一步无有效right时直接给空结果，不消费无效字段，
是有效raw输入的等价简化，不声称执行了两个native函数调用。

BucketAdmission先登记来源，再以新pending.start请求推进旧pending，随后入队并重置H/S/A。
来源ledger可先建空reducer，不通过零时长fake add占用tie序号。carry独立于旧pending/current，
同值不同occurrence不得按字段去重；每项由调用方保证一次性提交。

BucketRollover只支持collection给出的连续next bounds，完成旧桶后重放raw carry；
新current=start、TOTAL/ledger/来源集合全新，mapping上下文也必须由调用方新建。
旧current可超过end，不能用它裁next carry；不固定加60或86400。无carry跳桶查找仍未实现。
返回状态事务性不代表callback副作用回滚，lookup/ranking须由adapter暂存并联合提交。
