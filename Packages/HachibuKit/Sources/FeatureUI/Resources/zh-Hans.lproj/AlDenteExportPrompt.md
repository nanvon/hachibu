# 为 Hachibu 导出我的全部 AlDente 历史数据

请使用本机文件访问和命令执行能力，实际完成导出，并生成符合下述 Hachibu 格式、经过完整核对的历史文件。不要只解释操作步骤。如果你没有本地文件或命令权限，停止并说明需要本地工具，不要让我把数据库或历史文件上传到聊天中。

## 先检查本机安装和数据库

- 查找实际安装的 AlDente，常见位置是 `/Applications/AlDente.app` 或 `~/Applications/AlDente.app`。读取 Info.plist，取得真实版本、构建号和 Bundle ID，预期 Bundle ID 是 `com.apphousekitchen.aldente-pro`。不能使用示例中的版本号，也不能假设不同版本实现相同。
- 已验证过的历史数据库路径是 `~/Library/Preferences/com.apphousekitchen.aldente-pro_stats.sqlite3`，必须先确认实际文件。不要访问许可证、凭证或其他无关用户文件。
- 本机读取仅在 AlDente 1.39.3（111）验证过。该安装使用 SQLCipher 加密，App 内包含 `SQLCipher.framework` 和 `SQLite.framework`。普通 SQLite 报 `file is not a database` 不代表数据损坏。必要时检查实际安装的库和数据库初始化代码，确认本机读取参数；不能假设通用密钥，不能打印密钥，也不能把密钥写入脚本或报告，参数仅在进程内存中使用。如果无法确认正确读取方式，停止并报告阻碍，不生成声称完整的导出。
- 导出前盘点全部数据库对象、建表语句、列信息和 SQLite 原值类型。预期用户数据恰好是下方示例中的 13 张表。若发现新增或缺失的表、变化的列或约束、不支持的类型、格式不允许的 NULL、无法精确保留的值，停止并报告具体结构差异。不能丢弃未知数据、强制转换来适配格式，也不能编造缺失表。

## 只读操作，同一一致性快照

- 不修改数据库及其 journal/WAL/SHM 文件、应用偏好、充电设置或已安装应用。不启动或退出 AlDente，不更改权限，不自动安装依赖。优先使用已有的本地工具和安装包中的 SQLCipher 库。如果确实需要额外操作，先说明并取得授权。
- 用带 `mode=ro` 的 `file:` URI，以 `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` 打开，确认 `sqlite3_db_readonly(..., "main") == 1`，并启用 `PRAGMA query_only=ON`。加密参数在内存中初始化后再查询。不能安全只读打开就停止。不要对正在变化的数据库使用 `immutable=1`，也不要只复制主数据库而遗漏 WAL。
- 在同一个只读事务中读取 schema、列信息、全部记录，并完成所有核对查询，最后结束只读事务而不修改来源。AlDente 可能继续采样，不能拿不同时刻的快照记录数相互比较。

## 输出格式：hachibu.aldente.raw，第 1 版

- 输出 UTF-8 JSON，`format` 严格为 `hachibu.aldente.raw`，整数 `formatVersion` 严格为 `1`。`source.app` 为 `AlDente`，`source.bundleIdentifier` 为上面核实的标识。`source.version` 和 `source.build` 必须使用实际安装的非空字符串。可另存 `exportedAt`、来源数据库文件名、user_version、cipher 版本等元数据，不包含加密参数。
- `schema` 保存来源数据库对象，把 sqlite_master 的 `type`、`name`、`tbl_name`、`sql` 对应保存为 `type`、`name`、`table`、`sql`。包含全部 13 张表的真实建表 SQL，索引、视图或触发器元数据也保留。不得执行来源 SQL，也不能用示例 SQL 替换实际建表语句。
- `tables` 必须恰好包含下方全部 13 张表。每表包含 `columns`、`rowCount`、`rows`。`columns` 是按顺序保留的实际 `PRAGMA table_info` 结果：cid/name/type/notnull/dflt_value/pk 对应 position/name/type/notNull/default/primaryKey。每表必须恰好是 `id` INTEGER、`timestamp` TEXT、`value`（类型见示例）三列；position 为 0、1、2，notNull 均为整数 1，primaryKey 为 1、0、0，default 均为 JSON null。实际结构不符时不能伪装成此结构。
- 每条记录恰好包含 `id`、`timestamp`、`value`。ID 保留原始有符号 64 位整数，timestamp 保留原文。ID 在本快照的单张来源表内唯一，不同快照中可循环复用；不能用 ID 判断时间先后，也不能用它关联不同指标表。
- INTEGER 值和 ID 必须是精确的有符号 64 位 JSON 整数，不能变成浮点或布尔。REAL 必须是有限数值，用足够精度序列化，重新读取后 IEEE 754 双精度位模式必须完全一致，包括负零。TEXT 原样保留空字符串、Unicode 和经过 JSON 转义的控制字符。使用能保留 64 位整数的序列化工具，不经过 JavaScript Number。
- 每张表的每条记录都要保留，包括零、负数、异常记录、电池标识、校准值和充电上限历史。空表也保留真实列信息、`rowCount: 0` 和 `rows: []`。不聚合、过滤、去重、插值，不换算单位或时区，不推断缺失值，不合并时间。`lastCalibration.value` 与该行 timestamp 分开保存。

## 核对和交付

1. 在可写位置新建私有输出目录（权限 700），使用新文件名，不覆盖已有文件。历史导出和报告均使用私有文件权限 600。
2. 基于真实查询生成 `aldente-full-history.json`，不能拿模板充当数据。同一个只读事务尚未结束时，重新读取写出的 JSON，核对完整对象和表清单、列信息。每张表核对 COUNT(*)、ID 唯一性，以及每条记录的 ID、timestamp、value 类型和原值。整数精确比较，文本精确比较，REAL 比较 IEEE 754 的 64 位位模式。只核对条数或时间范围不算通过。
3. 单独生成 `verification.json`，记录实际应用版本和构建号、快照及导出时间、全部表名和条数、总条数、原始时间范围、schema 和逐条原值核对结果，以及最终导出文件的 SHA-256。聊天或日志中不打印电池标识、历史记录或加密参数。失败必须明确报告，全部核对通过后才能标为完整；失败候选文件从最终输出位置移走，避免被误认为已验证导出。
4. 返回两个文件的绝对路径、应用版本、全部 13 张表的条数、总条数、SHA-256 和完整核对是否通过。然后告诉我在 Hachibu 的「设置 → 历史数据 → 导入 AlDente 历史…」选择 JSON，检查预览再确认。不直接修改 Hachibu 数据库，也不自动导入。

## 完整结构示例

下面是格式示例，故意使用空表及占位版本和构建号，不代表我的真实数据。不能直接作为导出结果交付，不能拿示例的零条数生成报告，也不能用示例建表 SQL 替换真实数据库定义。必须先检查并核对，再替换全部占位值，并填入每张来源表的全部真实记录。
