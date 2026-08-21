# ROOT_ONLY_UI_MAP — Root-only UI 与熔断清单

> 依据:源码 hook + Filza 主程序 strings/反汇编(rabin2)+ bins/ 内容核对。

## 一、RootHelper 熔断现状

### 已成功熔断(12,Tweak.m:1441-1457,目标类 TGRootFileManager)

| Selector | 熔断后行为 |
|---|---|
| +isRootHelperAvailable | 恒 NO |
| -spawnRootHelper / -spawnRootHelperIfNeeds / -respawnRootHelper | 返 0,不 spawn |
| -tryLoadFilzaHelper / -createHelperConnectionIfNeeds | no-op |
| -spawnRoot:args:pid: | *pid=0,返 -1 |
| -sendObjectWithReplySync:(×3 变体) | xpc_null / fd=-1 |
| -sendObjectNoReply: | 丢弃 |
| -sendObjectWithReplyAsync:queue:completion: | completion(nil) |

### 未熔断的进程内降级路径(5,binary 反汇编证实仍会执行)

XPC 回复被替换为 xpc_null 后,类型校验不匹配 → 走原实现的**进程内降级分支**(以沙盒用户身份执行,拿不到 root 但命令真实运行):

| Selector | 原实现地址 | 降级路径 | 触发者 |
|---|---|---|---|
| -_execRootShell:chdir: | 0x100106400 | chdir + TGSystem(→posix_spawn+waitpid 或 system()) | RootShell exec 系 |
| -_execRootShell:args:chdir: | 0x100106604 | _TGSystemWithArgs | 同上 |
| -_execRootShellWithOutput:args:chdir:maxOutLen: | 0x100106858 | _TGSystemWithArgs | 同上 |
| -forkRootShell:chdir: | 0x100106cb8 | isRootHelperAvailable=NO → XPC 类型不匹配 → **forkpty 交互 shell** | NewTerminalViewController/TerminalViewController forkACommand |
| -dpkgInfo: | 0x1001071d4 | _dpkgInfo = pipe+fork+dup2+execl(dpkg)(找 /var/jb、/jb/bin 等越狱路径) | DEB 信息/安装 |

UI 门控缺口:`+[TGAvailability IsShellAvailable]`(0x100196568)只 access() 检查 shell 路径存在,**不查 isRootHelperAvailable** → 终端菜单可能仍然可见可点。
`IsDEBAvailable` 同类门控 → DEB 功能入口同理。

## 二、root-only UI 清单(处理方式)

| 页面/菜单/按钮 | Class | Selector/证据 | 为什么需要 root | 处理方式 |
|---|---|---|---|---|
| 终端(Terminal) | NewTerminalViewController / TerminalViewController / SwiftTermManager | forkACommand → forkRootShell:;SwiftTerm.framework(dlopen) | root shell(forkpty 降级虽能跑但属沙盒用户伪终端,行为不可控且违背产品定位) | 隐藏入口(hook IsShellAvailable→NO)+ 补熔断 forkRootShell: |
| Root Shell 执行 | RootShell | +exec: / exec:args:chdir: / execWithOutput:args:max: | root 命令执行 | 熔断降级路径;无独立 UI 入口则随终端隐藏 |
| DEB 安装(dpkg -i) | TGPageViewController / Zipper | createDEBFromSelectedFolder、`dpkg -i "%@" ;` 字符串、IsDEBAvailable | dpkg + root | 隐藏菜单项 + 熔断 dpkgInfo: |
| DEB 制作/解包 | Zipper | -createDEB:toFilePath: / -unDEBFile:toPath:… | dpkg -b / dpkg 工具链 | 隐藏菜单项 |
| 挂载点浏览 | MountPointsBrowserView / MountPointItem | mountpoints:// URL、"Mount points"、-[MountPointItem statfs] | mount 表/root 视角 | 隐藏入口 |
| App 卸载 | ApplicationAttributesViewController / TGApplicationsViewController 菜单 | MobileInstallationUninstall、"Do you want to uninstall selected application(s)" | FilzaHelper 私有 entitlement(com.apple.private.uninstall.deletion) | 隐藏/置灰按钮(helper 已死,点击必静默失败) |
| uicache | 同上 | "uicache" 字符串 | helper 执行 | 隐藏/置灰 |
| 清除数据 | AsnItem clearDataEv(C++) | clearDataEv | 特权删除容器 | 隐藏/置灰 |
| WebDAV/SFTP/SMB 服务器开关 | 设置页 | launchctl load -w …LaunchDaemons…FilzaWebDAVServer(/var/bin、/jb/bin、/var/jb/bin 三套前缀) | LaunchDaemon 部署需 root | 隐藏;如要保留 WebDAV server,Phase 8 评估 app 内直接 spawn helpers/FilzaWebDAVServer(userspace 程序,Bonjour 监听无需 root) |
| 文件属性 chown/SetUID/SetGID 编辑 | 属性页(TGRootFileManager(Extended)) | extendedAttributesOfItemAtPath:error:、setAttributes root 路径 | root chown | 只读化/隐藏编辑入口(保留只读 owner/group/mode 显示) |
| ldid 重签名 | (无 UI,字符串) | `/usr/bin/ldid -S -M -K/usr/share/jailbreak/signcert.p12` | 越狱路径证书 | 无入口,随熔断自然失效 |

## 三、保留的高级功能(非 root)

- Apps Manager 浏览/属性查看(已由 3 个 hook userspace 化)
- MCM 全部容器目录(App Data/App Groups/Extension/VPN/Service/System/System Groups/Protected/Additional Locations/Experimental)
- 壁纸实验室
- Archive(ZIP/RAR)、收藏夹、SFTP/FTP/WebDAV/SMB 客户端
- 文本/plist/Hex/QuickLook/媒体查看

## 四、bins/ 目录事实

- `bins/bin`:7z、tar、zip、unzip、unrar、gzip、bzip2、xz、cp、mv、rm、mkdir、ln、ls、fish 等(iosbinpack64)。
- `bins/usr/bin`:find、sed、stat、xxd、id、du 等;`bins/usr/sbin`:chown。
- **无 dpkg、无 apt**(dpkg 仅存在于外部越狱路径探测字符串中)。
- `helpers/FilzaHelper`(root helper 本体,已被熔断封死)、`helpers/FilzaWebDAVServer`(userspace HTTP 服务器,当前仅 launchd 形态可用)。
- 处置建议:Phase 11 评估从 IPA 中剔除 bins/(终端隐藏后无消费方),减小包体与攻击面;helpers/FilzaHelper 同理。**本轮不动。**
