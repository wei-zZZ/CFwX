✅ 自动识别 HK / LA 角色
✅ 自动安装：cloudflared + WARP + xray
✅ HK 作为入口 + 分流
✅ LA 作为中继出口
✅ CF Tunnel 组内网
✅ 可重复执行 / 可卸载

⚠️ 说明一句：
Cloudflare Tunnel 的 login 授权步骤必须人工完成一次（CF 官方限制），脚本会在正确的地方停下来让你操作。

一、使用方式（先看）
1️⃣ 在 HK / LA 两台服务器都执行

```


curl -sSL -o install-singbox.sh https://raw.githubusercontent.com/wei-zZZ/CFwX/main/install-singbox.sh && chmod +x install-singbox.sh && sudo ./install-singbox.sh
```
脚本会自动：

判断服务器地区（HK / US）

US → 设为 LA 节点

非 US → 设为 HK 节点

2️⃣ 卸载 / 回滚
bash install.sh uninstall

三、你部署完后应当是这样
✔ HK

客户端入口

GeoIP 分流

亚区 → 本机 → WARP

美区 → LA → WARP

✔ LA

不暴露公网

只接 HK

只负责出美区

四、我强烈建议你下一步做的两件事

1️⃣ 把 UUID / 域名改成你自己的
2️⃣ 加 NO_PROXY，防止 WARP 套 Tunnel

systemctl edit cloudflared

[Service]
Environment=NO_PROXY=127.0.0.1,localhost

