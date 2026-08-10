# A13 Design Note — LauncherStoring 分解: DEFER

- Luna 设计门(2026-08-10)结论: DEFER
- 现状: LauncherStoring 单一职责面广; LayoutMutationCompleting 重复带 completion 的 mutation(抽象味)
- 但: 布尔回执已覆盖唯一消费者(LauncherStore.commit 仅在 save 成功后发布; 串行锁+completion 去重已在);
  拆分协议 + typed result 会扩大 API 变更面, 无已证收益
- 若未来做: LauncherReadModelProviding / LauncherObserving / LayoutCommanding / AppCommanding
  组合 façade(LauncherStore); typed mutation result
  (committed/noChange/rejected(.staleLayout|.invalidMutation|.busy)/failed(.persistence|.corruptionProtection))
  作为主接口, 旧 Bool 作临时适配器; 注意 save/moveToTrash 属 AppCommanding, 别被布局结果类型覆盖
- 触发条件: 新增第二个协议消费者, 或 mutation 语义需要区分失败类别时
