#!/usr/bin/env bash
# 在同事自己的 Linux 机器上安装个人助手。不修改其他机器上已经在跑的环境。
# 若 /data/$USER/multica/.env 已存在、且不是本脚本装的，直接退出。
set -euo pipefail

MULTICA_VERSION="v0.6.3"
VERIFY_CODE="916425"
FRONTEND_PORT_DEFAULT="13080"
BACKEND_PORT_DEFAULT="18080"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="$(id -un)"
HOME_DIR="${HOME:-/home/${USER_NAME}}"
DATA_DIR="/data/${USER_NAME}"
BIN_DIR="${DATA_DIR}/bin"
MULTICA_DIR="${DATA_DIR}/multica"
STATE_DIR="${DATA_DIR}/multica-state"
WORK_ROOT="${DATA_DIR}/multica-workspaces"
PROGRESS="${STATE_DIR}/progress.env"
OPS_SRC="${ROOT}/bin/ops-cli"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

progress_has() { [[ -f "${PROGRESS}" ]] && grep -q "^$1=1$" "${PROGRESS}"; }
progress_set() {
  mkdir -p "${STATE_DIR}"
  touch "${PROGRESS}"
  grep -v "^$1=" "${PROGRESS}" > "${PROGRESS}.tmp" || true
  printf '%s=1\n' "$1" >> "${PROGRESS}.tmp"
  mv "${PROGRESS}.tmp" "${PROGRESS}"
  chmod 600 "${PROGRESS}"
}

port_busy() {
  ss -ltn | awk '{print $4}' | grep -Eq "(^|:)$1$"
}

pick_port() {
  local p="$1"
  while port_busy "${p}"; do
    p=$((p + 1))
  done
  printf '%s\n' "${p}"
}

prompt_secret() {
  local label="$1" value
  IFS= read -rsp "${label}: " value
  printf '\n' >&2
  [[ -n "${value}" ]] || die "${label} 为空"
  printf '%s' "${value}"
}

ensure_hosts() {
  local line="10.9.35.9 intl-oss.p1.cn intl-sso-gw.p1.cn intl-kibana.p1.cn"
  if grep -q 'intl-kibana.p1.cn' /etc/hosts && grep -q 'intl-oss.p1.cn' /etc/hosts; then
    log "hosts 已有国际化平台域名"
    return
  fi
  log "写入 /etc/hosts"
  printf '\n# your-agent: 公司 DNS 没有这些名字\n%s\n' "${line}" | sudo tee -a /etc/hosts >/dev/null
}

ensure_dirs() {
  mkdir -p "${BIN_DIR}" "${STATE_DIR}" "${WORK_ROOT}" "${HOME_DIR}/.local/bin"
  chmod 700 "${STATE_DIR}"
  if [[ -e "${HOME_DIR}/.multica" && ! -L "${HOME_DIR}/.multica" ]]; then
    die "${HOME_DIR}/.multica 已存在且不是软链接。请先挪走再安装。"
  fi
  ln -sfn "${STATE_DIR}" "${HOME_DIR}/.multica"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    log "Docker 已可用，不改它的数据目录"
    return
  fi
  [[ -r /etc/os-release ]] || die "无法识别系统，请先安装 Docker 再重新运行"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    rocky|rhel|centos|almalinux) ;;
    *) die "请先安装 Docker，然后重新运行 ./install.sh" ;;
  esac
  log "安装 Docker，数据目录 /data/docker"
  sudo dnf install -y dnf-plugins-core
  sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo mkdir -p /data/docker /etc/docker /etc/systemd/system/docker.service.d
  sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "data-root": "/data/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" }
}
EOF
  local proxy="${https_proxy:-${HTTPS_PROXY:-}}"
  if [[ -n "${proxy}" ]]; then
    sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null <<EOF
[Service]
Environment="HTTP_PROXY=${proxy}"
Environment="HTTPS_PROXY=${proxy}"
Environment="NO_PROXY=${NO_PROXY:-${no_proxy:-localhost,127.0.0.1}}"
EOF
  fi
  sudo systemctl daemon-reload
  sudo systemctl enable --now docker
  sudo usermod -aG docker "${USER_NAME}" || true
}

install_ops_cli() {
  [[ -x "${OPS_SRC}" ]] || die "仓库里没有 bin/ops-cli"
  cp -a "${OPS_SRC}" "${BIN_DIR}/ops-cli"
  chmod 755 "${BIN_DIR}/ops-cli"
  ln -sfn "${BIN_DIR}/ops-cli" "${HOME_DIR}/.local/bin/ops-cli"
}

install_multica_cli() {
  if [[ -x "${BIN_DIR}/multica" ]]; then
    ln -sfn "${BIN_DIR}/multica" "${HOME_DIR}/.local/bin/multica"
    return
  fi
  log "下载 Multica CLI ${MULTICA_VERSION}"
  local tgz="${STATE_DIR}/multica-cli.tgz"
  curl -fL --retry 3 -o "${tgz}" \
    "https://github.com/multica-ai/multica/releases/download/${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION#v}-linux-amd64.tar.gz"
  tar -xzf "${tgz}" -C "${BIN_DIR}" multica
  chmod 755 "${BIN_DIR}/multica"
  ln -sfn "${BIN_DIR}/multica" "${HOME_DIR}/.local/bin/multica"
}

write_env() {
  local front="$1" back="$2"
  python3 - "${MULTICA_DIR}/.env.example" "${MULTICA_DIR}/.env" "${front}" "${back}" <<'PY'
import re, secrets, base64, sys
from pathlib import Path
src, dst, front, back = sys.argv[1:]
text = Path(src).read_text()
repls = {
    "POSTGRES_PASSWORD": secrets.token_hex(24),
    "JWT_SECRET": secrets.token_hex(32),
    "MULTICA_VCS_SECRET_KEY": base64.b64encode(secrets.token_bytes(32)).decode(),
    "MULTICA_DINGTALK_SECRET_KEY": base64.b64encode(secrets.token_bytes(32)).decode(),
    "PORT": back,
    "FRONTEND_PORT": front,
    "FRONTEND_ORIGIN": f"http://127.0.0.1:{front}",
    "MULTICA_APP_URL": f"http://127.0.0.1:{front}",
    "MULTICA_IMAGE_TAG": "v0.6.3",
    "APP_ENV": "development",
    "MULTICA_DEV_VERIFICATION_CODE": "916425",
}
out = []
for line in text.splitlines():
    raw = line.split("#", 1)[0].strip()
    m = re.match(r"^([A-Z0-9_]+)=(.*)$", raw)
    if m and m.group(1) in repls:
        out.append(f"{m.group(1)}={repls[m.group(1)]}")
        continue
    if line.startswith("DATABASE_URL=postgres://"):
        out.append(f"DATABASE_URL=postgres://multica:{repls['POSTGRES_PASSWORD']}@localhost:5432/multica?sslmode=disable")
        continue
    out.append(line)
Path(dst).write_text("\n".join(out) + "\n")
Path(dst).chmod(0o600)
PY
}

start_stack() {
  if [[ -f "${STATE_DIR}/ports.env" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_DIR}/ports.env"
  fi
  if progress_has STACK && [[ -n "${BACKEND_PORT:-}" ]] && curl -fsS "http://127.0.0.1:${BACKEND_PORT}/readyz" >/dev/null 2>&1; then
    log "Multica 已在运行"
    return
  fi
  if [[ ! -d "${MULTICA_DIR}/.git" ]]; then
    log "拉取 Multica ${MULTICA_VERSION}"
    git clone --depth 1 --branch "${MULTICA_VERSION}" https://github.com/multica-ai/multica.git "${MULTICA_DIR}"
  fi
  if [[ ! -f "${MULTICA_DIR}/.env" ]]; then
    FRONTEND_PORT="$(pick_port "${FRONTEND_PORT_DEFAULT}")"
    BACKEND_PORT="$(pick_port "${BACKEND_PORT_DEFAULT}")"
    [[ "${FRONTEND_PORT}" != "${BACKEND_PORT}" ]] || BACKEND_PORT="$(pick_port "$((BACKEND_PORT + 1))")"
    write_env "${FRONTEND_PORT}" "${BACKEND_PORT}"
    printf 'FRONTEND_PORT=%s\nBACKEND_PORT=%s\n' "${FRONTEND_PORT}" "${BACKEND_PORT}" > "${STATE_DIR}/ports.env"
    chmod 600 "${STATE_DIR}/ports.env"
  fi
  # shellcheck disable=SC1090
  source "${STATE_DIR}/ports.env"
  log "启动 Multica（网页 ${FRONTEND_PORT}，API ${BACKEND_PORT}）"
  sudo docker compose --project-directory "${MULTICA_DIR}" -f "${MULTICA_DIR}/docker-compose.selfhost.yml" up -d
  local i
  for i in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${BACKEND_PORT}/readyz" >/dev/null 2>&1; then
      progress_set STACK
      return
    fi
    sleep 2
  done
  die "Multica 没有在 120 秒内就绪。看日志: sudo docker compose --project-directory ${MULTICA_DIR} -f ${MULTICA_DIR}/docker-compose.selfhost.yml logs backend"
}

ensure_cursor() {
  export PATH="${HOME_DIR}/.local/bin:${BIN_DIR}:${PATH}"
  if ! command -v agent >/dev/null 2>&1 && ! command -v cursor-agent >/dev/null 2>&1; then
    log "安装 Cursor CLI"
    curl -fsSL https://cursor.com/install | bash
  fi
  if command -v agent >/dev/null 2>&1 && ! command -v cursor-agent >/dev/null 2>&1; then
    ln -sfn "$(command -v agent)" "${HOME_DIR}/.local/bin/cursor-agent"
  fi
  command -v cursor-agent >/dev/null 2>&1 || die "未找到 cursor-agent。请先安装 Cursor CLI 后重新运行。"
  if ! cursor-agent status 2>&1 | grep -q "Logged in"; then
    log "请用浏览器打开下面的链接，完成 Cursor 登录"
    NO_OPEN_BROWSER=1 cursor-agent login
  fi
  cursor-agent status 2>&1 | grep -q "Logged in" || die "Cursor 仍未登录"
}

bootstrap_account() {
  # shellcheck disable=SC1090
  source "${STATE_DIR}/ports.env"
  export PATH="${HOME_DIR}/.local/bin:${BIN_DIR}:${PATH}"
  if progress_has ACCOUNT && [[ -f "${STATE_DIR}/config.json" ]]; then
    return
  fi
  local email
  if [[ -f "${STATE_DIR}/email" ]]; then
    email="$(cat "${STATE_DIR}/email")"
  else
    read -rp "本机登录邮箱（收不到邮件，只作账号名）: " email
    [[ "${email}" == *"@"* ]] || die "邮箱格式不对"
    printf '%s\n' "${email}" > "${STATE_DIR}/email"
    chmod 600 "${STATE_DIR}/email"
  fi
  log "创建本机账号 ${email}"
  EMAIL="${email}" BACKEND_PORT="${BACKEND_PORT}" STATE_DIR="${STATE_DIR}" python3 - <<'PY'
import json, os, urllib.request, urllib.error
from pathlib import Path
base = f"http://127.0.0.1:{os.environ['BACKEND_PORT']}"
email = os.environ["EMAIL"].strip().lower()
state = Path(os.environ["STATE_DIR"])

def call(method, path, payload=None, token=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"HTTP {e.code} {path}: {e.read().decode()[:400]}")

call("POST", "/auth/send-code", {"email": email})
login = call("POST", "/auth/verify-code", {"email": email, "code": "916425"})
jwt = login["token"]
ws_file = state / "workspace.json"
if ws_file.exists():
    ws = json.loads(ws_file.read_text())
else:
    host = os.uname().nodename.split(".")[0].lower()
    slug = "".join(ch if ch.isalnum() else "-" for ch in host).strip("-")[:40] or "agent"
    ws = call("POST", "/api/workspaces", {
        "name": host or "agent",
        "slug": slug,
        "description": "personal agent",
        "issue_prefix": "DEV",
    }, jwt)
    ws_file.write_text(json.dumps(ws))
    ws_file.chmod(0o600)
pat = call("POST", "/api/tokens", {"name": "daemon"}, jwt)
(state / "daemon.token").write_text(pat["token"] + "\n")
(state / "daemon.token").chmod(0o600)
print(ws.get("id", ""))
PY
  local token
  token="$(cat "${STATE_DIR}/daemon.token")"
  multica config set server_url "http://127.0.0.1:${BACKEND_PORT}"
  multica config set app_url "http://127.0.0.1:${FRONTEND_PORT}"
  multica config set workspaces_root "${WORK_ROOT}"
  multica config set device_name "$(hostname -s)"
  printf '%s\n' "${token}" | multica login --token
  rm -f "${STATE_DIR}/daemon.token"
  progress_set ACCOUNT
}

install_daemon() {
  export PATH="${HOME_DIR}/.local/bin:${BIN_DIR}:${PATH}"
  sudo tee /etc/systemd/system/your-agent.service >/dev/null <<EOF
[Unit]
Description=Personal agent daemon
After=docker.service network-online.target
Wants=docker.service

[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
Environment=HOME=${HOME_DIR}
Environment=PATH=${HOME_DIR}/.local/bin:${BIN_DIR}:/usr/local/bin:/usr/bin:/bin
ExecStart=${BIN_DIR}/multica daemon start --foreground
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable your-agent.service
  sudo systemctl restart your-agent.service
  local i
  for i in $(seq 1 30); do
    if multica runtime list 2>/dev/null | grep -q cursor; then
      progress_set DAEMON
      return
    fi
    sleep 2
  done
  die "daemon 没发现 Cursor。确认 cursor-agent 已登录后重新运行 ./install.sh"
}

create_agent() {
  export PATH="${HOME_DIR}/.local/bin:${BIN_DIR}:${PATH}"
  if progress_has AGENT && [[ -f "${STATE_DIR}/agent.id" ]]; then
    return
  fi
  local runtime_id agent_id
  runtime_id="$(multica runtime list --output json | python3 -c '
import json,sys
items=json.load(sys.stdin)
for it in items:
    if it.get("provider")=="cursor" or "cursor" in (it.get("name") or "").lower():
        print(it["id"]); break
')"
  [[ -n "${runtime_id}" ]] || die "没有 Cursor runtime"
  log "创建 Agent"
  agent_id="$(multica agent create \
    --name "助手" \
    --description "钉钉私聊指挥这台机器" \
    --runtime-id "${runtime_id}" \
    --model "grok-4.7-high-fast" \
    --visibility private \
    --max-concurrent-tasks 1 \
    --instructions "$(cat <<'EOF'
你在这台机器上执行任务。代码在这台机器已有的仓库里改，不要另克隆，除非任务明确要求。

没有明确要求时：不要 git push，不要部署，不要改生产配置，不要读取或打印密钥、token、.env。

回复用简体中文，先给结论。

查线上的实例、日志、指标、告警时使用 ops-cli，当前平台是 matchup。只查线上。测服暂时不能用 ops-cli 查，不要对测服调用 ops-cli。日志用 ops-cli log，不要改走 SSH。
EOF
)" --output json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  printf '%s\n' "${agent_id}" > "${STATE_DIR}/agent.id"
  chmod 600 "${STATE_DIR}/agent.id"
  progress_set AGENT
}

configure_ops() {
  export PATH="${HOME_DIR}/.local/bin:${BIN_DIR}:${PATH}"
  if progress_has OPS; then
    return
  fi
  local key
  key="$(prompt_secret "粘贴 matchup 的 SSO API Key（以 sk_ 开头，不会显示）")"
  printf '%s\n' "${key}" | ops-cli api-key set matchup --from-stdin
  ops-cli switch matchup
  ops-cli api-key test matchup
  progress_set OPS
}

configure_dingtalk() {
  export PATH="${HOME_DIR}/.local/bin:${BIN_DIR}:${PATH}"
  if progress_has DINGTALK; then
    return
  fi
  # shellcheck disable=SC1090
  source "${STATE_DIR}/ports.env"
  local cid secret agent_id ws_id
  read -rp "钉钉 Client ID: " cid
  secret="$(prompt_secret "钉钉 Client Secret（不会显示）")"
  [[ -n "${cid}" && -n "${secret}" ]] || die "钉钉凭证为空"
  agent_id="$(cat "${STATE_DIR}/agent.id")"
  ws_id="$(python3 -c 'import json; print(json.load(open("'"${STATE_DIR}"'/workspace.json"))["id"])')"
  log "连接钉钉机器人"
  DING_ID="${cid}" DING_SECRET="${secret}" AGENT_ID="${agent_id}" WS_ID="${ws_id}" \
    BACKEND_PORT="${BACKEND_PORT}" STATE_DIR="${STATE_DIR}" python3 - <<'PY'
import json, os, urllib.request, urllib.error
from pathlib import Path
cfg = json.loads((Path(os.environ["STATE_DIR"]) / "config.json").read_text())
body = json.dumps({
    "client_id": os.environ["DING_ID"].strip(),
    "client_secret": os.environ["DING_SECRET"].strip(),
}).encode()
url = (
    f"http://127.0.0.1:{os.environ['BACKEND_PORT']}"
    f"/api/workspaces/{os.environ['WS_ID']}/dingtalk/install/byo"
    f"?agent_id={os.environ['AGENT_ID']}"
)
req = urllib.request.Request(url, data=body, method="POST")
req.add_header("Content-Type", "application/json")
req.add_header("Authorization", "Bearer " + cfg["token"])
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode() or "{}")
except urllib.error.HTTPError as e:
    raise SystemExit(f"钉钉连接失败 HTTP {e.code}: {e.read().decode()[:400]}")
print("dingtalk", data.get("status", "ok"))
PY
  progress_set DINGTALK
}

main() {
  [[ "$(uname -m)" == "x86_64" ]] || die "目前只支持 Linux x86_64"
  [[ -d /data ]] || die "没有 /data。程序和数据要放在 data 盘"
  need git; need curl; need python3; need openssl; need ss
  sudo -v
  if [[ -f "${MULTICA_DIR}/.env" && ! -f "${PROGRESS}" ]]; then
    die "这台机器已有 ${MULTICA_DIR}，不是本脚本安装的。为避免改掉现有助手，已停止。请在新机器上运行。"
  fi
  ensure_dirs
  ensure_hosts
  install_docker
  install_ops_cli
  install_multica_cli
  start_stack
  ensure_cursor
  bootstrap_account
  install_daemon
  create_agent
  configure_ops
  configure_dingtalk
  # shellcheck disable=SC1090
  source "${STATE_DIR}/ports.env"
  log "安装完成"
  cat <<EOF
钉钉：私聊你自己的机器人下指令。不用填验证码。
网页：SSH 后执行 ssh -L ${FRONTEND_PORT}:127.0.0.1:${FRONTEND_PORT} <这台机器>
      浏览器打开 http://127.0.0.1:${FRONTEND_PORT} ，验证码 ${VERIFY_CODE}
ops-cli：只查线上 matchup。测服不要用它查。
EOF
}

main "$@"
