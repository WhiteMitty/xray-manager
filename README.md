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
<br>

### 局限说明
- xhttp 只做了 v4 v6 分离，刚需双栈机器，脚本未引入 CDN 方案的分支
- nginx 前置过滤 sni 的方案搭建 Reality 是为了防偷，但可能会影响其他服务
- 此脚本仅考虑 xray 客户端兼容性，而随着 xray 的更新，sing-box 等客户端不一定支持
<br>

### License
MIT
