# FILZA_RUNTIME_API_MAP — Filza Runtime Hook 全量清单

> 扫描范围:仓库全部源码(排除 Vendor/unrar、XPF/external)。命中:NSClassFromString×19、NSSelectorFromString×85、objc_msgSend 直调×46、class_getInstanceMethod/class_getClassMethod/method_setImplementation/class_replaceMethod/class_addMethod/object_getClass×50。无 logos(%hook/%ctor)、无 MSHook*。
> Binary 验证:全部被 hook 的 14 个 class 与全部 selector 均确认存在于 Filza 主程序(strings + `_objc_msgSend$...` stub 双重确认)。

## 启动 constructor(3 个,均 __attribute__((constructor)))

| Constructor | 位置 | 职责 |
|---|---|---|
| TweakInit | Tweak.m:1644 | installHooks() → runMCMPath()(MCMFilzaStart+壁纸+探针)→ scheduleInitialBrowserRepair |
| FSStartupProgressInstall | StartupProgressController.m:226 | 启动遮罩三通知观察者 |
| TGFocusedResponderTimingFixInit | TGFocusedInputResponderTimingFix.m:210 | 异步装键盘时序 hook |

## Hook 总表(37 点)

方式缩写:REPL=class_replaceMethod、IMP=method_setImplementation、ADD=class_addMethod(子类 override 继承方法)。原实现列:—=完全不调用;✅=无条件调 orig;条件=按 lease/路径判断。

### A. RootHelper 熔断(12)

| # | Class | Selector | Hook 实现(位置) | 安装 | 方式 | 原实现 | binary | 状态 |
|---|---|---|---|---|---|---|---|---|
| 1 | TGRootFileManager(meta) | +isRootHelperAvailable | Tweak.m:24-26 | :1444 | REPL | 否 | ✅ | 已熔断(恒 NO) |
| 2 | TGRootFileManager | -spawnRootHelper | Tweak.m:28 | :1445 | IMP | 否 | ✅ | 已熔断(返 0) |
| 3 | TGRootFileManager | -spawnRootHelperIfNeeds | Tweak.m:29 | :1446 | IMP | 否 | ✅ | 已熔断 |
| 4 | TGRootFileManager | -respawnRootHelper | Tweak.m:30 | :1447 | IMP | 否 | ✅ | 已熔断 |
| 5 | TGRootFileManager | -tryLoadFilzaHelper | Tweak.m:31 | :1448 | IMP | 否 | ✅ | 已熔断(no-op) |
| 6 | TGRootFileManager | -createHelperConnectionIfNeeds | Tweak.m:32 | :1449 | IMP | 否 | ✅ | 已熔断(不建 XPC) |
| 7 | TGRootFileManager | -spawnRoot:args:pid: | Tweak.m:145-148 | :1450 | IMP | 否 | ✅ | 已熔断(*pid=0,-1) |
| 8 | TGRootFileManager | -sendObjectWithReplySync: | Tweak.m:150-152 | :1451 | IMP | 否 | ✅ | 已熔断(xpc_null) |
| 9 | TGRootFileManager | -sendObjectWithReplySync:fileDescriptor: | Tweak.m:154-157 | :1452 | IMP | 否 | ✅ | 已熔断(fd=-1) |
| 10 | TGRootFileManager | -sendObjectWithReplySync:fileDescriptor:logintty: | Tweak.m:159-162 | :1453 | IMP | 否 | ✅ | 已熔断 |
| 11 | TGRootFileManager | -sendObjectNoReply: | Tweak.m:164 | :1454 | IMP | 否 | ✅ | 已熔断(丢弃) |
| 12 | TGRootFileManager | -sendObjectWithReplyAsync:queue:completion: | Tweak.m:166-168 | :1455 | IMP | 否 | ✅ | 已熔断(completion(nil)) |

⚠️ **未覆盖的降级路径**(binary 反汇编证实,XPC 回复类型不匹配后仍会执行):`_execRootShell:chdir:`(0x100106400→TGSystem→posix_spawn/system)、`_execRootShell:args:chdir:`(0x100106604)、`_execRootShellWithOutput:args:chdir:maxOutLen:`(0x100106858)、`forkRootShell:chdir:`(0x100106cb8→forkpty)、`dpkgInfo:`(0x1001071d4→fork+execl dpkg)。以沙盒用户身份运行,拿不到 root 但命令真实执行。**Phase 4 必补 hook。**

### B. MCM 虚拟根 / 浏览器导航(3)

| # | Class | Selector | Hook 实现 | 安装 | 方式 | 原实现 | 分类 |
|---|---|---|---|---|---|---|---|
| 13 | TGPreferences | -defaultPath | Tweak.m:37-40 | :1316-1317 | IMP | 否 | 启动/MCM(返回虚拟根,兜底调 MCMFilzaStart) |
| 14 | TGFileSystemListViewController | -setCurrentPath: | Tweak.m:71-85 | :1322-1326 | IMP | ✅(:75) | MCM/UI(旧路径重定向+壁纸按钮注入) |
| 15 | TGFileSystemListViewController | -viewWillAppear: | Tweak.m:89-143 | :1328-1332 | IMP | ✅(:106) | MCM/UI/启动(强制落回虚拟根、标题修正、doLoadingPage 重载) |

### C. 文件操作(lease 内接管)(8)

| # | Class | Selector | Hook 实现 | 安装 | 方式 | 原实现 | 说明 |
|---|---|---|---|---|---|---|---|
| 16 | TGFileSystemListViewController | -updateEditableUI(继承 TGPageViewController) | Tweak.m:64 行体 | :1334-1347 | ADD→IMP | ✅ | Edit 态刷新+壁纸按钮 |
| 17 | TGFileSystemListViewController | -pageDeleteAction | Tweak.m:1350-1359 | :1350 | ADD→IMP | 条件(:1069) | lease 内返 0x8000(语义需逆向) |
| 18 | TGFileSystemListViewController | -deleteSelectedItems | Tweak.m:1361-1368 | :1361 | IMP | 条件(:1079) | 非 MCM 走 orig |
| 19 | TGFileSystemListViewController | -askDeleteItems: | Tweak.m:1370-1379 | :1370 | IMP | 条件(父类 :1091) | MCM 弹归档/永久删除 ActionSheet |
| 20 | TGFileSystemListViewController | -doTrashSelectedIndexPaths:completion: | Tweak.m:1381-1389 | :1381 | IMP | 条件(:1169) | jailed 废纸篓 no-op → 拦截 |
| 21 | TGFileSystemListViewController | -doEraseSelectedIndexPaths:completion: | Tweak.m:1391-1399 | :1391 | IMP | 条件(:1199) | 进程内 removeItemAtPath |
| 22 | TGPageViewController | -askDeleteItems: | 同 #19 函数 | :1404-1412 | IMP | 条件 | 复用同一实现 |
| 23 | TGPageViewController | -doTrashSelectedIndexPaths:completion: | 同 #20 | :1414-1421 | IMP | 条件 | 同上 |
| 24 | TGPageViewController | -doEraseSelectedIndexPaths:completion: | 同 #21 | :1423-1430 | IMP | 条件 | 同上 |
| 25 | TGPageViewController | -copyFilesAndDirectoryFromPasteboard | Tweak.m:1236-1285 | :1432-1438 | IMP | 条件(:1237) | lease 内 POSIX 直拷 |

(rename/mkdir 无 hook,Filza 自身 NSFileManager 通道在沙盒内可用。)

### D. Archive(5,全部完全替换不调原实现)

| # | Class | Selector | Hook 实现 | 安装 | binary | 说明 |
|---|---|---|---|---|---|---|
| 26 | Zipper | -ZipFiles:toFilePath:currentDirectory: | Tweak.m:207-352 | :1458-1462 | ✅ | minizip 打包,无加密,ZIP64 |
| 27 | Zipper | -unZipFile:toPath:currentDirectory:outMessage: | ArchiveUnzipFix.m:1296-1311 | :1296 | ✅ | 主程序 unz* 符号直调;装前签名校验 |
| 28 | Zipper | -unZipFile:toPath:currentDirectory:withPassword:outMessage: | ArchiveUnzipFix.m:1313-1327 | :1313 | ✅ | +密码 |
| 29 | Zipper | -unRarFile:toPath:currentDirectory:outMessage: | ArchiveUnzipFix.m:1329-1339 | :1329 | ✅ | unrar 7.21 静态 |
| 30 | Zipper | -unRarFile:toPath:currentDirectory:withPassword:outMessage: | ArchiveUnzipFix.m:1341-1355 | :1341 | ✅ | +密码 |

### E. License 绕过(2)

| # | Class | Selector | Hook 实现 | 安装 | 原实现 | 说明 |
|---|---|---|---|---|---|---|
| 31 | TGAlertController(meta) | +showAlertWithTitle:text:cancelButton:otherButtons:completion: | Tweak.m:598-622 | :1467-1476 | ✅透传 | 吞 "binary was modified"/"reinstall Filza" 完整性弹窗 |
| 32 | NewActivationViewController | -viewDidLoad | Tweak.m:616 行体 | :1477-1484 | ✅ | 抑制激活页 |

### F. Apps Manager(3)

| # | Class | Selector | Hook 实现 | 安装 | 原实现 | 说明 |
|---|---|---|---|---|---|---|
| 33 | LSApplicationWorkspace | -allApplications | Tweak.m:462-497 | :1487-1491 | ✅ | 空结果时文件系统扫描兜底 |
| 34 | ApplicationItem | -setAppProxy: | Tweak.m:501-568 | :1492-1497 | ✅ | Info.plist 补齐属性 |
| 35 | TGApplicationsViewController | -browserView:didSelectItemAtIndexPath: | Tweak.m:573-590 | :1498-1502 | ✅ | documentPath 兜底 |

### G. 输入法时序修复(1)

| # | Class | Selector | Hook 实现 | 安装 | 原实现 | 说明 |
|---|---|---|---|---|---|---|
| 36 | TGFocusedInput | -textFieldDidBeginEditing: | TGFocusedInputResponderTimingFix.m:195-208 | :210 init | ✅ | iOS 27 键盘 accessory 时序 |

## 待定点逆向确认清单(仅凭 selector 名无法定语义)

| 项 | 原因 |
|---|---|
| pageDeleteAction 返回 0x8000 位含义 | Filza 私有标志位 |
| defaultPath 全部消费方 | 是否影响设置/最近/收藏夹 |
| 原 askDeleteItems:/doTrash* 是否真 no-op | 注释称是,未核实 |
| 主程序 unz* 符号行为与原版差异 | AES zip 支持取决于主程序构建 |
| showAlert 匹配文案的实际/本地化文本 | 失配则弹窗泄漏 |
| updateEditableUI 后按钮重建时机假设 | 100/500ms 延迟重刷依赖内部时机 |
| doLoadingPage 三处触发与 Filza 加载状态机冲突面 | viewWillAppear/repair/归档粘贴后 |

## Binary 中存在但当前零干预的功能面(供 Phase 8/9 参考)

SFTP(DLSFTP*/GDSFTP*,libssh2 静态)、FTP(GDFTP*/CkoFtp2)、WebDAV 客户端(GDWebDAV*,CFNetwork)、SMB 客户端(GDSMB*,libsmb2-ios.dylib)、收藏夹(FavoritesTableViewController/AddLinkViewController)、终端(NewTerminalViewController/SwiftTermManager)、DEB(Zipper createDEB/unDEBFile)、挂载点(MountPointsBrowserView)、root shell(RootShell)、dpkg(dpkgInfo:)。
