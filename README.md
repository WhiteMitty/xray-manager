# xray-manager 
### v 0.2.8
### 2026-11-23
### 准备工作
- Debian / Ubuntu / Alpine 环境
- root 权限
- 已安装 curl / wget 和 bash
<br>

### 安装脚本
#### curl
```bash
curl -fsSL -o xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh && bash xray-manager.sh
```
#### wget
```bash
wget -qO xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh && bash xray-manager.sh
```
<br>

### 快捷命令
```bash
zxray
```
- 快速调用脚本
- 按需求装代理
- 提供完整卸载
<br>

### 局限说明
- xhttp 只做了 v4 v6 分离，刚需双栈机器，此脚本不支持 CDN 分离方案
- sni 依旧选取大厂，虽避免了苹果微软等域名，但建议自筛更合适的 sni 或采用偷自己方案
- 因为 xray 更新策略，sing-box 等客户端将无法使用订阅，此脚本仅考虑 xray 客户端兼容性
- 推荐代理 vps 仅做代理，如果采用 nginx 前置过滤 sni 的方案搭建 reality，可能会影响其他服务，若不前置配大厂 SNI 则可能被偷流量（即使未用 CF CDN SNI）

### License
MIT
