# weixinbot

用 3 个脚本管理 OpenClaw 多实例，并给指定实例接入微信插件。

## 脚本

- `./install-openclaw.sh`
  交互式保存默认参数，连续创建多个 OpenClaw Docker 实例。
- `./weixin-connect.sh <instance>`
  对指定实例安装或修复 `openclaw-weixin`，并进入官方微信登录流程。
- `./uninstall-openclaw.sh`
  删除指定实例或全部实例，同时清理容器、网络和实例目录。

## 前置要求

- Linux
- Docker 与 `docker compose`
- `curl` 或 `node`
- 能拉取 `ghcr.io/openclaw/openclaw:*` 镜像

## 快速开始

首次运行安装脚本：

```bash
./install-openclaw.sh
```

脚本会提示你填写并保存默认参数，保存位置：

```text
./.manager/defaults.env
```

保存后，后续再执行时通常只需要输入实例名。

给实例接入微信：

```bash
./weixin-connect.sh demo01
```

删除单个实例：

```bash
./uninstall-openclaw.sh --name demo01
```

删除全部实例：

```bash
./uninstall-openclaw.sh --all
```

删除全部实例并清空默认参数：

```bash
./uninstall-openclaw.sh --all --purge-defaults
```

## 不 clone 也能用

这几个脚本不依赖 Git，但它们依赖“脚本所在目录”来存放 `.manager/` 和 `instances/`，所以不要直接 `curl ... | bash`。

推荐做法是先把脚本下载到同一个目录，再执行：

```bash
mkdir -p ~/weixinbot && cd ~/weixinbot

curl -fsSLO https://raw.githubusercontent.com/LiukerSun/weixinbot/master/install-openclaw.sh
curl -fsSLO https://raw.githubusercontent.com/LiukerSun/weixinbot/master/weixin-connect.sh
curl -fsSLO https://raw.githubusercontent.com/LiukerSun/weixinbot/master/uninstall-openclaw.sh

chmod +x *.sh
```

然后按正常方式使用：

```bash
./install-openclaw.sh
./weixin-connect.sh demo01
./uninstall-openclaw.sh --name demo01
```

## 常用命令

首次配置并连续创建多个实例：

```bash
./install-openclaw.sh
```

修改已保存的默认参数：

```bash
./install-openclaw.sh --edit-defaults
```

单次只创建一个实例：

```bash
./install-openclaw.sh --name demo01
```

不给实例名时，微信连接脚本会列出可选实例并让你输入：

```bash
./weixin-connect.sh
```

## 默认参数

`install-openclaw.sh` 会保存并复用这些参数：

- OpenClaw Docker 镜像
- 实例根目录
- 主模型提供方，当前支持 `zai` 或 `openai`
- `ZAI_API_KEY` 与 `ZAI_MODEL`
- `OPENAI_API_KEY`、`OPENAI_BASE_URL`、`OPENAI_MODEL`
- `BRAVE_API_KEY`
- 自动分配端口起点
- 时区
- 微信插件包名

## 目录结构

```text
./.manager/defaults.env
./instances/<instance>/
./instances/<instance>/compose.yml
./instances/<instance>/.env
./instances/<instance>/state/
./instances/<instance>/workspace/
```

说明：

- 每个实例都有独立目录、独立端口、独立容器名
- `state/` 保存 OpenClaw 状态与插件数据
- `workspace/` 作为该实例的工作目录

## 脚本行为说明

`install-openclaw.sh`：

- 自动寻找空闲端口对
- 写入实例 `.env`、`compose.yml` 和 `openclaw.json`
- 启动 `openclaw-gateway`
- 为实例设置默认主模型配置

`weixin-connect.sh`：

- 读取默认配置和实例配置
- 修复 `state/` 与 `workspace/` 权限
- 重写微信相关配置，避免旧安装残留干扰
- 先尝试官方安装器
- 如果遇到 ClawHub `429` 限流，自动回退到 npm 归档安装

`uninstall-openclaw.sh`：

- 支持删除单个实例或全部实例
- 会清理对应容器、默认网络和实例目录
- 可选清理 `./.manager/defaults.env`

## 注意事项

- `weixin-connect.sh` 依赖 `install-openclaw.sh` 创建出的实例目录，不能单独对一个不存在的实例运行
- 三个脚本最好放在同一个目录使用
- 默认实例目录是脚本所在目录下的 `./instances`
- 默认参数文件是脚本所在目录下的 `./.manager/defaults.env`
