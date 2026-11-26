# HealthSupport 离线模块测试

当前模块不进入 App/Theos/package 构建。本目录命令只编译并运行自有 C++ 核心，
不会查询 HealthKit、连接 SSH/USB、加载固件、安装或重启。

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

覆盖：默认关闭/原生接受结果透传、六槽时长与首次出现 tie、720 个排列、清醒参与、
DBL_MIN 阈值、非法值/区间拒绝；已完成统计后的旧式段投影、29 秒组合与空隙不计时、
raw 输入不改、乱序/重叠/超限/溢出无部分结果。主机 ASan/UBSan，O0/O2。
另覆盖零长度区间桥接拒绝、首尾相接、巨大间距和包围跨度溢出、合法空结果与失败接口区分。
内存分配异常有显式状态处理，但目前未用分配故障注入测试验证，不把普通 sanitizer 通过
视为这些分支已经执行。

流水线原语测试覆盖：阶段/来源保真切分、两短侧 numeric 顺序、0.01 前后、
浮点消减/正 subnormal、负时间网格、越过事件/目标、无法推进及算术溢出失败；
首有效来源贡献与 Awake 竞争、跨 slice 累计、调用方 bucket 不变、非法尾部不发布部分结果。
提供已排序 slice → 桶决定 → 旧式投影的合成衔接，但不生成真实来源顺序或日历桶，
不能当成 raw 样本到最终睡眠时长的完整实现。
来源账本测试覆盖同key多source、独立tie、count=false仍累计、来源0/负key、容量/溢出事务失败；
与单pending TOTAL状态联合测试确保失败不发布一半更新。合成token映射不证明真实bundle映射。
来源映射测试锁定nil重查、首次代表和provider失去/恢复；multi测试区分ledger key与bundle
group，计数flag不抑制时长；有界driver测试多→单→空、迭代上限、回调排列拒绝、越target不clamp。
这些测试使用显式fixture排序，不证明原生等价排序适配已实现，也不访问原生source manager。
另以精确二进制分数坐标遍历 39600 个切分组合，检查有效区间守恒及阶段/来源身份保留；
这些是自有实现的不变量测试，不与 Apple 方法差分执行。
另测外层target rounding、bucket终点不round、单pending两短侧/历史flag/TOTAL累计，
非空mask与SeparateBySource显式拒绝；fast-math及finite-math-only编译必须失败。
统计桶输出测试确认partial contribution仍使用完整提供边界、Awake后续投影排除、
非固定60秒边界不被重算、无prevailing与非法结果区分；这里没有实现calendar计算或DST验证。
同一合成空mask单pending流程还串起target计划→两次推进→完整桶→旧式投影，
确认累计状态/右片历史传递和原输入不变；未实现任意多来源或SeparateBySource分支。

固定排序测试独立使用本机16.5 SDK头文件（不是编译器默认modern排序），先核sort.h哈希。
只此测试需C++17和显式opt-in，普通core仍C++11；覆盖相等start、source缺失/重复、30和1000
阈值、索引vs完整记录同算法排列及桶driver接线。host runtime仍非iPhone libc++执行，
不把同算法自对照当native differential。未复制SDK算法源码或加载Apple固件。

接纳/跨桶测试覆盖桶前后whole、来源先登记再推进、空ledger不消耗序号、三桶carry重放、
计数重置、旧current overrun不裁next，以及carry-only/整个桶前/禁止advance的入口失败矩阵。
callback计数保留外部变化，只证明owned bucket未发布，不谎称外部lookup已自动回滚。

稳定来源series把原始合成输入接到明确多桶，覆盖partial/整桶/Awake/无贡献、nil来源、
非均匀边界、乱序和越range拒绝；固定SDK排序测试另接多来源/清醒冲突的三桶集成。
来源描述、排名和日历仍来自fixture，不表示已连接真实Health服务，也不授权全局stage接受。

薄适配测试只用自有Foundation类：真实继承链类型校验、数值连续性而非可覆写日期相等、
nil与异常分离、source成员唯一性、UTF-8字节限制。桥接测试另以O0/O2 sanitizer连接
collection/provider/固定排序/多桶series/旧式投影；实际原生身份守卫和动态key刷新未接入。
series拒绝非末桶残留pending，不因增加空桶而将同一个短样本丢失改报成功。

`resolved_statistics_intervals` 是未来上游适配器的条件，测试传入该值并不证明真实来源
选择和网格流水线已实现。没有 native differential test 或设备验收，不把绿色测试称为修复完成。
