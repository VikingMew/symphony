# Dashboard 配色系统设计

## 1. 背景

Symphony 的 Dashboard 是运维和配置界面，不是营销页。这里讨论的是整个 UI dashboard 的视觉配色，不只是消息、badge 或告警状态颜色。它需要长期被开发者和 operator 反复使用，所以配色应该满足：

- 整体界面有稳定的视觉识别度。
- 页面层级、导航、面板、表格和操作按钮容易区分。
- 状态辨识清晰，但状态色不是唯一设计重点。
- 信息密度高时不刺眼。
- 长时间使用不疲劳。
- 亮色有识别度，但不变成玩具感 UI。
- 不引入独立 Node 前端项目。
- 不使用角色图片、商标素材或 IP 图形，只抽取色彩气质。

本项目推荐的 dashboard 配色以四组颜色作为灵感来源：

- 杰尼龟：蓝 / 青，用于整体主色、主导航、链接和选中态。
- 小火龙：橙 / 暖红，用于强调操作、温暖点缀和需要注意的区域。
- 妙蛙种子：绿 / 青绿，用于辅助色、健康感、稳定感和完成状态。
- 皮卡丘：黄，用于轻量高亮、空状态插画色块、待处理提示和图表强调。

## 2. 设计原则

- **运维优先**：界面必须适合扫描、对比、排障和重复操作。
- **低饱和主背景**：大面积背景使用中性色，不使用大面积高饱和彩色背景。
- **先做 UI 配色，再做状态色**：先定义应用外壳、导航、背景、面板、表格和表单的基础色，再把状态色映射到这些 token 上。
- **颜色有语义**：蓝、橙、绿、黄分别绑定稳定含义，避免同一颜色在不同页面代表完全不同的交互意图。
- **少量点缀**：高饱和色只用于关键按钮、选中态、状态点、badge、图表线条和轻量提示。
- **可访问性优先**：正文和关键状态文本需要满足足够对比度；不能只靠颜色传达状态。
- **组件一致**：同一种状态在 Dashboard、Runs、Workers、Projects、Settings 页面使用同一套 token。

## 3. 推荐色彩 Token

这套 token 分两层：

- **UI 基础层**：控制 dashboard shell、导航、surface、表格、表单、按钮和图表。
- **状态语义层**：在基础层之上表达 running、queued、completed、failed 等运行状态。

不要只把这套配色实现成消息级别的 alert/status badge。Dashboard 的整体视觉应该由这些 token 统一驱动。

### 3.1 基础中性色

```text
--color-bg: #F7F8FA
--color-surface: #FFFFFF
--color-surface-muted: #F0F3F6
--color-border: #D8DEE6
--color-border-strong: #B8C2CC
--color-text: #17202A
--color-text-muted: #5F6B7A
--color-text-subtle: #7B8794
```

用途：

- 页面背景。
- 表格背景。
- 表单输入。
- 分割线。
- 普通文字。

### 3.2 杰尼龟蓝：主色 / 信息

```text
--color-primary: #2F80C1
--color-primary-hover: #256AA3
--color-primary-soft: #DCEEFF
--color-primary-border: #9BC8EE
```

用途：

- App shell 里的主导航选中态。
- 主按钮。
- 当前导航项。
- 链接。
- 主要 tab / segmented control 选中态。
- 图表中的第一主序列。
- `info` 状态。
- 当前选中的 tab。

### 3.3 小火龙橙：强调 / 警告 / 执行中

```text
--color-warning: #E97832
--color-warning-hover: #C95F22
--color-warning-soft: #FFE7D6
--color-warning-border: #F3B385
```

用途：

- 次级强调按钮。
- 需要用户注意的配置区域边线或图标。
- 图表中的第二强调序列。
- `running` / `retrying` / `needs_attention`。
- 危险操作前的轻量警示。
- Hook 执行中。
- Worker lease 即将过期。

### 3.4 妙蛙种子绿：成功 / 健康

```text
--color-success: #3D9A64
--color-success-hover: #2F7C50
--color-success-soft: #DFF3E7
--color-success-border: #9BD3B2
```

用途：

- 成功类按钮的辅助样式。
- 健康 worker / project 的视觉锚点。
- 图表中的健康/完成序列。
- `completed`。
- `healthy`。
- Worker online。
- 配置校验通过。

### 3.5 皮卡丘黄：提醒 / 待处理

```text
--color-accent: #F2C94C
--color-accent-hover: #D5AA2E
--color-accent-soft: #FFF4C7
--color-accent-border: #E8D27A
```

用途：

- 空状态中的轻量高亮。
- 当前等待队列、pending work 的图表序列。
- 注意力引导，但不用于主要 CTA。
- `queued`。
- `pending`。
- 非阻塞提醒。
- 需要用户确认但不危险的提示。

### 3.6 错误色

错误色不直接使用四组灵感色，避免和小火龙橙的 warning 混淆。

```text
--color-danger: #C94343
--color-danger-hover: #A83232
--color-danger-soft: #FBE0E0
--color-danger-border: #E89A9A
```

用途：

- `failed`。
- 删除确认。
- token 泄露风险。
- worker 认证失败。

## 4. UI 配色层级

### 4.1 App Shell

Dashboard 外壳推荐使用：

```text
body background      -> --color-bg
top/nav background   -> --color-surface
active nav item      -> --color-primary-soft + --color-primary
nav hover            -> --color-surface-muted
focus ring           -> --color-primary
```

导航不使用大面积高饱和蓝底。杰尼龟蓝作为选中态、边线、图标和链接使用，让 UI 有识别度但不压迫内容。

### 4.2 Surface / Panel / Card

```text
page section         -> transparent / --color-bg
panel/card           -> --color-surface
panel muted          -> --color-surface-muted
panel border         -> --color-border
panel heading        -> --color-text
secondary text       -> --color-text-muted
```

面板主体保持中性，彩色只用于局部锚点：左边线、badge、图标、图表线条或按钮。

### 4.3 表格

```text
table header         -> --color-surface-muted
row background       -> --color-surface
row hover            -> --color-surface-muted
row selected         -> --color-primary-soft
row border           -> --color-border
```

表格是 dashboard 的主要信息载体。不要把整行状态涂成高饱和彩色；使用状态列、左边线或小 badge 表达状态。

### 4.4 表单

```text
input background     -> --color-surface
input border         -> --color-border
input focus border   -> --color-primary
input error border   -> --color-danger
input warning border -> --color-warning
help text            -> --color-text-muted
```

配置表单以可读性为主。小火龙橙用于风险提示，皮卡丘黄用于非阻塞提示，错误仍使用 danger。

### 4.5 按钮

```text
primary action       -> primary
secondary action     -> neutral
attention action     -> warning
success action       -> success，谨慎使用
destructive action   -> danger
```

默认主 CTA 使用杰尼龟蓝。小火龙橙不作为全局主要按钮色，而用于“需要注意但不是删除”的操作。

### 4.6 图表

图表序列推荐顺序：

```text
series 1             -> primary
series 2             -> success
series 3             -> warning
series 4             -> accent
negative/error       -> danger
grid                 -> border
axis text            -> text-muted
```

图表不要只依赖颜色；tooltip、legend 和 label 必须显示名称。

## 5. 状态语义映射

```text
completed       -> success
healthy         -> success
online          -> success

queued          -> accent
pending         -> accent
waiting         -> accent

running         -> warning
retrying        -> warning
lease_expiring  -> warning

failed          -> danger
offline         -> danger
cancelled       -> neutral
expired         -> danger 或 warning，取决于是否会自动 retry

info            -> primary
selected        -> primary
```

状态组件必须同时显示文本或图标，不能只靠颜色区分。

## 6. 页面应用规则

### 6.1 Dashboard 首页

- 顶部 summary 指标使用中性 card，不使用大面积彩色 card。
- 指标里的图标、趋势线、状态点或小 badge 使用语义色。
- 页面主导航、选中 tab、链接和主要操作使用 primary。
- 队列图表可以使用 primary / success / warning / accent 形成四组可区分序列。
- Active runs 使用 warning。
- Completed runs 使用 success。
- Queued tasks 使用 accent。
- Failed runs 使用 danger。

### 6.2 Runs 页面

- 状态列使用统一 badge。
- `running` 用 warning，避免和 `success` 混淆。
- `retrying` 使用 warning soft 背景和 warning 文本。
- `failed` 使用 danger。
- 行 hover 使用 `--color-surface-muted`，不要用彩色背景。

### 6.3 Workers 页面

- Worker online 使用 success。
- Worker offline 使用 danger。
- Worker idle 使用 neutral。
- Active lease 使用 warning。
- Queued task 使用 accent。

### 6.4 Workflow / Settings 页面

- 表单默认保持中性。
- 保存按钮使用 primary。
- 校验通过使用 success。
- 校验失败使用 danger。
- 非阻塞提示使用 accent。
- 需要确认的风险配置使用 warning。

## 7. CSS 组织建议

第一版可以在 Phoenix assets 的全局 CSS 中定义 token：

```css
:root {
  --color-bg: #F7F8FA;
  --color-surface: #FFFFFF;
  --color-border: #D8DEE6;
  --color-text: #17202A;
  --color-text-muted: #5F6B7A;
  --color-primary: #2F80C1;
  --color-warning: #E97832;
  --color-success: #3D9A64;
  --color-accent: #F2C94C;
  --color-danger: #C94343;
}
```

后续可以扩展为：

- `badge-*`
- `button-*`
- `status-*`
- `table-*`
- `nav-*`
- `form-*`
- `chart-*`

不要把颜色硬编码在 HEEx 模板里。组件应通过 class 或 CSS token 复用色彩语义。

## 8. 可访问性要求

- 关键文字和背景需要保持足够对比度。
- soft 背景上的文字不能直接用浅色，应使用对应深色 token。
- 图表、badge、状态点必须配合文字。
- hover/focus 状态需要可见。
- 键盘 focus ring 可以使用 primary，但必须有足够宽度。
- 不要用黄底白字作为关键文本组合。

## 9. 不做事项

- 不使用角色图像、剪影、logo 或商标素材。
- 不把四种颜色平均铺满页面。
- 不使用大面积渐变背景。
- 不做游戏风格 UI。
- 不把配色只做成 alert/message/status badge。
- 不让配色压过运维信息本身。

## 10. 后续落地顺序

1. 定义 CSS token。
2. 统一 app shell、navigation、surface、table、form、button 的基础配色。
3. 统一 badge/status 组件。
4. 定义图表和指标序列配色。
5. 迁移 Dashboard 首页。
6. 迁移 Runs / Workers / Projects / Settings 页面。
7. 增加 LiveView snapshot 或 HTML 断言，防止 UI 配色和状态语义回退。

## 11. 结论

Symphony Dashboard 的推荐配色应从杰尼龟、小火龙、妙蛙种子和皮卡丘提取“蓝、橙、绿、黄”的可识别方向，但实际落地为低饱和、语义化、可维护的运维 UI 色彩系统。

这套配色不是角色主题皮肤，也不是消息级别的状态色表，而是一个面向控制台、dashboard 和配置页面的整体 UI 色彩系统。
