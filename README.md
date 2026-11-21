# xray-manager 
### v 0.2.8
### 2026-11-22
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
xray
```
- 快速调用脚本
- 按需求装代理
- 提供完整卸载
<br>

### 局限说明
- xhttp 只做了 v4 v6 分离，刚需双栈机器，此脚本不支持 CDN 分离方案
- 若 xray 内核过新，sing-box 等客户端将无法使用订阅，此脚本仅考虑 xray 客户端兼容性
- 倡导代理 vps 仅做代理，强制采用 nginx 前置过滤 sni 的方案搭建 reality，可能会影响其他服务

### License
MIT
