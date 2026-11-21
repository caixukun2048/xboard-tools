# xboard-tools

一键安装干净的 Xboard 面板，只装面板，不建套餐、不建用户、不建节点。

## 一行安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/caixukun2048/xboard-tools/main/install-xboard-v2bx.sh)
```

按提示输入服务器 IP（直接回车自动检测）。装完会打印管理后台地址和管理员密码。

要求：Debian / Ubuntu，内存 1G 以上。

## 卸载

```bash
cd /www/wwwroot/xboard && docker compose down -v; rm -rf /www/wwwroot/xboard /root/.xboard-installed; docker rmi ghcr.io/cedar2025/xboard:latest 2>/dev/null; systemctl stop xboard-node 2>/dev/null; systemctl disable xboard-node 2>/dev/null; rm -rf /etc/xboard-node /usr/local/bin/xbctl; rm -f /etc/systemd/system/xboard-node.service; systemctl daemon-reload; echo "全部清理完成"
```
