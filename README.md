# 个人助手

在自己的 Linux 机器上装一套。钉钉私聊下指令，网页登录不发邮件。任务记录留在这台机器的 data 盘，不进 Multica 公有云。

仓库：<https://github.com/YukunWork/your-agent>

设计说明：<https://intl-wiki.p1.cn/pages/viewpage.action?pageId=114929773>

## 先准备

机器：Linux x86_64，能 `sudo`，有 `/data`。

三把钥匙自己申请，不要发到群里，也不要提交到 Git：

1. Cursor 账号。安装时脚本会给出登录链接。
2. ops-cli 的 API Key。说明见 [国际化 Ops-cli 使用说明](https://intl-wiki.p1.cn/pages/viewpage.action?pageId=114920065)。Omi / CoCome 打开 [账号页](https://intl-oss.p1.cn/user/basic)，进入「账号 → API Keys」新建。来源 IP 填 `10.0.0.0/8`，最低 ops-cli 版本留空。完整 Key 以 `sk_` 开头，只显示一次。
3. 钉钉 Stream 机器人的 Client ID 和 Client Secret。打开 [钉钉开发者后台](https://open-dev.dingtalk.com/)，应用开发 → 创建企业内部应用。左侧「凭证与基础信息」复制 Client ID、Client Secret。再在「添加应用能力 → 机器人」里把消息接收模式选成 **Stream**，不要填 HTTP 地址。最后到「版本管理与发布」发布一版，不发布则钉钉里找不到这个机器人。不要把机器人加进群。

## 安装

```bash
git clone git@github.com:YukunWork/your-agent.git
cd your-agent
./install.sh
```

脚本会问：登录邮箱、Cursor 登录、API Key、钉钉 Client ID / Secret。邮箱收不到信，只当作本机账号名。

中途失败可以再执行一次 `./install.sh`，已完成的步骤会跳过。

如果提示「已有 multica，不是本脚本安装的」，说明这台机器上已经有一套助手。不要继续，换一台机器。

## 装完怎么用

钉钉里私聊自己的机器人。例如：`用 ops-cli log 查某服务今天 10:30 到 10:45 的 error，按类型贴一条关键日志。不要 SSH。`

查线上实例、日志、指标、告警走 ops-cli，平台是 matchup。测服不要用 ops-cli。

要看网页时，在自己电脑上把端口转过来（端口以安装结束时打印的为准，默认 13080）：

```bash
ssh -L 13080:127.0.0.1:13080 <你的机器>
```

浏览器打开 `http://127.0.0.1:13080`，验证码填 `916425`。这个码只用于网页，钉钉不用填。
