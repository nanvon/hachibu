# AlDente 历史导出指南

Hachibu 已支持导入、查看和原文件导出。首次从 AlDente 迁移时，先使用能访问本机文件、执行命令的本地 AI 工具生成完整 JSON，再交给 Hachibu 导入。

## 操作步骤

1. 打开 Hachibu「设置 → 历史数据」，展开「如何从 AlDente 导出」。
2. 点击「复制 AI 导出提示词」，确认界面显示已复制。中文和英文界面会复制对应语言的说明，包含完整格式示例。
3. 将提示词粘贴到本地 AI 工具，让它检查实际安装的 AlDente 版本和数据库，执行只读导出。提示词要求直接完成工作，工具没有本机权限时应说明限制。
4. 等待工具提供 `aldente-full-history.json`、`verification.json` 的绝对路径、来源版本、全部表的记录数、总记录数、文件 SHA-256 及逐条核对结果。
5. 仅在完整核对通过后，返回 Hachibu「导入 AlDente 历史…」，选择 JSON，检查预览中的 13 类数据和记录数后确认。
6. 导入完成后点击「查看已导入历史…」，按批次和来源表查看独立曲线或分页浏览原始记录；需要备份时可在该窗口导出字节一致的原始文件。

本功能只把提示词复制到剪贴板，不自动联系 AI 服务、执行脚本、安装依赖或读取 AlDente 数据库。无需将数据库或导出文件上传到聊天中。导出包含电池标识和历史记录，生成文件保存在本机。

## 读取范围与兼容性

本机只读读取已在 AlDente 1.39.3（111）验证。该版本的历史位于 `~/Library/Preferences/com.apphousekitchen.aldente-pro_stats.sqlite3`，数据库经过 SQLCipher 加密，App 内包含相应库。提示词要求检查本机实际版本、结构和初始化方式，不内置或发布解密参数，也不承诺其他版本兼容。

如果 AI 报告无法安全只读打开、发现额外或缺失的表、列或值类型不支持，应保留报告，先处理差异。不要让工具忽略未知表、生成空表来凑数量，或把不完整文件当作全量导出。

来源库必须在同一个只读事务中完成读取和核对，AlDente 运行期间不同时刻的统计可能不同。提示词要求保留数据库与日志文件，不退出或启动 AlDente、不改变充电设置。

## 提示词及格式维护

复制内容由以下随应用分发的文件组成，不需要网络：

- [英文提示词](../Packages/HachibuKit/Sources/FeatureUI/Resources/en.lproj/AlDenteExportPrompt.md)
- [简体中文提示词](../Packages/HachibuKit/Sources/FeatureUI/Resources/zh-Hans.lproj/AlDenteExportPrompt.md)
- [完整 JSON 结构示例](../Packages/HachibuKit/Sources/FeatureUI/Resources/AlDenteExportExample.json)

结构示例中的 13 张表均为空，版本和构建号为占位值，只说明文件结构。实际导出必须保存真实 schema、原始 ID、时间和全部原值，包括零、负数、空字符串、异常记录、电池标识和校准值；不能聚合、过滤、换算单位或时区。具体约束见 [AlDente 全量导入](AlDente全量导入.md)。

`verification.json` 是供用户和导出工具核对的独立报告，Hachibu 导入时只选择历史 JSON，并再次执行自身结构与原值类型校验。报告至少应包含实际版本和构建号、快照时间、13 张表各自的数量与原始时间范围、总数量、schema 和逐条核对结果、历史文件 SHA-256。只比较条数或范围不能证明数据完整；REAL 值需要逐条核对浮点位模式。

修改导出契约时同时检查 `HistoryStore/AlDenteArchive.swift`、结构示例、双语提示词和此文档。资源测试使用实际导入解析器验证结构示例，不依赖真实用户历史。测试不会运行其他 AI 工具，也不能证明其他 AI 一定能读懂任意 AlDente 版本。
