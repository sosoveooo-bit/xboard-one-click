# xboard-one-click

Xboard + Nginx Proxy Manager 的 VPS 部署和维护脚本。当前管理脚本版本：2.0.0。

此维护分支属于 `sosoveooo-bit/xboard-one-click`。下面的命令不会再切换到 `slobys` 的脚本。

## 已部署的 VPS：先只更新管理脚本

以 root 登录 VPS，执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sosoveooo-bit/xboard-one-click/codex/fix-xboard-update-env/bootstrap.sh) --update-scripts
bash /root/xboard-one-click/menu.sh
```

这一步只更新管理脚本，不执行安装、不更新容器镜像、不重建数据库、不重置密码。已有 `xb` 快捷命令也可以继续使用。

如果提示本地脚本有内容修改，更新会停止，避免丢失手动修改。可先用 `git -C /root/xboard-one-click status --short` 查看，不要通过强制清空工作区解决。单纯执行权限变化不会阻止更新。

更新前的脚本提交保存在 Git 引用 `refs/xboard-one-click/previous`。已有安装使用 detached HEAD 读取所选远程版本，不会删除原本的本地分支或提交。

## 全新 VPS 安装

适用于 Debian/Ubuntu、root、本机 Docker daemon、Docker Compose v2、Python 3、curl 和 flock。默认使用 SQLite 和容器内置 Redis。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sosoveooo-bit/xboard-one-click/codex/fix-xboard-update-env/bootstrap.sh)
```

默认目录是 `/root/xboard-one-click`，默认分支是 `codex/fix-xboard-update-env`。新机器会进入交互式安装；检测到已有 `runtime` 目录时只进入菜单，不会自动重新安装。

安装时设置 NPM 的 HTTP/HTTPS/管理端口、Xboard 对外端口和管理员邮箱。建议将公网 80/443 留给 NPM；管理端口按需要设置，并在云安全组中限制管理来源。安装结束后从菜单 4 获取入口，从菜单 22 验证并查看随机生成的管理员密码。

脚本会尝试补齐 apt 源中可用的依赖。若系统源没有 Compose v2 插件，会明确停止，请按 [Docker 官方 Linux 插件安装说明](https://docs.docker.com/compose/install/linux/) 配置后重试，不会退回旧版 docker-compose 继续执行危险操作。

首次安装仍会获取上游镜像。检查通过后将运行镜像固定为本机准确版本；后续只有主动执行菜单 2 才解除锁定并尝试更新。镜像、网络或上游应用不兼容时，脚本可能停止，不能承诺任何上游版本都可以直接升级。

## 菜单与日常操作

| 菜单 | 用途 |
| --- | --- |
| 1 | 安装或重新配置端口；有旧数据时先备份，不初始化旧库 |
| 2 | 更新 Xboard/NPM 镜像；必须先完整备份，失败默认自动回滚 |
| 4 | 查看入口和账号；密码默认隐藏，可主动验证后展示 |
| 14 | 本机应用健康检查 |
| 15 | 完整备份 |
| 16 | 按编号或完整路径选择备份并恢复 |
| 17/18 | 停止部署并保留数据 / 删除当前运行数据 |
| 19 | 安全修复当前 Xboard，不更新镜像、不重置密码 |
| 20 | 卸载当前部署；是否删除备份需要第二次确认 |
| 21 | 仅更新管理脚本 |
| 22 | 列出管理员、验证展示已保存密码、单独重置或恢复账号 |

更新期间应安排维护窗口，暂停面板操作、支付回调和外部写入。回滚恢复的是备份时刻的数据，不会自动合并维护期间新增的订单或其他写入。

安装、更新、备份、恢复、修复、密码操作和卸载使用同一个操作锁，不要同时从多个终端执行维护命令。

### 安全更新

```bash
bash /root/xboard-one-click/update.sh
```

更新使用现有 Compose 配置和 `.env`，不强制切换数据库或覆盖站点地址。它保存准确镜像和数据卷后暂停旧容器，拉取候选镜像、迁移数据库、清理缓存、检查业务记录和关键配置，最后执行应用就绪检查。

失败时默认恢复原镜像、配置、SQLite 和命名数据卷；恢复本身也必须通过检查。更新失败即使回滚成功，命令仍返回非零，便于识别结果。`PRE_UPDATE_BACKUP=0` 不再允许进行安全更新。若明确关闭 `AUTO_ROLLBACK_ON_UPDATE_FAIL`，必须自行使用保留的备份恢复。

不要从 Xboard 面板内的系统更新按钮绕过脚本保护。新安装、安全更新及安全修复会禁用应用内自动更新；仅更新管理脚本不会修改应用配置。

### 安全修复

```bash
bash /root/xboard-one-click/repair.sh
```

修复只使用当前版本镜像，先备份，再修复安装标记、已知 SQLite 路径别名、迁移和缓存。不会移动旧库、生成空库、改变 APP_KEY 或自动创建管理员。

存在数据但缺少原 `.env` / APP_KEY，或者 SQLite 无法安全读取时，会停止。请先找回原配置或已验证备份。数据库读取错误不是允许重新初始化的理由；`FORCE_XBOARD_INSTALL=1` 对已有数据库会被拒绝。

### 密码与账号恢复

```bash
bash /root/xboard-one-click/password.sh --list
bash /root/xboard-one-click/password.sh --show
bash /root/xboard-one-click/password.sh --reset 实际管理员邮箱
```

重置需要输入确认文字，随后生成并保存随机新密码。只允许重置已存在且未被禁用的管理员，不会把普通用户提升为管理员。

仅当数据库完全没有管理员时，可从菜单 22 的独立入口创建管理员，需要额外输入 `CREATE_ADMIN` 确认。此操作不重建数据库，也不恢复已经丢失的用户或节点。

在面板里改过密码后，本地保存的旧密码可能失效。展示前会与当前密码哈希核对；失效则明确提示，不会拿旧密码冒充有效密码，也不会顺便重置账号。`deploy.env` 和备份文件限制为仅所有者可读写，请勿上传这些文件到公开仓库或群聊。

## 备份与迁移

菜单 15 或下面命令会输出完整备份的绝对路径：

```bash
bash /root/xboard-one-click/backup.sh
```

默认目录：`/root/xboard-one-click-backups`。更新、修复的备份分别位于其 `pre-update`、`pre-repair` 子目录。

完整备份包含项目文件、`.env`、SQLite、用户/节点配置、NPM 配置与证书、准确容器镜像和命名数据卷（包括 Redis 持久化数据）。不支持默默漏掉项目目录之外的 bind mount 或其他项目同时使用的数据卷；遇到这些情况会停止。

镜像也在备份中，因此包会比旧版本大。预检会为镜像、文件和卷快照预留磁盘空间。打包期间服务会暂停；成功后默认重新启动原容器，备份或重新启动失败会明确返回失败。旧备份和历史恢复目录不会自动清理。

迁移步骤：

1. 在旧 VPS 完成备份，将 `.tar.gz`、同名 `.sha256` 和 `.info` 一起传到新 VPS 的 `/root`。
2. 新 VPS 安装 Docker Compose v2、Python 3 和 curl，再运行本文“只更新管理脚本”的命令准备工具，不需要先创建空面板。
3. 在新 VPS 执行下面的恢复命令，填写真实文件名。
4. 健康检查通过后，检查域名解析、新 VPS 安全组、NPM 反代和证书，再切换业务流量。旧 VPS 和原备份先保留。

```bash
bash /root/xboard-one-click/restore.sh /root/你的备份文件.tar.gz
```

也可以不填写文件名，由脚本列出默认备份目录中的备份供选择：

```bash
bash /root/xboard-one-click/restore.sh
```

新备份默认必须通过 SHA-256、归档路径、链接和镜像/卷载荷校验。迁移不会因为校验文件里记录了旧服务器的路径而失败。恢复在临时目录完成准备后才停止现有服务，为恢复的命名卷创建独立副本，不覆盖旧数据卷。

现有目录需要确认后才会替换；非交互场景必须显式设置 `RESTORE_OVERWRITE=1`。旧目录会保留为 `xboard-one-click.before-restore-时间-随机值`。候选恢复未通过检查时会保留为 `failed-restore-*` 并尝试重新启动先前部署，命令仍返回失败。

### 旧版本备份

旧包没有镜像和命名数据卷清单，不能保证还原原镜像或 Redis 数据。仅对你自己可信的旧备份，明确接受限制后使用：

```bash
ALLOW_LEGACY_RESTORE=1 bash /root/xboard-one-click/restore.sh /root/旧备份文件.tar.gz
```

菜单 16 也提供 `LEGACY` 确认。已有但校验不匹配的 `.sha256` 仍会拒绝恢复，不能靠这个开关跳过损坏检查。恢复旧包可能同时恢复旧版管理脚本，恢复后请重新执行本文“只更新管理脚本”命令，避免继续使用旧版修复逻辑。

只恢复可信来源的备份；校验和证明文件一致，不证明来源可信。恢复内容包含可执行脚本和镜像。

## 卸载保护

默认卸载保留备份。菜单 20 要求输入 `DELETE`，若还要删除备份，必须另外输入 `DELETE_BACKUPS`。

卸载只处理能核对到当前 Compose 工作目录的容器和数据卷，不按名称前缀删除全机资源，不清理其他项目的镜像。外部/共享卷、未选择删除的备份及历史恢复目录会保留并提示。自定义备份目录还需要有效的归属标记；符号链接和危险路径会被拒绝。

不要执行全机 Docker prune 或盲目关闭全部占用 80/443 的进程来代替本项目卸载。

## 验证范围

```bash
python3 -m unittest discover -s tests -v
```

仓库提供 Bash 语法与故障回归测试，以及 GitHub Actions 的真实 Docker 备份/恢复测试。推送代码时还会在一次性 Linux runner 中安装真实 Xboard/NPM、修复并注入更新失败，验证回滚；Actions 手动运行时可勾选 `xboard_smoke` 执行同样检查。

健康检查验证本机容器、应用身份下的数据库和 Redis、管理员、后台 HTML 和公开配置 JSON。仅有端口监听或根路径返回 4xx 不代表通过；本机检查不代替公网 DNS、防火墙、证书和完整业务测试。

当前 Xboard 镜像的应用进程用户和启动行为依据上游 [Supervisor 配置](https://github.com/cedar2025/Xboard/blob/master/.docker/supervisor/supervisord.conf) 与 [入口脚本](https://github.com/cedar2025/Xboard/blob/master/.docker/entrypoint.sh) 适配。上游发生不兼容变更时应停止升级并检查，不应通过放松健康检查来显示成功。
