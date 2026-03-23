# OpenClaw Weixin Deploy Scripts

这套脚本用于在任意一台新的 Linux 服务器上，快速创建 OpenClaw 实例并接入微信。

当前默认行为：

- 使用官方镜像 `ghcr.io/openclaw/openclaw:latest`
- 默认安装 `openclaw-weixin`
- 默认支持 `ZAI`，也可同时配置 `OpenAI-compatible` 模型提供方
- 支持引导式安装和参数安装
- 自动探测未占用端口
- 自动检查并安装宿主机依赖
- 提供 `openclaw-stats.sh`，可汇总所有实例的模型与 token 用量
- 实例统一创建到 `OPENCLAW_INSTANCES_DIR` 下
- 创建完成后默认自动尝试微信登录并显示二维码
- 不常驻创建 `openclaw-cli` 容器，只有安装插件或扫码登录时才临时运行
- 已内置微信兼容补丁，不需要额外拷贝补丁文件

## 环境要求

建议在 Debian 或 Ubuntu 上，以 `root` 用户执行。

脚本会自动检查并尝试安装以下依赖：

- Docker
- Docker Compose
- `node`
- `openssl`
- `base64`
- `gzip`

说明：

- Compose 可以是 `docker-compose`
- 也可以是 `docker compose`
- `ss` 或 `lsof` 不是必须，缺失时脚本会回退到 `node` 探测端口
- 自动安装逻辑当前只支持 Debian/Ubuntu 的 `apt-get`
- 首次运行如果宿主机缺少依赖，脚本会先安装 Docker、Compose、Node.js 和基础工具，然后再继续创建实例

## 一键安装

推荐直接拉取引导脚本，它会自动下载并安装：

- `create-openclaw-instance.sh`
- `weixin-login.sh`
- `openclaw-stats.sh`

默认安装位置是 `/usr/local/bin`，然后立即开始 OpenClaw 安装流程。

### 交互式安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LiukerSun/weixinbot/master/install-openclaw.sh)
```

### 参数模式安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LiukerSun/weixinbot/master/install-openclaw.sh) \
  openclaw_demo auto auto \
  --primary-model-provider openai \
  --openai-api-key "your_openai_api_key" \
  --openai-base-url "https://your-openai-compatible-endpoint/v1" \
  --openai-model "gpt-5.4" \
  --zai-api-key "your_zai_api_key" \
  --brave-api-key "your_brave_api_key"
```

说明：

- 这条命令会先把脚本安装到 `/usr/local/bin`
- 然后执行 `/usr/local/bin/create-openclaw-instance.sh`
- 后续如果需要重新扫码，可直接执行 `/usr/local/bin/weixin-login.sh openclaw_demo`
- 如果你不想安装到 `/usr/local/bin`，可以先设置 `OPENCLAW_INSTALL_DIR`

例如：

```bash
export OPENCLAW_INSTALL_DIR="/root/.local/bin"
bash <(curl -fsSL https://raw.githubusercontent.com/LiukerSun/weixinbot/master/install-openclaw.sh)
```

## 一键统计

如果你只想临时跑一次统计，不想先安装到本机，可以直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LiukerSun/weixinbot/master/run-openclaw-stats.sh)
```

参数会原样透传给 `openclaw-stats.sh`，例如：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LiukerSun/weixinbot/master/run-openclaw-stats.sh) \
  --instance openclaw_demo \
  --since 2026-03-01 \
  --until 2026-03-31 \
  --json
```

## 获取脚本

如果你不想走引导脚本，也可以只拉主安装脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/LiukerSun/weixinbot/master/create-openclaw-instance.sh -o ./create-openclaw-instance.sh
chmod +x ./create-openclaw-instance.sh
```

## 实例目录

默认实例目录：

```text
/root/openclaw-instances/<instance_name>
```

如果你想改到别的位置：

```bash
export OPENCLAW_INSTANCES_DIR="/data/openclaw-instances"
```

## 快速开始

### 引导式创建

```bash
bash ./create-openclaw-instance.sh
```

脚本会提示你输入：

- 实例名
- Gateway 端口
- Bridge 端口
- 是否安装 `openclaw-weixin`
- 默认主模型提供方（`zai` 或 `openai`）
- `ZAI_API_KEY`
- `OpenAI API key`
- `OpenAI base URL`
- `OpenAI model`
- `BRAVE_API_KEY`

端口默认会自动给出一组未占用的建议值。

### 参数模式创建

```bash
bash ./create-openclaw-instance.sh openclaw_demo auto auto \
  --primary-model-provider openai \
  --openai-api-key "your_openai_api_key" \
  --openai-base-url "https://your-openai-compatible-endpoint/v1" \
  --openai-model "gpt-5.4" \
  --zai-api-key "your_zai_api_key" \
  --brave-api-key "your_brave_api_key"
```

参数说明：

- `auto auto` 表示自动寻找一组可用端口
- 默认安装 `openclaw-weixin`
- 默认主模型提供方是 `zai`
- 如果要把默认模型切到 OpenAI-compatible，可加 `--primary-model-provider openai`
- OpenAI-compatible 配置支持 `--openai-api-key`、`--openai-base-url`、`--openai-model`
- 为兼容旧命令，`codex` / `--codex-*` 仍然可用，但推荐统一改用 `openai` / `--openai-*`
- 默认在创建完成后自动尝试微信登录
- 如果暂时不想拉起微信登录，可加 `--skip-weixin-login`
- 如果不想安装微信插件，可加 `--without-weixin`

## 微信登录

如果创建时没有跳过自动登录，实例创建完成后脚本会直接尝试：

- 启动 `openclaw-gateway`
- 安装并启用 `openclaw-weixin`
- 写入兼容补丁
- 重启网关
- 显示微信二维码

如果你后续需要重新扫码：

```bash
bash ./weixin-login.sh openclaw_demo
```

这个脚本会在需要时自动：

- 检查实例是否存在
- 如果实例不存在，先调用创建脚本创建
- 确保微信插件已安装
- 按实例 `.env` 同步 `ZAI` / `OpenAI-compatible` 配置，避免重登时把模型配置覆盖回默认值
- 重新写入补丁
- 重启网关并显示二维码

## 常用命令

启动实例：

```bash
docker compose -f /root/openclaw-instances/openclaw_demo/docker-compose.yml up -d
```

停止实例：

```bash
docker compose -f /root/openclaw-instances/openclaw_demo/docker-compose.yml down
```

查看容器：

```bash
docker ps -a | grep openclaw_demo
```

查看日志：

```bash
docker logs -f openclaw_demo_openclaw-gateway_1
```

查看所有实例的模型和 token 统计：

```bash
openclaw-stats.sh
```

## 目录结构

一个实例创建完成后，常见文件如下：

- `/root/openclaw-instances/openclaw_demo/.env`
- `/root/openclaw-instances/openclaw_demo/docker-compose.yml`
- `/root/openclaw-instances/openclaw_demo/state`
- `/root/openclaw-instances/openclaw_demo/workspace`

其中：

- `state` 保存 OpenClaw 配置和插件数据
- `workspace` 保存工作目录数据

## 端口说明

每个实例占用两个本机端口：

- Gateway 端口，映射到容器内 `18789`
- Bridge 端口，映射到容器内 `18790`

脚本会把端口绑定到 `127.0.0.1`，不会直接暴露到公网。

## 脚本参数

创建脚本：

```bash
bash ./create-openclaw-instance.sh <instance_name> <gateway_port|auto> <bridge_port|auto> \
  [--with-weixin] \
  [--without-weixin] \
  [--skip-weixin-login] \
  [--primary-model-provider <zai|openai>] \
  [--zai-api-key <key>] \
  [--openai-api-key <key>] \
  [--openai-base-url <url>] \
  [--openai-model <model>] \
  [--brave-api-key <key>]
```

同步已有实例配置：

```bash
bash ./create-openclaw-instance.sh --sync-instance-config /root/openclaw-instances/openclaw_demo
```

如果实例是旧版本脚本创建的，这条命令会同时重写：

- `docker-compose.yml`
- `state/openclaw.json`

然后重启实例即可让新的 OpenAI/Codex 配置生效。

登录脚本：

```bash
bash ./weixin-login.sh <instance_name>
```

统计脚本：

```bash
bash ./openclaw-stats.sh [--instance <instance_name>] [--since <YYYY-MM-DD|ISO8601>] [--until <YYYY-MM-DD|ISO8601>] [--json]
```

## 数据统计

`openclaw-stats.sh` 会扫描 `OPENCLAW_INSTANCES_DIR` 下每个实例的 `state` 目录，读取其中的 `jsonl` 运行记录，并在可用时通过 Docker 识别对应的 OpenClaw 容器状态，按实例和按模型汇总：

- `provider/model`
- `input` tokens
- `output` tokens
- `cacheRead` tokens
- `cacheWrite` tokens
- `totalTokens`
- 产生 usage 的 assistant 消息次数
- 每个实例匹配到的容器数量
- `openclaw-gateway` 容器状态

默认统计所有实例：

```bash
openclaw-stats.sh
```

只看单个实例：

```bash
openclaw-stats.sh --instance openclaw_demo
```

按时间范围过滤：

```bash
openclaw-stats.sh --since 2026-03-01 --until 2026-03-31
```

说明：

- 只传 `YYYY-MM-DD` 时，会按宿主机本地时区取当天 `00:00:00.000` 到 `23:59:59.999`
- 如果宿主机没有 `docker` 命令，或 Docker daemon 不可用，脚本会自动降级为只输出 usage 汇总，不影响 token 统计

输出 JSON，方便接监控或二次处理：

```bash
openclaw-stats.sh --json
```

也可以直接依赖环境变量：

```bash
export ZAI_API_KEY="your_zai_api_key"
export OPENAI_API_KEY="your_openai_api_key"
export OPENAI_BASE_URL="https://your-openai-compatible-endpoint/v1"
export OPENAI_MODEL="gpt-5.4"
export OPENCLAW_PRIMARY_MODEL_PROVIDER="openai"
export BRAVE_API_KEY="your_brave_api_key"
export OPENCLAW_INSTANCES_DIR="/root/openclaw-instances"
bash ./create-openclaw-instance.sh
```

## 部署建议

新服务器推荐流程：

```bash
export ZAI_API_KEY="your_zai_api_key"
export OPENAI_API_KEY="your_codex_api_key"
export OPENAI_BASE_URL="https://your-openai-compatible-endpoint/v1"
export OPENAI_MODEL="gpt-5.4"
export OPENCLAW_PRIMARY_MODEL_PROVIDER="openai"
export BRAVE_API_KEY="your_brave_api_key"
bash <(curl -fsSL https://raw.githubusercontent.com/LiukerSun/weixinbot/master/install-openclaw.sh)
```

## 注意事项

- 请使用 `root` 执行，否则默认目录可能没有写权限
- 如果宿主机缺少依赖，脚本会自动安装；这一步需要服务器能访问 Debian/Ubuntu 软件源以及 Docker 官方软件源
- 如果实例目录已存在且非空，创建脚本会直接拒绝覆盖
- 创建过程失败时，脚本会自动清理未完成的半成品实例目录
- 微信兼容补丁已经内嵌在脚本中，不需要单独同步源码补丁
- `weixin-login.sh` 会按需启动临时 `openclaw-cli` 容器来安装插件或拉起登录
- 现有实例如果想切换默认模型提供方，可直接修改对应实例的 `.env` 里的 `OPENCLAW_PRIMARY_MODEL_PROVIDER`、`OPENAI_API_KEY`、`OPENAI_BASE_URL`、`OPENAI_MODEL`，然后执行 `create-openclaw-instance.sh --sync-instance-config <instance_dir>`，最后重启网关
- `gateway.bind` 默认写为 `lan`，但端口映射仍然只绑定在宿主机 `127.0.0.1`
