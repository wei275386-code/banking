# 家庭财务复盘

面向 macOS 和 iPhone 的家庭账本 App。将账单、交易凭证和人工确认整理成可复核的交易生命周期，用于消费统计、资料补全和 FIRE 规划。

项目仍在开发中。软件版本、build number 和最低系统要求以 [release-version.json](config/release-version.json) 为准。

## 当前功能

- **账本与材料**：创建、打开和导入当前结构的家庭资料；处理支持的 PDF、CSV、XLSX 账单，以及图片、录屏材料。不同来源和版式的解析能力以现有处理器为准。
- **交易复核**：分类、标签、消费人、支付账户、日期及金额确认；来源关联、重复来源归并、退款和报销关联；补全队列与统计范围管理。
- **家庭规则**：商户确认和组合条件规则随用户资料保存，对后续新增交易继续生效。后续人工修改可以覆盖适用的自动结果。
- **报表与规划**：按月份、分类、标签等维度复盘支出，并维护 FIRE 模型参数。
- **家庭同步**：Mac 建立家庭同步目录并承担材料处理；iPhone 和其他客户端读取家庭快照、保存离线编辑，并在同步时交换修改、处理冲突和重试。
- **备份恢复**：完整工作备份恢复为新的可写账本，再由用户明确建立同步连接。客户端副本备份保留副本权限及未同步修改。

最新完整快照可独立读取。历史对象按当前状态、未完成工作和正在使用的读取引用回收；原件可以按需下载并保存在本机缓存中。

## 使用方式与数据位置

首次在 Mac 中选择“创建新的家庭资料”，或打开符合当前结构的已有资料，再通过 App 导入账单和素材。需要家庭同步时，在 Mac 中明确选择同步目录；iPhone 在 Files 中选择同一目录。使用 iCloud Drive 时，设备需具备该目录的访问权限。

macOS 的托管账本位于系统应用支持目录中的 `FamilyReview/Workspaces`，iPhone 将副本保存在自己的应用容器中。用户选择的外部目录和同步目录按相应授权访问。App 的运行数据与工程源码分开存放。

私人账本、家庭规则、原始凭证、录屏、数据库及备份不包含在本仓库中。仓库内的测试资料是合成样本；新建家庭使用通用默认配置。

程序只读写当前一种自有数据结构，没有旧格式转换入口。数据通过当前字段、类型、业务关系及文件校验值验证；自有格式不使用独立的格式版本号分流。App 发布版本和第三方依赖版本仍保留。

## 工程结构

| 路径 | 作用 |
| --- | --- |
| `native/PaymentImageCore/Sources/PaymentImageCore` | 共享业务模型、账本事务、家庭同步、备份、材料校验与引用回收 |
| `native/PaymentImageCore/Sources/EvidenceBrowser` | macOS App 及两端共享的 SwiftUI 界面和编辑逻辑 |
| `native/FamilyReviewIOS` | iPhone App、XcodeGen 配置及 UI 测试 |
| `scripts` | Python 材料处理、交易投影、运行时组装、安装与发布工具 |
| `schemas` | 当前数据契约及其校验样本 |
| `release` | 通用默认配置、源码导出清单、依赖锁定和构建工具清单 |
| `tests`、`native/PaymentImageCore/Tests` | Python 与 Swift 回归测试、合成样本及样本生成器 |
| `config/release-version.json` | 软件发布版本、build number 和最低系统要求 |

## 开发与测试

当前 macOS 打包目标为 Apple Silicon（arm64），最低 macOS 14；iPhone 最低 iOS 17。Swift Package 要求 Swift 6.1 工具链。开发需要 Xcode、Python、XcodeBuildMCP CLI；生成 iOS 工程还需要 XcodeGen。发布工具使用 [native-toolchain.json](release/native-toolchain.json) 中锁定的工具链。

以下命令从仓库根目录执行。Python 开发测试已在 Python 3.12 环境运行；Mac 安装包自带独立 Python runtime，不依赖用户安装的 Python。运行时的精确依赖见 [runtime-lock.json](release/runtime-lock.json)。

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install pypdf==6.1.1 openpyxl==3.1.5 pdfplumber==0.11.7 pypdfium2==4.30.0

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=.:tests python -m unittest discover -s tests -q
xcodebuildmcp swift-package test --package-path "$PWD/native/PaymentImageCore"
```

### 构建 macOS App

先构建整个 Release package，再从已提交且干净的工程组装 App。目标路径必须是尚不存在的暂存位置。

```sh
xcodebuildmcp swift-package build --package-path "$PWD/native/PaymentImageCore" --configuration release
python -m scripts.package_macos_release --destination "$PWD/dist/FamilyReview.app"
```

组装工具会准备锁定的 Python runtime、原生辅助程序和通用默认配置，生成构建来源及运行时清单。这个命令生成本机候选 App；Developer ID 签名、公证和对外分发由独立发布流程处理。版本库不附带开发者签名配置。

### 生成 iOS 工程

```sh
python -m scripts.generate_release_inputs
xcodegen generate --spec native/FamilyReviewIOS/project.generated.yml
open native/FamilyReviewIOS/FamilyReview.xcodeproj
```

在 Xcode 中选择自己的 Signing Team 和目标设备。需要隔离 QA 包时，生成输入使用 `--qa --team YOURTEAMID`；`YOURTEAMID` 为实际的十位 Team ID。生成的工程、Bootstrap、DerivedData 和本机签名资料不进入 Git。

## 验证范围

当前代码已完成 macOS、iOS 编译，以及业务、处理器、数据校验、同步、冲突、备份恢复和回收相关回归测试。真实 iCloud 跨设备验收本轮按要求跳过，未计作通过；编译和合成测试结果不代表该项已验证。
