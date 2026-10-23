# AlDente 全量历史导入

本轮实现将全部来源记录保存到 Hachibu 的独立存储，不修改原有采样表，不自动转换为现有历史曲线。原始充电上限是历史数据，不会应用到系统设置。方案中的 v3 是功能标识，应用版本号不随之调整。

## 使用流程

没有导出文件时，在「设置 → 历史数据」展开「如何从 AlDente 导出」，点击「复制 AI 导出提示词」，交给能在这台 Mac 上访问文件、执行命令的本地 AI 工具。提示词随应用提供，包含完整格式和全部 13 张表的结构示例，不依赖远程网页。应用本身不执行提示词或读取 AlDente 数据库；用户在本地 AI 工具中执行导出，再返回 Hachibu 选择文件。操作说明见 [AlDente 导出指南](AlDente导出指南.md)。

在「设置 → 历史数据 → 导入 AlDente 历史…」选择全量 JSON 文件。Hachibu 先读取并校验文件，显示 13 类数据各自的记录数、原始时间范围和来源应用版本，点击「导入」后才写入。

导入完成后显示新增记录数和已保存记录数。文件选择或确认阶段取消均不写入。解析在后台执行，数据库写入使用单个事务；任意写入或核对失败整批回滚。

「设置 → 历史数据 → 查看已导入历史…」打开独立档案窗口。按导入批次选择来源文件，显示导入时间、AlDente 版本、记录总数和完整文件 SHA-256；再从全部 13 张来源表中选择指标，包括空表。每张表显示记录数、原始时间范围，以及原始 ID、时间和值。每页 200 条，按原始时间字符串倒序，同时间按来源 ID 和记录摘要稳定排序；切换批次或来源表回到第一页。

原始记录模式不进行单位或时区转换，整数不转为浮点，浮点使用可往返的十进制表示。文本带引号和转义，空字符串显示为 `""`。原始校准值仍为来源数值，不混用为记录时间。这里显示来源记录，不合并进现有历史曲线。

数值指标默认显示独立的来源曲线，可切换「曲线 / 原始记录」。校准、电池状况和电池标识始终显示明细，不作为连续测量绘图。曲线支持 24 小时、7 天、30 天、1 年和全部；范围截止于所选表最新的可绘制记录，不以当前日期截取旧档案。图表、悬停读数均明确使用 UTC，时间只接受已验证的 `yyyy-MM-dd'T'HH:mm:ss.SSS` 原文并严格校验，不改写来源时间。

曲线只读取所选批次、所选表的完整记录，不受明细每页 200 条限制。高频表相邻记录超过 3 分钟、每日指标（循环、满充容量、系统最大容量）超过 3 天时断线；设计容量稀疏，只画点。循环和充电上限使用阶梯线，其他可绘制数值使用直线。同一时刻多条记录各自画独立点，不用连线推定先后，也不选取某一条覆盖其他值。

无法严格解析的时间、无法精确转为绘图数值的整数等不绘制，界面报告表内对应条数，仍可在原始记录查看。零、负数和异常读数不会被清洗。密集数据仅在展示时按时间桶和分段保留首末、最小值和最大值点，显示绘图点数和范围内记录数；悬停仍查询范围内的全部原始点。原始数据不减少，曲线不会跨来源缺口连线。图表转换在后台执行，切换时间范围可复用所选表的解析结果。

三张功率表沿用来源数值，不标为 W 或 mW，界面提示单位与测量来源尚未核实。此实现不向 Hachibu 原生曲线或采样表写入任何转换结果。

窗口中的「导出原始文件…」按所选批次取回完整 JSON，包括电池标识与附加元数据；在后台核对 SHA-256 后原子写入用户选择的位置，字节与导入文件一致。文件校验失败不会写出。不提供批次删除或撤销。

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

追加迁移 `aldenteRawImports`，原有 `v1` 迁移不变：

- `aldente_imports`：保存完整原始文件字节、文件 SHA-256、来源版本、导入时间和记录数量。未识别的附加元数据仍保留在原始文件中。
- `aldente_records`：保存原表名、ID、原始时间、值类型和值。整数保存 64 位位模式，浮点保存 IEEE 754 位模式，文本保存 UTF-8，均为 BLOB，避免 SQLite 类型转换改变值。
- `aldente_import_records`：保留每个导入批次与记录的关联。多个文件共用相同记录时仍能按批次重建各自内容。

同一文件重复导入直接复用原批次。其他文件的记录只有在表名、ID、时间、类型和原值全部相同时才复用；相同 ID 的新时间或新值都会保留，原记录不覆盖。不同来源文件完整保留，即使其记录完全重叠。

提交事务前逐表核对记录数及每条记录的全部字段和原值字节，不一致即回滚。`alDenteArchiveData(identifier:)` 可取回未经重新编码的完整原始文件。明细查询只读取所选批次的元数据及当前页记录；曲线查询额外读取所选来源表的全部记录，不会重新解析完整 JSON，也不修改来源存储或原有采样表。

## 验证

普通测试使用合成数据，不将真实数据库、序列号或完整导出文件提交到仓库。通过环境变量额外启用本机真实导出验证：

```bash
HACHIBU_ALDENTE_VALIDATION_FILE=/path/to/aldente-full-history.json swift test --package-path Packages/HachibuKit
```

该验证在临时数据库中导入全部记录、重新打开数据库、取回完整文件并逐条核对，再检查重复导入。不会向实际运行中的 Hachibu 数据库写入。
