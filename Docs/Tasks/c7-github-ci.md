# 任务包 C7: GitHub Actions macOS CI

## 背景
Stage C §C7。仓库缺可靠 macOS CI gate。添加基本 GitHub Actions:
- LaunchCore tests
- LaunchPlatform tests
- LaunchUI tests
- Debug build
- Release build
不测硬件-only; 不存 secrets; 普通 CI 不要求签名凭据。

## 允许修改的文件
- .github/workflows/ci.yml(新增)
- 不生产代码

## 需求
- macOS runner(latest)
- steps: checkout → xcode-select/Xcode 版本 → 三包 swift test → xcodebuild Debug/Release build
- 缓存 .build(可选)
- 失败即 workflow 失败
- 注意: xcodegen 生成工程(如 CI 需, 先 xcodegen generate 再 xcodebuild)

## 命令纪律(硬性)
bash 每条单命令。读用 read 工具。

## 禁止
不提交 git; 不改 Launchpad_Back; 不加 secrets

## 输出
workflow 文件路径 + yaml 内容 + 说明; 每步 [PROGRESS]
