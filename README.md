# xray-manager

A Multifunctional Proxy Tool Based on Xray

整合了 vless-enc 等功能的 xray 代理工具箱

具备自启 bbr + fq 及校正时间的功能（代理友好）

可自动从 12 个备选 sni 中选择 tls 握手最快的支持自定义

支持双栈小鸡进行 v4 v6 上下行分离，也支持端口复用直出 + 至多 3 个落地

## 主界面
<p align="center">
  <img src="main.jpg" alt="主界面" width="800">
</p>


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
## 使用

按 3 次 1，一直回车即可完成 Reality 直出的安装

安装代理时若想简单，选择自动

若想进行一些自定义设置，选择手动

若想进行更精细的设置，可用 8 号功能修改

ss2022 和 vless-enc 均不推荐过墙，均有封 ip 风险

vless-enc 的 padding 建议有经验再自行填充，官方默认值足够好

xhttp 只做了基于 v4 v6 的上下行分离，所以刚需双栈小鸡，客户端仅推荐 v2rayN 因为需要填 xhttp extra

## XHTTP 订阅示例



## 卸载

选项 9 可仅删除脚本或 xray 和脚本一起删除
