# xray-manager 
### v 0.2.7
### 2026-11-07
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
- 若 xray 内核过新，sing-box 客户端将无法使用订阅，此脚本仅考虑 xray 客户端兼容性
<br>

### License
MIT
