# FreeLLMAPI 部署指南

本文档介绍如何使用 `deploy.sh` 脚本在 VPS 上一键部署、升级、管理 FreeLLMAPI。

> 适用于：2 核 1G 及以上的 Linux 服务器（Ubuntu / Debian / CentOS / Rocky / Alpine）

---

## 快速开始

一行命令完成安装：

```bash
curl -fsSL https://raw.githubusercontent.com/zczy-k/freellmapi/main/deploy.sh | sudo bash -s install -y
```

安装完成后，按照终端提示开放防火墙端口，然后访问 `http://<你的IP>:3001` 进入管理面板。

---

## 前置条件

- 一台 Linux VPS（推荐 Ubuntu 22.04 / Debian 12）
- Root 权限
- 可访问 GitHub 和 npm（国内服务器需确保代理或网络通畅）

脚本会自动处理以下依赖，无需手动安装：

| 依赖 | 说明 |
|---|---|
| Node.js 20 | 通过 nvm 安装到项目目录，不影响系统 Node.js |
| git, curl, python3, make, g++ | 仅在缺失时安装 |
| Swap | 内存 ≤ 2GB 时自动提示添加 |

---

## 命令一览

```bash
./deploy.sh <command> [options]
```

| 命令 | 说明 |
|---|---|
| `install` | 安装 FreeLLMAPI |
| `upgrade` | 升级到最新版本 |
| `uninstall` | 卸载 FreeLLMAPI |
| `status` | 查看服务状态 |
| `logs [-f]` | 查看日志（`-f` 实时跟踪） |
| `start` | 启动服务 |
| `stop` | 停止服务 |
| `restart` | 重启服务 |
| `check-update` | 检查是否有新版本 |

| 选项 | 说明 |
|---|---|
| `-y, --yes` | 跳过所有确认提示 |
| `--auto` | 非交互模式（cron 使用） |
| `-p, --port PORT` | 指定端口（默认 3001） |
| `-h, --help` | 显示帮助 |

---

## 安装

### 交互式安装

```bash
wget https://raw.githubusercontent.com/zczy-k/freellmapi/main/deploy.sh
chmod +x deploy.sh
sudo ./deploy.sh install
```

脚本会依次询问端口号、是否添加 Swap、是否开启自动升级。

### 一键安装（跳过确认）

```bash
sudo ./deploy.sh install -y
```

### 指定端口安装

```bash
sudo ./deploy.sh install -y -p 8080
```

### 安装过程

脚本自动执行以下步骤：

1. 检测操作系统
2. 检测端口是否被占用
3. 安装缺失的系统依赖（git, curl, python3, make, g++）
4. 通过 nvm 安装 Node.js 20（隔离安装，不影响系统）
5. 内存不足时提示添加 1GB Swap
6. 创建专用系统用户 `freellmapi`
7. 克隆仓库到 `/opt/freellmapi`
8. 安装 npm 依赖并构建项目
9. 生成 `ENCRYPTION_KEY` 并创建 `.env` 配置
10. 创建 systemd 服务（含沙箱隔离）
11. 配置自动升级 cron（每 6 小时检测）
12. 启动服务并健康检查

### 安装完成后

终端会显示访问地址和防火墙提示：

```
[INFO] ===========================================
[INFO]  FreeLLMAPI installed successfully!
[INFO] ===========================================
[INFO]
[INFO]   Dashboard:  http://<your-ip>:3001
[INFO]   API:        http://<your-ip>:3001/v1/chat/completions
[INFO]   Config:     /opt/freellmapi/.env
[INFO]   Data:       /opt/freellmapi/data
[INFO]   Node.js:    /opt/freellmapi/.nvm/versions/node/v20.x.x/bin/node
[INFO]   Logs:       journalctl -u freellmapi -f
[INFO]
[WARN]   IMPORTANT: Make sure port 3001 is open in your firewall!
[WARN]
[WARN]   Firewall commands (choose one):
[WARN]     ufw allow 3001/tcp
```

**必须手动开放防火墙端口**，否则外部无法访问。

---

## 防火墙配置

根据你的系统选择对应命令：

### Ubuntu / Debian（ufw）

```bash
# 开放端口
sudo ufw allow 3001/tcp

# 查看状态
sudo ufw status
```

### CentOS / Rocky / RHEL（firewalld）

```bash
# 开放端口
sudo firewall-cmd --permanent --add-port=3001/tcp
sudo firewall-cmd --reload

# 查看已开放端口
sudo firewall-cmd --list-ports
```

### 通用（iptables）

```bash
# 开放端口
sudo iptables -A INPUT -p tcp --dport 3001 -j ACCEPT

# 保存规则（Debian/Ubuntu）
sudo netfilter-persistent save

# 保存规则（CentOS/RHEL）
sudo service iptables save
```

### 云服务商安全组

如果 VPS 在阿里云、腾讯云、AWS 等云平台上，还需要在**控制台的安全组**中放行对应端口的 TCP 入站规则。

---

## 升级

### 手动升级

```bash
sudo ./deploy.sh upgrade
```

脚本会自动：
1. 从 GitHub 拉取最新代码
2. 对比当前版本与最新版本
3. 如有更新，询问是否升级
4. 备份当前版本
5. 拉取代码 → 安装依赖 → 构建 → 重启
6. 健康检查，失败则自动回滚

### 自动升级

安装时默认开启，每 6 小时自动检测一次。也可手动开启/关闭：

自动升级的 cron 配置在 `/etc/cron.d/freellmapi-auto-upgrade`，可手动编辑调整检测频率。

### 升级安全机制

- **`.env` 和 `data/` 目录始终保留**，不会丢失加密密钥和数据库
- 升级前自动备份到 `/opt/freellmapi-backup`
- 健康检查失败后自动回滚到旧版本
- 回滚也失败时保留备份目录，供手动恢复

---

## 卸载

```bash
sudo ./deploy.sh uninstall
```

卸载时提供两种选择：

| 选项 | 说明 | 删除范围 |
|---|---|---|
| **1) 保留数据** | 仅删除应用，保留数据库和配置 | 应用、服务、cron、日志 |
| **2) 完全清除** | 删除所有内容，包括数据 | 应用、数据、Swap、用户、nvm |

完全清除后会提示关闭防火墙端口。

### 一键完全卸载

```bash
sudo ./deploy.sh uninstall -y
```

---

## 日常管理

### 查看服务状态

```bash
sudo ./deploy.sh status
```

输出示例：

```
[INFO] FreeLLMAPI Status
  ─────────────────────────────────────
  Install dir:   /opt/freellmapi
  Version:       a1b2c3d4e5f6
  Config:        /opt/freellmapi/.env
  Data dir:      /opt/freellmapi/data
  Port:          3001
  Node.js:       v20.x.x (/opt/freellmapi/.nvm/.../node)
  Service:       active
  Auto-upgrade:  enabled
  Swap:          1024MB
  Memory usage:  45MB

[INFO] Health check: OK
```

### 查看日志

```bash
# 最近 100 行
sudo ./deploy.sh logs

# 实时跟踪
sudo ./deploy.sh logs -f

# 或直接使用 journalctl
journalctl -u freellmapi -f
```

### 修改端口

1. 编辑配置文件：

```bash
sudo nano /opt/freellmapi/.env
```

2. 修改 `PORT=3001` 为新端口

3. 重启服务并更新防火墙：

```bash
sudo ./deploy.sh restart
sudo ufw allow 新端口/tcp
sudo ufw deny 3001/tcp
```

### 修改加密密钥

> ⚠️ 修改 `ENCRYPTION_KEY` 后，已加密的 Provider API Key 将无法解密，需要重新添加。

1. 生成新密钥：

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

2. 编辑 `/opt/freellmapi/.env`，替换 `ENCRYPTION_KEY` 的值

3. 重启服务：

```bash
sudo ./deploy.sh restart
```

---

## 隔离性说明

脚本设计了多层隔离，确保不影响 VPS 上的其他项目：

| 隔离项 | 实现方式 |
|---|---|
| **Node.js** | 通过 nvm 安装到 `/opt/freellmapi/.nvm`，不碰系统 Node.js |
| **系统用户** | 专用用户 `freellmapi`，无 shell 登录权限 |
| **文件系统** | systemd `ProtectSystem=strict`，只允许写入 `data/` 和 `.env` |
| **临时文件** | systemd `PrivateTmp=true`，独立 /tmp 命名空间 |
| **内存** | systemd `MemoryMax=512M`，防止内存泄漏影响其他服务 |
| **CPU** | systemd `CPUQuota=50%`，最多占用 1 核的一半 |
| **网络端口** | 安装前自动检测端口冲突 |
| **Swap** | 项目专属 Swap 文件，卸载时只删自己创建的 |
| **权限** | systemd `NoNewPrivileges=true` + `CapabilityBoundingSet=` |
| **系统调用** | systemd `SystemCallFilter=@system-service`，禁止危险调用 |

---

## 文件路径

| 路径 | 说明 |
|---|---|
| `/opt/freellmapi/` | 应用根目录 |
| `/opt/freellmapi/.env` | 环境变量配置（含 ENCRYPTION_KEY 和 PORT） |
| `/opt/freellmapi/data/` | SQLite 数据库目录 |
| `/opt/freellmapi/.nvm/` | nvm 安装的 Node.js |
| `/opt/freellmapi/.deploy-version` | 当前部署版本号 |
| `/opt/freellmapi.swap` | Swap 文件（如创建） |
| `/opt/freellmapi/.swap-created-by-deploy` | Swap 标记文件 |
| `/opt/freellmapi-backup/` | 升级备份目录（升级成功后自动删除） |
| `/etc/systemd/system/freellmapi.service` | systemd 服务文件 |
| `/etc/cron.d/freellmapi-auto-upgrade` | 自动升级 cron |
| `/var/log/freellmapi-deploy.log` | 部署操作日志 |

---

## 常见问题

### 安装时端口被占用

```
[ERROR] Port 3001 is already in use!
[ERROR]   LISTEN  0  128  0.0.0.0:3001  0.0.0.0:*  users:(("nginx",pid=1234,fd=6))
```

解决方案：
- 停止占用端口的服务
- 或使用 `-p` 指定其他端口：`sudo ./deploy.sh install -y -p 8080`

### 健康检查失败

```
[ERROR] Health check failed after 10 retries
```

排查步骤：
1. 查看日志：`journalctl -u freellmapi -n 50`
2. 检查 `.env` 中 `ENCRYPTION_KEY` 是否正确
3. 检查端口是否被防火墙拦截：`curl http://127.0.0.1:3001/api/ping`
4. 检查 Node.js 是否正常：`/opt/freellmapi/.nvm/versions/node/v20.x.x/bin/node -v`

### 内存不足（OOM）

2 核 1G 服务器建议：
1. 确保 Swap 已添加（脚本会自动提示）
2. 检查其他服务的内存占用：`free -m`
3. 如仍不足，考虑关闭不必要的服务

### 同步上游后脚本被覆盖

`deploy.sh` 和 `DEPLOY.md` 来自你的 fork 仓库，上游没有这些文件，同步时不会被覆盖。但如果上游新增了同名文件，合并时可能冲突，此时保留你的版本即可。

### 国内服务器无法访问 GitHub

如果 VPS 在国内，`git clone` 和 `npm install` 可能超时。解决方案：
1. 配置代理后重试
2. 或在境外机器上构建后打包上传

---

## 使用 API

安装完成后，使用任意 OpenAI 兼容客户端连接：

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://<你的IP>:3001/v1",
    api_key="freellmapi-你的统一密钥",  # 在管理面板 Keys 页面获取
)

response = client.chat.completions.create(
    model="auto",
    messages=[{"role": "user", "content": "你好"}],
)
print(response.choices[0].message.content)
```

统一密钥在管理面板 `http://<你的IP>:3001` 的 **Keys** 页面顶部获取。
