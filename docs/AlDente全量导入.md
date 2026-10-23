# AlDente 全量历史导入

本轮实现将全部来源记录保存到 Hachibu 的独立存储，不修改原有采样表，不自动转换为现有历史曲线。原始充电上限是历史数据，不会应用到系统设置。方案中的 v3 是功能标识，应用版本号不随之调整。

## 使用流程

在「设置 → 历史数据 → 导入 AlDente 历史…」选择全量 JSON 文件。Hachibu 先读取并校验文件，显示 13 类数据各自的记录数、原始时间范围和来源应用版本，点击「导入」后才写入。

导入完成后显示新增记录数和已保存记录数。文件选择或确认阶段取消均不写入。解析在后台执行，数据库写入使用单个事务；任意写入或核对失败整批回滚。

## 已验证的文件格式

格式依据本机 AlDente 1.39.3（111）真实数据库的只读全量导出，不要求 AlDente 提供官方导出按钮。标识为 `hachibu.aldente.raw`，`formatVersion` 为整数 `1`。

顶层包含：

- `source`：`app` 为 `AlDente`，`bundleIdentifier` 为 `com.apphousekitchen.aldente-pro`，`version` 和 `build` 为非空字符串。
- `schema`：原始数据库结构，至少包含下表全部 13 个表定义的 `type`、`name`、`table`、`sql`。SQL 仅保存，绝不执行。
- `tables`：以下全部 13 张表，不能省略没有记录的表；空表的 `rows` 为 `[]`，`rowCount` 为 `0`。

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

本轮不提供自动读取 AlDente 数据库或运行 AI 脚本的入口。导出工具和供其他用户使用的提示词另行实现。

## 存储与核对

追加迁移 `aldenteRawImports`，原有 `v1` 迁移不变：

- `aldente_imports`：保存完整原始文件字节、文件 SHA-256、来源版本、导入时间和记录数量。未识别的附加元数据仍保留在原始文件中。
- `aldente_records`：保存原表名、ID、原始时间、值类型和值。整数保存 64 位位模式，浮点保存 IEEE 754 位模式，文本保存 UTF-8，均为 BLOB，避免 SQLite 类型转换改变值。
- `aldente_import_records`：保留每个导入批次与记录的关联。多个文件共用相同记录时仍能按批次重建各自内容。

同一文件重复导入直接复用原批次。其他文件的记录只有在表名、ID、时间、类型和原值全部相同时才复用；相同 ID 的新时间或新值都会保留，原记录不覆盖。不同来源文件完整保留，即使其记录完全重叠。

提交事务前逐表核对记录数及每条记录的全部字段和原值字节，不一致即回滚。`alDenteArchiveData(identifier:)` 可取回未经重新编码的完整原始文件；本轮未增加档案浏览、撤销或重新导出的界面。

## 验证

普通测试使用合成数据，不将真实数据库、序列号或完整导出文件提交到仓库。通过环境变量额外启用本机真实导出验证：

```bash
HACHIBU_ALDENTE_VALIDATION_FILE=/path/to/aldente-full-history.json swift test --package-path Packages/HachibuKit
```

该验证在临时数据库中导入全部记录、重新打开数据库、取回完整文件并逐条核对，再检查重复导入。不会向实际运行中的 Hachibu 数据库写入。
