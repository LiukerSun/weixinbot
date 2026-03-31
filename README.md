# weixinbot

> 🧩 用一套轻量脚本，把 OpenClaw 多实例管理、微信插件接入、实例清理三件事一次理顺。

面向需要批量部署 OpenClaw 实例的场景，`weixinbot` 提供了一套尽可能直接、少废话、可重复执行的 Bash 工具链：

- 🚀 快速创建多个 OpenClaw Docker 实例
- 💬 为指定实例接入 `openclaw-weixin` 官方流程
- 🧹 一键卸载单个或全部实例
- 📦 不依赖 clone 仓库，下载脚本即可使用

## ✨ 核心能力

### 1. 多实例创建

`install-openclaw.sh` 会保存一份默认配置，之后你只需要连续输入实例名，就可以批量创建多套独立运行的 OpenClaw 环境。

每个实例都具备：

- 独立目录
- 独立端口
- 独立容器
- 独立状态目录与工作目录

### 2. 微信插件接入

`weixin-connect.sh` 会基于已有实例：

- 修复状态目录权限
- 清理旧的微信插件残留
- 按官方流程安装 `openclaw-weixin`
- 在遇到 ClawHub `429` 限流时自动回退到 npm 归档安装

### 3. 实例清理

`uninstall-openclaw.sh` 支持：

- 删除单个实例
- 删除全部实例
- 清理相关容器与网络
- 可选删除保存下来的默认配置

## 🧰 脚本一览

| 脚本 | 作用 |
| --- | --- |
| `./install-openclaw.sh` | 交互式保存默认参数，并创建 OpenClaw 实例 |
| `./weixin-connect.sh <instance>` | 给指定实例安装或修复微信插件，并进入登录流程 |
| `./uninstall-openclaw.sh` | 删除单个或全部实例，并清理目录、容器、网络 |

## 📋 前置要求

运行前请确认环境具备以下条件：

- 🐧 Linux
- 🐳 Docker
- 🧱 `docker compose`
- 🌐 `curl` 或 `node`
- 📥 能正常拉取 `ghcr.io/openclaw/openclaw:*` 镜像

## ⚡ 快速开始

### 1. 首次创建实例

```bash
./install-openclaw.sh
```

脚本会提示你填写默认参数，并保存到：

```text
./.manager/defaults.env
```

保存完成后，后续再次执行通常只需要继续输入实例名即可。

### 2. 给实例接入微信

```bash
./weixin-connect.sh demo01
```

如果不传实例名：

```bash
./weixin-connect.sh
```

脚本会列出当前实例并让你手动输入目标实例。

### 3. 删除实例

删除单个实例：

```bash
./uninstall-openclaw.sh --name demo01
```

删除全部实例：

```bash
./uninstall-openclaw.sh --all
```

删除全部实例并清空默认配置：

```bash
./uninstall-openclaw.sh --all --purge-defaults
```

## 📥 不 clone 也能用

这套脚本不依赖 Git 仓库本身，但依赖“脚本所在目录”来存放 `.manager/` 和 `instances/`，所以不建议直接使用 `curl ... | bash`。

推荐方式是把脚本下载到同一个目录再执行：

```bash
mkdir -p ~/weixinbot && cd ~/weixinbot

curl -fsSLO https://raw.githubusercontent.com/LiukerSun/weixinbot/master/install-openclaw.sh
curl -fsSLO https://raw.githubusercontent.com/LiukerSun/weixinbot/master/weixin-connect.sh
curl -fsSLO https://raw.githubusercontent.com/LiukerSun/weixinbot/master/uninstall-openclaw.sh

chmod +x *.sh
```

然后直接运行：

```bash
./install-openclaw.sh
./weixin-connect.sh demo01
./uninstall-openclaw.sh --name demo01
```

## 🛠️ 常用命令

修改默认参数：

```bash
./install-openclaw.sh --edit-defaults
```

只创建一个实例：

```bash
./install-openclaw.sh --name demo01
```

## ⚙️ 默认配置项

`install-openclaw.sh` 会保存并复用这些参数：

- `OPENCLAW_IMAGE`
- `INSTANCES_DIR`
- `OPENCLAW_PRIMARY_MODEL_PROVIDER`
- `ZAI_API_KEY`
- `ZAI_MODEL`
- `OPENAI_API_KEY`
- `OPENAI_BASE_URL`
- `OPENAI_MODEL`
- `BRAVE_API_KEY`
- `PORT_BASE`
- `OPENCLAW_TZ`
- `WEIXIN_PLUGIN_PACKAGE`

这意味着你第一次配置完后，后续新增实例的成本会明显下降。

## 🗂️ 目录结构

```text
./.manager/defaults.env
./instances/<instance>/
./instances/<instance>/compose.yml
./instances/<instance>/.env
./instances/<instance>/state/
./instances/<instance>/workspace/
```

目录说明：

- `.manager/defaults.env`：保存默认参数
- `instances/<instance>/compose.yml`：该实例的 Compose 配置
- `instances/<instance>/.env`：该实例的环境变量
- `instances/<instance>/state/`：OpenClaw 状态与插件数据
- `instances/<instance>/workspace/`：该实例的工作目录

## 🔄 脚本工作流

### `install-openclaw.sh`

主要负责实例初始化：

- 自动选择空闲端口对
- 写入实例 `.env`
- 生成 `compose.yml`
- 生成 `openclaw.json`
- 启动 `openclaw-gateway`
- 为实例设置默认主模型配置

### `weixin-connect.sh`

主要负责微信接入：

- 读取默认配置与实例配置
- 修复 `state/` 和 `workspace/` 权限
- 清理旧插件残留
- 调用官方安装器
- 遇到 `429` 时自动回退到 npm 归档安装
- 重启 Gateway 使插件配置生效

### `uninstall-openclaw.sh`

主要负责实例清理：

- 下线实例容器
- 清理残留容器
- 删除默认网络
- 删除实例目录
- 按需清理默认配置文件

## ✅ 适合的使用方式

如果你的目标是下面这些场景，这个项目会比较顺手：

- 需要快速起多个 OpenClaw 实例
- 希望每个实例互相隔离
- 需要反复重装或修复微信插件
- 想把部署、接入、清理流程收敛成统一脚本

## ⚠️ 注意事项

- `weixin-connect.sh` 依赖 `install-openclaw.sh` 先创建实例
- 三个脚本最好放在同一个目录使用
- 默认实例目录是脚本目录下的 `./instances`
- 默认配置文件位于脚本目录下的 `./.manager/defaults.env`
- 如果系统里存在权限较复杂的挂载目录，建议优先检查宿主机目录属主和 Docker 运行用户映射

## 🧪 一个典型流程

```bash
./install-openclaw.sh --name demo01
./weixin-connect.sh demo01
./uninstall-openclaw.sh --name demo01
```

## 📌 总结

`weixinbot` 不是一个大而全的平台，而是一组聚焦于“部署 OpenClaw + 接入微信 + 管理实例生命周期”的实用脚本。

它的目标很直接：

- 减少重复手工操作
- 降低多实例管理成本
- 让接入和清理流程更稳定

如果你只是想把 OpenClaw 实例更快地跑起来，并且顺手接上微信，这套脚本已经足够直接。 🚀
