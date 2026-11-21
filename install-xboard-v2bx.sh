#!/bin/bash
#
# Xboard 一键部署脚本（官方方法版，只装面板）
# ============================================================
# 按 Xboard 官方 Quick Start 的方法部署面板：
#   compose 分支 + SQLite + 容器内置 Redis，宿主机不装 MariaDB/Redis。
# 只装一块干净的面板，不做其它设置：不建套餐、不建订阅用户、
# 不建节点、不生成通讯密钥、不装后端。
# 装完进管理后台，你自己手动添加服务器、添加节点、配置套餐，就能用。
#
# 用法（用 root 登录新服务器后）：
#   bash install-xboard-v2bx.sh [服务器IP] [管理员邮箱]
#   不传参数也行，脚本会提示你输入服务器 IP（直接回车就自动检测）。
#   管理员邮箱不提示，默认 admin@admin.com（传第 2 个参数可以改）。
#   管理员密码由安装程序随机生成，装完会打印出来，请保存好。
#   反代另外用通用的 install-reverse-proxy.sh，不在这个脚本里做。
#
# 注意：跑一半失败了可以直接重跑，它会接着做完；
#      装完后会在 /root/.xboard-installed 留个标记，重复运行会直接退出，
#      确认要重装就删掉标记文件再跑，或加环境变量 FORCE=1。
#      如果安装中途失败，先删掉 .docker/.data/database.sqlite 再重跑。
#
set -euo pipefail

# ---------- 0. 参数（没传 IP 就交互提示） ----------
SERVER_IP="${1:-}"
ADMIN_EMAIL="${2:-admin@admin.com}"
FORCE="${FORCE:-0}"
SUB_BASE=""
ADMIN_PASS=""

# 没传 IP 就问一句（回车自动检测）；不是交互终端就不问，直接自动检测
if [ -z "$SERVER_IP" ] && [ -t 0 ]; then
  read -r -p "请输入服务器公网 IP（直接回车自动检测）: " SERVER_IP
fi
# 输入的不是有效 IPv4（比如粘贴命令时被 read 吃掉了整行）就清空，改走自动检测，别直接报错退出
if [ -n "$SERVER_IP" ] && ! printf '%s' "$SERVER_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "提示：输入的不是有效 IPv4（$SERVER_IP），改用自动检测。"
  SERVER_IP=""
fi

# ---------- 1. 检查 ----------
[ "$(id -u)" -ne 0 ] && { echo "请用 root 运行这个脚本"; exit 1; }
if [ -f /root/.xboard-installed ] && [ "$FORCE" != "1" ]; then
  echo "这台服务器已经装过一次了（标记文件 /root/.xboard-installed 存在），不要重复运行。"
  echo "确认要重装：先删掉标记文件，或用 FORCE=1 bash install-xboard-v2bx.sh 再跑。"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
# 先装脚本自己要用的最小工具：全新最小化系统可能连 openssl、curl 都没有，
# 而下面的随机密码和 IP 检测要用到它们，所以必须先装
apt-get update -y
apt-get install -y openssl curl ca-certificates

# 内存检查：官方这套（SQLite + 内置 Redis）比 MariaDB 轻得多，
# 但 400MB 以下还是装不了
TOTAL_MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
if [ "$TOTAL_MEM_MB" -lt 400 ] && [ "$FORCE" != "1" ]; then
  echo "错误：这台服务器内存只有 ${TOTAL_MEM_MB}MB，装不下（至少要 400MB，建议 1GB 以上）。"
  echo "换台大一点的服务器再装。如果坚持要装，用 FORCE=1 再跑。"
  exit 1
fi
echo "内存：${TOTAL_MEM_MB}MB"
[ "$TOTAL_MEM_MB" -lt 1024 ] && echo "注意：内存不到 1GB，面板会用最小资源配置，能跑但比较紧。"

# IP 检测（只取 IPv4：裸 IPv6 放进 APP_URL 会让 Laravel 报 Invalid URI）
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(curl -4 -s --max-time 5 https://ifconfig.me || true)"
fi
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(hostname -I | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
fi
if ! printf '%s' "$SERVER_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "错误：没拿到有效的 IPv4 地址（拿到的是 ${SERVER_IP:-空}），装不下去。"
  echo "如果这台服务器只有 IPv6，请在命令里手动传一个 IPv4 或域名做参数。"
  exit 1
fi
echo "服务器 IP：$SERVER_IP"
echo "管理员邮箱：$ADMIN_EMAIL"

# ---------- 2. 装基础软件（只要 Docker + git，不装 MariaDB/Redis） ----------
echo "== [1/5] 安装基础软件 =="
apt-get update -y
apt-get install -y curl wget git unzip python3 ca-certificates dnsutils iproute2
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# ---------- 3. 面板：官方 compose 分支 ----------
echo "== [2/5] 下载 Xboard（官方 compose 分支） =="
mkdir -p /www/wwwroot
cd /www/wwwroot
if [ ! -d xboard/.git ]; then
  git clone -b compose --depth 1 https://github.com/cedar2025/Xboard.git xboard
else
  cd xboard
  git fetch origin compose --depth 1
  git checkout compose
  git reset --hard origin/compose
  cd ..
fi
cd xboard

# 内存不到 1GB 时用最小资源配置（单 Octane worker，Horizon 1/1/1）
if [ "$TOTAL_MEM_MB" -lt 1024 ]; then
  sed -i 's/RESOURCE_PROFILE=balanced/RESOURCE_PROFILE=minimal/' compose.yaml
  echo "已把面板设为最小资源配置"
fi

# 准备 .env 和 SQLite 文件。
# 注意：安装程序会把 .env.example 复制成 .env 再写配置，
# 所以 APP_URL 要在安装完成后再改，这里先把数据库配成 SQLite，
# 让容器第一次启动时就用 SQLite（而不是 .env.example 里的 MySQL）。
mkdir -p .docker/.data storage/logs storage/theme plugins
[ -f .env ] || cp .env.example .env
[ -f .docker/.data/database.sqlite ] || : > .docker/.data/database.sqlite
python3 - .env <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
updates = {
    'DB_CONNECTION': 'sqlite',
    'DB_DATABASE': '.docker/.data/database.sqlite',
    'DB_HOST': '',
    'DB_USERNAME': '',
    'DB_PASSWORD': '',
    'REDIS_HOST': '/data/redis.sock',
    'REDIS_PORT': '0',
}
lines = text.splitlines()
seen = set()
out = []
for line in lines:
    if '=' in line and not line.lstrip().startswith('#'):
        key = line.split('=', 1)[0]
        if key in updates:
            out.append(f'{key}={updates[key]}')
            seen.add(key)
            continue
    out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f'{key}={value}')
path.write_text('\n'.join(out) + '\n')
PY

echo "== [3/5] 启动面板容器 =="
docker compose up -d

# 等容器内置 Redis 就绪（socket 出现说明服务已启动；
# 新安装时 entrypoint 会跳过数据库更新，不会和后面的安装抢数据库）
echo "等内置 Redis 就绪…"
REDIS_OK=0
for i in $(seq 1 30); do
  if docker compose exec -T xboard sh -lc 'test -S /data/redis.sock' 2>/dev/null; then
    REDIS_OK=1
    break
  fi
  sleep 2
done
[ "$REDIS_OK" = "1" ] || { echo "错误：内置 Redis 30 次都没起来"; docker compose logs --tail=80 xboard; exit 1; }
echo "内置 Redis 已就绪"

# ---------- 4. 官方安装 ----------
# 判断是不是真的装好了：数据库非空 + .env 有 APP_KEY + INSTALLED=true，
# 三个都满足才跳过。只看数据库会误判——数据库有内容但 .env 不完整时，
# 上次没装完的状态会被当成已装好，后面算管理地址就报错。
TRULY_INSTALLED=0
if [ -s .docker/.data/database.sqlite ] && grep -q '^APP_KEY=.\+' .env 2>/dev/null && grep -qE '^INSTALLED=(1|true)$' .env 2>/dev/null; then
  TRULY_INSTALLED=1
fi

if [ "$TRULY_INSTALLED" = "1" ]; then
  echo "== [4/5] 检测到已安装，跳过安装（管理员密码沿用上次安装时生成的） =="
else
  # 状态不一致（数据库有内容但 .env 不完整）或全新：清掉重装，保证装出来是干净完整的
  if [ -s .docker/.data/database.sqlite ]; then
    echo "数据库有内容但 .env 不完整（缺 APP_KEY 或未标记已安装），这是上次没装完留下的，清空后重新装。"
    rm -f .docker/.data/database.sqlite
    : > .env
  fi
  echo "== [4/5] 执行官方安装 =="
  # 保险：确保安装程序走完整安装流程（而不是直接返回）
  sed -i 's/^INSTALLED=.*/INSTALLED=false/' .env
  if ! docker compose exec -T \
    -e ENABLE_SQLITE=true \
    -e ENABLE_REDIS=true \
    -e ADMIN_ACCOUNT="$ADMIN_EMAIL" \
    xboard php artisan xboard:install > /tmp/xboard-install.log 2>&1; then
    echo "错误：官方安装失败，日志在 /tmp/xboard-install.log，最后 30 行："
    tail -30 /tmp/xboard-install.log
    exit 1
  fi
  # 安装程序会打印管理员密码，从输出里取出来（去掉可能的颜色码）
  ADMIN_PASS="$(sed 's/\x1b\[[0-9;]*m//g' /tmp/xboard-install.log | grep '管理员密码：' | sed 's/.*管理员密码：//' | tr -d '[:space:]' | head -1)"
  [ -n "$ADMIN_PASS" ] || { echo "错误：安装输出里没找到管理员密码，请看 /tmp/xboard-install.log"; tail -30 /tmp/xboard-install.log; exit 1; }
  echo "官方安装完成"
  # 安装程序有时把 APP_KEY 写进容器里自己的 .env，但宿主机的 .env 没同步
  # （.env 是文件挂载，容器内整体重写一次后两边会分叉，宿主机就一直是空的）。
  # 这里以容器里的为准，先同步回宿主机；容器里也没有的话就自己生成一个，
  # 保证后面能算出管理地址。
  if ! grep -q '^APP_KEY=.\+' .env 2>/dev/null; then
    if docker compose exec -T xboard sh -c 'grep -q "^APP_KEY=.\+" /www/.env 2>/dev/null'; then
      echo "容器里的 .env 有 APP_KEY，同步回宿主机。"
      docker compose exec -T xboard cat /www/.env > .env
    else
      echo "容器里也没有 APP_KEY，生成一个写进宿主机 .env。"
      NEW_KEY="base64:$(openssl rand -base64 32)"
      python3 - .env "$NEW_KEY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); key = sys.argv[2]
lines = p.read_text().splitlines() if p.exists() else []
out = []
found = False
for line in lines:
    if line.startswith("APP_KEY="):
        out.append(f"APP_KEY={key}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"APP_KEY={key}")
p.write_text("\n".join(out) + "\n")
PY
    fi
  fi
fi

# 给 Hysteria/Trojan 节点自动补证书配置（Xboard 管理后台建节点时没有证书字段，
# 不补的话节点起不来）。用数据库触发器，一劳永逸：以后建节点自动补，不用再手动改。
if [ -s .docker/.data/database.sqlite ]; then
  echo "创建证书自动补全触发器（以后建 Hysteria/Trojan 节点自动补证书）..."
  python3 - .docker/.data/database.sqlite <<'PY' || echo "警告：触发器创建失败，以后建 Hysteria/Trojan 节点要手动补 cert_config"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""CREATE TRIGGER IF NOT EXISTS v2_server_cert_auto_insert
AFTER INSERT ON v2_server
WHEN NEW.type IN ('hysteria','trojan') AND NEW.cert_config IS NULL
BEGIN
  UPDATE v2_server SET cert_config='{"cert_mode":"self","domain":"www.bing.com"}' WHERE id=NEW.id;
END""")
c.execute("""CREATE TRIGGER IF NOT EXISTS v2_server_cert_auto_update
AFTER UPDATE ON v2_server
WHEN NEW.type IN ('hysteria','trojan') AND NEW.cert_config IS NULL
BEGIN
  UPDATE v2_server SET cert_config='{"cert_mode":"self","domain":"www.bing.com"}' WHERE id=NEW.id;
END""")
c.commit()
print("触发器已就绪:", [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='v2_server'")])
PY
fi

# 安装会重写 .env，这时再把 APP_URL 改成实际地址，并重启面板生效
python3 - .env "$SERVER_IP" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
ip = sys.argv[2]
text = path.read_text()
lines = text.splitlines()
out = []
seen = False
for line in lines:
    if line.startswith('APP_URL='):
        out.append(f'APP_URL=http://{ip}:7001')
        seen = True
    else:
        out.append(line)
if not seen:
    out.append(f'APP_URL=http://{ip}:7001')
path.write_text('\n'.join(out) + '\n')
PY
# 用重建代替 restart：.env 是文件挂载，安装时容器内重写过一次后两边可能分叉，
# 只有重建容器才会重新挂载宿主机的 .env，让容器读到同步好的 APP_KEY 和 APP_URL。
docker compose up -d --force-recreate xboard

# 管理后台地址：crc32(APP_KEY)，和官方安装程序算的一样
SECURE_PATH="$(python3 - .env <<'PY'
from pathlib import Path
import binascii
import sys
app_key = ""
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("APP_KEY="):
        app_key = line.split("=", 1)[1].strip()
        break
print(f"{binascii.crc32(app_key.encode()) & 0xffffffff:08x}" if app_key else "")
PY
)"
[ -n "$SECURE_PATH" ] || { echo "错误：没算出管理后台地址（.env 里没有 APP_KEY）"; exit 1; }

# ---------- 5. 验证 ----------
echo "== [5/5] 验证 =="
SUB_BASE="http://$SERVER_IP:7001"

# 防火墙放行（如果 ufw 开着）
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 7001/tcp >/dev/null
  echo "已放行 ufw 端口"
fi

# 等面板真正响应（重启后 entrypoint 要跑更新，需要一点时间）
echo ""
echo "---------- 验证 ----------"
PANEL_CODE="000"
for i in $(seq 1 30); do
  PANEL_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:7001/ || echo "000")"
  [ "$PANEL_CODE" = "200" ] && break
  sleep 2
done
echo "面板首页 HTTP：$PANEL_CODE"
touch /root/.xboard-installed

# 管理员密码：这次安装生成的就打印出来；跳过安装时沿用上次的
if [ -z "$ADMIN_PASS" ]; then
  ADMIN_PASS_LINE="（沿用上次安装时生成的，本次未改动）"
else
  ADMIN_PASS_LINE="$ADMIN_PASS"
fi

cat <<EOF

============================================================
 安装完成！
============================================================
 面板地址：  $SUB_BASE/
 管理后台：  $SUB_BASE/$SECURE_PATH
 管理员账号：$ADMIN_EMAIL
 管理员密码：$ADMIN_PASS_LINE

 数据库是 SQLite，文件在 /www/wwwroot/xboard/.docker/.data/database.sqlite，
 记得定期备份。

 接下来你自己在管理后台做：
  - 添加服务器、添加节点
  - 配置套餐、建用户（订阅账号），订阅链接在用户中心自动生成

 注意：
  - 云商家（AWS/阿里云等）的安全组里也要放行端口
    7001/TCP（面板）；节点端口按你建节点时用的放行
============================================================
EOF
