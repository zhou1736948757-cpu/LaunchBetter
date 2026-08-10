# 任务包 A5+A6: Icon pipeline — 消除双光栅化 + 磁盘写离首屏关键路径

## 背景
LaunchBetter v0.2.3(Prompt Stage A §A5/A6)。`IconRepository.resolve`(LaunchPlatform):
- §A5: live provider `AppIconProvider.liveIcon` 已返回"精确 pixelSize + 显示就绪"位图
  (NSWorkspace.icon + render(pixelSize)), 但 resolve 随后 `preDecode(live, pixelSize:)`
  再次光栅化 → 双光栅化。
- §A6: resolve 在返回前同步执行 `diskCache.store(key:image:)`(PNG encode + 原子写盘),
  首个 live icon 消费者会等待磁盘写入。

## 允许修改的文件(禁止范围外)
- Packages/LaunchPlatform/Sources/LaunchPlatform/IconRepository.swift
- Packages/LaunchPlatform/Sources/LaunchPlatform/AppIconProvider.swift(仅审计, 通常不需改)
- Packages/LaunchPlatform/Sources/LaunchPlatform/IconDiskCache.swift(如需独立 writer 支持)
- 测试: Packages/LaunchPlatform/Tests/LaunchPlatformTests/

## 设计

### A5 消除 live 双光栅化
1. 审计 AppIconProvider.liveIcon 输出: 是否 exact requested pixelSize / premultiplied / display-ready
2. 若确认 → resolve 对 live 结果**不再** preDecode, 直接返回
3. 磁盘加载路径的 preDecode 保留(磁盘 PNG 可能非显示就绪)
4. 零可见退化; 1x/2x 像素尺寸一致; content version / stale-generation 语义不变

### A6 磁盘写离关键路径
1. resolve: live → 内存缓存 → 立即返回 image(不等磁盘写)
2. 独立受控 DiskCacheWriter(actor 或串行/有界 worker):
   - 按 IconKey 去重(同 key 仅一次写)
   - 有界并发(不做无界 Task.detached 洪泛)
   - PNG encode + atomic write 在 writer 内
   - 写失败不阻塞 UI(仅记录)
   - 干净 shutdown(进程退出/隐藏时不丢关键写, 可等或放弃)
   - 新语义 key 不能被陈旧内容覆盖(写时携带 generation/key 校验)
3. 测量: 冷 icon 首显延迟 / 全冷页解析(改动前后)

## 约束
- 不改 IconRepository 的 in-flight dedup / 消费者取消 / stale-generation 语义
- 内存缓存正确性不变
- 不新增 main.sync; 每帧无 IO
- LaunchPlatform 测试需覆盖

## 验收标准
1. live 结果不再二次光栅化(代码 + 测量)
2. 首个 live icon 返回不等待磁盘写(可测: resolve 期间 store 未完成)
3. 磁盘 writer 有界、按 key 去重、错误不阻塞 UI
4. 冷 icon 延迟不劣化、全冷页解析正确
5. LaunchPlatform swift test 全绿(含新增)
6. xcodebuild build 成功

## 必写测试
- live 路径不 preDecode(如: 注入 fake provider 返回特定尺寸位图, 断言 resolve 返回同一对象或同尺寸)
- disk write 异步不阻塞(时序断言)
- writer 按 key 去重(同 key 只写一次)
- writer 错误容错(写失败 resolve 仍返回图像)
- 内存缓存/陈旧代际回归

## 禁止
- 不修改 /Users/mac/Projects/Launchpad_Back
- 不提交 git、不切换分支
- 不引入新依赖
- 不改 IconMemoryCache 语义

## 输出要求
改动文件清单 / 技术假设清单 / build+test 结果 / 前后测量(首显延迟/冷页)/ 与任务包偏差 / 未决问题; 每步 [PROGRESS]
