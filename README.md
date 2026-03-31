# weixinbot

只保留两个脚本：

- `./install-openclaw.sh`
  交互式保存默认参数，然后连续输入实例名，快速创建多个 OpenClaw Docker 实例。
- `./weixin-connect.sh <instance>`
  对指定实例安装或修复 `openclaw-weixin` 插件，并进入微信二维码登录流程。
- `./uninstall-openclaw.sh`
  删除指定实例或全部实例，并清理对应目录与容器。

## 用法

首次运行：

```bash
./install-openclaw.sh
```

脚本会保存默认参数到：

```text
./.manager/defaults.env
```

后续如果默认参数不变，再次执行时只需要不断输入实例名即可。

修改默认参数：

```bash
./install-openclaw.sh --edit-defaults
```

单次创建一个实例：

```bash
./install-openclaw.sh --name demo01
```

给实例对接微信：

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

删除全部实例并清空保存的默认参数：

```bash
./uninstall-openclaw.sh --all --purge-defaults
```

不传实例名时，`weixin-connect.sh` 会列出实例并让你手输选择。

## 目录

- `./instances/<instance>/`
  每个实例一个独立目录
- `./instances/<instance>/compose.yml`
  该实例的 Docker Compose 文件
- `./instances/<instance>/.env`
  该实例的环境变量
- `./instances/<instance>/state`
  OpenClaw 状态目录
- `./instances/<instance>/workspace`
  OpenClaw 工作目录

## 说明

- 安装脚本默认只启动 OpenClaw 实例本身
- 微信插件安装、依赖修复、二维码登录由 `weixin-connect.sh` 负责
- 默认端口会从你保存的起始端口开始自动寻找空闲端口对
