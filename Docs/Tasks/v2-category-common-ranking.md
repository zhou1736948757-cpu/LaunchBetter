# 任务包: V2 — 分类卡按"常用"排序 + 冷启动先验

## 背景
用户要求分类卡主要回答"本分类里我最常用的 App"。当前 Builder 用单一 rankComparator(有 usage > recent 桶 > launchCount > lastLaunchedAt > name > id),"昨天用一次"会排过"用过 100 次但最近没开"——违反"常用"语义。用户举例 Social 应突出 QQ/WeChat。
且手动覆盖/手动拖移的 App 在目标分类必须靠前(否则拖完看不见,用户以为失败)。

## 允许修改
- `Packages/LaunchCore/Sources/LaunchCore/AppLibraryModel.swift`(Builder 排序策略)
- `Packages/LaunchCore/Tests/LaunchCoreTests/AppLibraryModelTests.swift`
- 禁止改其它、提交、改 Launchpad_Back。

## 规格
1. **拆语义 ranker**(A6): 至少三个独立策略:
   - `SuggestionRanker`: Suggestions 卡专用(可保留现有 recent/usage 语义,不污染分类卡)。
   - `CategoryCommonRanker`: 分类卡专用。优先级:
     1) 显式手动覆盖/手动分配(该 app 被 override 到本分类)→ 最前
     2) launchCount 降序(频率优先;即使最近未用)
     3) 冷启动熟悉度先验(见下)
     4) lastLaunchedAt 仅作 tie-break
     5) displayName / AppID 稳定 tie-break
   - `RecentlyAddedRanker`: Recently Added 卡专用(按 firstSeen,现逻辑保留)。
2. **不得**让"最近用过一次"压过"高频但最近未用"(A7)。CategoryCommonRanker 必须 launchCount 主排序。
3. **冷启动先验**(A8): 无 usage(或极稀疏)时,Layout Page1 顺序作为熟悉度先验输入(只做 ranking 输入,不改 Layout)。Builder Inputs 已含 `page1FallbackAppIDs`;新增一个"page1 order rank"信号: 分类内无 usage 的 app 按 Page1 中顺序排序(在分类内)。有 launchCount>0 的 app 频率优先,不受 Page1 顺序影响。
4. **手动覆盖置顶**(A17): 分类卡 primary 里,被 override 到该分类的 app 排最前;多个手动 app 之间按频率。
5. **Suggestions/Recently Added 不污染分类顺序**(A9): 分类卡各自独立 ranking 上下文;Suggestions 出现不改变分类卡内顺序。
6. 保留: 手动覆盖 > bundle 校正 > classifier;稀疏含覆盖分类不合并。

## 必写测试
- 高频但最近未用 > 低频最近用(分类卡内)
- 手动覆盖 app 置顶(即使频率低)
- 无 usage 冷启动按 Page1 顺序
- 有 usage 后频率优先于 Page1 顺序
- Suggestions 不改变分类顺序
- lastLaunchedAt 仅 tie-break
- 既有全量测试不回归

## 验收
1. LaunchCore 全绿(记录数字)。
2. 报告: 旧/新排序、冷启动行为、QQ/WeChat 行为(合成 record)。
