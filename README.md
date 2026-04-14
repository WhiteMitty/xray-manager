# xray-manager 
## v 0.1.0 2026-04-13 

<br>

## 常规安装

## curl

```bash
curl -fsSL -o xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh && bash xray-manager.sh
```

## wget

```bash
wget -qO xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh && bash xray-manager.sh
```
<br>

## 启动脚本

```bash
zdd xray
```

## 启动脚本并安装

```bash
zdd install
```
## 更新脚本和 Xray (不包括 SS-Rust)

```bash
zdd update
```

## 完整卸载 脚本 Xray SS-Rust 及各种配置

```bash
zdd uinstall
```

<br>

## ⚠ 慎用！全自动安装，此脚本将覆盖原先所有配置！ ![warning](https://img.shields.io/badge/Warning-无法取消-red)

## curl

```bash
curl -fsSL -o xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh && printf '1\n1\n1\n1\n' | bash xray-manager.sh --quick-install
```

## wget

```bash
wget -qO xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh &&  printf '1\n1\n1\n1\n' | bash xray-manager.sh --quick-install
```
<br>

## SS-Rust 除阿尔卑斯系统外不会额外安装，所以也没设置更新选项
## 仅 1、4、7 号方式中的 reality 适合直连，8号为激进玩法，容易被墙
## 确保 443、8443 未被占用，防火墙已放行，Reality 写死 443/8443 端口

<br>

<h2 align="left">主界面</h2>
<p align="left">
  <img src="main.jpg" alt="主界面" width="900">
</p>

<h2 align="left">安装界面</h2>
<p align="left">
  <img src="install.jpg" alt="安装界面" width="900">
</p>

<h2 align="left">粘贴落地链接</h2>
<p align="left">
  <img src="landing.jpg" alt="端口复用" width="900">
</p>

<h2 align="left">节点订阅界面</h2>
<p align="left">
  <img src="node_sub.jpg" alt="订阅界面" width="900">
</p>

<br>

## xhttp 使用

## xhttp 只做了 v4 v6 上下行分离，刚需双栈小鸡，
## 客户端仅推荐 v2rayN 因除订阅还要填 xhttp extra

<br>

## 复制此处 json 
![v1演示](xhttp_json.jpg)

<br>

## 在此处粘贴 
![v2演示](v2rayN.jpg)

<br>

![v3演示](xhttp_extra.jpg)

<br>

## 完整卸载
![v4演示](unistall.jpg)

## 9 号功能可完整卸载脚本和 xray 及各种配置文件

## 因本身带管理运维功能，所以脚本会留在 vps 上，若嫌弃可以选仅删除脚本
