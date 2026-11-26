# Health Support（已纳入 WatchFix 插件构建，默认不启用）

本目录现在是 WatchFix 工程中的正式模块目录；`Plugins/HealthSupport` 会把已验证的
Runtime 编入 WatchFix 插件包。插件默认不启用：没有用户安装动作时不会写 marker，
不会让 healthd 加载或安装 hook。顶层 Makefile 仍提供 `healthsupport-offline-check` 入口。

第一阶段目标：在 iOS 15.4 上保留真实睡眠阶段，并提供旧健康界面可用的睡眠时长。
**已有离线核心、假对象适配及独立LoadCheck构建候选，尚无可安装或可启用的健康修复。**

`LoadCheck/README.md`说明独立构建的arm64/arm64e加载核验候选：不读取健康样本，
不装hook、不开放接收。产物未签名、未包装、未上机；不进入普通构建或“全部安装”。

最新状态：独立候选曾获单次设备授权，E1七边界metadata匹配；injector收尾异常及高CPU后，
经另授权仅重启healthd恢复低CPU，用户确认健康App正常。原injector停用，无生产健康hook。
上述“未上机”等是早期候选说明，具体历史/恢复以本机reports当前状态为准。

恢复后新增operation-scoped day准入：显式failure与binding/builder/cache/代次必须一致，
工作前和发布前检查；已有首错阻止后续candidate，enum delivery/terminal亦核代次。
正常nil/native error优先/原异常保持；同步归属、late-end排除和native完整覆盖前提仍保留。

后续operation wrapper清理已使用generation-scoped end，旧调用不关闭新代次；day准入增加
统计/InBed后及原调用前检查，失败时不再进入原create。原调用内失败只拒绝发布不承诺回滚。
这不建立native线程独占，真正caller/完整查询覆盖和安全部署仍未接通。

新增`QueryRouteProbe/`独立本地工程候选：显式安装四个真实查询方法的透传替换，关联
enumerator/profile/cache与实际返回builder，仅计数观察、不读样本或改摘要。不是LoadCheck，
也不调用统计适配；没有constructor/filter/安全加载通路或普通构建集成，尚未设备运行。
详细边界见其README；fresh-cache和完整caller准入未证，不能借它开启HealthSupport。

## 已实现

- `Core/SleepStageDurationReducer.hpp`：按精确 iOS 16 证据独立编写的六槽阶段时长选择。
  最大时长优先，同量时最早首次进入者优先；清醒保留参与上游统计。
- `Core/LegacyDerivedSummary.hpp`：仅对来源选择/阶段竞争完成后的统计区间进行旧式投影，
  将睡着集合 1/3/4/5 表达为派生 category1，省略 Awake2，并保留区间空隙不计时。
  不是原始样本合并器，不接受 InBed0、未知值、乱序或重叠的统计输出。
  也拒绝零长度统计输出，防止空点把两个不相连的区间桥接。失败结果的 `data()` 为
  `nullptr`，不能直接读取成“零时长”；成功空结果则有非空数据对象。
- `Core/ModuleReadiness.hpp`：编译时关闭的运行时门；任何值仍保持原系统接受/拒绝结果。
- `Core/SleepStageFragments.hpp`：正长度有效片段的阶段保真切分，显式 0.01 秒阈值顺序；
  不修改输入，只有有效侧可消费，不模拟原生无效侧残留字段或 ABI。
- `Core/SleepSourceMergeAdvance.hpp`：已核多样本网格推进公式，不擅自 clamp；
  可越过事件/目标，不能当成完整事件选择器或单样本快速路径。
- `Core/SleepSourceSliceAccumulator.hpp`：对已排序、切分且有效的单次推进片段执行
  strategy0 总统计贡献门控，首个有效来源参与，同来源保留 Awake 和阶段竞争。
  不自行猜来源排名；不同来源不贡献本次 total 不等于从全局数据丢弃。
- `Core/SleepAdvanceDispatch.hpp`：外层目标条件取整和单 pending、空 mask、TOTAL-only
  的推进状态。非空 mask、SeparateBySource、目标在片段外仍明确拒绝，未伪称完整 dispatch。
  bucket/pending/current 必须来自同一真实推进历史，接口不能仅凭数值验证或阻止重放。
- `Core/SleepStatisticsBucketOutput.hpp`：已完成统计桶到完整边界输出的接口；保留 Awake
  到后续投影。边界由日历适配器提供，不按样本端点缩短末桶、不推定固定 24 小时。
  现有日历薄适配器只对假collection测试，未接真实原生collection。
- `Core/SleepSourceLedger.hpp`：适配器已解析的来源键各自维护阶段统计，同键可合并不同
  sourceID。键必须来自同一桶映射历史；原生重新分组可改变后续键，旧账本不迁移。
- `Core/SleepSingleSourceLedgerAdvance.hpp`：单 pending 空 mask 路径联合更新总统计、
  来源账本和剩余片段，任一步失败均不发布部分更新；不处理非空 mask 或完整多样本调度。
- `Core/SleepSourceIdentityMap.hpp`：桶内来源键解析的已审 miss 路径，保留 nil bundle 重查、
  非空 bundle 缓存和 provider 消失行为；不擅自冻结 raw sourceID，不迁移旧账本数据。
- `Core/SleepMultiSourceAdvance.hpp`：已排序有效片段的多样本推进，独立保留 raw source、
  账本键和本轮 bundle 分组。只支持已证明为空的 mask，不猜同起点排序。
- `Core/SleepBucketAdvance.hpp`：有步数/资源上限的多→单→空推进编排；排序回调必须是
  经审阅的原生等价适配，当前测试只提供合成排列，因此还不是完整 raw-input 流水线。
- `Core/PinnedSleepPendingOrder.hpp`：固定SDK libc++15006排序骨架的适配，不复制算法源码。
  需要外部驱动先验证已审sort.h哈希并显式opt-in；当前只在独立host测试中编译，
  不进入普通构建。相同算法的索引/完整记录排列回归不等于native运行时差分验收。
- `Core/SleepRawAdmission.hpp`：按桶起止切分的接纳计划，保留whole短边和原始carry，
  不以普通求交替代，不修改输入。
- `Core/SleepBucketAdmission.hpp`：先注册来源、推进旧pending，再加入新pending和空来源账本；
  入口校验不因carry-only或禁止advance分支跳过。
- `Core/SleepBucketRollover.hpp`：按外层提供的连续日历桶完成旧桶、重放独立raw carry；
  新统计、来源和计数状态重新建立，不按旧current裁carry。
- `Core/StableSleepSeries.hpp`：对稳定provider/来源描述和明确连续桶的有界统计控制器，
  可从原始合成stage片段连到多桶结果；当前不支持真实provider变化和完整native query输入。
- `Adapters/CalendarBucketAdapter`、`SourceProviderAdapter`：消费调用者提供的现有对象，
  校验已有方法ABI及返回结构；不查找/创建原生类、不读取样本、不装载HealthKit。
  日历连续性比较有限数值；bundle的实际nil与查询失败分开，来源排列检查成员及唯一性。
- `Adapters/StableSeriesAdapter`：Objective-C++稳定来源子集的薄适配→固定排序→series集成，
  可从调用者给的合成片段生成统计结果再做旧式投影；只经假对象测试。
  bundle预收集只在来源稳定前提下成立，不能代替动态source-key消费点刷新。
- `Adapters/DayBuilderSnapshot`与`SleepSampleAdapter`：真实15.4字段/getter签名的输入适配，
  不重跑init；保留原日区间、三组输入和InBed对象，raw1..5交阶段统计。只经自有假类测试。
- `Adapters/LegacyPeriodAdapter`：投影结果交回旧segment/period工厂，保留sampleIntervals的
  正空隙不计时，空输入不调用旧finish；非nil原summary可保留metadata重建。
  不代表原create已经安全或nil原summary已支持，也不替代真实来源身份守卫。
- `Core/SleepSourceConsumptionContext.hpp`：在实际贡献点分别查bundle与ledger key，
  bundle缓存不提前选key代表；nil重查、provider变化不复用过时入队key。完整query生命周期未接。
- `Core/ConsumptionSleepSeries.hpp`：复用series调度，每桶独立owner与来源context，旧桶完成／
  新carry重放期间两者分别存活；全series字节预算不随换桶刷新。薄适配也已有非预取调用链。
  provider真实weak生命周期及枚举器caller准入仍未接完；后续排名缓存/集合遍历见下项。
- `Core/PinnedSleepSourceRanks.hpp`：限定fresh insert-only路径的固定SDK集合遍历与排名缓存，
  注册数量变化才刷新；每桶私有ordering，不在换桶时误用旧rank。外部hash依赖独立校验。
- `Adapters/QueryBuilderBinding`：query-server fresh-cache链的显式身份关联层，weak profile、
  builder身份和代次匹配，不用TLS；仍未装native hooks或证明实际caller/fresh准入。
- `Adapters/PeriodFinishAdapter`：原finish窄四条件空态保护，copy失败不调危险original，
  正常非空调用original一次且原异常保真。真实finish hook/query失败桥仍未接。
- `Adapters/DaySummaryAdapter`：bound day快照→统计→period preflight→一次受保护原create→
  保留原metadata重建。原metadata INPUT全空且稳定calendar受审时，支持限定stage-only正常nil。
- `Adapters/LoadedMethodIdentity`：已有Class/方法的loaded image、UUID、owner、ABI、IMP/offset
  校验及漂移检测；未绑定宿主/caller准入或hook，check-use排他前提仍由外层满足。
- `Adapters/IOS154BoundaryIdentity`：7个19E241关键方法固定身份契约，离线cache核验
  path/UUID/ABI/offset，自有冷类全部拒绝；并非所有callee或caller来源的完整放行。
- `Adapters/EnumerationAdapter`：显式本次binding及失败通道，不用TLS。保留handler时机／stop，
  day候选失败最终NO+自有NSError，不把nil当普通成功；之前已交付的结果不假称可回滚。
  当前为自有callback整链，未安装到真实枚举器/便利入口。
- `Adapters/StageWriteBoundary`：真实完整insert签名的独立离线封装，停新增接收时整批拒绝，
  不关闭既存decode政策、不静默删样本报成功；后续已接本地持久许可，生产移除控制仍缺。
- `Adapters/ReceiveGate`及`LeasedStageInsert`：真实自有metadata文件的持久依赖先写、接收日志、
  move-only在途许可及stop排空，已包住original同步写入并验证异常释放。
  单协作进程，重启默认关闭；尚无跨进程App控制、读取底座移除硬门或runtime放行。
- `Adapters/SleepCalendarContext`：原生Gregorian睡眠日起点→cache日历components→旧collection
  构造与有界完整桶读取，不以固定日长替代。只用假factory测试，真实身份仍须验证。
- `Adapters/ProfileSleepSourceProvider`：已绑定profile的15.4来源manager/category63接口，
  非nil preference可为subset/empty；calculator在完整source向量另作非稳定排名，不删来源。
- `Adapters/DayStatisticsAdapter`：将以上构造接到consumption series与day-summary编排，
  不再仅靠手填日历桶/固定来源描述。完整native查询范围及hook仍未落地。
- `Core/RawFeedCalendarPlan.hpp`：按首raw.start定位、carry40决定相邻桶、无carry跳空跨度，
  finish不按pending48或day hull决定末桶。日摘要桥已采用；不裁raw、不固定补尾桶。
- `module.json`：研发状态清单，不是插件 manifest，不被安装器读取。

## 缺少的部分

1. 薄适配器与真实日历桶/来源对象的受验证接线、完整原生流式query控制器及动态key刷新。
   排序、接纳和连续跨桶已有离线实现，但不是完整原生输入流水线；现有bucket driver
   的映射字段仅覆盖推进期间稳定的子情况，不能泛化到动态provider。
   新建睡眠 builder 路径的 mask 已静态证明为空，不需通用 category 比例缩放；
   任意外部 masked calculator/归档恢复不属于支持范围，非空 mask 仍拒绝。
2. 原生输入/摘要适配、精确宿主和方法来源守卫、所有查询的失败处理。
3. 已保存阶段在关闭/卸载后的读取兼容和定向进程影响验证。
4. 经另行授权的设备加载、效果与回归验证。

`resolved_statistics_intervals` 是调用者的接口前提，不是通过枚举值就自动证明来源选择正确。
当前没有生产调用者可真实满足上述完整流水线；运行时门不会因核心算法成功而开启。
兼容核心不包含hook或自动装载入口。独立LoadCheck有constructor只核验metadata，
仍无注入filter、权限声明、安装/重启脚本、插件配置provider或Makefile。
顶层构建未增加此目录，App 的插件扫描也不会发现它。因此不出现在“全部安装”中。

## 约束

- 不替换健康 App/framework/daemon；不全局重标 `HKCategorySample.value`。
- 不写健康数据库、原样本、同步锚点，不伪造 ACK，不补造旧 Asleep1 记录。
- 不承诺 iOS16 全阶段图、其他健康类型或历史缺失记录自动补回。
- AppsSupport、Messages、SleepSync、照片和配对兼容模块不变。

## 离线测试

在工程根目录执行：

```sh
python3 -B Tests/HealthSupport/test_core_offline.py
python3 -B Tests/HealthSupport/test_pipeline_primitives_offline.py
python3 -B Tests/HealthSupport/test_source_ledger_offline.py
python3 -B Tests/HealthSupport/test_source_identity_offline.py
python3 -B Tests/HealthSupport/test_multi_source_offline.py
python3 -B Tests/HealthSupport/test_bucket_advance_offline.py
python3 -B Tests/HealthSupport/test_pinned_pending_order_offline.py
python3 -B Tests/HealthSupport/test_raw_admission_offline.py
python3 -B Tests/HealthSupport/test_bucket_admission_offline.py
python3 -B Tests/HealthSupport/test_bucket_rollover_offline.py
python3 -B Tests/HealthSupport/test_stable_series_offline.py
python3 -B Tests/HealthSupport/test_calendar_bucket_adapter_offline.py
python3 -B Tests/HealthSupport/test_source_provider_adapter_offline.py
python3 -B Tests/HealthSupport/test_stable_adapter_offline.py
python3 -B Tests/HealthSupport/test_sleep_sample_adapter_offline.py
python3 -B Tests/HealthSupport/test_day_builder_snapshot_offline.py
python3 -B Tests/HealthSupport/test_legacy_period_adapter_offline.py
python3 -B Tests/HealthSupport/test_source_consumption_offline.py
python3 -B Tests/HealthSupport/test_consumption_series_offline.py
python3 -B Tests/HealthSupport/test_pinned_source_ranks_offline.py
python3 -B Tests/HealthSupport/test_query_builder_binding_offline.py
python3 -B Tests/HealthSupport/test_period_finish_adapter_offline.py
python3 -B Tests/HealthSupport/test_day_summary_adapter_offline.py
python3 -B Tests/HealthSupport/test_loaded_method_identity_offline.py
python3 -B Tests/HealthSupport/test_load_check_candidate_offline.py
python3 -B Tests/HealthSupport/test_enumeration_adapter_offline.py
python3 -B Tests/HealthSupport/test_receive_gate_offline.py
python3 -B Tests/HealthSupport/test_leased_stage_insert_offline.py
python3 -B Tests/HealthSupport/test_sleep_calendar_context_offline.py
python3 -B Tests/HealthSupport/test_profile_sleep_source_provider_offline.py
python3 -B Tests/HealthSupport/test_raw_feed_calendar_plan_offline.py
python3 -B Tests/HealthSupport/test_stage_write_boundary_offline.py
python3 -B Tests/HealthSupport/test_module_isolation.py
```

测试只编译运行本模块自有 C++/Objective-C(++)及Foundation假对象，使用合成输入；
不调用 HealthKit、不访问设备或真实健康记录，不执行提取固件里的Apple代码。
投影输出分配的 `bad_alloc`／`length_error` 返回明确失败状态，不发布部分结果；
输入 vector 的分配发生在调用方，`maximum_intervals` 是数量限制，不是整个进程内存预算。
资源分配异常分支目前没有故障注入验收，不能宣称已覆盖所有资源故障。
默认使用项目内临时目录，结束后只清理其自行创建的精确测试目录。
原始固件、二进制、私有诊断和凭据均不属于模块源码。

来源映射采用事务性整图副本，数量上限不等于字符串字节或执行时间预算；未来原生适配器
需限制可信 bundle 字节和总资源。mapper 与 ledger 是独立函数，上层必须联合提交，
不能 mapper 成功就发布，再把 ledger 失败当整个操作已回滚。此联合适配尚未接原生对象。
