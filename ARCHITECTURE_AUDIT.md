# ARCHITECTURE_AUDIT — FilzaSlop-zh 架构审计(Phase 0,只读)

> 审计基线:`refactor/mcm-userspace-fm` 分支,c54e459。
> 方法:全部结论基于源码阅读 + Makefile/include graph/symbol 引用核对 + 对 `/tmp/opencode/filza_bin/Payload/Filza.app/Filza`(arm64,stripped)的 strings/rabin2/nm 定点侦察与反汇编验证。未做任何代码修改。

---

## 1. 当前完整启动流程

```
dyld 加载 FilzaApplySandboxExt.dylib(注入 Bundles: com.tigisoftware.Filza / com.apple.mobile.MobileHouseArrest,FilzaApplySandboxExt.plist:1)
├─ TweakInit(Tweak.m:1644,__attribute__((constructor)),无 logos %ctor)
│   ├─ installHooks()(Tweak.m:1313)— 安装全部 37 个 runtime hook(见 FILZA_RUNTIME_API_MAP.md)
│   ├─ runMCMPath()(Tweak.m:1634)
│   │   ├─ MCMFilzaStart()(MCMFilzaIntegration.m:1634,dispatch_once + 后台队列)
│   │   │    ├─ 签名身份校验(MCMSignedCodeIdentifier == com.apple.mobile.MobileHouseArrest,:1652-1658)
│   │   │    ├─ 建虚拟根 Documents/Device Storage(:150-161、:1615-1631)
│   │   │    ├─ 组装 identifiers(动态枚举/LSApplicationWorkspace/csstore 扫描/研究清单/custom plist,:1703-1717)
│   │   │    ├─ 按分类激活 MCM lease 并安装 symlink(:1722-1875)
│   │   │    └─ 发出进度/完成通知(:38-43)
│   │   ├─ PBWallpaperFeatureStart()(PosterBoardFeature)
│   │   └─ 可选探针(FILZA_WRITE_PROBE / FILZA_PASTE_PROBE 环境变量)
│   └─ scheduleInitialBrowserRepair(8)(Tweak.m:1626-1632,每 400ms 重试 ≤8 次,把浏览器拉回虚拟根)
├─ FSStartupProgressInstall(StartupProgressController.m:226)
│   └─ 监听 didFinishLaunching / Progress / Complete 三通知,显示启动遮罩并在完成后重载浏览器
└─ TGFocusedResponderTimingFixInit(TGFocusedInputResponderTimingFix.m:210,异步装 TGFocusedInput 键盘时序修复)
```

要点:`installHooks()` 先于 `MCMFilzaStart()`,hook 体首次调用时才触达 MCM 状态;`hook_defaultPath`(Tweak.m:37-40)内部兜底调 `MCMFilzaStart()`。

## 2. IPA 构建和 dylib 注入流程

1. GitHub Actions(macos-14,.github/workflows/build.yml)装 Theos → `make package FINALPACKAGE=1` 产出 `FilzaApplySandboxExt.dylib` + deb。
2. `workflow_dispatch` 传入 base_ipa_url 时执行 `scripts/build_release_ipa.sh`:把 dylib 注入未签名 Filza IPA,并**强制校验 bundle id 为 com.apple.mobile.MobileHouseArrest**(build_release_ipa.sh:41-45,否则 exit 65)。
3. 整包重签后 CFBundleIdentifier 与 CodeDirectory identifier 必须同时为 MobileHouseArrest(README.md:63-94),否则系统以 `MismatchedBundleIDSigningIdentifier` 拒启。

## 3. FilzaApplySandboxExt.dylib 加载流程

- 注入过滤 plist 只匹配上述两个 bundle id(FilzaApplySandboxExt.plist:1)。
- dylib 内三个 constructor(见 §1)。无 Substrate/Substitute 依赖,纯 `method_setImplementation/class_replaceMethod/class_addMethod` 手工 swizzle。
- 主 binary 的 LC_LOAD_DYLIB 中含 `@executable_path/Frameworks/FilzaApplySandboxExt.dylib`(注入脚本改写)。

## 4–5. Runtime hook 清单及逐项说明

见 **FILZA_RUNTIME_API_MAP.md**(37 个 hook 点,14 个 class,全部经 binary 验证存在;每条含原实现是否被调用、是否必要)。

## 6. MCM/MHA 权限获取完整流程

1. 进程签名身份必须为 `com.apple.mobile.MobileHouseArrest`(常量 MCMFilzaIntegration.m:18;校验点 :288-291、:335-338、:1652-1658,基于 SecTaskCreateFromSelf + SecTaskCopySigningIdentifier :77-92)。
2. containermanagerd 信任该身份调用者,为其签发其他容器的沙盒扩展(:1377-1382 注释)。
3. 调用链:`dlopen("/usr/lib/system/libsystem_containermanager.dylib")` → 19 个 dlsym 函数指针(MCMBridge.m:46-77)→ query 流程(§7)→ token → activate。

## 7. ContainerManager query 流程

`container_query_create`(MCMBridge.m:168)→ `set_class`(容器类 2/4/6/7/10/12/13/15,:173)→ `set_identifiers`/`set_group_identifiers`(xpc string,:174-176)→ `set_flags`(非 scoped `0x900000000ULL`,scoped `0x8100000000ULL`,:180)→ 可选 `set_part(_domain)`(:181-194,iOS 18 无此 API 时要求 part==0)→ `get_single_result`(:195,失败取 posix errno+message)→ `get_path`(/var→/private/var 规范化 :206-214)→ `copy` + `copy_sandbox_token`(:233-236)→ `sandbox_extension_activate(token,false)`(:237)。
枚举走 `container_query_iterate_results_sync`(flags `0x100000000ULL` metadata-only,:79-116)。
门禁:`MCMBridgeAvailable()` 要求 15 个符号全部非空(MCMBridge.m:118-128);失败路径一律 free 后返回 nil+error。

## 8. sandbox extension 获取及激活流程

`MCMLease.activate:`(MCMBridge.m:130-254):query → object → path → copy object → copy_sandbox_token → activate。**iOS 26 特例**:containermanagerd 缺 genericExtensionsAllowedForAll,token 可能被拒但路径仍可 open —— 因此 open(`O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW`)成功即接受 lease 即使 activated==NO(MCMFilzaIntegration.m:308-322);open 失败一律 invalidate 返回 nil。**删除该兜底会导致 iOS 26 大量容器不可达(高风险)**。

## 9. MCMLease 生命周期

- 存储:`gLeases`(NSMutableDictionary,MCMFilzaIntegration.m:34,@synchronized 保护)。
- key:普通 `class:id`(:263-266);scoped `class:id:part:partDomain:flags`(:268-273)。
- 创建:MCMActivate(:284-327)/ MCMActivateScoped(:329-373),命中缓存直接返回;成功后存入 gLeases。
- 释放:**无超时机制**,lease 存活至进程退出;invalidate 仅在失败路径与 dealloc。
- 引用检测:`MCMFilzaPathHasActiveLease(path)`(:394-420)遍历 gLeases 判定前缀归属;虚拟根/归档路径恒 YES;Experimental/Files Traversal 显式排除。

## 10. Device Storage 虚拟根实现

入口:`TGPreferences.defaultPath` → `MCMFilzaVirtualRoot()`(= Documents/Device Storage,LiveContainer 下 $HOME/Documents/Device Storage)。浏览器路径强制修正:TGFileSystemListViewController setCurrentPath:/viewWillAppear:(Tweak.m:71-143)+ 定时 repair(Tweak.m:1626-1632)。旧 "MCM Containers" 目录自动迁移删除(MCMFilzaIntegration.m:1607-1610)。

## 11. symlink 映射机制

`MCMInstallLinkWithFailureLogging`(:516-548):以 identifier 为名建 symlink 指向真实容器根;幂等(同目标跳过,异目标 unlink 重建);**非链接条目一律保留不覆盖**(:533,防用户数据丢失)。scoped 版 :630-659;`gUnrestrictedFilesystem` 时另有直扫真实目录的直链模式(:560-585,当前无人开启)。命名合法性 `MCMSafeIdentifier`(:275-282)。

## 12. App Data / App Groups / System Groups 等访问流程

虚拟目录 → MCM class 映射(MCMFilzaIntegration.m:1722-1875):

| 虚拟目录 | class | group | 备注 |
|---|---|---|---|
| [MHA-C2] App Data | 2 | NO | 动态枚举+LS+csstore+研究清单+custom plist,fallback 直链 |
| [MHA-C7] App Groups | 7 | YES | group_identifiers 分支 |
| [MHA-C4] Extension Data | 4 | NO | PluginKitPlugin |
| [MHA-C6] VPN Data | 6 | NO | VPNPlugin |
| [MHA-C10] Service Data | 10 | NO | swcd/familycircled/locationd/installd/accountsd 等 |
| [MHA-C12] System Data | 12 | NO | eligibilityd/geod/springboard |
| [MHA-C13] System Groups | 13 | YES | systemgroup.* fallback |
| [MHA-C15] Protected Data | 15 | NO | appmanagedfeaturesd |
| [MHA-C13 Scoped] Additional Locations | 13+part/domain | — | InstallCoordination/Configuration Profiles/MobileGestalt Cache |
| [MHA-Mixed EXP] Experimental | 10/12/13/15 scoped 探测 | — | 结果写 Probe Results.plist |
| [MHA-C2] Wallpaper Lab | 2(PosterBoard) | — | PosterBoardFeature.m:460 激活 |
| Archive | — | — | symlink → Documents/FilzaSlop Archive |

identifier 发现四级:动态枚举(≤1024)→ LSApplicationWorkspace(≤1024)→ iOS 26 csstore 字节扫描(≤65536)→ 研究清单/custom plist。

## 13. 文件操作相关 hooks

仅对 **lease 内路径**接管,进程内 POSIX 实现;非 lease 路径回落 Filza 原实现:
- 粘贴复制:`TGPageViewController copyFilesAndDirectoryFromPasteboard`(Tweak.m:1236-1285,read/write/mkdir/symlink 直拷,防自递归)。
- 删除/废纸篓/擦除:deleteSelectedItems / askDeleteItems: / doTrashSelectedIndexPaths: / doEraseSelectedIndexPaths:(Tweak.m:1064-1210,jailed 版原生为 no-op,tweak 补齐为 归档 or 永久删除)。
- rename/mkdir 常规路径无 hook(走 Filza 自身 NSFileManager 通道,黑盒可用)。

## 14. ZIP 创建实现

`Zipper ZipFiles:toFilePath:currentDirectory:` 完全替换(Tweak.m:1458-1462 → :207-352):仓库内置 minizip writer(FSMinizipZip.c 以 #include 方式编入,符号改名 FSMinizip_* 防冲突),deflate 默认级别,**无加密**,ZIP64 自动,拒绝 symlink 与 `..`/绝对路径,临时文件+rename 原子提交。纯 userspace。

## 15. ZIP 解压实现

`unZipFile:` 两变体替换(ArchiveUnzipFix.m:1288-1327):解析主二进制 LC_SYMTAB 直调其内置 `_unzOpen64` 等 8 个本地符号(ASLR slide+ptrauth),流式解压;UTF-8 失败回退 Latin-1;支持密码;CRC 校验;路径穿越防护;staging+回滚提交管线。**脆点**:依赖主程序符号未被 strip;失败则解压直接报错,无 CLI fallback。

## 16. RAR 支持实现

unrar 7.21 全源码静态编入 dylib(-DRARDLL,Makefile:10-19、36):RAR1.5/2/3/4/5、AES 加密、密码;回调流式写盘;同 ZIP 提交管线。缺口:无 UCM_CHANGEVOLUME 回调(缺分卷直接报错)、拒绝链接条目(RedirType!=0)、固定 0644/0755 不保权限位。

## 17. Apps Manager 当前实现

三个 hook 修复沙盒下数据缺失(Tweak.m:1487-1502):
- `LSApplicationWorkspace.allApplications` 为空时扫 /var/containers/Bundle/Application + /Applications 构建(:462-497);
- `ApplicationItem.setAppProxy:` 用 Info.plist+文件系统补 name/icon/filePath/documentPath/version(:501-568);
- `TGApplicationsViewController didSelect` 用 bundlePath 兜底 documentPath(:573-590)。
数据容器经 `MCMFilzaDataContainerPath`(=MCMActivate class 2)获取,无 root。卸载/uicache/清数据未 hook(root helper 已死,按钮点了必静默失败)。

## 18. RootHelper 所有相关代码

编译集内全部在 Tweak.m:24-32、145-168(hook 实现)与 :1441-1457(安装),目标类 `TGRootFileManager`,共 12 个 selector。详见 ROOT_ONLY_UI_MAP.md §熔断现状——**12 个已熔断,但 binary 反汇编发现 5 个 selector 的进程内降级路径未被覆盖**(§21)。

## 19. 可能调用 RootHelper 的 Filza 功能(binary 证据)

- 终端(NewTerminalViewController/TerminalViewController forkACommand → forkRootShell:)
- DEB 制作/解包(Zipper createDEB/unDEBFile,TGPageViewController createDEBFromSelectedFolder)
- dpkg 信息/安装(dpkgInfo: → fork+execl dpkg;`dpkg -i "%@" ;`)
- root shell(RootShell exec: 系列)
- WebDAV 服务器(launchctl load LaunchDaemon)
- 文件操作 helper 通道(copyItemAtPathEx 等 TGRootFileManager(Extended) 扩展)

## 20. 已完全 userspace 化的功能

ZIP 创建(minizip)、ZIP 解压(主程序符号直调)、RAR 解压(unrar 静态)、lease 内文件复制/删除/归档(POSIX/NSFileManager)、MCM 全部容器访问、Apps Manager 浏览、壁纸实验室、收藏夹/书签(未干预即原生可用)、SFTP/FTP/WebDAV/SMB 客户端(libssh2/Chilkat/CFNetwork/libsmb2 全静态或用户态,零干预)、QuickLook/文本/plist/Hex/媒体查看(Filza 原生,无干预无 root 依赖证据)。

## 21. 当前仍依赖 Root/Jailbreak 的功能

| 功能 | 依赖 | 现状 |
|---|---|---|
| **5 个未熔断降级路径** | `_execRootShell:chdir:`、`_execRootShell:args:chdir:`、`_execRootShellWithOutput:args:chdir:maxOutLen:`(XPC 回复类型不匹配 → TGSystem → posix_spawn/system)、`forkRootShell:chdir:`(→ forkpty 交互 shell)、`dpkgInfo:`(→ fork+execl dpkg) | **反汇编证实仍会真正执行**(以沙盒用户身份,拿不到 root 但命令会跑)。终端可达性由 `+[TGAvailability IsShellAvailable]` 门控,只 access() 检查 shell 路径,不查 isRootHelperAvailable |
| 卸载 App/uicache/清除数据 | FilzaHelper 私有 entitlement | helper 已死 → 按钮可见但必静默失败(UI 未隐藏) |
| WebDAV 服务器 | launchd LaunchDaemon 部署 | 无法部署;FilzaWebDAVServer 本体是 userspace 程序 |
| Mount Points 浏览 | mount 权限 | root-only |
| DEB 安装(dpkg -i) | dpkg + root | 包内无 dpkg(bins/ 来自 iosbinpack64,无 dpkg/apt) |

## 22. 当前 build 真正使用的 exploit/legacy 文件

**没有**。Makefile `_FILES`(Makefile:21-24)= Tweak/MCMBridge/MCMFilzaIntegration/PosterBoardFeature/TGFocusedInputResponderTimingFix/StartupProgressController/ArchiveUnzipFix/FSMinizipZip.c/unrar。kexploit/kpf/XPF/sandbox_escape/apfs_own/utils/compat 均**不参与编译**;MCM 是 containermanagerd 合法 API 调用,非 exploit。

## 23. 看起来没用但暂不能删的文件

- 无"有隐藏引用不能动"的文件(逐 include/extern 核对为零引用)。
- 但按约束本轮不删,只标记:`MCMFilzaSetUnrestrictedFilesystem`(MCMFilzaIntegration.m:132,编译集内死函数,属导出 API 面,建议保留)。
- `-I$(PWD)/compat`、`-I$(PWD)/XPF/src`、`-I$(PWD)/XPF/external/ChOma/include`(Makefile:27)是残留搜索路径,移除 Legacy 目录时需同步删,否则无害警告。

## 24. 可安全迁移到 Legacy 的代码

`sandbox_escape.*`、`apfs_own.*`、`kexploit/`(12 文件)、`kpf/`(2 文件)、`XPF/`(src 8 文件 + external/ChOma 全套)、`utils/`(6 文件)、`compat/sys/fileport.h` —— 零 include/import/extern 跨引,git 历史确认初始提交后从未改动。唯一连带动作:删 Makefile:27 的三条 `-I`。

## 25. 高风险 hook(crash/regression 面)

| 风险 | 位置 | 说明 |
|---|---|---|
| dlsym 符号表/身份常量 | MCMBridge.m:46-77、MCMFilzaIntegration.m:18 | 任一失效 → Device Storage 全静默禁用 |
| flags 常量 0x900000000/0x8100000000 | MCMFilzaIntegration.m:16-17 | 改动 → token 签发被拒 |
| iOS 26 open() 兜底 | :308-322 | 删除 → iOS 26 容器大面积不可达 |
| gLeases key 方案 | :263-273 | scoped/普通混用 → 错误复用容器 |
| symlink 覆盖保护 | :533 | 去掉 → 用户真实条目被 unlink |
| ZIP 解压符号解析 | ArchiveUnzipFix.m:36-123 | 主程序换包 → 解压全灭且无 fallback |
| unzip hook 签名校验失败静默 | ArchiveUnzipFix.m:1308-1311 | 退回必死的原实现且无提示 |
| pageDeleteAction 返回 0x8000 | Tweak.m:1350-1359 | 私有标志位语义未逆向确认 |
| defaultPath 消费方 | Tweak.m:1316 | 除浏览器外是否影响设置/最近/收藏夹未确认 |
| showAlert 文案匹配 | Tweak.m:1467-1476 | 依赖英文原文案,本地化下可能失配 |

---

## 附:绝对不能动的 MCM 核心(汇总)

1. `kRequiredIdentifier` 及三处身份校验(MCMFilzaIntegration.m:18、288-291、335-338、1652-1658)。
2. MCMBridge 的 dlopen 路径、19 个符号名、15 符号门禁(MCMBridge.m:46-128)。
3. flags/part 常量与 identifiers/group_identifiers 分支(MCMBridge.m:174-194)。
4. gLeases key 方案与 @synchronized(MCMFilzaIntegration.m:34、263-273)。
5. iOS 26 open() 兜底(:308-322、356-367)。
6. MCMSafeIdentifier 校验(:275-282)。
7. symlink 幂等/覆盖保护(:516-548)。
8. /var→/private/var 规范化(:213-214、384-387、744-750)。
9. MCMFilzaStart 的 dispatch_once+后台队列编排(:1634-1899)。
10. 虚拟根目录树常量与填充逻辑(:19-31、1722-1875)。
