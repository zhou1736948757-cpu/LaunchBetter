# B6 Design Note — 垂直连续滚动布局: DEFER

- Luna 设计门(2026-08-10)结论: DEFER
- 理由: 现有 page/slot + 横向 paging 契约未定义垂直线性索引/自动滚动/模式切换;
  直接实现会导致拖拽错位并破坏横向回归
- 关键设计点(Luna, 供未来实施):
  - prepareSearch 是最有价值基础(单 section/顶部锚定/动态高度/垂直 scroller), 视 search 为"连续几何的内容投影"
  - LayoutMode 类型在 Core/Config 契约, 持久化归 Config(不持久化 GridGeometry)
  - Config schemaVersion + 明确 raw value; 旧 schema 默认 .paged; 未知值/迁移失败保留旧文件
  - 模式切换不得改 Catalog/Layout 顺序或墓碑
  - 现有列主序注释与实际不符, 实施前明确顺序
  - PagingGridLayout.mode 需 didSet invalidate
  - 全量 itemFrames 扫描需测量
- 触发条件: 用户明确要求垂直模式, 且先冻结 layoutMode/schema 迁移与垂直拖拽设计
