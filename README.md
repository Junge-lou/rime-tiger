# Rime 虎码配置

这是虎码的 Rime 配置文件，来源于秃包版本，并在此基础上做了个人化调整。

## 主要改动

- 去掉 `'` 的复选相关行为。
- 关闭候选框超长时的自动翻转。
- 在虎词 `tigress` 方案中集成用户加词、减词和候选词序调整功能。

## 虎词加词、减词、调序

该功能只接入 `tigress`，没有接入 `tiger`。

### 快捷键

- `Ctrl+;`：进入加词模式。
- `Ctrl+'`：进入减词模式，并默认带入当前高亮候选词。
- `Enter`：在加词/减词模式中确认。
- `Esc`：退出加词/减词模式。
- `Backspace`：删除正在输入的取字编码；没有取字编码时，删除已经取到的最后一个字。
- `Ctrl+上` 或 `Ctrl+左`：当前高亮候选前移一位。
- `Ctrl+下` 或 `Ctrl+右`：当前高亮候选后移一位。
- `Ctrl+Home`：当前高亮候选移到当前页第一位。
- `Ctrl+End`：当前高亮候选移到当前页最后一位。

### 加词流程

1. 正常输入目标编码，例如先打出要挂词的编码。
2. 按 `Ctrl+;` 进入加词模式。
3. 输入组成新词的单字编码。
4. 用空格、数字、`;` 或 `'` 选择候选字，已取到的字会显示在提示里。
5. 按 `Enter` 确认加词。

### 减词流程

1. 正常输入编码，让候选列表出现。
2. 把焦点移动到要减掉的候选词。
3. 按 `Ctrl+'` 进入减词模式，当前高亮候选会自动填入。
4. 确认无误后按 `Enter`。

如果默认带入的词不是目标词，可以用 `Backspace` 删除后重新取字。

### 调整词序

调词序不需要进入加词或减词模式。正常输入编码并移动焦点到目标候选后，直接使用 `Ctrl+方向键`、`Ctrl+Home` 或 `Ctrl+End` 即可。

当前实现调整的是当前页可见候选顺序。调整后焦点会跟随被移动的词，方便连续调整。

## 数据保存方式

用户加词和调序会写入 `tigress.extended.dict.yaml` 的自动生成区。减词会在匹配到的词库条目前写入禁用标记并注释原条目，同时也会在扩展词库记录操作历史。

涉及的词库文件：

- `tigress.extended.dict.yaml`
- `tigress.dict.yaml`
- `tigress_ci.dict.yaml`
- `tigress_simp_ci.dict.yaml`

这样重新部署后，用户加过的词、减掉的词和调整过的顺序仍然生效。

## 只移植加减词和调序功能

如果只想把这个功能加到自己的 Rime 配置里，需要复制和修改这些文件。

### 需要复制

- `lua/tigress_user_words.lua`

如果保留文件名和模块名不变，schema 中也要按下面的名字接入。

### 需要修改 schema

在目标方案的 `engine/processors` 中，把 Lua processor 放在 `key_binder` 前面：

```yaml
engine:
  processors:
    - ascii_composer
    - recognizer
    - lua_processor@*tigress_user_words*processor
    - key_binder
```

在目标方案的 `engine/filters` 中，把 Lua filter 放在普通简繁、注释、去重等 filter 前面：

```yaml
engine:
  filters:
    - lua_filter@*tigress_user_words*filter
    - uniquifier
```

如果原方案已经有类似 `lua_filter@core2022` 这种字集过滤器，可以保留在它后面：

```yaml
engine:
  filters:
    - lua_filter@core2022
    - lua_filter@*tigress_user_words*filter
    - simplifier@simplification
    - uniquifier
```

### 需要按自己的词库改 Lua 配置

打开 `lua/tigress_user_words.lua`，修改顶部的 `config`：

```lua
local config = {
    extended_dict = "tigress.extended.dict.yaml",
    source_dicts = {
        "tigress.extended.dict.yaml",
        "tigress.dict.yaml",
        "tigress_ci.dict.yaml",
        "tigress_simp_ci.dict.yaml",
    },
    weight_base = 100000000000,
    weight_step = 1000,
}
```

- `extended_dict`：用户加词和调序写入的扩展词库。
- `source_dicts`：减词时会搜索并注释的词库文件列表。

移植到其他方案时，把这些文件名改成自己方案实际使用的词库文件名。

### 注意事项

- 目标方案需要支持 Lua。
- 修改 schema 后需要重新部署 Rime。
- 如果目标方案已经占用了 `Ctrl+;`、`Ctrl+'` 或 `Ctrl+方向键`，需要在 Lua 里调整快捷键。
- 这个功能不依赖 Rime 用户词库 DB；它会直接写入 YAML 词库文件。
