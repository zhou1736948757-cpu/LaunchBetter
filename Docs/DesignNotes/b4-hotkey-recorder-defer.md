# B4 Design Note — 自定义热键录制器: DEFER

- 现状: GlobalHotkey(Carbon)5 预设已工作(⌘L 等)
- 自定义 recorder(按键+修饰键+冲突检测+回滚+持久化+无障碍)引入不成比例复杂度
- Prompt §B4: 若不成比例 → Luna review + document decision
- 决策: defer 自定义 recorder; 预设满足当前产品。若用户明确要求可自定义再实施
- 实施要点(未来): 当前热键保持激活直至新键注册成功; 注册失败回滚; 持久化 + 冲突检测
