# 试点任务(极简版): 验证 implementer 独立 subagent 流程

目标: 最快确认 implementer 独立窗口能读任务包 → 写文件 → 运行 → 回报。

## 任务
1. 写文件 Docs/Tasks/pilot/hello.py, 内容: 打印一行 "hello implementer"
2. 运行: python3 Docs/Tasks/pilot/hello.py
3. 回报: 运行输出

## 纪律
- 只动 Docs/Tasks/pilot/hello.py 这一个文件
- 每完成一小步输出一行 [PROGRESS]
- 不使用 git
