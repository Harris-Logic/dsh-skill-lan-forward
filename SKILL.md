# 局域网两台主机 → SSH 本地转发访问回环服务

把「B 机器上只监听 `127.0.0.1` 的服务」接到「A 机器的浏览器/客户端」，不打开任何
`0.0.0.0` 监听。适用于任意两端：PC↔PC、PC↔手机、PC↔平板、PC↔服务器；
服务可以是 dsh web、VS Code Server、任何 HTTP/TCP 服务。

## 何时用

- 目标服务按安全默认只绑回环（dsh web 明确拒绝 `--host 0.0.0.0`，很多服务同理）；
- 要在另一台机器上用浏览器/客户端访问，且**不想**把服务暴露到局域网；
- 两端在同一局域网，能 SSH（密码或公钥都行）；
- 连接会断（笔记本睡眠、DHCP 换 IP、服务重启），希望一条命令重建。

**不要**用它做对外暴露：SSH 跳板本身就是信任边界，隧道只应绑在客户端自己的回环上。

## 为什么这就是官方最佳实践

以 DSH 为例（读安装包源码得到，其他服务同理）：

| 证据 | 含义 |
|---|---|
| `dsh-web-app/README.md`：*Binding all network interfaces is not supported — `--host 0.0.0.0` is rejected at startup for safety* | 远程访问不是靠放开监听，而是靠转发 |
| `dsh-web-app/lib/startup.js`：`error: --host 0.0.0.0 ... would expose remote code execution to the network` | 这个 Web API 具备执行能力，不能直接暴露 |
| `dsh-web-app/README.md`：通过 SSH 启动时 *the SSH client or editor owns the local forwarding address* | 转发端由客户端负责——正是本技能做的事 |
| `dsh-client-connection`：`isLoopbackHostname()` 接受整个 `127/8` | 转发到 `127.0.0.x` 天然通过 Host/Origin 围栏，不需要 `--trusted-host` |

所以正确形态是：**服务端只绑 `127.0.0.1`；客户端绑一个回环别名，用 SSH 把两者接起来。**

## 一句话架构

```
客户端 A                                         服务端 B
浏览器 → http://127.0.0.2:<P>  ──ssh -N -L──►  sshd ──►  127.0.0.1:<P>（服务）
         （A 自己的回环）                              （B 的回环）
```

## 三个关键决定

### 1) 客户端绑 `127.0.0.x`，不是 `127.0.0.1`

- 客户端本机常常已经占着 `127.0.0.1:<P>`（自己也在跑同样的服务），隧道抢不到同一个 (IP, 端口)；
- Windows 把整个 `127/8` 当回环，具体地址可以与 `0.0.0.0` 泛监听并存，内核按**最具体地址**分发
  （实测：`127.0.0.2:3080` 走隧道，`127.0.0.1:3080` 仍是本机服务，互不串流量）；
- **cookie 按主机名分、不按端口分**：两个同款服务都挂 `127.0.0.1` 会互相覆盖 cookie，
  换别名就是两个独立 cookie 域，可同时保持登录。

### 2) 服务端永远不放开监听

- 服务端保持 `127.0.0.1`；不要 `--host 0.0.0.0`，不要为了"方便"加局域网防火墙放行；
- 需要临时直连时用端口转发，而不是改绑定；用完删规则。

### 3) 连上之后要**验真**，不要只看"端口有响应"

- 客户端可能已经有别的服务占着泛监听，`127.0.0.x:<P>` 有应答不代表是你想要的；
- 用内容特征判定（dsh 的 401 页 / VS Code 的 `workbench` 字样）或 token 校验，
  脚本的 `--check` 就是干这个的。

## 对端地址怎么找

按可靠性排序，脚本会自动尝试前两条：

| 方式 | 适用 | 说明 |
|---|---|---|
| `--peer <ip>` | 全部 | 最可靠，手工指定 |
| ssh 配置里的 `HostName` | 静态 IP / 有 DNS / mDNS | 脚本用 `ssh -G <alias>` 读取并验证端口通 |
| 默认网关 | 目标就是网关（手机热点） | 手机热点下手机既是 DHCP 也是网关 |
| 网段扫描 | 兜底 | 慢且有噪音，建议手工 `--peer` |

**不要按 MAC 找**：热点 AP 的 BSSID 常被随机化（本地管理位 = 1），每次开热点都变。

## 用法

```bash
# 起隧道（默认绑 127.0.0.2，端口与服务端一致）
./forward.sh start --ssh desk --service 3080 --check 'dsh web|authentication required'

# 服务在非标准端口、指定本机别名与端口
./forward.sh start --ssh desk --service 3100 --local 127.0.0.3:13100

# 看状态 / 关掉
./forward.sh status --name desk-3080
./forward.sh stop   --name desk-3080
```

Windows 双击 `forward.cmd`，参数透传。

| 参数 | 说明 |
|---|---|
| `--ssh <alias>` | ssh 目标：`~/.ssh/config` 里的别名，或 `user@host` |
| `--peer <ip>` | 覆盖地址探测 |
| `--service <port\|host:port>` | 服务端上的回环地址，默认 `127.0.0.1:<port>` |
| `--local <ip:port>` | 客户端监听，默认 `127.0.0.2:<service port>` |
| `--name <tag>` | pidfile 名字，默认 `<alias>-<port>` |
| `--check <regex>` | 用 HTTP 响应体做验真；不给则只做 TCP 探测 |
| `--port <n>` | 服务端 sshd 端口，默认 22 |
| `--open` | 起好后用默认浏览器打开 |

## 三个真实案例

### dsh web（token 换 cookie）

```bash
./forward.sh start --ssh workstation --service 3080 --check 'authentication required'
# 浏览器打开 http://127.0.0.2:3080/?token=<服务端启动时打印的 token>
```

token 是一次性引导凭证：换到 cookie 后（补丁版 365 天）就不用再带；token 在哪取：
服务端启动日志里的 `dsh web: http://127.0.0.1:3080/?token=…`。

### VS Code Server / openvscode-server

```bash
./forward.sh start --ssh tablet --service 8080 --check 'workbench|stable-'
# 浏览器打开 http://127.0.0.2:8080/
```

### 任意 HTTP 服务

```bash
./forward.sh start --ssh nas --service 9000 --check 'MiniDLNA|Content-Type'
```

## 坑（都踩过）

### 1) 客户端端口落在 Windows 保留段 → 任何 bind 都 `Permission denied`

```cmd
netsh int ipv4 show excludedportrange protocol=tcp
```
这不是"上次隧道没释放"。脚本检测到就自动换端口；永久解法（管理员）：

```cmd
netsh int ipv4 delete excludedportrange protocol=tcp startport=<P> numberofports=1
```

### 2) 上一轮的 socket 还没释放（`Address already in use`，1–2 秒窗口）

脚本退避重试 3 次；一直失败就 `--name` 换一个或 `stop` 后重建。

### 3) 容器里的服务（proot/chroot）要靠宿主侧拉起

例：`proot-distro login` 默认 `--kill-on-exit`，会话退出会杀掉里面 `nohup` 的后台进程。
做法是从宿主（Termux）侧 `nohup proot-distro login … --exec 服务` 拉起，让 proot 进程常驻。

### 4) 手机/平板会被系统冻结

`termux-wake-lock`（脚本无关，设备侧做）+ 关闭电池优化；症状是端口无响应但进程还在。

### 5) 别把隧道绑成 `0.0.0.0`

`-L 0.0.0.0:...` 等于把服务开到局域网，和"只绑回环"的初衷相反。

## 排障对照表

| 现象 | 真正原因 | 处置 |
|---|---|---|
| `bind [127.0.0.2]:P: Permission denied` | 落在 Windows 保留段 | 换端口或管理员删保留段 |
| `Address already in use` | 旧 socket 未释放 | 重试；不行 `stop` 后重建 |
| 本机 `000`、服务端正常 | 隧道没起 / 绑错地址 | `netstat -ano -p tcp | findstr :P` 看 `127.0.0.x:P` |
| 有响应但内容不对 | 端口被别的服务占着（泛监听或旧隧道） | 看 `--check` 输出，换别名/端口 |
| 打不开或空白 | 服务刚起、静态资源未就绪 | 等几秒；看服务端日志 |
| `Permission denied (publickey)` | 客户端公钥没在服务端 authorized_keys | 服务端追加公钥（Windows 管理员账号在 `administrators_authorized_keys`） |

## 验证清单

- [ ] 服务端 `netstat -ano | findstr :<P>` 只有 `127.0.0.1:<P>`
- [ ] 客户端 `netstat -ano | findstr :<P>` 出现 `127.0.0.x:<P>`
- [ ] `--check` 命中（或 `curl` 拿到预期状态码）
- [ ] 再跑一次 → `already up`（复用而不是重建）
- [ ] `stop` 后端口释放
- [ ] 客户端本机原有服务（`127.0.0.1:<P>`）不受影响

## 与 `phone-hotspot-tunnel` 的关系

那份 skill 是本模式的**手机热点专案**（dsh web、网关探测、Termux 细节）。
本 skill 是通用版：任意两端、任意回环服务，脚本换成了参数化的 `forward.sh`。
