# xray-manager

A Multifunctional Proxy Tool Based on Xray

整合了 vless-enc 等功能的 xray 代理工具箱
具备自启 bbr + fq 及校正时间的功能（代理友好）
可自动从 12 个备选 sni 中选择 tls 握手最快的支持自定义
支持双栈小鸡进行 v4 v6 上下行分离，也支持端口复用直出 + 至多 3 个落地

## 安装

### curl

```bash
curl -fsSL -o xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh && bash xray-manager.sh
```

### wget

```bash
wget -qO xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh && bash xray-manager.sh
```
## 调用

```bash
zdd xray
```

## 卸载

选项 9 可仅删除脚本或 xray 和脚本一起删除
