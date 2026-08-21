# IMPLEMENTATION_PLAN — 重构实施计划

> 定位:Filza 原生文件管理能力 + MHA/MCM 跨容器访问 − Root/Jailbreak 功能。
> 原则:每阶段可构建、小提交、先抽象后迁移;MCM 链路冻结不动(见 ARCHITECTURE_AUDIT.md 附录)。

## 目标架构(Phase 3 起逐步落地,第一轮不搬文件)

```
Core/        FSCapabilities.*      能力模型(启动探测,UI 依据)
             FSAccessManager.*     统一文件访问判定(read/write/create/delete/rename/copy/move/mkdir/extract/compress/editor save)
             FSFeatureRegistry.*   功能注册与可见性
Access/      MCMBridge.*(现有)    ABI 绑定层(冻结)
             MCMFilzaIntegration.*(现有) 策略层(冻结核心,增量演进)
             MCMAccessProvider.* / MCMVirtualRoot.* / MCMAppResolver.*(后续从 Integration 拆出)
Compatibility/ RootHelperBlocker.*(新:统一熔断,含 5 个降级路径)
             FeaturePruning.*(root-only UI 隐藏)
             FileOperationHooks.*(现 Tweak.m 文件操作部分)
             AppsManagerCompat.* / TGFocusedInputResponderTimingFix.*
Archive/     ArchiveUnzipFix.* + Vendor/minizip + Vendor/unrar
Optional/    PosterBoard/*
Legacy/      kexploit/ kpf/ XPF/ sandbox_escape.* apfs_own.* utils/ compat/
```

## FSCapabilities 模型(Phase 3)

| Capability | 启动探测 |
|---|---|
| NormalFilesystem | YES(恒定) |
| Archive | FSLoadInProcessUnzip() && unrar 可用 |
| Network | YES(SFTP/FTP/WebDAV/SMB 客户端静态内嵌) |
| MCMContainers | MCMBridgeAvailable() && 身份校验通过 && MCMFilzaStart 完成 |
| RootHelper | **NO(恒定)** |
| RootShell | NO(恒定) |
| PackageManager | NO(恒定) |
| SystemModification | NO(恒定) |

UI 与操作逻辑一律依据 capability,不依据 "Filza 原本有没有"。

## 阶段计划

### Phase 0 — Audit only ✅(本轮)
产出:ARCHITECTURE_AUDIT.md、FILZA_RUNTIME_API_MAP.md、FEATURE_MATRIX.md、ROOT_ONLY_UI_MAP.md、IMPLEMENTATION_PLAN.md。零代码改动。

### Phase 1 — Runtime API Map 复核
对 FILZA_RUNTIME_API_MAP.md §待定点逆向清单做定点逆向(pageDeleteAction 0x8000 位、defaultPath 消费方、askDeleteItems 原 no-op 核实、showAlert 实际文案)。
风险控制:只读 IDA/rabin2 反汇编,不改码。

### Phase 2 — Feature Matrix 真机验证
rename/mkdir/搜索/非 lease 复制删除在真机逐项验证(FEATURE_MATRIX ❓ 项),记录实际行为。
验收:矩阵 Current Status 全部落定。

### Phase 3 — Capability 抽象 ✅ 已实现(Core/FSCapabilities,CI 通过)
新增 Core/FSCapabilities(纯新增,零侵入);启动时探测并 NSLog 快照。
提交粒度:①加文件 ②接 constructor ③文档。

### Phase 4 — RootHelper 补熔断(最高优先级代码变更)✅ 已实现(待 CI 编译 + 真机回归)
`RootHelperBlocker.m`(独立 constructor,仿 StartupProgressController 模式):
- 熔断 5 个降级 selector:`_execRootShell:chdir:`、`_execRootShell:args:chdir:`、`_execRootShellWithOutput:args:chdir:maxOutLen:`、`forkRootShell:chdir:`、`dpkgInfo:`(binary 已确认全部为 TGRootFileManager 实例方法);
- stub 按运行时 method_getTypeEncoding 返回类型路由:@→nil、v→空、B/c→NO、数值→-1(spawn 语义失败,与既有 spawnRoot:args:pid: 一致);
- `+[TGAvailability IsShellAvailable]`/`IsDEBAvailable` → NO(反汇编确认均为 access() 探测返回 BOOL),终端/DEB UI 入口随之消失。
Makefile _FILES 增加 RootHelperBlocker.m。
回归验证清单:终端入口消失;DEB 菜单消失;Archive 三件套不受影响;MCM 浏览/复制/删除正常;启动无 [RootHelperBlocker] missing 日志。

### Phase 5 — Root-only UI pruning ✅ 菜单层已实现(FeaturePruning.m,CI 通过)
菜单过滤:identifier(terminal/uicache/makedeb/mountpoints/respring)+ 卸载标题关键词(en/zh),覆盖 TGPageViewController 基类与 TGApplicationsViewController 覆写的三个菜单数据源。
待后续:设置页 WebDAV 服务器开关、属性页 Ownership 编辑入口的精确定位(需真机/深度逆向)。
原计划::Apps Manager 卸载/uicache/清数据按钮置灰或移除;属性页 chown/SetUID/SetGID 只读化;服务器开关隐藏。
实现优先用 capability 判定(FSFeatureRegistry),避免散落 if。
回归:普通属性查看、Apps Manager 浏览不受影响。

### Phase 6 — 文件操作兼容(FSAccessManager)✅ 已实现(Access/FSAccessManager,CI 通过)
FSAccessCanManagePath = active lease ∨ 自身沙盒;5 处文件操作判定全部换用。网络路径仍回落原生(保 SFTP/FTP/WebDAV/SMB)。压缩/解压/编辑器保存不加重复门禁(OS EACCES 已清晰报错)。
原计划::目标路径 ∈ 自身沙盒 ∨ 虚拟根 ∨ active lease → userspace 放行;否则清晰报错(不再静默回落死通道)。
覆盖 read/write/create/delete/rename/copy/move/mkdir/extract/compress/editor save。
重点修复 FEATURE_MATRIX ⚠️ 项:非 lease 路径复制/删除的明确失败提示;跨容器 rename/mkdir 行为按 Phase 2 结论处理。
回归:容器内粘贴/删除/归档、沙盒内常规操作、错误路径提示文案。

### Phase 7 — Archive 加固
ZIP 解压符号解析失败的显式错误(已是如此,补 UI 提示确认);评估自带 minizip 解压侧替换主程序符号直调(消除换包脆点);RAR 分卷缺卷提示优化。
回归:加密 zip、中文文件名、大文件、RAR5 密码包。

### Phase 8 — SFTP/网络验证
真机验证 SFTP/FTP/WebDAV/SMB 客户端连接→浏览→下载到 MCM 容器→上传 全链路(预期零干预可用)。
WebDAV server 决策:默认隐藏;如需保留,评估 app 内 spawn helpers/FilzaWebDAVServer(userspace,Bonjour 无需 root)。
回归:收藏夹添加网络书签。

### Phase 9 — Apps Manager cleanup
保留:列表/Bundle ID/Data Container/App Groups 入口。
隐藏:卸载/uicache/清数据(若 Phase 5 未覆盖完)。
增强(可选):详情页直接展示 MCM 容器路径跳转。

### Phase 10 — Device Storage UX cleanup
目录命名中文化梳理(应用数据/App Groups/…)、Experimental 折叠、空目录清理策略复核(MCMPruneEmptyGeneratedDirectory 不误删用户目录)。

### Phase 11 — Legacy source cleanup
git mv 至 Legacy/:kexploit/ kpf/ XPF/ sandbox_escape.* apfs_own.* utils/ compat/;
同步删 Makefile:27 的 `-I$(PWD)/compat -I$(PWD)/XPF/src -I$(PWD)/XPF/external/ChOma/include`;
评估 IPA 内剔除 bins/ 与 helpers/FilzaHelper(终端已隐藏后无消费方;FilzaWebDAVServer 视 Phase 8 决策)。
验收:CI 构建通过 + 真机全功能回归。

## 提交规范

每次提交记录:changed files / why / behavior change / risk / test method。禁止跨模块大提交;禁止同轮多智能体改同一文件。

## 明确不做

- 不改 MobileHouseArrest identity、MCMBridge 符号表、flags 常量、gLeases key 方案、iOS 26 open() 兜底、symlink 保护(ARCHITECTURE_AUDIT 附录清单)。
- 不把 sandbox extension/MCM 当 root 功能删除。
- 不重写 Filza UI/SFTP 等黑盒功能,只做 backend 替换与可见性裁剪。
- 不因功能调用 helper 就删功能;能 userspace 化的先替换 backend。
