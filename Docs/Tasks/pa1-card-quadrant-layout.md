# 任务包: PA1 — App Library 卡片象限布局与密度

## 背景
用户要求卡片布局改为真 2×2 象限构成，去掉独立的 mini 胶囊条；并调小卡片尺寸、提高密度（1470pt 宽目标 4 列）。

## 允许修改的文件
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryCardCell.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryLayout.swift`(仅 metrics 常量)
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryLayoutTests.swift`
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryViewTests.swift`

禁止改其它文件、提交、切分支、改旧仓库、改用户数据。

## 卡片构成(必须逐条)

1. **普通分类卡 / Recently Added**: 2×2 象限 =
   - 左上: large app 0
   - 右上: large app 1
   - 左下: large app 2
   - 右下: mini 2×2 簇(4 个 mini)
   标题 top-left 对齐。大图标=3, mini=4。卡片内**不放** app 标签(无障碍保留全名)。
2. **mini 2×2 簇**: 右下象限内的 2×2 网格;默认**无胶囊/药丸背景**(不要独立容器背景)。若视觉上明显失衡,允许极轻底色但必须小。
3. **Suggestions 卡**: 2×2 四个大图标(primary=4),标题 top-left,每个直接启动。
4. **Recently Added**: 3 large + 右下 2×2 mini(与普通分类一致,不发明新样式)。
5. **尺寸/密度**: `AppLibraryLayoutMetrics` 调整为
   preferredCardWidth ≈ 320-340、maxCardWidth ≈ 350-380、
   horizontal inset 28-32、spacing/rowSpacing 16-18;
   **不要硬编码 4 列**,保持响应式 4/3/2/1(列数由可用宽度+preferred 推导,维持现有 metrics 逻辑);1470pt 宽应给 4 列。卡片有界,不许变超大 dashboard 瓦片。
6. 点击路由保持: 大图标 → launch;mini 区 / 标题 → openDetail。鼠标 press 反馈保留。
7. 无障碍: 大图标/mini 各自 a11y label 保留全名。

## 必写/更新测试
- `AppLibraryLayoutTests`: metrics 新数值(列数/宽度/间距/inset 在 1470→4 列、1200→3、800→2、极窄→1);卡片高度仍方形或有界。
- `AppLibraryViewTests`: 普通分类卡 frame 断言(3 large + mini 2×2 象限不重叠、边界在卡片内);Suggestions 2×2 四图标;mini 2×2 边界;1x/2x 语义(用 bounds 而非像素)。
- 全量 LaunchUI 测试通过。

## 验收
1. `cd Packages/LaunchUI && swift test` 全绿。
2. Debug build 成功。
3. 输出改动清单、测试数、与规格偏差。
