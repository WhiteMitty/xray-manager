# xray-manager 
### v 0.1.0 2026-04-15 

#### 常规安装

#### curl

```bash
curl -fsSL -o xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh && bash xray-manager.sh
```

#### wget

```bash
wget -qO xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh && bash xray-manager.sh
```
<br>

#### 启动脚本

```bash
zdd xray
```

#### 启动脚本并安装

```bash
zdd install
```
#### 更新脚本和 Xray (不包括 SS-Rust)

```bash
zdd update
```

#### 完整卸载 脚本 Xray SS-Rust 及各种配置

```bash
zdd uninstall
```

<br>

#### ⚠ 慎用！全自动覆盖安装！ ![warning](https://img.shields.io/badge/Warning-无法取消-red)

#### curl

```bash
curl -fsSL -o xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh && printf '1\n1\n1\n1\n' | bash xray-manager.sh --quick-install
```

#### wget

```bash
wget -qO xray-manager.sh https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh &&  printf '1\n1\n1\n1\n' | bash xray-manager.sh --quick-install
```
<br>

#### -  推荐 Xray 内核的代理如 v2rayN Exclave
#### - xhttp 只做了 v4 v6 分离，刚需双栈机器
#### - SS-Rust 除阿尔卑斯系统外不会额外安装，所以也没设置更新选项
#### - 仅 1、4、7 号方式中的 reality 适合直连，8 号为激进玩法，容易被墙
#### - 确保 443、8443 未被占用，防火墙已放行，Reality 写死 443/8443 端口
#### - 因本身带管理运维功能，所以脚本会留在 vps 上，若嫌弃可以用 9 号功能删除

<br>

<h4 align="left">主界面</h4>
<p align="left">
  <img src="main.jpg" alt="主界面" width="900">
</p>

<h4 align="left">代理安装界面</h4>
<p align="left">
  <img src="install.jpg" alt="安装界面" width="900">
</p>

<h4 align="left">用订阅链接链式代理</h4>
<p align="left">
  <img src="landing.jpg" alt="端口复用" width="900">
</p>




