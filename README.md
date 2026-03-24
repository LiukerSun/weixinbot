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
- 提供 `openclaw-monitor.sh`，可把实例、模型、token、quota 状态暴露为 Prometheus 指标
- 提供 `openclaw-quota-control.sh`，可按 token 阈值自动暂停实例容器
- 提供基于 `Go + React` 的管理后台，可查看用户实例用量、调整额度、重启或创建实例
- 实例统一创建到 `OPENCLAW_INSTANCES_DIR` 下
- 创建完成后默认自动尝试微信登录并显示二维码
- 不常驻创建 `openclaw-cli` 容器，只有安装插件或扫码登录时才临时运行
- 已内置微信兼容补丁，不需要额外拷贝补丁文件
- 对已存在实例执行 `--sync-instance-config` 或 `weixin-login.sh` 时，会自动修复 `openclaw-weixin` 的宿主兼容导入并恢复 `plugins.allow`

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
- `set-openclaw-model.sh`
- `openclaw-monitor.sh`
- `openclaw-quota-control.sh`

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
  --zai-model "glm-5-turbo" \
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
- 如果你已经装过旧版脚本，重新执行一次 `install-openclaw.sh` 就会覆盖更新 `/usr/local/bin` 下的脚本
- 如果你不想安装到 `/usr/local/bin`，可以先设置 `OPENCLAW_INSTALL_DIR`

例如：

```bash
export OPENCLAW_INSTALL_DIR="/root/.local/bin"
bash <(curl -fsSL https://raw.githubusercontent.com/LiukerSun/weixinbot/master/install-openclaw.sh)
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
- `ZAI model`
- `OpenAI API key`
- `OpenAI base URL`
- `OpenAI model`
- `BRAVE_API_KEY`

端口默认会自动给出一组未占用的建议值。

### 参数模式创建

```bash
bash ./create-openclaw-instance.sh openclaw_demo auto auto \
  --primary-model-provider openai \
  --zai-model "glm-5-turbo" \
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
- `ZAI` 模型支持 `--zai-model`
- OpenAI-compatible 配置支持 `--openai-api-key`、`--openai-base-url`、`--openai-model`
- 为兼容旧命令，`codex` / `--codex-*` 仍然可用，但推荐统一改用 `openai` / `--openai-*`
- 默认在创建完成后自动尝试微信登录
- 如果暂时不想拉起微信登录，可加 `--skip-weixin-login`
- 如果不想安装微信插件，可加 `--without-weixin`

## 调整已有实例模型

如果实例已经存在，可以直接按实例名或容器名切换模型：

```bash
bash ./set-openclaw-model.sh openclaw_demo --model openai/gpt-5.4
```

如果你想用引导模式，直接不带参数执行即可。脚本会先列出当前运行中的实例供你选择，再按模型提供方分别提示参数：

- `zai`：提示 `ZAI model`、`ZAI API key`
- `openai`：提示 `OpenAI model`、`OpenAI API key`、`OpenAI base URL`

```bash
bash ./set-openclaw-model.sh
```

也可以直接传容器名：

```bash
bash ./set-openclaw-model.sh openclaw_demo_openclaw-gateway_1 --model zai/glm-4.5-air
```

如果需要同时更新 OpenAI-compatible 配置：

```bash
bash ./set-openclaw-model.sh openclaw_demo \
  --primary-model-provider openai \
  --openai-model "gpt-5.4" \
  --openai-base-url "https://your-openai-compatible-endpoint/v1" \
  --openai-api-key "your_openai_api_key"
```

这个脚本会自动：

- 定位目标实例
- 更新实例 `.env`
- 重写 `docker-compose.yml` 和 `state/openclaw.json`
- 在检测到相关容器存在时尝试重载 `openclaw-gateway`
- 默认补一轮 smoke test，直接校验当前 provider 的 `API key`、`base URL`、`model` 是否可用；如果不想测试，可加 `--skip-test`

## 微信登录

如果创建时没有跳过自动登录，实例创建完成后脚本会直接尝试：

- 启动 `openclaw-gateway`
- 安装并启用 `openclaw-weixin`
- 自动修复 `openclaw-weixin` 的旧 SDK 导入并写入兼容补丁
- 恢复 `plugins.allow` 和 `plugins.entries.openclaw-weixin.enabled`
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
- 自动修复 `openclaw-weixin` 的旧 SDK 导入
- 恢复 `plugins.allow`
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

输出 Prometheus 指标：

```bash
openclaw-monitor.sh snapshot
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
  [--zai-model <model>] \
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

如果实例里已经装了 `openclaw-weixin`，这条命令还会同时：

- 自动修复插件对旧版 `openclaw/plugin-sdk/*` 子路径的引用
- 恢复 `plugins.allow` 和 `plugins.entries.openclaw-weixin.enabled`

然后重启实例即可让新的 OpenAI/Codex 配置生效。

登录脚本：

```bash
bash ./weixin-login.sh <instance_name>
```

切换模型脚本：

```bash
bash ./set-openclaw-model.sh
bash ./set-openclaw-model.sh <instance_name|container_name> --model <provider/model>
```

统计脚本：

```bash
bash ./openclaw-stats.sh [--instance <instance_name>] [--since <YYYY-MM-DD|ISO8601>] [--until <YYYY-MM-DD|ISO8601>] [--json]
```

监控导出脚本：

```bash
bash ./openclaw-monitor.sh serve [--base-dir <instances_dir>] [--quota-config <path>] [--bind <host>] [--port <port>]
bash ./openclaw-monitor.sh snapshot [--base-dir <instances_dir>] [--quota-config <path>]
```

配额控制脚本：

```bash
bash ./openclaw-quota-control.sh check --config <path> [--base-dir <instances_dir>] [--instance <instance_name>] [--dry-run]
bash ./openclaw-quota-control.sh daemon --config <path> [--base-dir <instances_dir>] [--interval-seconds <n>] [--instance <instance_name>] [--dry-run]
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

## 监控接入

`openclaw-monitor.sh` 会调用 `openclaw-stats.sh --json`，并把结果转成 Prometheus 文本格式，适合直接被 Prometheus 抓取，再在 Grafana 里做面板或告警。

先本地看一眼指标：

```bash
openclaw-monitor.sh snapshot
```

常驻启动 exporter：

```bash
openclaw-monitor.sh serve --bind 0.0.0.0 --port 9469
```

Prometheus 抓取示例：

```yaml
scrape_configs:
  - job_name: openclaw
    static_configs:
      - targets: ["127.0.0.1:9469"]
```

导出的指标包括：

- 实例数量、session 文件数量、assistant 消息数量
- 全局和实例级 `input` / `output` / `cache_read` / `cache_write` / `total` token
- 模型维度和实例+模型维度的 token 统计
- `openclaw-gateway` 是否运行
- quota 限额、当前用量、超限状态、是否被 quota controller 暂停

## 用量限制与自动停容器

当前限额粒度是实例级。如果你的部署是一人一个实例，那就等价于用户级用量限制。

示例配置文件已经放在仓库里：

- `./openclaw-quota-config.example.json`

你可以复制成正式配置，例如：

```bash
cp ./openclaw-quota-config.example.json /root/openclaw-instances/quota-config.json
```

配置格式示例：

```json
{
  "defaults": {
    "limits": {
      "daily": 200000,
      "monthly": 3000000
    },
    "stopServices": ["openclaw-gateway"],
    "resumeWhenWithinLimit": true
  },
  "instances": {
    "openclaw_vip_user": {
      "limits": {
        "daily": 500000,
        "monthly": 10000000
      },
      "validFrom": "2026-01-02",
      "validUntil": "2026-04-15"
    },
    "openclaw_total_cap": {
      "limits": {
        "total": 5000000
      },
      "resumeWhenWithinLimit": false
    }
  }
}
```

字段说明：

- `daily`：按当天累计 token 限额
- `monthly`：按月度周期累计 token 限额；如果配置了 `validFrom`，则月度周期按开始日期滚动重置，例如 `2026-01-02` 开始，则在 `2026-02-02` 重置
- `total`：按有效期起点以来的累计 token 限额；如果未配置有效期，则按实例历史累计
- `stopServices`：超限后要停止的 Compose 服务，默认是 `openclaw-gateway`
- `resumeWhenWithinLimit`：如果超限窗口恢复到阈值以内，是否自动重新 `up -d`
- `disabled`：禁用某个实例的限额控制
- `validFrom` / `validUntil`：额度有效期，必须成对出现，且 `validUntil` 必须晚于 `validFrom`

先做一次演练，不实际停容器：

```bash
openclaw-quota-control.sh check --config /root/openclaw-instances/quota-config.json --dry-run
```

正式执行一次：

```bash
openclaw-quota-control.sh check --config /root/openclaw-instances/quota-config.json
```

常驻运行：

```bash
openclaw-quota-control.sh daemon \
  --config /root/openclaw-instances/quota-config.json \
  --interval-seconds 60
```

行为说明：

- 当某个实例命中任意已配置阈值时，脚本会执行 `docker compose stop openclaw-gateway`
- 如果配置了 `validFrom` / `validUntil`，实例只会在这个区间内可用；未到开始日期或已经过期时，也会被 quota controller 自动暂停
- 状态会写入实例目录下的 `state/quota-controller.json`
- 如果配置了 `monthly` 且带有效期，月额度会按开始日期的月度周期滚动重置，不按自然月重置
- 如果只配置了 `daily` / `monthly`，并且 `resumeWhenWithinLimit=true`，到新的一天或进入下一个月度周期后，controller 会自动恢复实例
- 如果配置了 `total` 历史总量阈值，通常不会自动恢复，除非你提高阈值或改配置
- `openclaw-monitor.sh` 在传入同一份 quota 配置时，会同时导出 quota 相关指标

## 管理后台

仓库里已经新增一个管理后台工程：

- 后端：`./admin`，使用 Go 标准库 HTTP 服务
- 前端：`./admin/web`，使用 React + Vite

管理后台目前支持：

- 查看所有用户实例的 token 用量
- 查看每个实例的 `gateway` 状态、quota 状态、最近使用模型
- 直接给某个用户实例增加额度或重设额度
- 给某个用户实例设置任意开始日期、截止日期，以及按开始日期滚动的月度重置周期
- 直接暂停、恢复、重启某个用户实例容器
- 直接创建新的用户实例
- quota 超额后由后台 daemon 自动停止实例容器，不只是前端显示 `limit hit`

### 后端接口

后端会复用现有脚本和 Compose：

- 调 `openclaw-stats.sh --json` 获取实例与用量
- 调 `openclaw-quota-control.sh check` 刷新 quota 状态
- 调 `create-openclaw-instance.sh` 创建实例
- 直接执行 `docker compose` / `docker-compose` 对实例做暂停、恢复、重启

主要接口：

- `GET /api/healthz`
- `GET /api/instances`
- `GET /api/instances/:name`
- `POST /api/instances`
- `POST /api/instances/:name/pause`
- `POST /api/instances/:name/resume`
- `POST /api/instances/:name/restart`
- `POST /api/instances/:name/quota`

`POST /api/instances/:name/quota` 支持两种更新模式：

- `mode=set`：直接设置额度
- `mode=add`：在当前额度基础上追加额度

例如给 `user_zhangsan` 增加 `50000` 日额度：

```json
{
  "mode": "add",
  "daily": 50000
}
```

### 前端启动

先安装依赖并构建前端：

```bash
cd /root/weixinbot/admin/web
npm install
npm run build
```

如果你要本地开发前端：

```bash
cd /root/weixinbot/admin/web
npm run dev
```

默认会把 `/api` 代理到 `http://127.0.0.1:8088`。

### 后端启动

如果宿主机已经安装 Go：

```bash
cd /root/weixinbot
OPENCLAW_SCRIPTS_DIR=/root/weixinbot \
OPENCLAW_ADMIN_WEB_DIST=/root/weixinbot/admin/web/dist \
OPENCLAW_INSTANCES_DIR=/root/openclaw-instances \
go run ./admin/cmd/openclaw-admin
```

常用环境变量：

- `OPENCLAW_ADMIN_LISTEN`：后台监听地址，默认 `:8088`
- `OPENCLAW_INSTANCES_DIR`：实例目录，默认 `/root/openclaw-instances`
- `OPENCLAW_QUOTA_CONFIG`：quota 配置文件路径
- `OPENCLAW_SCRIPTS_DIR`：脚本目录，通常就是仓库根目录
- `OPENCLAW_ADMIN_WEB_DIST`：前端构建产物目录
- `OPENCLAW_ADMIN_ALLOWED_ORIGINS`：前端开发源，逗号分隔

启动后访问：

```text
http://127.0.0.1:8088
```

### Docker 部署管理后台

仓库根目录已经提供：

- `Dockerfile.admin`
- `docker-compose.admin.yml`

其中包含两个服务：

- `openclaw-admin`：管理后台 Web/API
- `openclaw-quota-daemon`：常驻执行 quota 检查，超额后自动停止 `openclaw-gateway`

直接启动：

```bash
cd /root/weixinbot
docker compose -f docker-compose.admin.yml up -d --build
```

默认映射端口：

- `2052`
- `39188`

默认后台认证：

- 用户名：`admin`
- 密码：查看 `docker-compose.admin.yml` 中的 `OPENCLAW_ADMIN_PASSWORD`

行为说明：

- `openclaw-quota-daemon` 启动后会立即执行一次检查
- 某个实例任意 quota 窗口超额后，会自动执行 `docker compose stop openclaw-gateway`
- 如果给实例设置了开始日期和截止日期，daemon 会按开始日期切分月度周期，例如 `1 月 2 日开始`，则 `2 月 2 日` 自动进入下一个月度周期
- 暂停状态写入对应实例目录下的 `state/quota-controller.json`
- 管理后台里的“已暂停”统计依赖这个状态文件，因此必须部署 daemon 才会和超额状态保持一致

### 编译检查

前端已可直接构建：

```bash
cd /root/weixinbot/admin/web
npm run build
```

如果宿主机还没安装 Go，可以直接用 Docker 做后端编译检查：

```bash
docker run --rm -v /root/weixinbot:/src -w /src/admin golang:1.22 go test ./...
```

也可以直接依赖环境变量：

```bash
export ZAI_API_KEY="your_zai_api_key"
export ZAI_MODEL="glm-5-turbo"
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
export ZAI_MODEL="glm-5-turbo"
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
- `create-openclaw-instance.sh --sync-instance-config <instance_dir>` 现在也会顺带修复已安装 `openclaw-weixin` 的兼容导入并恢复 `plugins.allow`
- 现有实例如果想切换默认模型，优先使用 `set-openclaw-model.sh`；如果手动改 `.env`，至少要同步 `OPENCLAW_PRIMARY_MODEL_PROVIDER`、`ZAI_MODEL`、`OPENAI_MODEL`，并执行 `create-openclaw-instance.sh --sync-instance-config <instance_dir>`
- `gateway.bind` 默认写为 `lan`，但端口映射仍然只绑定在宿主机 `127.0.0.1`
