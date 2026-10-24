# AlDente 历史数据调研

调研时间：2026-10-22，数据统计截至约 18:00（Asia/Taipei，UTC+8）。

用途：为 Hachibu v3 导入本机 AlDente 历史数据提供依据。本文是调研记录和方案建议，不替代 `v1技术设计.md` 中已经确定的实现规则。

## 1. 结论

本机一年多的满充容量和循环记录可以导入。清理异常、按日去重后，有 **343 天有效容量和循环记录**；系统最大容量百分比有 **285 天有效记录**，最后记录于 2026-08-08。

Hachibu 当前设计的 `minute_samples`、`hourly_samples`、`daily_samples` 可以承接主要曲线，但无法完整、无损保存 AlDente 的全部历史。来源库还保存健康状态、电池身份、校准事件和充电上限，这些没有对应字段。来源库也没有直接保存历史接电状态和充电状态，不能自行补成确定值。

长期容量和循环的导入可行性已经确认。功率指标与 Hachibu 是否同源、同口径，以及温度传感器来源，尚未确认。

## 2. 调研范围和方法

本次仅进行了文件定位、安装包静态分析、数据库只读查询，以及仓库设计和代码阅读。未修改或导出文件，未启动、退出 AlDente 或 Hachibu，未写入 SMC，未运行构建、测试或浏览器自动化。

本机安装版本：

- 应用：`/Applications/AlDente.app`
- Bundle ID：`com.apphousekitchen.aldente-pro`
- 版本：1.39.3，构建号 111

历史数据库：

```text
~/Library/Preferences/com.apphousekitchen.aldente-pro_stats.sqlite3
```

调研时文件大小为 2,605,056 字节，约 2.6 MB。`~/Library/Application Support/AlDente` 不是本次找到的历史数据库位置。

该数据库经过加密，普通 SQLite 打开后查询会报 `file is not a database`。本文的表结构和统计来自调研时在本机的一次只读读取，不记录读取方法和参数，也不保存电池序列号或授权信息。Hachibu 不提供解密 AlDente 数据库的方法或指引，v3 的数据来源见 `v1技术设计.md` 第 18 节。

查询在只读事务中进行，没有生成明文副本。库的 `journal_mode` 为 `delete`，`user_version` 为 0。

AlDente 在调研期间继续更新高频数据，后续查询的首末时间会变化。下文的高频范围是本次查询时的快照，不能作为固定保留起点。

## 3. 实际数据库结构

数据库包含 13 张表。各指标独立保存，均包含 `id`、`timestamp`、`value` 三列，差别主要在 `value` 类型。

实际建表语句示例：

```sql
CREATE TABLE "batteryMaxCap" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "timestamp" TEXT NOT NULL,
  "value" INTEGER NOT NULL
);

CREATE TABLE "batteryTemp" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "timestamp" TEXT NOT NULL,
  "value" REAL NOT NULL
);

CREATE TABLE "macOSbatteryCondition" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "timestamp" TEXT NOT NULL,
  "value" TEXT NOT NULL
);
```

| 表 | value 类型 | 内容或候选含义 | 记录数 | 覆盖日期（UTC+8） |
|---|---|---|---:|---|
| `batteryMaxCap` | INTEGER | 满充容量，mAh | 352 | 2025-09-18～2026-10-22 |
| `batteryCycles` | INTEGER | 循环次数 | 352 | 2025-09-18～2026-10-22 |
| `macOSbatteryMaxCap` | INTEGER | 系统最大容量，整数百分比 | 293 | 2025-09-18～2026-08-08 |
| `macOSbatteryCondition` | TEXT | 健康状态 | 352 | 2025-09-18～2026-10-22 |
| `batteryDesignCap` | INTEGER | 设计容量，mAh | 4 | 2026-08-09～2026-10-08 |
| `batterySerial` | TEXT | 电池身份 | 15 | 2025-09-18～2026-10-13 |
| `lastCalibration` | REAL | 最近校准事件的 Unix 时间 | 3 | 2026-03-11～2026-09-21，日期取记录时间 |
| `batteryPercentage` | INTEGER | 电量百分比 | 10,080 | 约 2026-09-28～2026-10-22 |
| `batteryTemp` | REAL | 温度，读数与摄氏温度一致 | 10,080 | 同上 |
| `chargingPower` | REAL | 电池充放电功率候选；采集口径待确认 | 10,080 | 同上 |
| `systemLoad` | REAL | 系统功率候选；采集口径待确认 | 10,080 | 同上 |
| `systemPowerIn` | REAL | 输入功率候选；采集口径待确认 | 10,080 | 同上 |
| `chargeLimit` | INTEGER | 充电上限百分比 | 10,080 | 同上 |

### 3.1 时间精度和时区

`timestamp` 的实际格式为：

```text
yyyy-MM-dd'T'HH:mm:ss.SSS
2026-10-22T08:13:43.766
```

精度为毫秒，按 UTC 保存，虽然字符串没有 `Z` 后缀。导入时应先按 UTC 解析，再转为目标时区计算每日记录日期。不能直接将字符串的前十个字符作为本地日期。

依据是本机 `SQLite.framework` 的日期格式化初始化代码：

- arm64 地址 `0x1f4b8` 引用上述日期格式。
- `0x1f53c`～`0x1f540` 以 0 调用 `TimeZone(secondsFromGMT:)`。
- `0x1f598` 设置格式化器时区。

这与 [SQLite.swift 的 Foundation.swift](https://github.com/stephencelis/SQLite.swift/blob/master/Sources/SQLite/Foundation.swift) 中的序列化实现一致。

来源库没有逐条保存原始所在地时区。若用户曾跨时区使用电脑，无法仅凭这些表恢复当时所在地的日历日期；导入需要明确统一使用哪个时区。

### 3.2 高频数据保留方式

六张高频表各有 10,080 条记录，存在循环复用 ID 的现象。例如一次查询中：

```text
batteryPercentage
id=10080 → 2026-10-06T02:24:33.255
id=1     → 2026-10-06T02:25:33.240
```

因此，ID 大小不代表时间先后，也不能用 ID 在不同指标表之间关联记录。

电量、温度和系统功率的相邻记录时间差中位数约为 60.001 秒，但存在明显缺口。电量一次查询中有 459 个相邻间隔超过 3 分钟，最大间隔约 14.8 小时。不能仅凭这些间隔判断每次缺口的具体原因。

10,080 条相当于连续每分钟采样 7 天；实际存在缺口，因此当前数据跨越约 25 个自然日，不能按“最近 7 个自然日”理解。

## 4. 健康度、容量和循环的含义

### 4.1 两种健康度口径必须分开

实际记录示例，时间均为数据库中的 UTC 原文：

```text
batteryMaxCap
2026-10-22T08:13:43.766 → 7942

batteryCycles
2026-10-22T08:13:43.761 → 68

macOSbatteryMaxCap
2026-08-08T08:13:43.963 → 95

batteryDesignCap
2026-10-08T02:32:03.581 → 8694
```

- `batteryMaxCap` 保存满充容量，最新为 7942 mAh，不能直接当成健康百分比。
- `macOSbatteryMaxCap` 保存系统最大容量百分比，对应 Hachibu 的 `system_max_capacity_pct`。
- `7942 / 8694 × 100 ≈ 91.4%` 是容量比，与系统最大容量的 95% 属于不同口径。这个计算使用不同时间的最新记录，仅用于说明口径区别，不能视为同一时刻采样。
- 来源库没有独立的容量比历史表，历史容量比需要使用对应容量数据计算。

本机 AlDente 当前版本的静态代码中，读取 `FullChargeCapacity` 后写入 `batteryMaxCap` 对应的传感器属性，读取 `DesignCapacity` 后写入设计容量属性。这个证据支持当前版本的容量含义，不能证明此前每个版本的采集实现均完全相同。

### 4.2 系统最大容量存在停止记录的区间

`macOSbatteryMaxCap` 最后一条记录是 2026-08-08 的 95%。全部记录中，96 有 96 条、95 有 194 条、0 有 3 条；首次记录 95 的日期为 2026-01-13。

本机 1.39.3 的采样代码在 arm64 地址 `0x10019af24`～`0x10019af38` 检查 macOS 27 及以上，满足条件时跳过随后针对 `macOSbatteryMaxCap` 的写入分支。这与当前缺口一致。

不能据此确定历史升级日期，也不能将 2026-08-08 后的系统最大容量自动补成 95%。满充容量不能代替缺失的系统百分比。

### 4.3 设计容量记录稀疏

`batteryDesignCap` 的全部记录如下，时间为 UTC：

| timestamp | value |
|---|---:|
| 2026-08-09T02:32:02.226 | 8694 |
| 2026-08-09T02:32:03.797 | 8694 |
| 2026-09-08T02:32:03.637 | 8694 |
| 2026-10-08T02:32:03.581 | 8694 |

这是 4 条记录、3 个日期。不能把今天的设计容量无标记地回填到此前一年。如果采用同一电池内向后沿用最近设计容量的规则，应保留其来源时间和推导标记；早于首次设计容量记录的部分保持未知。

### 4.4 电池身份和校准事件

`batterySerial` 的 15 条记录中只有一个不同的值。本文不记录序列号原文。现有记录未显示电池身份变化，但这不能证明未记录区间一定没有更换电池。

`lastCalibration.timestamp` 是记录时间，`value` 才是校准事件的 Unix 时间。例如：

```text
记录时间：2026-03-11T01:12:17.091 UTC
value：1773136186.7426
事件时间：2026-03-10 17:49:46.742600 UTC+8
```

导入事件时不能将记录时间当成实际校准时间，也不应将其作为每日容量记录。

## 5. 数据质量

### 5.1 三批同步异常

2026-04-06、2026-05-02、2026-05-03 各有一次以下组合：

```text
满充容量 = 0
循环次数 = 0
系统最大容量 = 0
健康状态 = 空字符串
```

这些记录的各指标时间仅相差毫秒，且前后循环次数为非零值，支持将这三批视为采集失效。注意健康状态实际是 `TEXT ''`，并非数据库 `NULL`。

2026-05-02 同一天稍后恢复正常，原始时间为 UTC：

| 指标 | 06:22:53 左右 | 08:13:42 左右 |
|---|---:|---:|
| 满充容量 | 0 | 7989 mAh |
| 循环次数 | 0 | 45 |
| 系统最大容量 | 0 | 95% |
| 健康状态 | 空字符串 | Normal |

导入时应排除上述失效值，并保留同日有效记录。不能泛化为“所有循环次数 0 都无效”，新电池的循环次数可以确实为 0。

### 5.2 有效记录和日期缺口

| 指标 | 原始记录 | 排除异常后的有效记录 | 按本地日期去重后的有效天数 |
|---|---:|---:|---:|
| 满充容量 | 352 | 349 | 343 |
| 循环次数 | 352 | 349 | 343 |
| 系统最大容量百分比 | 293 | 290 | 285 |

容量和循环覆盖 400 个自然日。其中 55 天完全没有记录，另有 2 天只有异常值。缺口应保留，不插值或补录。

排除三批异常后，循环次数从 34 增至 68，没有发现倒退。满充容量存在日间波动，不能强制修正成单调下降。

### 5.3 高频数据不能直接拼成同步快照

各指标独立记录时间。一次查询中，将时间按 UTC 分钟取整后，电量、温度、电池功率和系统功率的分钟集合一致，但输入功率存在不同的分钟集合。电量的 10,080 条还落在 9,973 个不同分钟内，说明同一分钟可能有多条记录。

导入应按每个指标的实际时间处理，不能按原始时间字符串做等值连接，也不能默认同 ID 的多项指标同时采样。

## 6. 与 Hachibu 存储设计的映射

目标结构以 `v1技术设计.md` 第 10 节为准。调研时 `HistoryStore.swift` 仍为占位文件，以下是与设计的映射，不代表导入已经实现。

| AlDente 来源 | Hachibu 目标 | 导入规则或限制 |
|---|---|---|
| `batteryMaxCap` | `daily_samples.full_charge_mah` | 按本地日期取最后有效值 |
| `batteryCycles` | `daily_samples.cycle_count` | 同上，缺失日期不补 |
| `macOSbatteryMaxCap` | `daily_samples.system_max_capacity_pct` | 同上，2026-08-08 后保持缺失 |
| `batteryDesignCap` | `daily_samples.design_mah` | 保存实际记录；沿用规则需单独定义 |
| `batteryPercentage` | `minute_samples.percent` | 每分钟取最后有效值；历史版本的系统/硬件电量口径仍需核实 |
| `batteryTemp` | `minute_samples.temperature_c` | 值域与摄氏温度一致，传感器来源待确认 |
| `chargingPower` | `minute_samples.battery_power_mw`，候选 | 采集来源、单位和与目标口径的一致性尚未完成核实 |
| `systemLoad` | `minute_samples.system_load_mw`，候选 | 同上 |
| `systemPowerIn` | `minute_samples.power_in_mw`，候选 | 同上，且采样时点不同 |
| `macOSbatteryCondition` | 无 | 每日表未设计健康状态字段 |
| `batterySerial` | 无 | 可用于识别电池、避免跨电池合并 |
| `lastCalibration` | 无 | 应作为事件处理 |
| `chargeLimit` | 无 | 属于历史控制设置，不能等同于系统充电上限 |

Hachibu 当前代码通过 `PowerTelemetryData` 读取功率，通过 `AppleSmartBatteryPack.BatteryData.Temperature` 读取温度。本次尚未证明 AlDente 对应历史表与这些来源一致，不能仅凭表名和数量级将功率乘 1000 后写入目标字段。

高频温度的观测范围约为 21.5～35.2；`chargingPower` 同时有正数、负数和大量 0。它们支持相应候选含义，但不足以证明采集来源和失效值规则。不能将所有高频 0 一律过滤，也不能全部视为有效测量。

来源库没有直接保存以下历史值：

- `is_external`：是否接外接电源。
- `is_charging`：系统报告的充电状态。
- 电池电压和电流。

这些字段应保持 `NULL`。不能用充电功率为 0 推断未接电，也不能填成 `false`。历史接电底色因此无法完整恢复；`hourly_samples.external_minutes` 同样不能用 0 代替未知。

## 7. 建议的导入、去重与冲突规则

以下均为待设计确认的建议，尚未修改 v1 设计或实现。

### 7.1 读取与规范化

1. 记录来源应用版本、数据库格式、导入批次和统计时区，使用只读事务获得一致的读取结果。
2. 严格按 UTC 解析原始毫秒时间，保留原始时间；目标分钟时间按分钟取整，目标日期按明确约定的时区生成。
3. 各指标独立排序、清理和去重。每天或每分钟按字段选择最后有效值，不要求不同指标原始时间完全相同。
4. 对三批已确认异常按组合证据处理，不将单个数值为 0 当作通用失效规则。缺失区间不生成虚构采样。

### 7.2 与原生数据冲突

同一天或同一分钟存在 Hachibu 原生有效字段时，优先保留原生值，只用导入值补缺。导入字段缺失时，不能覆盖目标已有值。

例如某天已有原生满充容量，但没有循环次数，可仅补循环次数。不要对每日整行直接使用 `INSERT OR REPLACE`。

单个 `updated_at` 无法表达多个来源字段各自的观测时间。如果需要准确解释来源或撤销导入，应增加对应的来源信息，或在来源存储中保留字段级关联。

### 7.3 重复导入和撤销

同一来源记录重复导入不应增加重复曲线点。需要来源标识、批次和稳定的去重规则；高频表的循环 ID 不能独自充当稳定身份。

应能报告新增、补缺、冲突和异常的数量，并能撤销指定导入批次，避免删除或覆盖原生采样。

### 7.4 小时聚合

早于目标分钟保留期限的数据按目标规则聚合。处理与目标已有小时重叠的数据时，不能直接覆盖整小时，也不能对两个平均值简单求平均。

若需要合并聚合结果，应保留每个指标的有效样本数，才能正确加权；另一种方案是明确整小时来源优先级，不混合两个来源。未知接电状态不能汇总成 0 分钟接电。

### 7.5 保存原始信息

若要求完整保存来源历史，建议先保留来源数据，再生成每日、分钟和小时曲线数据。来源存储需要保留原始时间、来源指标、原始值和导入批次，并将电池身份信息限定在必要范围内。

来源数据的具体存储形式和表结构尚未设计。它不要求直接照搬 13 张表，但必须能保留现有三张目标表无法表达的事件、状态和设置。

## 8. 对现有设计的影响和后续待核实项

`v1技术设计.md` 第 18 节目前写着：“AlDente 的数据格式还没调研。导入的数据写入现有三张表，不另建表。”

本次已确认格式和主要长期指标。仅使用三张表可以实现有损的曲线导入；若 v3 要完整保存来源历史，则需要保留额外来源数据。建议修订这项设计假设，但本次没有修改设计文档或代码。

后续需要确认：

- 三张功率表的采集来源、单位、符号及失效值，是否与 Hachibu 同口径。
- 温度传感器来源，以及历史版本电量百分比采用系统口径还是硬件口径。
- 导入统计时区，设计容量向后沿用的范围与推导标记。
- 完整保留来源数据还是仅导入目标曲线，以及对应的来源、撤销和聚合冲突设计。
- 合法的数据来源：AlDente 自身能否导出历史数据。

## 9. 依据与复核入口

本机依据：

- `~/Library/Preferences/com.apphousekitchen.aldente-pro_stats.sqlite3`：真实 schema、记录、时间范围和异常组合。
- `/Applications/AlDente.app/Contents/Info.plist`：版本和 Bundle ID。
- `/Applications/AlDente.app/Contents/MacOS/AlDente`：容量读取与采样分支的静态证据。
- `/Applications/AlDente.app/Contents/Frameworks/SQLite.framework/SQLite`：日期序列化格式与 UTC 时区。
- `/Applications/AlDente.app/Contents/Resources/en-US.lproj/Localizable.strings`：容量和健康状态的界面命名辅助证据。

仓库依据：

- `docs/v1技术设计.md` 第 5、10、11、18 节：数据口径、存储、曲线和导入预留。
- `Packages/HachibuKit/Sources/HistoryStore/HistoryStore.swift`：调研时的存储实现状态。
- `Packages/HachibuKit/Sources/BatteryCore/BatterySnapshot.swift`：调研时 Hachibu 的实际字段来源。

外部辅助依据：

- [SQLite.swift 日期序列化实现](https://github.com/stephencelis/SQLite.swift/blob/master/Sources/SQLite/Foundation.swift)。时区结论同时经过本机安装包静态代码核实。

调研时用于复核结构和基础统计的查询，仅作记录：

```sql
SELECT type, name, sql
FROM sqlite_master
ORDER BY type, name;

SELECT COUNT(*) AS row_count,
       MIN(timestamp) AS first_timestamp,
       MAX(timestamp) AS last_timestamp,
       COUNT(DISTINCT timestamp) AS distinct_timestamps
FROM batteryMaxCap;

SELECT id, timestamp, value
FROM batteryMaxCap
WHERE value = 0
ORDER BY timestamp;

SELECT typeof(value), quote(value), COUNT(*)
FROM macOSbatteryCondition
GROUP BY value;

SELECT id, timestamp, value
FROM macOSbatteryMaxCap
ORDER BY timestamp DESC
LIMIT 3;
```
