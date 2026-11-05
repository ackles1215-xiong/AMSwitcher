# AMSwitcher

专为 macOS Apple Music 设计的自动采样率切换工具，基于 [Arczotis/MusicRateSwitcher](https://github.com/Arczotis/MusicRateSwitcher) 修改。

## 本分支的变化

- 只启用 Apple Music 数据源，不启动网易云、QQ 或汽水音乐监视器。
- 专辑封面独立显示；背景提取封面平均色生成渐变，歌曲与播放按钮位于深色安全区。
- 通过 Apple Music 自动化接口读取当前歌曲、歌手、专辑封面，并提供上一首、播放/暂停、下一首。
- 移除多播放器开关、网易云缓存授权入口、首次欢迎弹窗、Star 按钮和宣传链接。
- 支持采样率默认折叠；重新检测与诊断仍然保留。
- 保留 music+ 外部监听器的唤醒方式，不在本应用提供重复的登录启动开关。

## 运行与权限

首次打开播放面板时，macOS 可能询问是否允许控制“音乐”。此权限用于读取曲目信息/封面和响应播放按钮；不参与实际采样率检测。

部分流媒体歌曲、推荐或电台可能无法通过 Apple Music 自动化接口返回曲目信息。失败时显示静态占位，不阻塞日志解析或采样率匹配。切换曲目会清除旧封面，避免显示上一首的图片。

封面仅在面板打开时读取。面板关闭后不进行定时封面轮询；图像缩小至最长边 512 像素，并只保留当前封面及两种渐变色。读取过程带超时，临时文件随后删除。

采样率继续使用原项目的 Apple Music 系统日志检测和 Core Audio 设备控制。封面/专辑的音质标签不会用于推断实际播放采样率。有损 AAC 不保证触发采样率切换。

## 与 music+ 配合

应用显示名及包名是 **AMSwitcher.app**，内部可执行文件与 bundle identifier 保留兼容：

- 可执行文件：`MusicRateSwitcher`
- Bundle identifier：`io.github.music-rate-switcher`

因此 music+ 仍可按 bundle identifier 启动它。正式替换安装前应退出并备份旧版，避免两个相同 identifier 的版本被系统同时识别。当前开发产物位于隐藏的 `.build/app/`，不会主动替换 `/Applications` 中的原应用。

仅启用 music+ 的登录启动。无需同时让 AMSwitcher 登录启动。

## 构建和检查

需要 macOS 13+ 及合适版本的 Xcode / Swift。

```sh
./scripts/build-app.sh
./scripts/run-tests.sh
```

应用产物：`.build/app/AMSwitcher.app`。

调试界面渲染：

```sh
swift build -c debug --product MusicRateSwitcher
"$(swift build -c debug --show-bin-path)/MusicRateSwitcher" --snapshot .build/preview
```

真实 Apple Music 元数据检查（只读取，不运行采样率控制器）：

```sh
"$(swift build -c debug --show-bin-path)/MusicRateSwitcher" --metadata-check .build/live-check
```

`--metadata-check` 需要 Music 正在播放且自动化授权可用，生成的图片仅保存在被忽略的 `.build/` 中。不要把个人播放记录、专辑图片或诊断日志提交至仓库。

## 已验证与限制

- 实际歌曲名称、歌手、封面读取与图像尺寸限制已验证。
- 浅色/深色、占位与播放状态的界面渲染已检查。
- 原有 40 项解析、采样率匹配等检查通过。
- 推荐/电台、连续切歌和最终安装后的首次授权仍需进一步现场验证。
- 共享 Core 库中保留上游的其他播放器实现及测试，便于后续同步；本应用仅创建 Apple Music 监视器。

## 开源许可

MIT。原项目：MusicRateSwitcher / Arczotis；许可证中的版权声明保持不变，完整文本见 [LICENSE](LICENSE)。应用的“更多 → 开源许可”也包含许可全文。
