# AlDente 全量历史导入

导入是一次性历史迁移。导入记录存入 Hachibu 的历史数据模型，与应用自己采集的数据由同一套查询和历史页展示；界面没有来源选择、批次选择或独立档案窗口。导入不会更改系统充电设置。

## 使用流程

在「设置 → 历史数据」展开「如何导出历史」，点击「复制 AI 导出提示词」，交给能在本机读取文件、执行命令的 AI 工具。提示词包含完整格式和 13 张表的结构示例；导出工具负责只读读取来源数据库并核对全部记录。应用本身不执行脚本或读取其他应用数据库，操作说明见 [导出指南](AlDente导出指南.md)。

点击「导入历史…」选择完整 JSON。应用在后台解析、严格校验，预览 13 类指标的记录数和时间范围，确认后在单个事务中保存原始档案和应用历史；失败整批回滚。取消不写入。

导入成功后自动进入现有历史页，两组时间范围切到「全部」。电量、温度、充电上限与新采样一起展示；长期显示系统最大容量、满充容量、设计容量和循环次数。近期支持 1 小时、24 小时、7 天、30 天、全部，超过 24 小时按小时展示；历史时间统一按 UTC 解析，界面使用当前本地时区，每日指标按当前本地日期归组。

「历史明细」在同一页中分页显示应用采样及导入的全部 13 类指标，每页 200 条，只按指标筛选，不按来源或批次筛选。校准显示事件时间及原始数值，健康状态和电池标识保留为文本。三张功率表的单位、符号和测量口径尚未核实，因此在明细中标注“单位未确认”，不写入 mW 曲线；应用自己的功率记录仍标注 mW。

## 统一展示规则

- 各指标独立按记录时间读取。同一分钟内取该指标最后一条记录，同一时刻冲突按记录摘要稳定选择；原值全部保存在明细中。
- 每日容量和循环指标各自取当天最后一条，不把不同指标强行视为同时采样，不将系统最大容量与容量比混用，不向缺失日期补值。
- 时间重叠时，应用自己采集的非空字段优先，导入数据只补缺失字段。已经聚合的原生小时记录同样优先，不重复累计重叠分钟。
- 不根据电量或功率推断接电、充电状态；未知历史不画确定的接电底色。曲线保留缺口。
- 无效时间、不能精确用于绘图的整数仍保留在明细中，不丢弃或改写原值。零、负数和异常数值不做自动清洗。
- 充电上限加入后续分钟采样，并在小时归档中保存该小时最后一次已知上限。设计容量只按实际记录日期展示，不向其他日期补齐。
- 原始档案保留于数据库内部，用于完整性核对和去重，不作为用户需要管理的数据来源。

## 已验证的文件格式

格式依据本机 AlDente 1.39.3（111）真实数据库的只读全量导出，不要求 AlDente 提供官方导出按钮。标识为 `hachibu.aldente.raw`，`formatVersion` 为整数 `1`。

顶层包含：

- `source`：`app` 为 `AlDente`，`bundleIdentifier` 为 `com.apphousekitchen.aldente-pro`，`version` 和 `build` 为非空字符串。
- `schema`：原始数据库结构，至少包含下表全部 13 个表定义的 `type`、`name`、`table`、`sql`。SQL 仅保存，绝不执行。
- `tables`：以下全部 13 张表，不能省略没有记录的表；空表的 `rows` 为 `[]`，`rowCount` 为 `0`。

`schema` 中 `type: "table"` 的对象必须恰好对应全部 13 张表，`name` 和 `table` 相同，`sql` 必须为字符串；索引、视图和触发器等其他对象元数据可以保留。发现未知表或结构变化时，导出工具应先报告不支持，不可删去未知内容后声称全量。`exportedAt`、来源文件名、cipher 版本等附加元数据可保留在原始 JSON，但不参与记录类型判断。

| 表名 | `value` 类型 |
|---|---|
| `batteryCycles` | INTEGER |
| `batteryDesignCap` | INTEGER |
| `batteryMaxCap` | INTEGER |
| `batteryPercentage` | INTEGER |
| `batterySerial` | TEXT |
| `batteryTemp` | REAL |
| `chargeLimit` | INTEGER |
| `chargingPower` | REAL |
| `lastCalibration` | REAL |
| `macOSbatteryCondition` | TEXT |
| `macOSbatteryMaxCap` | INTEGER |
| `systemLoad` | REAL |
| `systemPowerIn` | REAL |

每张表的对象包含 `columns`、`rowCount`、`rows`。字段严格按 `id`（INTEGER）、`timestamp`（TEXT）、`value`（上表类型）排列。`columns` 原样记录 SQLite `table_info`：`position` 为 0、1、2，`notNull` 均为 1，`primaryKey` 依次为 1、0、0，`default` 均为 JSON `null`。

每条 `rows` 记录包含原始 `id`、`timestamp`、`value`。ID 是有符号 64 位整数，单表单次导出内唯一；不同导出可以循环复用 ID。时间保持原始字符串，不转换时区、不截成日期、不合并不同指标。INTEGER 不接受布尔或浮点替代，REAL 接受有限数值，TEXT 保留空字符串。零、负数、异常记录、电池标识、校准时间全部保留，不进行业务清洗。

完整结构示例随应用提供于 `Packages/HachibuKit/Sources/FeatureUI/Resources/AlDenteExportExample.json`，全部表故意为空，版本为 `EXAMPLE-NOT-AN-EXPORT`，不能作为用户数据交付。复制的提示词会附加此示例；测试直接用 `AlDenteArchive` 解析，并填充各类型的合成记录检查契约。

不提供自动读取 AlDente 数据库或运行 AI 脚本的入口。中英文提示词位于 FeatureUI 的 `en.lproj/AlDenteExportPrompt.md`、`zh-Hans.lproj/AlDenteExportPrompt.md`，复制时按应用语言选择，中文与英文共用同一个 JSON 示例。

## 存储与核对

已发布的 `v1`、`aldenteRawImports` 迁移不修改，追加 `unifiedHistory`：

- `history_records` 使用应用自己的指标名称，保存原始数值字节、原时间字符串和严格解析的 UTC 时间。时间无法解析时为 NULL，仍能查看原值。
- 数据库升级时将已有 `aldente_records` 全部转换为应用历史记录，无需重新导入。新导入在同一事务中写入原始档案及应用历史。
- 现有 `minuteSamples`、`minuteSamplesByHour`、`dailySamples`、最早记录时间及记录概况统一查询应用采样与历史记录。原生分钟、小时、每日表不被导入覆盖，正常采样继续使用原有写入和聚合流程。
- `aldente_imports`、`aldente_records`、`aldente_import_records` 作为内部原始档案与去重依据保留，完整文件、附加元数据和数值位模式保持不变。界面不再暴露这些存储概念。

同一文件重复导入不新增记录。不同文件只有表名、ID、时间、类型和原值完全相同时才复用记录；相同 ID 的新时间或新值仍保留。提交事务前逐表逐字段核对记录数及值字节，任何失败都回滚应用历史与原始档案。

## 验证

普通测试使用合成数据，不将真实数据库、序列号或完整导出文件提交到仓库。通过环境变量额外启用本机真实导出验证：

```bash
HACHIBU_ALDENTE_VALIDATION_FILE=/path/to/aldente-full-history.json swift test --package-path Packages/HachibuKit
```

该验证在临时数据库中导入全部记录、重新打开数据库、取回完整文件并逐条核对，再检查重复导入。不会向实际运行中的 Hachibu 数据库写入。
