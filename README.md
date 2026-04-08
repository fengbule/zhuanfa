# fb

一个偏“论坛成品脚本”风格的 VPS 端口转发管理工具，支持交互菜单、一键部署、状态查看、规则管理、备份恢复和彻底卸载。

管理命令固定为 `fb`。

## 功能特点

- 7 种转发方案：`iptables` / `HAProxy` / `socat` / `gost` / `realm` / `rinetd` / `nginx stream`
- 自动安装依赖、自动生成配置、自动创建 `systemd` 服务、自动开机重建
- 自动应用网络优化：`BBR` / `TCP Fast Open` / 缓冲区 / `IP Forward`
- 支持交互菜单、状态页、监听端口查看、目标连通性检测、日志查看
- 支持同一方案批量添加多个 IP 或域名，监听端口自动递增
- `iptables` 使用独立 `FB_*` 链，尽量不影响现有防火墙
- `haproxy` / `rinetd` / `nginx` 使用专用实例配置，避免覆盖主配置
- 单条和批量规则变更都会先备份，若重建失败会自动回滚
- 支持仅卸载命令，也支持彻底卸载服务、规则、配置、备份和脚本本体

## 一键使用

直接启动菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fengbule/zhuanfa/main/fb.sh)
```

一键安装到系统命令 `fb`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fengbule/zhuanfa/main/fb.sh) install-self
```

安装完成后直接执行：

```bash
fb
```

## 手动安装

```bash
curl -fsSL https://raw.githubusercontent.com/fengbule/zhuanfa/main/fb.sh -o fb.sh
chmod +x fb.sh
sudo ./fb.sh
```

安装到系统命令：

```bash
sudo ./fb.sh install-self
```

## 常用命令

```bash
fb menu
fb add iptables tcp 0.0.0.0 3389 1.2.3.4 3389
fb batch-add realm tcp 0.0.0.0 33001 22 1.1.1.1,2.2.2.2,3.3.3.3:2222
fb list
fb status
fb pretty-status
fb logs 100
fb backup
fb backups
fb restore /etc/fb/backups/fb-backup-xxxx.tar.gz
fb stop
fb uninstall
fb uninstall purge
fb purge
```

## 批量转发说明

`batch-add` 用于同一方案同时转发多个 IP 或域名。

```bash
fb batch-add METHOD PROTO LISTEN_ADDR START_LISTEN_PORT TARGET_PORT TARGET1,TARGET2,...
```

示例：

```bash
fb batch-add realm tcp 0.0.0.0 33001 22 1.1.1.1,2.2.2.2,3.3.3.3:2222
```

上面的命令会生成：

```text
0.0.0.0:33001 -> 1.1.1.1:22
0.0.0.0:33002 -> 2.2.2.2:22
0.0.0.0:33003 -> 3.3.3.3:2222
```

## 卸载说明

- `fb uninstall`
  仅卸载 `fb` 命令与开机重建入口，保留现有转发服务和配置
- `fb uninstall purge`
  彻底卸载服务、规则、配置、备份
- `fb purge`
  彻底卸载，并尽量删除当前这个脚本文件

## 方案建议

- 游戏 / RDP / VNC：`iptables`
- SSH 中转：`realm` / `iptables`
- Web 服务：`HAProxy` / `nginx`
- 需要加密：`gost`
- 多端口 TCP 转发：`rinetd`

性能排序：`iptables > realm > HAProxy/nginx > socat/rinetd > gost`

## 兼容环境

- Debian 10 / 11 / 12
- Ubuntu 20.04 / 22.04 / 24.04
- CentOS 7 基本兼容，未做深度验证

## 注意事项

1. 默认基于 `systemd`。
2. `gost` / `realm` 会按当前 CPU 架构自动匹配 GitHub Release 资源。
3. `batch-add` 是批量生成多条规则，不是单监听口负载均衡。
4. `fb uninstall` 不会主动停掉现有非 `fb-rebuild` 转发实例，但系统重启后若是 `iptables` 规则不会自动重建。

## 测试

仓库里附带一个 mock 集成测试脚本：

```bash
bash ./mock-integration-test.sh
```
