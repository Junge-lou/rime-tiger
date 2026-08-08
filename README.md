# Rime 虎码配置

这是虎码的 Rime 配置文件，来源于秃包版本，并在此基础上做了个人化调整。

## 方案列表

本配置保留两个用户常用方案：

- `tiger`：虎码官方单字
- `tigress`：虎码官方词库
- `PY_c`：拼音方案

`tiger` 和 `tigress` 底层加载全字集词典，默认开启常用字过滤。按 `Ctrl+H` / `Ctrl+Shift+H` 可以在“常用字”和“全字集”之间切换。这个状态是普通 Rime option：关为常用字，开为全字集；已加入 `switcher/save_options`，并由 `lua/option_sync.lua` / `lua/option_state.lua` 做跨窗口同步。

`tiger` / `tigress` 使用同一份全字集词典入口，并通过 `extended_char` 开关在常用字和全字集之间切换。历史全字集独立方案文件已经移除；如果部署后方案菜单仍停在已删除旧方案，请重新选一次 `tiger` 或 `tigress`。

## 官方码表自动同步

`tigress` 字词方案每天北京时间 06:00 自动检查
[`lvyww/tiger-code`](https://github.com/lvyww/tiger-code) 的官方字词码表，也可以在
GitHub Actions 中手动触发。同步范围仅包括 `tigress` 的单字、四码词、简词及其常用版；
不会修改 `tiger` 单字方案或用户词典。

同步使用上一版官方快照识别新增、删除和改码，同时保留本仓库额外的全字集记录及现有
字频。只有码表校验和仓库全部测试通过后，工作流才会直接提交到 `main`；异常数据、测试
失败或推送冲突都不会产生提交。仓库需要允许 GitHub Actions 的 `GITHUB_TOKEN` 写入
contents，并确保 `main` 的分支保护允许该工作流推送。

## 用户词管理

`tiger` 和 `tigress` 都支持加词、减词和候选调序，操作只影响当前方案。两个方案继续加载各自的手工用户词典：

- `tiger.user.dict.yaml`
- `tigress.user.dict.yaml`

两个方案都会导入自己的用户层，因此功能一致但新增内容不会互相串用。首次启用新版逻辑时，已有用户词典和旧版禁用标记会迁移到 Rime 用户数据库；之后的加词、减词、调序只写入用户数据库，不再改写官方码表。更新仓库或覆盖官方码表后，用户操作仍会继续生效。

用户数据分两处保存：手工维护的词条仍在上述 `*.user.dict.yaml` 文件中；通过快捷键产生的加词、减词和调序记录，分别存入名为 `tiger_user_words_tiger`、`tiger_user_words_tigress` 的 LevelDB 数据库。数据库由 Rime 管理并放在用户数据目录中，常见位置是 macOS 的 `~/Library/Rime`、Windows 的 `%APPDATA%\Rime`；Linux 的位置随前端而异，例如 Fcitx5 通常使用 `~/.local/share/fcitx5/rime`。实际数据库文件名可能因 Rime 版本和前端不同而带有不同后缀，不建议直接编辑；备份时直接备份整个 Rime 用户数据目录即可。

## 顿号与符号菜单

`/` 键现在只输出顿号 `、`。

旧版 `/bd`、`/pi`、`/bq` 等符号命令迁移到反斜杠：

- `\bd`：标点符号
- `\bq`：表情
- `\pi`：π
- `\sz`：色子
- `\chol`：切换火星文

输入 `\`、`\b`、`\p` 等前缀时，候选框会提示可用符号命令。

## 空码与符号顶字

`tiger`、`tigress` 都接入了空码标顶清屏和候选唯一时符号顶字：

- 空码时按符号，会清掉错误编码并吞掉这次符号。
- 候选唯一时按符号，会先上屏唯一候选，再让该符号继续生效。
- 有第二候选时不顶字，继续交给原有选重逻辑，例如 `;` 仍然选二候选，`'` 仍然选三候选。

## 加词、减词、调序

该功能同时接入 `tiger` 和 `tigress`，对当前方案的单字或词语候选都生效。

快捷键：

- `Ctrl+;`：进入加词模式。
- `编码 + \\ + Space`：在目标编码后连续输入两个反斜杠，再按空格进入加词模式；用于 `Ctrl+;` 被系统或应用占用时。
- `Ctrl+'`：进入减词模式，并默认带入当前高亮候选词。
- `Enter`：在加词/减词模式中确认。
- `Esc`：退出加词/减词模式。
- `Backspace`：删除正在输入的取字编码；没有取字编码时，删除已经取到的最后一个字。
- macOS 推荐 `Ctrl+Option+方向键`；Windows/Linux 可继续使用 `Ctrl+方向键`。
- `Ctrl+上/左` 或 `Ctrl+Option+上/左`：当前高亮候选前移一位。
- `Ctrl+下/右` 或 `Ctrl+Option+下/右`：当前高亮候选后移一位。
- `Ctrl+Home` 或 `Ctrl+Option+Home`：当前高亮候选移到当前页第一位。
- `Ctrl+End` 或 `Ctrl+Option+End`：当前高亮候选移到当前页最后一位。

`tiger` 和 `tigress` 的加词、减词、调序状态写入各自独立的 Rime 用户数据库，不会修改当前方案的官方码表。首次迁移后，`tiger.user.dict.yaml` / `tigress.user.dict.yaml` 仍可作为手工用户词典使用；通过快捷键产生的记录不再依赖这两个文件。

双反斜杠入口只识别“正常编码末尾的两个反斜杠”。以反斜杠开头的 `\\djs`、`\\tj` 等命令仍交给原命令组件处理，不会被当作加词或发生转义。

## 倒计时

输入 `\djs` 显示倒计时，第 9 位固定为“管理倒计时”。进入管理后可新增、编辑、删除和恢复默认倒计时。

新增事件名时，选“新增倒计时”后会清空输入；直接正常打编码，输入期间会显示当前事件名状态，选候选后追加到事件名并清空输入，可继续打下一段，事件名填好后按 `Enter` 进入历法选择。日期输入使用 `YYYYMMDD`，可选公历或农历。

倒计时排序使用 `Command+上/左`、`Command+下/右` 调整当前高亮倒计时的位置；虎词词序排序仍使用 `Ctrl+方向` 或 `Ctrl+Option+方向`。

## 拼音与拆分提示

拼音滤镜已去掉注释里的全角圆括号。候选框显示拼音或拆分时，可以用：

- `Ctrl+Shift+Enter`：上屏候选注释中的拼音或拆分内容。

用户设置菜单里的拼音、拆分开关后面也会提示这个快捷键。

## 火星文滤镜

`tiger`、`tigress`、`PY_c` 都接入了火星文滤镜：

- 在方案选单/选项菜单里切换 `火星文 关 \chol` / `火星文 开 \chol`。
- 输入 `\chol` 并确认候选，也可以切换火星文开关。
- 火星文、测速统计、拼音提示、拆分提示等功能开关已加入 `switcher/save_options`，并由 `lua/option_sync.lua` / `lua/option_state.lua` 做跨窗口即时同步。
- 火星文数据来自 `zhanyuzhang/text-convert` 的 `convert.js`，保存在 `lua/mars_data.lua`。
- `lua/mars.lua` 只常驻轻量滤镜壳；`mars_data.lua` 会在火星文开关开启后首次处理候选时加载，关闭后释放映射表引用并触发一次 Lua GC。
- 移植到其他 Rime 配置时，复制 `lua/mars.lua`、`lua/mars_data.lua`、`lua/option_state.lua`；需要跨窗口同步普通开关时再复制 `lua/option_sync.lua` 并加 `lua_processor@*option_sync`。目标方案里还要加 `mars` 开关、`lua_processor@*mars*processor`、`lua_translator@*mars*translator` 和 `lua_filter@*mars`；不需要改 `rime.lua` 预加载。

## 鼠须管皮肤

仓库包含 `squirrel.custom.yaml`。在 macOS 鼠须管下部署后，会使用当前配置里的皮肤和配色；Windows 小狼毫仍使用 `weasel.custom.yaml`。
