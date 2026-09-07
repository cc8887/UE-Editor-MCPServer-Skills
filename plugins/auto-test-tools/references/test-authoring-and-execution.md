# AutoTestTools 测试编写与执行参考

本文供编写和运行测试用例时按需读取。业务逻辑实现与审查只需使用 `ue-autotesttools-core` 和对应功能 skill，不应为此加载本文。

## 使用边界

AutoTestTools 仅用于 Unreal Editor，测试主体使用 Python，关键引擎边界由 Editor-only C++/CQTest 模块承担。当前具备可执行 provider 的能力只有：

| `requires` 值 | PIE 入口 | 要求 |
| --- | --- | --- |
| `actor` | `pie.actors` | `AutoTestToolsActor` |
| `enhanced_input` | `pie.input` | `AutoTestToolsEnhancedInput` 与引擎 `EnhancedInput` |
| `animation` | `pie.animation` | `AutoTestToolsAnimation` |
| `animation_pose_search` | `pie.animation_pose_search` | 可选的 `AutoTestToolsAnimationPoseSearch` 与引擎 `PoseSearch` |

FX、Gameplay、UI、Render 和 Network 尚不是当前可执行测试能力。打包构建、独立客户端、设备部署、自定义 Gauntlet 节点以及多客户端 PIE 也不在当前范围内。NullRHI 适合验证逻辑状态，不用于截图或严格 GPU 渲染校验。

编写领域测试前，必须同时使用 `ue-autotesttools-core` 与对应功能 skill；具体领域接口再读取同目录下对应的 API reference。

## 声明测试

测试文件和函数不要求命名约定。发现标记是模块顶层函数上的 `@test` 装饰器：

```python
from auto_test_tools import test


@test(
    name="Smoke.PIE",
    timeout=30,
    tags=("smoke",),
    requires=("actor",),
)
async def pie_smoke(context):
    async with context.pie("/Engine/Maps/Entry") as pie:
        assert pie.world is not None
```

支持 `@test`、`@test(...)`、`@autotest.test(...)` 和 `@auto_test_tools.test(...)`。后两种形式分别要求：

```python
import auto_test_tools as autotest
import auto_test_tools
```

装饰器字段：

- `name`：可选名称；设置后注册为 `Project.AutoTest.<name>`。省略时使用发现根目录下的相对文件路径和函数名生成稳定标识。
- `timeout`：可选的有限正数秒数；省略时使用项目设置 `DefaultTimeoutSeconds`。
- `tags`：非空字符串组成的列表或元组；`[` 和 `]` 为 Unreal 原生标签编码保留字符。
- `requires`：声明测试真正使用的能力。当前只应使用上表列出的四项。

所有元数据必须是 Python 字面量。测试函数必须位于模块顶层并且只接收一个 `context` 参数。重复标识、非法签名或元数据会生成失败项 `Project.AutoTest.Discovery`；不支持的装饰器形式和嵌套函数会产生带源码位置的 warning。

## 发现与刷新

默认扫描项目 `Content/Python`，以及项目已加载插件中的 `Content/Python`；默认不扫描引擎插件。可在 **Project Settings > Plugins > Auto Test Tools** 配置：

- `AdditionalDiscoveryRoots`
- `ExcludedDiscoveryRoots`
- `DefaultTimeoutSeconds`
- `CleanupGraceSeconds`

发现阶段只使用 AST，不导入候选模块。修改脚本或发现设置后执行：

```text
AutoTest Refresh
```

然后刷新 **Tools > Test Automation**。测试位于 `Project.AutoTest` 前缀下，每个装饰函数对应一个独立结果。

## 上下文、PIE 与清理

`async with context.pie(map_path)` 为当前测试创建并拥有唯一一个主 PIE 会话。成功、异常、取消或超时都会进入清理；如果已有非本测试拥有的 PIE，会直接失败且不会停止该会话。

```python
from auto_test_tools import test


@test(requires=("animation",))
async def animation_state(context):
    async with context.pie("/Game/Tests/Maps/AnimationTest") as pie:
        helper = pie.animation
        # 领域操作与断言见 animation-testing-api.md。
        assert pie.world is not None
```

通用上下文成员：

- `context.defer(callback)`：登记同步或异步清理，按 LIFO 顺序执行。
- `context.log(message)`：写入 Automation 信息。
- `context.warning(message)`：写入 Automation warning。
- `pie.world`：当前 PIE World。
- `pie.session`、`pie.is_running`：当前会话及运行状态。

清理回调必须可重试且幂等。一次回调失败不会阻止其他回调执行；作用域清理失败的回调会在最终清理阶段重试，剩余失败会使测试失败，同时保留原始测试异常。

跨 Tick 的测试必须使用 `async def` 和条件式 await helper。同步测试只能在当前 Editor Tick 完成，不得 sleep、轮询、等待 PIE 或阻塞 Game Thread。不要使用固定延时证明业务完成，应等待可观察状态或事件并设置有诊断信息的超时。

通用条件等待从包根导入：

```python
from auto_test_tools import wait_until

await wait_until(
    condition,
    timeout=5.0,
    message="Business state did not reach the expected value",
)
```

`condition` 是按异步 tick 重试的同步可调用对象；返回真值时完成。`message` 在开始等待前求值，不能动态展示后续观测。需要最后观测值时，把它保存在闭包中，捕获 `TimeoutError` 后将该值附加到新异常。不要在 condition 中阻塞、sleep 或启动另一个 PIE。

## 能力预检

`requires` 会在导入测试模块、启动 PIE 和分配资源之前执行原生预检。缺少必需 feature 模块、未知能力或非法声明属于硬错误；可选引擎依赖不可用或执行环境不兼容时，以带源码位置的 success-with-warning 跳过，而不是静默消失。

普通动画测试只声明 `animation`。只有真正验证 Motion Matching 时才额外声明 `animation_pose_search`，以免普通测试承担 PoseSearch 的加载和编译成本。

## Editor 内执行

### 通过 Unreal Editor MCP 执行

使用支持等待协程的 UE-Editor-MCPServer 时，`execute_command` 和 `excute_file`
会执行脚本，并等待脚本顶层的 `async def main()` 返回。等待由 Editor Tick 推进，
返回值应可 JSON 序列化。同步脚本仍可使用，不要用同步 sleep 等待 PIE 或测试结束。

1. 原生代码变更后，在 Editor 关闭时调用宿主侧 `build_project`，等待完整 Editor
   目标构建。成功直接消费状态；失败用 `read_artifact` 读取错误行附近，禁止测试旧 DLL。
   该工具不代替项目要求的插件版本与构建产物审计。
2. `open_editor` 等待实际 MCP ping 成功后返回 READY，并附带最小协程示例。
   首次连接或排查调度问题时运行一次，
   确认 `completed=true` 和 `ticks_during_await>0`；不必在每个用例前重复验证。
3. 将一轮测试的启动、条件等待、结果读取和清理组织在一次 `async def main()` 调用中。
   `Automation RunTest` 只表示提交测试，不能直接当作完成。等待本次测试的完成状态或
   新生成的结果文件，设置超时，再检查核心断言与通过数量。不可接受上次运行遗留结果。
4. 原生日志捕获覆盖整个 await。先读取工具直接返回的结果摘要；日志较长时保存在
   项目 `Saved/Logs/MCP`，按需使用返回路径读取小段日志，避免反复扫描整份 Editor 日志。
5. 在 `finally` 或测试上下文退出时释放自身 PIE、回调与临时设置。协程结束并回传
   结果后再从宿主调用 `close_editor`；不要在仍等待返回的 Editor Python 中关闭进程。

最小调度检查示例不代表业务测试通过；真正测试仍按本文的声明、发现和 provider 边界执行。
UI 截图只在验证需要时读取，优先保留能辨认被测控件的局部图，整屏原图可留在磁盘。

`MCP_EXECUTION_TIMEOUT` 是 Editor 侧协程执行上限，默认 86400 秒，配置为有限正数。
脚本自身仍应设置与业务匹配的条件等待超时。客户端 MCP 请求超时和外层工具执行的
提前返回阈值是另外两层：延长 MCP 超时不会阻止外层先返回“仍在运行”。优先配置外层
等待完成；必要时等待同一次调用，不要重启 Editor 或重新提交测试。

旧版服务不会自动等待 `main()`，先检查工具描述或启动示例是否声明支持这一契约。
不要在旧版服务上用 `create_task` 后立刻返回来声称测试已经完成。

在 **Tools > Test Automation** 中刷新并运行 `Project.AutoTest` 下的条目。也可在 Editor 控制台运行整个前缀：

```text
Automation RunTest Project.AutoTest
```

按原生标签筛选：

```text
Automation ApplyTagFilter smoke;RunTest Project.AutoTest
```

AutoTestTools 不实现自己的调度器或标签命令。

## NullRHI 命令行执行

`-NullRHI` 使用 Unreal 原生启动模式，和普通 Editor 运行同一批发现结果。替换以下占位路径：

```powershell
<EngineRoot>\Engine\Binaries\Win64\UnrealEditor-Cmd.exe <Project.uproject> `
  -NullRHI -Unattended -NoSplash `
  -ExecCmds="Automation RunTest Project.AutoTest;Quit" `
  -TestExit="Automation Test Queue Empty" `
  -ReportExportPath="<ProjectRoot>\Saved\AutomationReports\AutoTestTools" -log
```

按标签运行时，将 `-ExecCmds` 改为：

```powershell
-ExecCmds="Automation ApplyTagFilter smoke;RunTest Project.AutoTest;Quit"
```

## Gauntlet 一级接入

一级支持只复用 Unreal 原生 `UE.EditorAutomation` 节点运行同一 Automation 前缀；插件不提供自定义 AutomationTool 节点、控制器或调度逻辑：

```powershell
<EngineRoot>\Engine\Build\BatchFiles\RunUAT.bat RunUnreal `
  -project=<Project.uproject> `
  -platform=Win64 -configuration=Development -build=editor `
  -test=UE.EditorAutomation `
  -RunTest="Project.AutoTest" `
  -TagFilter="smoke" `
  -NullRHI `
  -ReportExportPath=<ProjectRoot>\Saved\AutomationReports\Gauntlet `
  -ResumeOnCriticalFailure
```

省略 `-TagFilter` 即运行完整前缀。进程监控、产物收集、报告导出和零测试处理均沿用 Unreal/Gauntlet 原生行为。

## 结果与诊断

`-ReportExportPath` 输出 Unreal 原生 JSON/HTML Automation Report。失败、断言、异常、超时与清理错误会保留被装饰 Python 文件及函数行号；Gauntlet 还会保留其标准运行产物。

排查无测试或测试数量异常时，依次确认：

1. 脚本位于默认或附加发现根目录，且未被排除。
2. 装饰函数位于模块顶层，元数据为字面量，签名只有一个 `context`。
3. 已执行 `AutoTest Refresh` 并刷新 Automation 面板。
4. `Project.AutoTest.Discovery`、Editor 日志和 Automation Report 中没有发现错误。
5. `requires` 只声明实际安装并启用的当前 provider。
