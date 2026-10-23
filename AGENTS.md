# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Overview

This repository builds multi-architecture Docker images (linux/amd64, linux/arm64) for nginx + php-fpm with predefined configurations for Drupal and Laravel applications.

**Base image: `serversideup/php`**（2026-09 起，替代 nfrastack/nginx-php-fpm）。
serversideup 镜像 = 官方 PHP 镜像 + s6-overlay + install-php-extensions + 全免费的环境变量配置。
nfrastack 时代的备份见 `backup/nfrastack-base` 分支。

**官方基座草案（2026-10-21 起并行验证）**：`Dockerfile.official.template` +
`base/`（自研运行时：entrypoint/s6 服务/pool 模板，install/ 零改动）直接基于官方 `php`
镜像构建，绕过 serversideup 中间层；PECL 扩展走 GitHub 钉版本源码（pecl CDN 故障单点）。
CI 发 `8.x-{alpine,debian}-official` tag（workflow: docker-image-official.yml），
稳定后再考虑切换正式 tag；旧基座模板保留 3 个月+ 作回退。
详见 `docs/plan-official-php-base.md`。

## Build Commands

### Alpine variant
```bash
docker build -f Dockerfile.alpine.template \
  --build-arg PHP_VERSION=8.4 \
  --build-arg UPSTREAM_VERSION=8.4-fpm-nginx-alpine \
  -t your-image-name:8.4-alpine .
```

### Debian variant
```bash
docker build -f Dockerfile.debian.template \
  --build-arg PHP_VERSION=8.4 \
  --build-arg UPSTREAM_VERSION=8.4-fpm-nginx \
  -t your-image-name:8.4-debian .
```

### Legacy PHP 7.4 variant
```bash
docker build -f Dockerfile.alpine-old.template \
  --build-arg PHP_VERSION=7.4 \
  --build-arg UPSTREAM_VERSION=7.4-fpm-nginx-alpine \
  -t your-image-name:7.4-alpine .
```
（CI 见 `docker-image-old.yml`，仅手动触发。）

### PHP 7.4 安全补丁（CVE-2026-109618 / CVE-2026-109619）
PHP 7.4 在修复可用前就已 EOL，php.net 不会发布 7.4.34，所以旧镜像在构建时
**用基础镜像自带的 `/usr/src/php.tar.xz` 重新编译 7.4.33**，并打上游 EOL 缓解补丁：

- 补丁：`security/php74/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2.patch`
  （php-src commit `712e60f9`，"Avoid state corruption via bailout"）
- 行为变化：OOM 立即 `_exit(1)` 且不执行 shutdown 函数；新增
  `max_multipart_body_parts`（默认 -1 = `max_input_vars + max_file_uploads`）；
  原生 session upload progress 回调被禁用
- configure 参数逐字复制基础镜像的 `Configure Command`（`php -i` 可查），
  保证新二进制与 serversideup 预装的扩展 ABI 兼容（补丁不改结构体布局）
- `security/php74/verify.sh` 在构建期验证：INI 项存在、OOM 退出码 1 且无
  shutdown 回调（未打补丁的 7.4.33 是退出码 255 + 回调照跑）、`php-fpm` 版本
- 升级/更换上游镜像时若发现基础镜像已自带该 INI 项，构建会自动跳过重编译

运行时如何确认打了补丁（`php -v` 永远是 `7.4.33`，不能作为依据）：
```bash
# 1) 决定性判据：只有补丁引擎才有这个 INI 项（-1 = 自动上限）
docker exec <container> php -r 'var_dump(ini_get("max_multipart_body_parts"));'
# 2) 内置校验脚本（INI 项 + OOM 退出码 1 且不跑 shutdown 回调 + php-fpm 版本）
docker exec <container> verify-php74-cve
# 3) 镜像元数据 / 标记文件
docker inspect -f '{{ index .Config.Labels "com.davyin.php74-cve.upstream-commit" }}' <image>
docker exec <container> cat /usr/local/share/php74-cve/upstream.txt
```
注意：更新镜像后必须重建容器，`docker restart` 不会换运行时。

## Architecture

### Base Image (serversideup/php)
- Alpine: `serversideup/php:{PHP_VERSION}-fpm-nginx-alpine`
- Debian: `serversideup/php:{PHP_VERSION}-fpm-nginx`
- 关键事实（已实测验证）：
  - 默认 `USER www-data`，本镜像 Dockerfile 用 `USER root` 切回（sshd/cron 需要）
  - `NGINX_HTTP_PORT` 上游默认 **8080**，本镜像 ENV 改为 80
  - php-fpm 监听 **TCP 9000**（非 unix socket），`clear_env = no` 已内置
  - php.ini / pool 配置是 `${VAR}` 占位符模板，由 PHP/php-fpm 启动时从进程环境展开
  - php-fpm pool `pm.*` 参数原生可用（无付费锁定）；但本镜像的 canonical 变量是
    nfrastack 时代的 `PHP_FPM_PROCESS_MANAGER/PHP_FPM_MAX_CHILDREN/...`（DSF 平台注入的这组），
    由 `06-compat.sh` 无条件渲染进 pool 配置——serversideup 原生 `PHP_FPM_PM_*` 会被
    ENV 里的 canonical 默认值覆盖，不要使用
  - nginx.conf 由 `10-init-webserver-config.sh` 从 `nginx.conf.template` envsubst 渲染；
    `/etc/nginx/conf.d/default.conf` 若已存在（本镜像自带 Drupal 配置）则保留不覆盖
  - s6 服务 envdir 是 `/run/s6/container_environment`（注意是下划线）
  - 进程身份对齐 nfrastack 时代：nginx worker 与 php-fpm pool 子进程均为
    **nginx(80):www-data(82)**（Dockerfile `usermod -u 80 -g www-data nginx` +
    nginx.conf.template 顶部 `user nginx www-data;`（上游模板原本没有 user 指令，
    会回落到编译默认 nginx:nginx）+ ENV `PHP_FPM_CHILD_PROCESS_USER/GROUP=nginx/www-data`）。
    nginx/php-fpm 的 master 均为 root（旧镜像 php-fpm master 是 80:82，
    属设计差异，root master + 降权子进程是标准做法）。Debian 变体为 80:33

### Init System（s6-overlay 标准结构）
- `/etc/entrypoint.d/*.sh` 按数字序执行（每个在子 shell 中 source，**export 不会跨脚本传递**），
  全部在 `/init`（s6 启动）之前运行 → 此阶段可安全修改已渲染配置、删除 s6 contents.d 服务文件
- serversideup 自带：0-container-info、1-log-output-level、5-fpm-pool-user、5-generate-ssl、
  10-init-webserver-config、50-laravel-automations
- 本镜像的脚本（`install/etc/entrypoint.d/`）：
  - `06-compat.sh` — 旧变量名翻译：sed 替换 pool/php.ini 模板里的 `${VAR}` 占位符为具体值
    （同时渲染 `/etc/drush/drush.yml` 的 `${DRUSH_SQL_EXTRA}`；pgsql 站点须将该变量置空，psql 不兼容 `--skip-ssl`）
  - `60-s6-register.sh` — 把 cron 注册进 base 的 user bundle（sshd 由 63 注册/移除）；
    位置运行时探测：新 base 用 `/etc/s6-overlay/user-bundles.d/user/contents.d/`，旧 base 用
    `/etc/s6-overlay/s6-rc.d/user/contents.d/`——**两处都定义会冲突**，同名 "user" bundle
    互相覆盖导致上游 nginx/php-fpm 从编译结果中丢失（2026-10 实测）
  - `61-drupal.sh` — 站点配置（端口/webroot/安全头/subdir/超时/legacy 日志路径）
  - `62-cron.sh` — 渲染 crontab（Alpine `/etc/crontabs/root`；Debian `/etc/cron.d/custom`）
  - `63-sshd.sh` — SSH 用户/密钥/host key + sudo 授权（`/etc/sudoers.d/90-$USER_NAME`，NOPASSWD）；`USER_NAME` 为空时 `rm contents.d/sshd` 禁用服务
  - `65-logrotate.sh` — 渲染 `/etc/logrotate.d/custom`
- 自有 s6 longrun 服务：`cron`、`sshd`
  （run 脚本用 `#!/command/execlineb -P` + `with-contenv`，调用 `/usr/local/sbin/start-*` 包装脚本；
  注册不在静态文件里，由 `60-s6-register.sh` / `63-sshd.sh` 在 entrypoint 阶段写 bundle contents.d，
  原因见 60 脚本注释）

### Directory Mapping
`install/` 目录通过 `ADD install /` 拷入容器：
- `install/etc/entrypoint.d/` → 初始化脚本
- `install/etc/nginx/conf.d/default.conf` → Drupal server block
- `install/etc/nginx/conf.d/drupal-maps.conf` → Boost map（http context，conf.d 在 http 级 include）
- `install/etc/nginx/extra/subdir.conf` → DRUPAL_SUBDIR(S) 运行时生成位置
- `install/etc/nginx/vhost.d/` → 用户自定义 pre-/post-*.conf 扩展点
- `install/etc/s6-overlay/s6-rc.d/` → 自有服务定义 + user/contents.d 注册
- `install/etc/ssh/sshd_config.d/00-custom.conf` → SSH 配置（Port 2222 等）
- `install/etc/profile.d/pathenv.sh` → 登录 shell 的 PATH + PS1（红 user/青 cwd 双行提示符）
- `install/etc/bash/ps1.sh` → 非登录交互 bash 的 PS1
  （Alpine 由 /etc/bash/bashrc 的 `*.sh` 循环自动加载；Debian 由 Dockerfile 向
  /etc/bash.bashrc 追加 source 行）

### PHP / Nginx 配置路径（Alpine 与 Debian 一致）
- php.ini: `/usr/local/etc/php/conf.d/serversideup-docker-php.ini`（含 ${VAR} 占位符）
- pool: `/usr/local/etc/php-fpm.d/docker-php-serversideup-pool.conf`（含 ${VAR} 占位符）
- nginx 主配置: `/etc/nginx/nginx.conf`（启动时从 template 渲染）
- 站点配置: `/etc/nginx/conf.d/default.conf`

### PHP Extensions
构建时用 `install-php-extensions`（mlocati 工具）安装 15 个：
igbinary, msgpack, memcached, imagick, ldap, yaml, bz2,
apcu, bcmath, exif, gd, imap, intl, mysqli, pgsql
（与 nfrastack 时代对齐；基础镜像已含 redis, zip, pdo_mysql, pdo_pgsql,
sodium, opcache 等。冒烟脚本会逐项校验全部 19 个扩展）

### SSH Server
- `USER_NAME` 设置时启用（默认 ENV `USER_NAME=dsf`），监听 2222
- `63-sshd.sh` 负责建用户/host key/密钥 + 写 sudoers drop-in 授予该用户 NOPASSWD sudo；USER_NAME 为空时从 s6 contents.d 移除服务
- 公钥在 `/etc/ssh/authorized_keys.d/<user>`（不用 ~/.ssh：webroot 挂载卷的属主问题
  会触发 StrictModes 拒绝；且 sshd 以目标用户身份读 authorized_keys，文件必须属该用户）
- `useradd` 新建账号默认锁定（shadow 为 `!`），必须 `usermod -p '*'` 否则公钥登录也被拒

## CI/CD

GitHub Actions workflows in `.github/workflows/`:
- `docker-image.yml` - Alpine builds (PHP 8.2/8.3/8.4/8.5)
- `docker-image-debian.yml` - Debian builds (PHP 8.2/8.3/8.4/8.5)

Triggers: push to main, weekly cron, manual dispatch.
Builds and pushes to Docker Hub and Aliyun Container Registry.

构建结构（2026-09 起）：每个 PHP 版本 × 架构一条 build leg，**arm64 在原生
`ubuntu-24.04-arm` runner 上构建**（公共仓库免费，避免 QEMU 模拟编译扩展，
快 10 倍以上），单架构镜像先推 `{tag}-amd64`/`{tag}-arm64` 中间 tag，
再由 merge job 用 `imagetools create` 合成多架构 manifest 打正式 tag。
另有 `type=gha` 层缓存（scope = tag+arch）。
注意：registry 上的 `-amd64`/`-arm64` 中间 tag 是构建产物，勿删错正式 tag。

基础镜像用浮动 tag（周更带安全补丁）；生产环境建议钉 `-v{serversideup版本}` tag。

## Testing

### 冒烟测试（推荐，提交前必跑）
```bash
./scripts/test-local-build.sh [PHP_VERSION] [VARIANT] [UPSTREAM_VERSION]
```
构建镜像 → 从官方 drupal 镜像的 `/opt/drupal`（含 vendor）提取代码 →
挂载并设 `DRUPAL_WEB_ROOT=web` → 验证安装页 HTTP 200。
注意：官方 drupal 镜像的 `/var/www/html` 是指向 `/opt/drupal/web` 的符号链接，
直接 cp 它会丢失 vendor/ —— 必须拷 `/opt/drupal`。
PHP 8.2 测试需用 Drupal 10 代码（默认 `drupal:11-apache` 要求 PHP >= 8.3）：
`DRUPAL_IMAGE=drupal:10-apache ./scripts/test-local-build.sh 8.2 alpine`

### Quick test
```bash
docker run -d --name test \
  -p 8080:80 \
  -v /path/to/code:/var/www/html \
  -e DRUPAL_WEB_ROOT=web \
  your-image-name:tag
```

### SSH test
```bash
docker run -d --name test-ssh \
  -p 8080:80 -p 2222:2222 \
  -e USER_NAME=admin \
  -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  your-image-name:tag
ssh -p 2222 admin@localhost
```

## Pre-push Requirement (提交推送前必须本地测试)

任何修改 `Dockerfile.*.template`、`install/`、`.github/workflows/` 或 CI 构建矩阵的提交，在
**commit 并 push 之前** 必须完成本地构建并通过 Drupal 冒烟测试：

```bash
./scripts/test-local-build.sh 8.4 alpine        # 必测
./scripts/test-local-build.sh 8.4 debian        # 改动影响 Debian 变体时必测
./scripts/test-local-build.sh 8.3 alpine        # 涉及 PHP 版本相关逻辑时补测
```

CI 构建成功 ≠ 镜像可运行（构建只验证 Dockerfile 能跑通，不验证容器运行时）。

## Runtime Gotchas (serversideup 基座)

- **entrypoint.d 脚本在子 shell 执行**：export 不跨脚本传递，也不进 s6 服务环境。
  要改 php/pool 配置 → sed 模板占位符；要改 s6 服务环境 → 写 `/run/s6/container_environment/`
  （但该目录 /init 后才存在，entrypoint 阶段写不进去）
- **nginx.conf 在 entrypoint #10 渲染**：我们的脚本（06/61+）在其前后分工：
  06 处理 php（与 nginx 无关）；61 在 #10 之后改已渲染的 nginx.conf
- **`docker exec` / SSH 会话只有镜像 ENV 默认值**：运行时 `-e` 覆盖只影响 s6 服务进程
  （sshd 会过滤环境变量）。php.ini 占位符在 CLI 下按 ENV 默认值展开
- **PHP_CLI 的 opcache**：`PHP_OPCACHE_ENABLE=1` 同时开 cli opcache（上游行为），无实际影响
- **JIT 保持关闭**：`PHP_OPCACHE_JIT=off` + `BUFFER_SIZE=0`（Alpine/musl 上 Drupal 会 SIGSEGV）

## Common Tasks

### Adding a new PHP version
1. Add entry to matrix in `.github/workflows/docker-image.yml` (Alpine)
2. Add entry to matrix in `.github/workflows/docker-image-debian.yml` (Debian)
3. Tag 格式：alpine `{version}-fpm-nginx-alpine`；debian `{version}-fpm-nginx`

### Modifying nginx configuration
- 站点 server block: `install/etc/nginx/conf.d/default.conf`
- Drupal Boost maps: `install/etc/nginx/conf.d/drupal-maps.conf`
- http 级其他指令：可在 default.conf 同目录加 `zz-*.conf`（conf.d 在 http context include）

### Adding an init script
1. 放到 `install/etc/entrypoint.d/{NN}-{name}.sh`（POSIX sh，必须 exit 0）
2. 序号参考：serversideup 自带 0/1/5/10/50；我们的 php 类放 06，nginx 类放 61（必须在 10 之后）
3. Dockerfile 的 chmod +x 步骤会覆盖 `*.sh`

### Adding a long-running service
1. `install/etc/s6-overlay/s6-rc.d/{name}/`：`run`（execline + with-contenv）+ `type`（longrun）
2. 注册：在 `60-s6-register.sh`（无条件服务）或对应条件脚本（如 `63-sshd.sh`）里 touch
   bundle contents.d 文件；位置由 60 脚本的探测逻辑决定（新 base：`/etc/s6-overlay/user-bundles.d/user/contents.d/`）
3. 条件启动：在对应 entrypoint 脚本里 `rm` contents.d 里的 `{name}`（entrypoint 先于 s6 编译运行）
