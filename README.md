# mpv-autosub

播放视频时自动为 [mpv](https://mpv.io/) 搜索并下载中文字幕。

> **系统适配：仅适配 Windows**，已在 **Windows 11** 测试通过。

## 特性

- **播放即下字幕**：视频加载后自动查找并下载中文字幕，无需手动操作
- **三级查找**：本地已有字幕 → moviehash 精确匹配 → 标题搜索
- **相关性校验**：比对年份与关键词，尽量避免下到不相关的字幕
- **状态可见**：每一步都通过 OSD 实时显示在画面上
- **依赖负担低**：curl 系统自带；Python 自动检测/安装，缺失也不影响播放
- **手动触发**：播放时按 `m` 键随时重试

## 安装

> 需要 `curl`（Windows 10 及以上自带，无需单独安装）。
> Python 为可选项，仅用于计算 moviehash，脚本会自动检测并尝试安装。

### Portable 模式

把 `autosub.lua` 放进 mpv 程序目录下的 `scripts` 文件夹：

```
<mpv 目录>\portable_config\scripts\autosub.lua
```

### 非 Portable（安装版）

把 `autosub.lua` 放进用户配置目录：

```
%APPDATA%\mpv\scripts\autosub.lua
```

即 `C:\Users\<用户名>\AppData\Roaming\mpv\scripts\autosub.lua`（目录不存在请手动创建）。

放好后重启 mpv 即可。

## 配置

用任意文本编辑器打开 `autosub.lua`，修改**文件开头**的 `o = { ... }`：

```lua
local o = {
    -- 在此填写你的 OpenSubtitles 凭据（留空会在播放时提示）
    os_api_key  = "",
    os_username = "",
    os_password = "",

    -- 文件名优先（适合手动规范命名的用户）
    prefer_filename = true,

    language = "zh-cn,zh-tw,zh",
    min_duration = 900,
    debug = false,
}
```

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `os_api_key` | `""` | **必填**，OpenSubtitles API Key |
| `os_username` | `""` | **必填**，OpenSubtitles 用户名 |
| `os_password` | `""` | **必填**，OpenSubtitles 密码 |
| `prefer_filename` | `true` | 优先使用文件名匹配（适合手动规范命名） |
| `language` | `zh-cn,zh-tw,zh` | 字幕语言优先级 |
| `min_duration` | `900` | 最短视频时长（秒），短于该值不处理 |
| `debug` | `false` | 输出调试日志 |

### 获取 OpenSubtitles 凭据

1. 注册 [OpenSubtitles.com](https://www.opensubtitles.com/) 账号
2. 在 [用户设置 → API](https://www.opensubtitles.com/en/consumers) 申请 API Key
3. 把 API Key、用户名、密码填入上面的 `o = { ... }`

> ⚠️ 三个凭据留空或填写错误时，脚本会在屏幕上给出提示，不会静默失败。
> **请勿把自己的凭据提交或分享给别人。**

## 使用

- 打开视频后脚本自动运行，注意屏幕上的 OSD 提示
- 手动触发：播放时按 `m` 键
- 下载的字幕保存为与视频同名的 `.zh.srt`

## 工作原理

加载视频后依次执行：

1. **本地已有字幕？** 检查视频同目录（含 `sub/`、`Subs/`、`subtitles/` 等子目录）是否已有中文字幕（`.zh.srt`、`.chs.srt` 等），有则直接加载，不联网。
2. **moviehash 匹配**：计算视频文件的哈希，向 OpenSubtitles 查询完全对应的字幕，并对结果做相关性校验。
3. **标题搜索**：从文件名 / 媒体标题中提取片名，优先用英文 release 名（带年份）搜索，失败后再用中文名兜底。
4. **下载**：把命中的字幕保存为 `<视频名>.zh.srt`，并让 mpv 重新扫描外挂字幕。

> moviehash 需要对 64 位无符号整数做累加，而 LuaJIT 不支持 Lua 5.3 的位运算符（`<<` 等）与原生 64 位整数，因此该步骤改由 Python 完成；Python 不可用时自动跳过第 2 步，不影响播放。

## 常见问题

**Q：屏幕提示「未填写 OpenSubtitles 凭据」？**
A：打开 `autosub.lua`，填写文件开头的 `os_api_key` / `os_username` / `os_password`。

**Q：提示「登录失败」？**
A：检查用户名、密码、API Key 是否正确，以及账号是否已激活。OpenSubtitles 免费账号有每日下载配额，用尽后需等待或升级。

**Q：一直找不到字幕？**
A：可能原因：文件名不含片名/年份、视频短于 `min_duration`、或该片确实没有中文字幕。可手动把文件名规范成「片名 + 年份」后按 `m` 重试。

**Q：一定要装 Python 吗？**
A：不需要。Python 仅用于 moviehash 精确匹配，没有它也能正常下载字幕（脚本会尝试自动安装）。

**Q：下载的字幕没有自动加载？**
A：按 `m` 重新触发一次，或检查视频所在目录是否有写入权限。

**Q：按 `m` 没反应？**
A：`m` 键可能与你使用的其它 mpv 脚本冲突，可修改 `autosub.lua` 末尾的 `mp.add_key_binding("m", ...)`。

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
