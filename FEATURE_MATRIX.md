# FEATURE_MATRIX — 功能能力矩阵

> Normal Userspace = 沙盒内普通用户态即可;MCM = 依赖 MobileHouseArrest 容器访问;Root = 依赖 root/helper/越狱。
> Current Status 基于源码 + binary 验证(Phase 0);Target 为重构目标。

| Feature | Normal Userspace | MCM | Root | Current Status | Target |
|---|---|---|---|---|---|
| 文件浏览(Device Storage 虚拟根) | YES | YES | NO | ✅ 可用(hook defaultPath/viewWillAppear 强制虚拟根) | KEEP |
| 文件浏览(自身沙盒/普通目录) | YES | - | NO | ✅ Filza 原生可用 | KEEP |
| Copy / Paste | YES | YES | NO | ⚠️ lease 内已接管(POSIX 直拷);**非 lease 路径回落原实现,而 helper 已死 → 可能无响应** | KEEP/FIX |
| Move | YES | YES | NO | ⚠️ 归档路径 moveItemAtPath 已接管;常规移动走原生(rename 同卷可用,跨容器未验证) | KEEP/FIX |
| Delete(永久) | YES | YES | NO | ✅ lease 内 NSFileManager 接管;非 lease 回落原生(jailed no-op) | KEEP/FIX |
| Rename | YES | MAYBE | NO | ❓ 无 hook,原生通道黑盒;同卷 rename 应可用,**需真机验证跨容器** | KEEP/VERIFY |
| mkdir / 新建文件 | YES | MAYBE | NO | ❓ 无 hook,原生通道;lease 内应可用,需验证 | KEEP/VERIFY |
| Trash 回收站 | - | - | YES(原生) | ❌ 原生废纸篓 jailed no-op;已替换为 归档 or 永久删除 ActionSheet | KEEP(现方案) |
| 搜索 | YES | MAYBE | NO | ❓ 未干预、未验证;lease 内大范围搜索可能触发 helper | KEEP/VERIFY |
| 收藏/书签(Favorites) | YES | - | NO | ✅ 零干预,binary 存在,userspace | KEEP |
| 文件属性(只读信息) | YES | MAYBE | NO | ✅ 原生;extendedAttributesOfItemAtPath 属 TGRootFileManager(Extended),helper 死后部分属性可能缺失 | KEEP/FIX |
| chown/SetUID/SetGID 修改 | - | - | YES | ❌ root-only | HIDE/DISABLE |
| 文本查看/编辑 | YES | YES | NO | ✅ 原生,进程内 | KEEP |
| Plist 查看/编辑 | YES | YES | NO | ✅ 原生,进程内 | KEEP |
| Hex Viewer | YES | YES | NO | ✅ 原生,进程内 | KEEP |
| 图片/视频/音频查看 | YES | YES | NO | ✅ 原生 | KEEP |
| QuickLook | YES | YES | NO | ✅ 原生 | KEEP |
| ZIP 创建 | YES | YES | NO | ✅ minizip 进程内(无加密) | KEEP |
| ZIP 解压 | YES | YES | NO | ✅ 主程序 unz* 符号直调(**脆点:换包即失效,无 fallback**) | KEEP/FORTIFY |
| RAR 解压 | YES | YES | NO | ✅ unrar 7.21 静态(RAR5/AES/密码 OK;分卷缺回调直接报错) | KEEP |
| DEB 制作/解包 | - | - | YES(dpkg) | ❌ createDEB/unDEBFile/dpkgInfo: root-only(dpkgInfo: 降级仍会 fork+execl) | REMOVE/HIDE + 熔断 |
| SFTP 客户端 | YES | - | NO | ✅ libssh2 静态进主程序,零干预,纯 userspace | KEEP |
| FTP 客户端 | YES | - | NO | ✅ Chilkat CkoFtp2 静态,零干预 | KEEP IF WORKING |
| WebDAV 客户端 | YES | - | NO | ✅ CFNetwork,零干预 | KEEP IF WORKING |
| SMB 客户端 | YES | - | NO | ✅ libsmb2-ios.dylib 用户态,零干预 | KEEP IF WORKING |
| WebDAV/SFTP/SMB 服务器 | - | - | YES(LaunchDaemon) | ❌ launchctl load 部署需 root;FilzaWebDAVServer 本体是 userspace 程序 | HIDE 或改 app 内 spawn |
| 终端(Terminal) | - | - | YES(root shell) | ❌ forkRootShell: 降级 forkpty **仍会执行**(沙盒用户身份);UI 门控 IsShellAvailable 只查路径不查 helper | REMOVE/HIDE + 熔断 |
| Apps 列表/浏览(Apps Manager) | - | YES | NO | ✅ 三 hook 修复(allApplications/setAppProxy/didSelect),数据容器走 MCM | KEEP |
| App 卸载 / uicache / 清除数据 | - | - | YES(helper entitlement) | ❌ helper 已死 → **按钮可见但必静默失败(UI 未隐藏)** | HIDE/DISABLE |
| 应用数据(Data Container 入口) | - | YES | NO | ✅ MCMFilzaDataContainerPath(class 2) | KEEP |
| App Groups | - | YES | NO | ✅ class 7 group 分支 | KEEP |
| Extension Data | - | YES | NO | ✅ class 4 | KEEP |
| VPN Data | - | YES | NO | ✅ class 6 | KEEP |
| Service Data | - | YES | NO | ✅ class 10 | KEEP |
| System Data | - | YES | NO | ✅ class 12 | KEEP |
| System Groups | - | YES | NO | ✅ class 13 | KEEP |
| Protected Data | - | YES | NO | ✅ class 15 | KEEP |
| Additional Locations(scoped) | - | YES | NO | ✅ MCMActivateScoped(part/domain) | KEEP |
| Experimental 探测目录 | - | YES | NO | ✅ scoped 探测+Probe Results 记录 | KEEP(可折叠) |
| 壁纸实验室(Wallpaper Lab) | - | YES(PosterBoard C2) | NO | ✅ PosterBoardFeature | KEEP |
| RootHelper 通道 | - | - | YES | ⚠️ 12 selector 已熔断;**5 个降级路径未熔断(execRootShell×3/forkRootShell/dpkgInfo:)** | 补熔断 |
| Root Shell UI | - | - | YES | ❌ IsShellAvailable 只 access() 查路径 → 终端入口可能可见 | HIDE |
| dpkg/apt | - | - | YES | 包内无 dpkg/apt(bins=iosbinpack64);dpkgInfo: 降级会找外部越狱路径的 dpkg | REMOVE/HIDE + 熔断 |
| mount / LaunchDaemon 管理 | - | - | YES | MountPointsBrowserView 等 root-only | HIDE |
| root chown | - | - | YES | bins/usr/sbin/chown 存在但 spawn 通道将全熔断 | DISABLE |

## 结论摘要

- **完全保留不动**:MCM 全链路、虚拟根、Archive 三件套、文本/plist/Hex/媒体/QuickLook、收藏夹、SFTP/FTP/WebDAV/SMB 客户端。
- **需要补齐(userspace backend 替换)**:非 lease 路径的复制/删除回落死通道问题;rename/mkdir/搜索 的 lease 内行为验证;WebDAV 服务器如保留需脱离 launchd。
- **必须补熔断**:execRootShell×3、forkRootShell:、dpkgInfo: 五个降级路径。
- **必须隐藏 UI**:终端、DEB 工具、挂载点、Apps Manager 卸载/uicache/清数据、root 属性修改(chown/SetUID)、服务器开关。
