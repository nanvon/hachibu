# macOS 菜单栏电池监控应用技术方案调研

调研日期：2026-10-22

> **说明（2026-10-22 审查后添加）**：本文是调研记录，写代码以 `docs/v1技术设计.md` 为准。正文未改动，审查时在本机（MacBookPro18,1，macOS 27.0.1）实测得到以下更正：
>
> 1. 第 5 节“`AppleSmartBatteryPack` 是否提供温度仍待验证”：已确认提供，`BatteryData.Temperature = 2669`，即 26.69°C。v1 只读这个字段，不实现 SMC 和 IOHID 温度读取。
> 2. 第 3 节“未找到读取当前设定的接口”：设定值保存在 `/Library/Preferences/com.apple.powerd.charging.plist`（NSKeyedArchiver 归档的 `ChargeCtrlPolicy`，本机 `reason = manualChargeLimit`、`soclimit = 80`），普通用户可读，属私有格式。
> 3. 第 1 节“没有源时间戳时只能记录应用读取时间”：`AppleSmartBattery.UpdateTime`（Unix 秒）可作为源时间戳。`PowerTelemetryData` 约每 60 秒刷新一次，和 `UpdateTime` 同步变化，因此第 1 节每 2–5 秒读取功率的调度表不采用。
> 4. 第 1 节表格未提及：IOPS 的 `DesignCycleCount` 本机为 300，与 IORegistry `DesignCycleCount9C` 的 1000 不一致，只用后者。
> 5. 第 1 节“充电器名称从 `AdapterDetails` 读取”：公开 API `IOPSCopyExternalPowerAdapterDetails()` 已提供 `Name`、`Manufacturer`、`Watts`，改用公开 API。
> 6. 第 1 节“`SystemVoltageIn`、`SystemCurrentIn` 单位需实机核验”：本机为 mV、mA（28008 × 518 / 1000 ≈ 14508，与 `SystemPowerIn = 14514` 一致）。
> 7. 本机 IOPS 字典没有 `BatteryHealth`、`BatteryHealthCondition` 字段。
> 8. 审查时有第三方充电控制工具在运行，同时系统充电上限设为 80%。接电后停在 80% 不充电，无法区分是哪一方造成的；`NotChargingReason`（本机 `0x1000000`）的含义同样无法据此判断。

**推荐方案：最低 macOS 14，首版支持 Apple Silicon；采用 AppKit + SwiftUI、IOPowerSources + IORegistry、SMC 温度后备、GRDB/SQLite、Swift Charts、Sparkle 2。**

主体功能可实现，但以下能力必须允许降级：自动确认系统充电上限、跨机型获得全部温度和功率字段、每秒获得新的功率测量、通过稳定公开 API 取得系统最大容量。界面应区分“不可用、原因未知、估算、数据较旧”。【推测·方案建议】

下文标记含义：

- **【官方文档】**：Apple 文档或公开头文件。
- **【开源代码】**：已核对的源码，不能视为 Apple 的兼容性承诺。
- **【实测·用户】／【实测·第三方】**：分别指用户提供的数据、公开的具体设备记录。
- **【推测·方案】**：工程建议，尚未经过本项目验证。

本次调研阶段只读分析，没有运行构建、测试或重新采集本机电池数据。本文档由调研答复整理保存。

## 1. 数据采集：公开状态与扩展指标分开读取

推荐一个统一采集器，输出包含数值、单位、来源、读取时间和有效性的快照。IOPowerSources 负责公开状态和通知，IORegistry 负责扩展指标，SwiftUI 只消费快照。【推测·方案】

公开读取链路：

```text
IOPSCopyPowerSourcesInfo()
→ IOPSCopyPowerSourcesList()
→ IOPSGetPowerSourceDescription()
```

只选择 `kIOPSTypeKey == kIOPSInternalBatteryType`，避免把 UPS 等电源当成内置电池。使用 `IOPSNotificationCreateRunLoopSource` 接收变化通知，回调后重新读取。它不是完整数据推送，也不保证每个遥测字段变化都会通知。【官方文档】[IOPS 字段定义](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPSKeys.h)、[通知 API](https://developer.apple.com/documentation/iokit/1523868-iopsnotificationcreaterunloopsou?language=occ)

扩展指标通过 `IOServiceMatching("AppleSmartBattery")` 查找服务，用 `IORegistryEntryCreateCFProperties` 一次读取节点。这样可减少逐字段读取造成的不一致，但无法保证固件内部所有字段来自同一测量时刻。【开源代码＋推测·方案】[Stats 电池读取器](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/Modules/Battery/readers.swift)

| 指标 | 推荐来源、单位 | 备选及限制 | 依据 |
|---|---|---|---|
| 电量百分比 | IOPS `kIOPSCurrentCapacityKey / kIOPSMaxCapacityKey × 100` | 经验证后可用 IORegistry 百分比字段；不能把所有 `CurrentCapacity` 当成 mAh | 官方文档、开源代码 |
| 外接电源 | `ExternalConnected`；参考 `kIOPSPowerSourceStateKey` | 接电、使用外接电源、正在充电应分开判断 | 官方文档、用户实测 |
| 是否充电 | `kIOPSIsChargingKey`、`IsCharging` | 同时参考电池净功率及有效性 | 官方文档、方案 |
| 剩余时间 | `kIOPSTimeToEmptyKey`、`kIOPSTimeToFullChargeKey`，分钟 | `AvgTimeToEmpty`、`AvgTimeToFull` 作经验证后备；过滤无效哨兵值 | 官方文档、开源代码 |
| 电池电压 | `Voltage`，mV | 转为 V 展示 | 开源代码 |
| 电池电流 | `Amperage`，mA | 验证方向和整数符号；部分历史实现会把负数表示成很大的无符号数 | 开源代码 |
| 电池净功率 | `PowerTelemetryData.BatteryPower`，本机 mW | 缺失时由电压、电流估算；负值表示放电已在本机确认 | 用户实测、方案 |
| 输入功率 | `PowerTelemetryData.SystemPowerIn`，本机 mW | 不保证 Intel 或其他系统提供 | 用户实测 |
| 系统功率 | `PowerTelemetryData.SystemLoad`，本机 mW | 不可用时不能用充电器额定功率替代 | 用户实测、方案 |
| 满充／设计容量 | `BatteryData.FullChargeCapacity`、`DesignCapacity`，mAh | `NominalChargeCapacity`、`AppleRawMaxCapacity`、旧机型 `MaxCapacity` 不能无标记互换 | 开源代码、用户实测 |
| 循环次数 | `CycleCount` | 换电池后可以下降 | 开源代码 |
| 设计循环次数 | `DesignCycleCount9C` | 本机存在；其他机型缺失时显示未知，不能全部硬编码为 1000 | 用户实测 |
| 健康状态 | `kIOPSBatteryHealthKey`、`kIOPSBatteryHealthConditionKey` | 可缺失；它们是状态字符串，不是健康百分比 | 官方文档 |
| 系统最大容量 | 低频读取 `system_profiler` | 详见第 2 项 | 用户实测、开源代码 |
| 电池温度 | 经验证的 IORegistry → SMC → 可选 HID | 详见第 5 项 | 开源代码 |
| 充电器功率 | `IOPSCopyExternalPowerAdapterDetails()`、`kIOPSPowerAdapterWattsKey`，W | 是适配器报告值，不是实时消耗，也未必是多口充电器外壳标称总功率 | 官方文档 |
| 名称、制造商 | 可用时读取 `AdapterDetails.Name`、`.Manufacturer`；`Description` 作描述 | 第三方充电器或扩展坞可能不提供；不能用电池厂商补充 | 开源代码 |
| 实时输入电压、电流 | `SystemVoltageIn`、`SystemCurrentIn` | 开源实现按 mV/mA 使用；未找到 Apple 单位契约，需实机核验 | 开源代码，跨机型不确定 |
| 低电量模式 | `ProcessInfo.processInfo.isLowPowerModeEnabled` | 监听 `Notification.Name.NSProcessInfoPowerStateDidChange` 后重读 | 官方文档 |

表中公开字段依据为 [IOPSKeys.h](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPSKeys.h)，扩展字段实现参照 [Stats 读取器](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/Modules/Battery/readers.swift)。

两个容易混淆的地方：

- `IOPSGetTimeRemainingEstimate()` 返回**秒**，与字典中的分钟字段不同；“到充满”也不能未经验证解释成“到系统充电上限”。【官方文档＋推测·方案】
- `AdapterDetails` 中的电压、电流可能是协商能力或协议参数，不能直接标成实时测量值；`PowerTelemetryData` 中也只有功率字段可以按 mW 理解，电压、电流需要独立确认单位。【开源代码＋推测·方案】

推荐初始调度如下，频率属于工程选择：【推测·方案】

| 场景 | 读取频率 |
|---|---|
| 插拔电源、状态通知、唤醒 | 立即重读 |
| 面板打开：功率、电压、电流 | 每 2–5 秒 |
| 面板关闭，菜单栏显示功率 | 每 5 秒 |
| 温度 | 面板约 5 秒；菜单栏约 10–15 秒；纯后台 30–60 秒 |
| 只显示百分比 | 通知驱动，60 秒兜底 |
| 分钟历史 | 每分钟持久化一次 |
| 系统最大容量 | 启动后、每日、用户主动刷新 |

**读取频率不等于硬件刷新频率。**没有源时间戳时，只能记录“应用读取时间”，不能证明本次拿到了新的硬件测量。

权限方面，公开 IOPS 和常规 IORegistry 只读路径通常不需要 root、辅助功能或完整磁盘访问；关闭 Sandbox 不会绕过驱动权限检查。扩展字段应按能力探测，不能按芯片名称承诺全部存在。【开源代码＋推测·方案】

另一个兼容风险是：Apple 当前开源 powerd 存在 `privacy/ImprecisePowerData` 分支，可将公开 IOPS 电量舍入到 5% 的倍数。**不能据此认定本机已启用**，但应将 IOPS、IORegistry、系统显示的一致性加入验收。【开源代码】[BatteryTimeRemaining.m](https://github.com/apple-oss-distributions/PowerManagement/blob/d415e45501842834a280930c3eed9186544a67f0/pmconfigd/BatteryTimeRemaining.m)

## 2. 健康度：系统最大容量与容量比分开

推荐主指标显示系统最大容量，详情显示原始满充容量、设计容量和容量比。两种百分比单独保存来源，不拼接成一条无说明的历史曲线。【推测·方案】

Apple 将最大容量定义为相对电池全新时的容量；健康管理还会考虑温度历史和充电模式，系统更新也可能重新校准。【官方文档】[Apple Silicon 电池健康管理](https://support.apple.com/en-us/102589)

Apple 开源 powerd 的 macOS 实现包含 FCC 样本过滤、跨日平均、IIR 平滑、NCC、reserve 修正和校准状态。它支持“系统值并非一次 FCC/DC 相除”的结论，但不能证明 macOS 27 所有硬件仍采用完全相同的算法。【开源代码】[健康度计算源码](https://github.com/apple-oss-distributions/PowerManagement/blob/d415e45501842834a280930c3eed9186544a67f0/pmconfigd/BatteryTimeRemaining.m)

用户本机：

```text
系统最大容量：95%
原始容量比：7903 / 8694 ≈ 90.9%
```

这两个值可以同时成立。**具体相差约 4 个百分点的原因不确定**，不能仅凭这两个数归因于某项修正，也不能断言 `NominalChargeCapacity / DesignCapacity` 就等于系统值。【实测·用户＋计算】

第三方读取系统报告值的务实方案是：

```text
/usr/sbin/system_profiler SPPowerDataType -json
```

在 `SPPowerDataType` 数组中找到 `_name == "spbattery_information"` 的对象，再取：

```text
sppower_battery_health_info
  .sppower_battery_health_maximum_capacity
```

这一路径有实际开源解析代码。使用 `Process` 异步执行、设置超时、缓存结果，不在每次展开面板时运行。JSON 结构不是稳定 SDK 契约；缺字段时返回未知。【开源代码】[Raycast 解析实现](https://github.com/raycast/extensions/blob/master/extensions/watts-up/src/profiler.ts)

公开健康状态字符串和私有健康百分比接口需要区分。Apple 开源 `updateBatteryHealthData` 路径检查 `com.apple.private.iokit.batterydata`；普通 Developer ID 应用不能靠自行添加该 entitlement 获得能力。【开源代码】[权限检查源码](https://github.com/apple-oss-distributions/PowerManagement/blob/d415e45501842834a280930c3eed9186544a67f0/pmconfigd/BatteryTimeRemaining.m)

备选方案是只显示容量比，但必须这样命名。通过稳定公开 API 高频取得与系统设置一致的百分比，目前未核实到可靠方案。

## 3. 系统充电上限：功能已确认，稳定读取接口未确认

Apple 官方说明：Charge Limit 支持 **Apple Silicon、macOS Tahoe 26.4 及以后版本**，可设置 80%–100%；接近上限时停止充电，电量下降超过约 5% 后恢复，偶尔仍会充到 100% 校准。这与用户本机确认的功能一致。【官方文档】[Apple 充电上限说明](https://support.apple.com/en-us/102338)

**未找到读取当前设定及触发状态的稳定公开 API。**不应编造 `ChargeLimit` 键或读取函数，也不建议通过系统设置 UI 自动化实现常驻查询。【不确定＋推测·方案】

`ChargerData.NotChargingReason` 可以保存作诊断，但不能直接套用跨机型枚举。公开记录中的值和位定义不同，还存在拔电后保留旧值的情况。`NotChargingReason != 0` 不足以证明达到系统充电上限。【实测·第三方＋开源代码】[WattMate 记录](https://wattmateapp.com/mac-not-charging-past-80)、[Anode 的处理](https://github.com/noahahoward/Anode/blob/068e807bea3326160daed7915196e80eff43644e/Sources/PowerKit/ChargeTarget.swift)

推荐按证据显示状态：【推测·方案】

| 已有证据 | 可显示文案 |
|---|---|
| 已验证的上限设置来源及触发原因 | 已达到系统充电上限 |
| 用户手动填写上限，持续接电、不充电且接近该值 | 接近设定上限，充电已暂停 |
| 只有接电、不充电、净功率接近零 | 已接电，未充电 |
| 接电且电池持续放电 | 已接电，电池正在放电 |

因此，原来的状态清单需要增加 **“已接电，未充电”**。电量停在 80% 或 95% 本身无法排除优化充电、热保护或充电器问题。

手动配置系统上限可以作为备选，但可能过期；持续观察停止充电的电量只能形成推测，不能提供可靠的自动确认。

## 4. 功率流向：保留原始值，不强行凑平衡

按本机已验证符号：

```text
A = SystemPowerIn
L = SystemLoad
B = BatteryPower：正数充电，负数放电

待验证关系：A ≈ L + B
残差：r = A − L − B
```

拔电时 `A ≈ 0`，应有 `L ≈ −B`，与用户测得的 `11164 / −11164 mW` 一致。插电时各字段完整的测量边界仍需验证。【实测·用户＋推测】

`AdapterEfficiencyLoss` 的测量位置、是否已经包含在其他值中，未找到 Apple 公开契约。**不要写死 `A = L + B + loss`**，也不要把差额全部分配给电脑或电池。首版将它作为独立可选遥测项，不参与三节点图的守恒计算。【不确定＋推测·方案】

| 状态 | 流向 |
|---|---|
| 接电，B 持续为正 | 充电器 → 电脑；充电器 → 电池 |
| 接电，B 接近零 | 充电器 → 电脑 |
| 接电，B 持续为负 | 充电器 → 电脑；电池 → 电脑 |
| 无外接电源 | 电池 → 电脑 |

第三种状态建议命名为 **“外接电源与电池共同供电”**。插电放电并不能单独证明充电器功率不足，也可能与系统调度有关。【推测·方案】

显示处理建议：

- 保留原始值，另外生成显示用平滑值。
- 使用约 5–10 秒时间常数的 EMA；方向切换加入零点死区和持续确认。
- 插拔、唤醒、字段失效时重置平滑，避免旧状态持续显示。
- 超出残差容差时标记“数据更新中／估算”，不修改原始数值制造守恒。
- 所有流带采用相同的 W→宽度比例；设置最小可见宽度后，小功率段就不再严格成比例。
- 方向动画与采样解耦，面板关闭立即停止动画。【推测·方案】

残差容差可以从 `max(1 W, 相关最大功率的 5%)` 起步，再根据实际数据调整；这不是传感器精度声明。

真实更新频率没有跨机型保证。有作者在 M3 Max、macOS 27 上报告 `PowerTelemetryData` 约 10–60 秒才更新，并尝试 SMC `PDTR`、`PSTR` 获取更实时功率。这只是具体设备记录。【实测·第三方】[Stats issue #3671](https://github.com/exelban/stats/issues/3671)

如果必须提供更即时的功率，SMC 功率后端是备选，但必须验证测量边界，不能直接混合不同后端的数据。Intel 缺少输入功率、系统负载时，可以显示电池功率，不能拿充电器额定功率倒推整机负载。【推测·方案】

历史页的“耗电量（系统负载）”应改为 **“系统功率，W”**。耗电量是 Wh，需要对有效时间积分；分钟抽样得到的也只是估计，不能跨休眠和缺测区间积分。【物理定义＋推测·方案】

## 5. 温度：先查电池包节点，再读 SMC

推荐读取顺序：

```text
经验证的 IORegistry 温度
→ SMC 电池温度
→ 可选 IOHID 电池温度
→ 不可用
```

Stats 当前源码的顺序是：

1. `AppleSmartBattery.Temperature / 100`
2. `AppleSmartBatteryPack.BatteryData.Temperature / 100`
3. SMC `TB1T`、`TB2T` 的有效值平均

因此，本机主节点没有温度，**不能排除 `AppleSmartBatteryPack`**；该节点在本机是否提供温度，仍待验证。【开源代码】[Stats 温度读取](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/Modules/Battery/readers.swift#L215)

上面的 `/100` 是该实现采用的单位转换，不能推广到全部旧 Intel 或其他温度字段。SBS 原始协议还有 0.1 K 的温度定义，不能与 macOS 转换后的字段混用，也不能只按数值量级猜单位。【开源代码＋协议文档】[Smart Battery Data Specification](https://sbs-forum.org/specs/sbdata10.pdf)

SMC 的具体只读方式如下：【开源代码】

```text
匹配 AppleSMC 服务
→ IOServiceOpen(service, mach_task_self_, 0, &connection)
→ IOConnectCallStructMethod(connection, 2, ...)
→ data8 = 9：读取 key 元数据
→ data8 = 5：读取值
```

使用与 SMC ABI 对应的 `SMCKeyData_t`，读取 key 类型、长度、结果码和 payload，同时检查 IOKit 返回值与 SMC 返回结果。关闭连接用 `IOServiceClose`，释放服务用 `IOObjectRelease`。本项目无需实现写入命令。[Stats SMC 实现](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/SMC/smc.swift#L636)

解码必须依据返回类型：

- `sp78`：两字节有符号定点格式，8 位小数；正确处理符号和端序。
- `flt `：四字节浮点，注意类型名末尾的空格；macmon 使用 little-endian 解码。
- 未知类型或不符长度：返回不可用。

不能仅凭 CPU 架构选择固定解码方式。【开源代码】[macmon SMC 解码](https://github.com/vladkens/macmon/blob/39e98aa73e49256e6281b2a228f6ef3499ae3209/src/sources.rs#L1503)

已核实的 key 范围：

| 平台 | 候选 key | 能确认的范围 |
|---|---|---|
| Intel MacBook | `TB1T` | Stats 明确列为 Intel 电池传感器；并非每款必有 |
| M1 系列 | `TB1T`、`TB2T` | Stats 的通用 Apple Silicon 映射 |
| M2 系列 | 同上 | 未找到完整逐机型验证矩阵 |
| M3 系列 | 同上 | 未找到完整逐机型验证矩阵 |
| M4 系列 | 同上 | 未找到完整逐机型验证矩阵 |
| M5 及后续 | 同上作为探测候选 | 是否全面可用不确定 |

这些依据来自 [Stats 传感器映射](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/Modules/Sensors/values.swift)，**不能解释成每代芯片存在不同且已确认的专属 key**。也不应把全部 `TB*T` 无区别平均。

权限方面，现有非沙箱、只读 SMC 实现通常无需 root、特权 helper 或特殊 entitlement；macmon 明确支持免 sudo。但具体权限由 IOService 驱动决定，AppleSMC 协议不属于稳定公开契约。仍需用正式签名构建验收，不能据此保证未来系统始终可读。【开源代码＋官方文档】[macmon README](https://github.com/vladkens/macmon/blob/39e98aa73e49256e6281b2a228f6ef3499ae3209/readme.md)、[IOServiceOpen](https://developer.apple.com/documentation/iokit/1514515-ioserviceopen)

IOHID 是三级备选。源码中确有 `"gas gauge battery"` 电池传感器名称，其读取涉及：

```text
IOHIDEventSystemClientCreate
匹配 PrimaryUsagePage = 0xff00、PrimaryUsage = 0x0005
IOHIDEventSystemClientCopyServices
IOHIDServiceClientCopyProperty(..., "Product")
IOHIDServiceClientCopyEvent(..., kIOHIDEventTypeTemperature, ...)
IOHIDEventGetFloatValue(..., 15 << 16)
```

这些未公开接口可用兼容层声明或 `dlsym` 加载。动态查找只能方便缺符号时降级，不提高稳定性，也不绕过权限。【开源代码】[macmon HID 实现](https://github.com/vladkens/macmon/blob/39e98aa73e49256e6281b2a228f6ef3499ae3209/src/sources.rs#L1292)

IOHID 还需要服务发现、名称匹配、空事件处理和缓存，维护成本高于读取少量已知 SMC key。不同系统的可用性记录不一致，服务为空就降级；不能用 CPU、GPU、`PMU tdie` 温度代替电池温度。【开源代码＋实测·第三方】[Stats HID 缓存实现](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/Modules/Sensors/reader.m)、[btop 设备记录](https://github.com/aristocratos/btop/issues/1653)

**未找到适用于全部 Mac 电池内部传感器的官方“正常／偏高”统一阈值。**Apple 的 10–35°C 指环境温度，不能拿 35°C 直接判定电芯偏高。建议显示“未超过提醒阈值／高于提醒阈值”；若保留原文案，需要注明依据是应用设置。【官方文档＋推测·方案】[Apple 温度说明](https://support.apple.com/zh-cn/102336)

## 6. 菜单栏面板：保留既定方案，明确焦点和关闭逻辑

采用既定 `NSStatusItem + NSPanel([.borderless, .nonactivatingPanel]) + NSHostingView`。AppKit 管理生命周期和窗口，SwiftUI 管理内容；使用 `LSUIElement`，主窗口由 `NSWindowController` 管理，打开主窗口时再显式激活应用。【官方文档＋推测·方案】[NSPanel](https://developer.apple.com/documentation/appkit/nspanel)

| 事项 | 推荐做法 |
|---|---|
| 定位 | 将实际点击的 `statusItem.button.bounds` 转为 window 坐标，再 `convertToScreen`；依据按钮所在屏幕限制面板边界，每次打开重新计算 |
| 多显示器 | 不假定 `NSScreen.main` 是菜单栏所在屏幕；处理缩放、布局、屏幕断开和菜单栏位置变化 |
| 外部点击关闭 | 面板打开期间安装 local/global 鼠标事件 monitor；排除按钮、面板及关联窗口，关闭后移除 |
| Esc | 使用本地事件或 responder 的 `cancelOperation`，无需全局键盘监听 |
| 键盘焦点 | 需要键盘导航时覆盖 `canBecomeKey = true`、`canBecomeMain = false`；nonactivating 不等于不能成为 key window |
| 失焦关闭 | `windowDidResignKey` 作为补充，不能只依赖 `NSApp.didResignActive`；应用可能从未激活 |
| Spaces、全屏 | 从 `.canJoinAllSpaces + .fullScreenAuxiliary` 开始验证；按系统可用性评估 `.canJoinAllApplications` |
| 窗口层级 | 验证合理浮动或状态栏层级，不默认使用 `.screenSaver`；切换 Space、锁屏、屏幕布局变化时关闭面板 |

上述 API 依据为 [坐标转换](https://developer.apple.com/documentation/appkit/nswindow/converttoscreen(_:))、[事件监控](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)、[collectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)。具体组合属于方案，仍需多屏、全屏和 Stage Manager 实机验证；几个 flags 不能保证全部场景正确。【官方文档＋推测·方案】

材质建议：

```text
macOS 26+：NSGlassEffectView，hostingView 放入 contentView
更早系统：NSVisualEffectView，例如 popover 材质
```

避免叠加多层玻璃与 SwiftUI 材质；响应减少透明度、减少动态效果设置。`NSGlassEffectView` 是 macOS 26+，其新增属性仍需分别检查 availability。【官方文档＋推测·方案】[NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)、[contentView](https://developer.apple.com/documentation/appkit/nsglasseffectview/contentview)

菜单栏文字使用 `title/attributedTitle`、等宽数字和稳定宽度；最终显示值没变就不更新。避免用高帧率刷新状态栏文字或不断改变 status item 宽度。采集在后台执行，按钮更新在主线程完成。【推测·方案】

备选 `NSPopover` 可以减少关闭逻辑，但没有必要改变已定方案。上述面板实现无需辅助功能、输入监控或屏幕录制权限；不要为了 Esc 关闭而增加全局键盘监听。

## 7. 后台运行：接受真实采样偏移，不阻止休眠

登录启动使用 `SMAppService.mainApp.register()`／`unregister()`，设置页展示真实 `status`；需要批准时使用 `SMAppService.openSystemSettingsLoginItems()` 引导。macOS 13+ 可以注册主应用，无需另外建立 login helper、LaunchDaemon 或 root 服务。【官方文档】[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)

后台保留一份采集服务，关闭窗口不退出应用。定时器设置合理 leeway，使用实际执行时间；面板关闭且菜单栏不显示功率时停止快速轮询。【推测·方案】

App Nap 可能延后定时器。推荐将要求定义为“机器唤醒、应用运行时尽量每分钟记录”，接受时间偏移。不要长期持有 `.latencyCritical` 或阻止系统休眠的 assertion；关闭 Sandbox 也不会自动关闭 App Nap。【官方文档＋推测·方案】[App Nap 指南](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)

监听 `NSWorkspace.shared.notificationCenter` 的：

- `willSleepNotification`：停止快速轮询，提交已有样本。
- `didWakeNotification`：立即重读，清空平滑历史，必要时重建 IOKit/SMC 连接。

休眠期间保留数据缺口，不补零、不复制睡前值，不延伸出确定的供电状态。每日记录在当天首次有效采样时产生，不为午夜记录唤醒机器。【官方文档＋推测·方案】[休眠通知](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification)

采样对耗电的具体影响目前**不确定**，不能凭静态方案给出百分比。后续应分别测量面板开关、功率菜单栏开关、电池及插电状态下的 CPU、wakeups、磁盘写入和 Energy Impact。【官方文档】[能耗测量指南](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MonitoringEnergyUsage.html)

## 8. 存储：GRDB/SQLite 最适合这组需求

| 方案 | 判断 |
|---|---|
| GRDB/SQLite | 推荐；范围查询、聚合、事务、迁移可以明确控制 |
| SwiftData | 可用；UI 绑定方便，但仍需实现聚合、保留策略和缺测语义 |
| 直接 SQLite | 可用；依赖更少，自己承担绑定、并发和迁移代码 |
| JSON/CSV 文件 | 适合导出和测试 fixture，不推荐作长期主存储 |

这是工程选择，并非 SwiftData 无法完成需求。SwiftData 的 `VersionedSchema`、`SchemaMigrationPlan` 可以处理版本迁移。【官方文档＋推测·方案】[SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan)

GRDB 初期可用 `DatabaseQueue`；每分钟一次写入吞吐很低。如果图表查询与维护确有并发需求，再使用 `DatabasePool` 和 WAL。【开源代码＋推测·方案】[GRDB 并发文档](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Concurrency.md)

建议的数据表和语义：【推测·方案】

| 表 | 用途 |
|---|---|
| `minute_samples` | 最近 7 天分钟样本 |
| `hourly_samples` | 小时聚合，长期保存 |
| `daily_battery_samples` | 每日健康度、容量、循环次数 |
| `power_events` | 接电、拔电及可确认的状态变化 |
| `battery_sessions` | 区分不同电池及指标来源变化 |

未知值存 `NULL`，不能存 0。记录来源、质量和电池标识；序列号只作本地最小化识别，公开 fixture 脱敏。

小时聚合保存均值、最小值、最大值、有效样本数和覆盖时长。循环次数使用末值或变化事件，不求平均。接电区间单独保存，不能用一个小时级“是否插电”布尔值替代。【推测·方案】

对已封闭且超过保留界限的小时，在一个事务中执行：

```text
读取对应分钟记录
→ upsert 小时聚合
→ 删除已聚合的分钟记录
→ 提交
```

用唯一键保证幂等。保留期边界上的半个小时要明确处理，不能聚合部分后删除整小时；没有有效数据的小时不生成零值。【推测·方案】

时间戳存 UTC；每日记录另定义本地日期和时区规则。关机日不补造记录，换电池后分段，处理时区变化和夏令时。

数据量估算：

```text
7 天分钟数据：10,080 行
每年小时数据：约 8,760 行
每年每日数据：约 365 行
10 年总量：约 101,330 行，另加电源事件
```

按每行及索引平均 200–500 字节估算，主体约 20–50 MB，另计 WAL、空闲页和事件。只是容量预算，不是实测。【计算＋推测】

迁移使用 `DatabaseMigrator.registerMigration`。已发布迁移只追加、不改写；升级前保留可恢复备份，验证旧数据库升级。Release 不启用 schema 变化即清库的开发选项。【开源代码＋推测·方案】[GRDB 迁移文档](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md)

这些存储方案均不要求特殊 entitlement。

## 9. 图表：Swift Charts 足够，先限制绘制点数

用户的时间范围实际需要：

| 范围 | 单条曲线约需点数 |
|---|---:|
| 近期 1 小时 | 60 |
| 近期 24 小时 | 1,440 |
| 近期 7 天，按小时 | 168 |
| 长期 30 天 | 30 |
| 长期 1 年 | 365 |
| 长期 10 年 | 3,650 |

因此，数据库有上万条记录，不代表界面要同时绘制上万个点。首版推荐 Swift Charts。【计算＋推测·方案】

对应能力：

- `LineMark`：电量、功率、温度、健康度、容量。
- `.interpolationMethod(.stepEnd)` 等阶梯插值：循环次数；用两点 fixture 核对阶梯发生在正确时刻。
- `RectangleMark(xStart:xEnd:...)` 或 `chartBackground`：插电时段及“未记录”区域。
- `RuleMark`＋annotation：悬停指示线和读数。【官方文档】[插值方法](https://developer.apple.com/documentation/charts/interpolationmethod)、[RectangleMark](https://developer.apple.com/documentation/charts/rectanglemark)

桌面悬停建议使用 `chartOverlay + onContinuousHover + ChartProxy.value(atX:as:)`。转换坐标时扣除绘图区原点，二分查找最近有效样本；缺测区间显示“未记录”，不要自动跨缺口插值。【官方文档＋推测·方案】[ChartProxy](https://developer.apple.com/documentation/charts/chartproxy/value(atx:as:))

近期、长期分别持有时间范围状态；所选范围早于首次记录时，也要保留完整横轴并标注未记录区域，而非偷偷缩短时间轴。【推测·方案】

macOS 14 增加了选择和滚动能力，是最低版本建议的依据之一。没有找到任意上万点保持固定帧率的官方保证；超过可视分辨率时先做保峰值降采样，再考虑 Canvas 或 Core Graphics。无需一开始自绘坐标轴、读数和辅助功能。【官方文档＋推测·方案】[macOS 14 更新说明](https://developer.apple.com/documentation/macos-release-notes/macos-14-release-notes)

## 10. 通知：用持久化状态机去抖

使用 `UNUserNotificationCenter`；用户开启提醒时申请 `.alert/.sound`，通过 `UNMutableNotificationContent`、`UNNotificationRequest` 发送本地通知。无需 APNs、push 或 critical-alert entitlement；展示时间仍受用户授权和专注模式影响。【官方文档】[通知授权](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:))

建议规则如下：【推测·方案】

| 提醒 | 去抖规则 |
|---|---|
| 温度 | 连续有效超限 2–3 分钟触发一次 |
| 温度恢复 | 低于阈值一定幅度，例如 2°C，并持续一段时间后重新允许触发 |
| 健康度 | 每日有效记录评估，连续两天低于阈值后提醒 |
| 持续异常 | 不每分钟或每天重复弹出 |
| 重启 | 恢复原来的异常事件状态，避免重复提醒 |
| 睡眠、数据缺失 | 不视为恢复正常 |
| 换电池、来源变化 | 重建基线，避免跨来源直接比较 |

持久化 `armed/active/lastDeliveredAt/source/batterySessionID`，通知 identifier 使用事件标识。持续时间、回差和冷却时间是产品参数，不是 Apple 安全标准。

如果展示温度采用均值、提醒采用最高值，应在详情中解释，否则可能出现“显示值没超阈值却提醒”的困惑。首版也可以统一采用最高有效电池温度，减少口径差异。【推测·方案】

## 11. 分发：保持 Hardened Runtime，使用标准公证和更新流程

推荐流程：

```text
Xcode Archive
→ Developer ID Application 签名
→ Hardened Runtime + secure timestamp
→ notarytool 提交公证
→ stapler staple
→ 验证签名、票据及下载后的 Gatekeeper 启动
```

以 DMG 分发时，按最终产物完成签名与公证流程；嵌套 frameworks、XPC 和 helpers 均需正确签名。【官方文档】[macOS 公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

本项目可以关闭 App Sandbox，保留 Hardened Runtime。正常 UI、数据库、本地通知和主应用登录启动不需要特殊高权限 entitlement。现有只读采集实现也不构成添加以下权限的理由：

```text
allow-jit
allow-unsigned-executable-memory
disable-library-validation
Apple Events automation
```

Release 不应包含 `get-task-allow = true`。SMC/HID 失败时应记录并降级，不能靠随意添加 Apple 私有 entitlement 解决。【官方文档＋开源代码＋推测·方案】[Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)

自动更新推荐 **Sparkle 2**：

```text
SPUStandardUpdaterController
SUFeedURL
SUPublicEDKey
HTTPS appcast
EdDSA 更新签名
```

Developer ID 签名与 Sparkle 更新签名都保留；更新私钥不要存放在下载服务器。按官方流程处理 Sparkle 内部 helpers，不以 `codesign --deep` 代替正确签名。【开源项目官方文档】[Sparkle 接入](https://sparkle-project.org/documentation/)、[发布更新](https://sparkle-project.org/documentation/publishing/)

备选是检查版本后打开官网下载，维护成本更低。自写下载、校验、替换和恢复流程没有明显收益，不建议首版采用。【推测·方案】

## 12. 工程结构：Xcode App 工程与 SwiftPM 配合

推荐 **Xcode App 工程＋本地 Swift Packages**。Xcode 管 App bundle、Info.plist、签名、公证和归档；SwiftPM 管依赖与可测试逻辑。纯 SwiftPM executable 仍需自行维护应用打包和发布脚本。【推测·方案】

| 模块职责 | 内容 |
|---|---|
| `AppShell` | AppDelegate、NSStatusItem、NSPanel、主窗口 |
| `BatteryCore` | 单位、快照、状态推导、平滑、提醒规则 |
| `HardwareReaders` | IOPS、IORegistry、SMC、可选 HID |
| `HistoryStore` | 数据库、聚合、保留策略、迁移 |
| `FeatureUI` | 面板、历史、通知、设置 |
| `PlatformServices` | 登录启动、通知投递、更新 |

可以先合并成 3–4 个 targets，无需每项独立建包。UI 使用 MainActor；硬件读取和数据库操作在 actor 或串行执行上下文中完成。【推测·方案】

录制测试数据应包含：

```text
IORegistry 原始值及类型
IOPS 字典
系统版本与 build、机型
读取时间及电源状态
SMC key / type / size / raw bytes
```

不能只录转换后的 Double，否则无法测试整数符号、字节序和类型变化。序列号、设备标识脱敏。【推测·方案】

通过注入 provider、时钟、通知出口，回放四类供电状态、未知充电原因、缺字段、异常单位、无符号负数、陈旧数据、温度抖动、睡眠、换电池和旧库迁移。

**录制数据测试只能验证解析和规则，不能证明硬件访问权限、实际刷新率、全屏面板或签名发行行为。**这些仍需实机验收。【推测·方案】

## 13. 开源参考与许可证

以下源码和许可证已核对。【开源代码】

| 项目 | 具体代码位置 | 许可证及用途 |
|---|---|---|
| exelban/Stats | [`Modules/Battery/readers.swift`](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/Modules/Battery/readers.swift)、[`SMC/smc.swift`](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/SMC/smc.swift)、[`Modules/Sensors/values.swift`](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/Modules/Sensors/values.swift)、[`reader.m`](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/Modules/Sensors/reader.m) | [MIT](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/LICENSE)；参考电池采集、SMC、HID 缓存；不要照搬未经验证的状态启发式 |
| vladkens/macmon | [`src/sources.rs`](https://github.com/vladkens/macmon/blob/39e98aa73e49256e6281b2a228f6ef3499ae3209/src/sources.rs) | [MIT](https://github.com/vladkens/macmon/blob/39e98aa73e49256e6281b2a228f6ef3499ae3209/LICENSE)；参考 SMC 类型解码、HID、免 sudo 读取；主要面向 Apple Silicon |
| Apple PowerManagement | [`pmconfigd/BatteryTimeRemaining.m`](https://github.com/apple-oss-distributions/PowerManagement/blob/d415e45501842834a280930c3eed9186544a67f0/pmconfigd/BatteryTimeRemaining.m) | 文件头为 APSL-2.0；用于研究健康计算和权限，不按 MIT 代码直接移植 |
| GRDB | [`Concurrency.md`](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Concurrency.md)、[`Migrations.md`](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md) | [MIT](https://raw.githubusercontent.com/groue/GRDB.swift/master/LICENSE)；参考并发、事务和迁移 |
| Sparkle 2 | [接入及发布文档](https://sparkle-project.org/documentation/) | [MIT 及附带第三方许可](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/LICENSE)；保留完整 notices |

## 技术选型总表

以下是综合前述依据的工程建议。【推测·方案】

| 项目 | 推荐选择 |
|---|---|
| 最低系统 | **macOS 14** |
| 首发架构 | **Apple Silicon**；Intel 作为独立兼容阶段 |
| 应用与窗口 | AppKit、`LSUIElement`、既定 NSStatusItem＋NSPanel |
| 界面 | SwiftUI＋NSHostingView，必要处嵌入 AppKit |
| 基础电源状态 | IOPowerSources＋通知 |
| 扩展电池与功率 | IORegistry 快照、字段能力探测 |
| 温度 | 已验证 IORegistry → SMC → 可选 HID |
| 系统健康度 | 低频 system_profiler；容量比另存另显 |
| 充电上限 | 确认后显示；否则保留“已接电，未充电” |
| 后台采样 | 单进程调度，休眠留缺口 |
| 登录启动 | SMAppService.mainApp |
| 存储 | GRDB/SQLite |
| 图表 | Swift Charts，绘制前降采样 |
| 通知 | UserNotifications＋持久化去抖 |
| 分发更新 | Developer ID、公证、Hardened Runtime、Sparkle 2 |
| 工程 | Xcode App＋本地 Swift Packages |
| 概览页 | 首版不保留，主窗口默认历史页 |

最低 macOS 14 的理由是：已有较完整的 Charts 交互能力，可以采用 Observation，窗口和后台 API 也满足需求；玻璃材质通过 macOS 26 条件分支启用，无需因此提高最低版本。macOS 13 是可行备选，但会增加交互兼容和测试范围。【官方文档＋推测·方案】[macOS 14 更新说明](https://developer.apple.com/documentation/macos-release-notes/macos-14-release-notes)

支持 Intel 主要增加这些工作：

- 发布 `arm64 + x86_64` Universal 二进制，核对依赖架构。
- 验证 Intel SMC key、类型、容量字段及电流符号。
- 为缺少整机功率遥测的设备明确降级显示。
- 验证旧款 MagSafe、USB-C、扩展坞返回的信息。
- 增加 Intel 实机的睡眠、唤醒、多屏面板和升级测试。

Rosetta 不能替代 Intel 传感器验证。Apple 已明确 macOS 26 是 Intel 最后一个 macOS 大版本，支持 Intel 意味着维护旧系统线；本机 macOS 27 不能代表这条线的验收。【官方文档＋推测·方案】[WWDC25 Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2025/102/)

## 风险清单

| 风险 | 影响 | 建议处理 |
|---|---|---|
| IORegistry、SMC、HID 未公开契约变化 | 指标缺失、单位或语义变化 | 隔离 provider，保存来源与类型，允许不可用 |
| 系统充电上限无法稳定读取 | 错误显示“已达到上限” | 必须保留原因未知状态 |
| 系统健康度与容量比不同 | 用户误认为应用计算错误 | 分名、分源、分历史 |
| 功率缓存及测量时间不一致 | 流量不守恒、方向闪动 | 保留残差、统一平滑、显示质量状态 |
| 温度源和提醒阈值不统一 | 错误判断“过热” | 只用明确电池源，阈值标为应用策略 |
| App Nap、休眠和关机 | 分钟数据缺口 | 保存实际时间和覆盖率，不补造数据 |
| Intel 字段覆盖不完整 | 功能不能与 Apple Silicon 完全一致 | 明确降级范围及独立验证矩阵 |
| 长期聚合或迁移出错 | 历史数据丢失 | 原子聚合、幂等维护、可恢复备份 |
| 多屏、全屏及焦点处理差异 | 面板位置或关闭行为异常 | 使用真实设备和系统组合验收 |

风险依据见对应章节；处理方式均为方案建议。

## 需要用户决定的问题

1. **是否接受 macOS 14 起步、首版只支持 Apple Silicon？**这是影响范围和验收成本最大的决定。
2. **是否接受缺失指标显示“—”，充电上限无法确认时显示“已接电，未充电”？**现有证据不足以承诺所有设备完整提供这些信息。
3. **健康度是否以系统最大容量为主，容量比放详情？**建议如此。
4. **功率是否接受按硬件实际刷新，不承诺每秒新测量？**若必须更即时，需要增加 SMC 功率后端的实机研究。
5. **温度采用最高值还是均值，默认提醒阈值如何设置？**建议展示和告警使用一致口径，并明确阈值属于应用设置。
6. **是否取消首版概览页，并将“耗电量”改为“系统功率”？**建议取消；Wh 耗电量作为独立估算功能再考虑。
7. **是否接受休眠缺口和后台定时器偏移？**建议接受，不为记录数据阻止系统休眠。
