# xboard-tools

一键安装干净的 Xboard 面板。

## 脚本

| 脚本 | 用途 |
| --- | --- |
| `install-xboard-v2bx.sh` | 一键安装 Xboard 面板（官方 compose 分支 + SQLite + 内置 Redis），只装面板本身，不建套餐、不建用户、不建节点，装完自己在后台手动添加 |

## 安装

```bash
bash install-xboard-v2bx.sh
```

运行后按提示输入服务器 IP（直接回车自动检测）。管理后台地址和管理员密码会在安装完成时打印出来。

要求：Debian / Ubuntu，内存建议 1G 以上，Docker 会自动安装。

## 说明

- 用的是 Xboard 官方 compose 分支 + SQLite + 内置 Redis，不装宿主机 MariaDB / Redis，内存占用更小。
- Hysteria / Trojan 节点建好后如遇证书问题，脚本已内置 SQLite 触发器，新节点会自动补证书配置。
- 反代另外做，不在这个项目里，见 [reverse-proxy-tools](https://github.com/caixukun2048/reverse-proxy-tools)。

## 卸载

```bash
cd /www/wwwroot/xboard && docker compose down -v; rm -rf /www/wwwroot/xboard /root/.xboard-installed; docker rmi ghcr.io/cedar2025/xboard:latest 2>/dev/null; systemctl stop xboard-node 2>/dev/null; systemctl disable xboard-node 2>/dev/null; rm -rf /etc/xboard-node /usr/local/bin/xbctl; rm -f /etc/systemd/system/xboard-node.service; systemctl daemon-reload; echo "全部清理完成"
```

一行清干净：面板容器、数据卷、网络、文件、安装标记、Docker 镜像、xboard-node 全部删除。
