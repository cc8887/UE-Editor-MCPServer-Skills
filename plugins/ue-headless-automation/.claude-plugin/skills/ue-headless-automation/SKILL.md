---
name: ue-headless-automation
description: Guide for running Unreal Engine in headless mode (-NullRHI, -Unattended, -NoSplash) via Editor CMD, with automation testing (Automation RunTests) as the primary use case. Also covers how to design plugins/features that can be launched purely via UnrealEditor.exe command line, and provides a step-by-step checklist to verify whether a feature supports headless CMD-only execution.
---

# UE Headless Automation — 无头模式与命令行运行指南

指导如何让 Unreal Engine 以无渲染、无人值守、跳过启动画面的**纯命令行模式**运行，以自动化测试为典型应用场景。

## When to Use

| Scenario                   | Trigger                   |
| -------------------------- | ------------------------- |
| 设置 UE 项目的 CI/CD 自动化测试      | "如何在 CI 中跑 UE 自动化测试"      |
| 在无 GPU 服务器上运行 UE 功能        | "服务器没有显卡怎么运行 UE"          |
| 设计插件使其支持命令行启动              | "如何让插件只依赖 Editor CMD 就能跑" |
| 验证某个功能是否兼容无头模式             | "这个功能能在 -NullRHI 下跑吗"     |
| 编写 Automation Test 并在命令行执行 | "怎么写 UE 自动化测试并命令行运行"      |
| 排查 Automation Test 失败原因    | "自动化测试跑不起来 / 报错"          |

---

## Part 1: UE 无头模式三大参数

### 1.1 核心命令行参数

```bash
UnrealEditor.exe MyProject.uproject \
    -NullRHI \          # 无渲染模式，不需要 GPU，适合 CI/无头服务器
    -Unattended \        # 无人值守模式，跳过所有弹窗和对话框
    -NoSplash \          # 跳过启动画面，加快启动速度
    -ExecCmds="<command>; Quit"   # 注入控制台命令，执行后自动退出
```

| 参数            | 作用       | 为什么重要                        |
| ------------- | -------- | ---------------------------- |
| `-NullRHI`    | 禁用渲染硬件接口 | 允许在没有 GPU 的服务器/CI 环境中运行；启动更快 |
| `-Unattended` | 无人值守模式   | 跳过所有模态对话框（错误弹窗、确认框等），防止进程卡死  |
| `-NoSplash`   | 跳过启动画面   | 减少启动时间，CI 中不需要视觉反馈           |
| `-ExecCmds`   | 注入控制台命令  | 启动后自动执行命令，`Quit` 确保执行完后退出进程  |

### 1.2 常用 ExecCmds 组合

```bash
# 运行特定命名空间下的所有自动化测试
UnrealEditor.exe MyProject.uproject -NoSplash -NullRHI -Unattended \
    -ExecCmds="Automation RunTests MyPlugin; Quit"

# 运行单条精确测试
UnrealEditor.exe MyProject.uproject -NoSplash -NullRHI -Unattended \
    -ExecCmds="Automation RunTests MyPlugin.Calculations.SimpleAddition; Quit"

# 运行批量测试（All 是自定义的聚合测试）
UnrealEditor.exe MyProject.uproject -NoSplash -NullRHI -Unattended \
    -ExecCmds="Automation RunTests MyPlugin.All; Quit"

# 运行多个不相关的测试
UnrealEditor.exe MyProject.uproject -NoSplash -NullRHI -Unattended \
    -ExecCmds="Automation RunTests ModuleA; Automation RunTests ModuleB; Quit"

# 列出所有可用测试（不执行）
UnrealEditor.exe MyProject.uproject -NoSplash -NullRHI -Unattended \
    -ExecCmds="Automation List; Quit"
```

### 1.3 退出码

UE Editor 在 `-ExecCmds` 执行完毕后，通过 `Quit` 命令退出。退出码为 `0` 表示正常退出（不等于测试全部通过）。要获取测试结果，需解析日志输出中的 `[FAIL]` 标记，或通过自动化测试框架的 `HasAnyErrors()` 机制。

---

## Part 2: 如何构建支持无头 CMD 的功能

### 2.1 核心原则

要让功能"只依赖 `UnrealEditor.exe` CMD 即可启动"，需要满足以下条件：

1. **功能在 Editor 模块中运行** — 使用 `UnrealEditor.exe` 而非 `UnrealGame.exe`，因为 Automation 框架只在 Editor 构建中存在
2. **不依赖 GPU/渲染** — 避免在启动路径中调用任何渲染相关 API（`UGameViewportClient`、`FSceneView` 等）
3. **不依赖用户交互** — 不能有模态对话框、鼠标点击、键盘输入等交互
4. **不依赖关卡加载** — 如果必须加载关卡，确保关卡可以在 `-NullRHI` 下加载（纯数据关卡可以）
5. **不依赖编辑器 GUI** — 不能使用 `FLevelEditorModule`、`SLevelViewport` 等 Slate 编辑器 UI

### 2.2 Build.cs 配置

```csharp
// MyPlugin.Build.cs
using UnrealBuildTool;

public class MyPlugin : ModuleRules
{
    public MyPlugin(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

        PublicDependencyModuleNames.AddRange(new string[] {
            "Core",
            "CoreUObject",
            "Engine"
        });

        PrivateDependencyModuleNames.AddRange(new string[] {
            // 其他依赖...
        });

        // ⚠️ 关键：Automation 测试框架仅在 Editor 构建时链接
        if (Target.bBuildEditor)
        {
            PrivateDependencyModuleNames.Add("AutomationTest");
        }
    }
}
```

**要点**：`AutomationTest` 模块是 `IMPLEMENT_SIMPLE_AUTOMATION_TEST` 等宏的来源，必须在 Editor 构建下链接。

### 2.3 编写自动化测试

#### 基础测试宏

```cpp
#include "Misc/AutomationTest.h"

// 注册单条测试
IMPLEMENT_SIMPLE_AUTOMATION_TEST(
    FMyTest_SimpleCalculation,                              // 测试类名
    "MyPlugin.Calculations.SimpleAddition",                 // 测试路径（过滤键）
    EAutomationTestFlags_ApplicationContextMask | EAutomationTestFlags::ProductFilter)
bool FMyTest_SimpleCalculation::RunTest(const FString& /*Parameters*/)
{
    // 测试逻辑
    const int32 Result = 1 + 2;
    TestEqual(TEXT("1 + 2 should equal 3"), Result, 3);
    return !HasAnyErrors();
}
```

#### 自定义测试宏（简化注册）

当有大量测试时，可以封装自己的宏：

```cpp
#define MY_AUTOMATION_TEST(TestSuffix, TestFunc) \
    IMPLEMENT_SIMPLE_AUTOMATION_TEST( \
        FMyTest_##TestSuffix, \
        "MyPlugin." #TestSuffix, \
        EAutomationTestFlags_ApplicationContextMask | EAutomationTestFlags::ProductFilter) \
    bool FMyTest_##TestSuffix::RunTest(const FString& /*Parameters*/) \
    { \
        if (!TestFunc()) { AddError(TEXT(#TestFunc " failed")); } \
        return !HasAnyErrors(); \
    }

// 使用
static bool Test_Addition()
{
    return 1 + 2 == 3;
}
MY_AUTOMATION_TEST(SimpleAddition, Test_Addition)
```

#### 测试路径命名规范

```
{PluginName}.{Category}.{TestName}     ← 层级结构，支持前缀过滤

例如：
MyPlugin.Calculations.SimpleAddition   ← 单条测试
MyPlugin.Calculations.All              ← 批量聚合测试
MyPlugin.*                             ← 运行所有 MyPlugin 测试
```

#### 聚合测试（批量运行）

```cpp
IMPLEMENT_SIMPLE_AUTOMATION_TEST(
    FMyPluginAll,
    "MyPlugin.All",
    EAutomationTestFlags_ApplicationContextMask | EAutomationTestFlags::ProductFilter)
bool FMyPluginAll::RunTest(const FString& /*Parameters*/)
{
    RunAllMyPluginTests();  // 内部调用所有 static bool Test_Xxx() 函数
    return !HasAnyErrors();
}
```

### 2.4 编译时验证（可选但推荐）

在头文件中添加编译时检查，确保编译环境正确：

```cpp
#pragma once
#include "CoreMinimal.h"

// 验证 Automation 头文件可访问
#if WITH_EDITOR
    #if __has_include("Misc/AutomationTest.h")
        #pragma message("✅ AutomationTest header accessible")
    #else
        #error "❌ AutomationTest header NOT found - check module dependencies"
    #endif
#else
    #error "❌ WITH_EDITOR is not defined - tests require Editor build"
#endif
```

### 2.5 功能模块适配无头模式

如果已有功能模块，希望它能在无头 CMD 下运行，需要做以下改造：

1. **检查所有初始化路径** — 搜索 `GEditor`、`GEngine->GameViewport`、`FSlateApplication` 等引用，添加 `nullptr` 检查
2. **条件编译渲染依赖** — 用 `#if WITH_EDITOR` 包裹编辑器专用代码
3. **避免 `LoadMap` 依赖** — 如果不需要关卡，使用 `NewObject` 在 transient package 中创建测试对象
4. **使用 `UE_LOG` 而非屏幕打印** — `GEngine->AddOnScreenDebugMessage` 在 `-NullRHI` 下不可用，改用 `UE_LOG`
5. **避免 `FMessageDialog`** — 用 `UE_LOG` + 返回值代替弹窗确认

---

## Part 3: 验证功能是否支持无头 CMD 的检查清单

当需要验证某个功能/插件是否能只依赖 `UnrealEditor.exe` CMD 运行时，按以下步骤逐项检查：

### 3.1 快速冒烟测试（2 分钟）

```bash
# 最简启动测试：如果这个命令能正常退出，说明基础环境没问题
UnrealEditor.exe MyProject.uproject -NoSplash -NullRHI -Unattended -ExecCmds="Quit"
```

**判定**：进程退出且无 crash，则通过基础检查。如果 crash 或卡住，说明有渲染或对话框依赖。

### 3.2 编译依赖检查

| 检查项                   | 如何验证                                                   | 不通过的表现          |
| --------------------- | ------------------------------------------------------ | --------------- |
| 模块是否在 Editor 构建中链接    | 检查 Build.cs 中 `Target.bBuildEditor` 条件                 | 运行时找不到模块        |
| 是否依赖 `AutomationTest` | 搜索 `IMPLEMENT_SIMPLE_AUTOMATION_TEST`                  | 测试无法注册          |
| 是否依赖 Editor-only API  | 搜索 `UnrealEd`、`LevelEditor`、`AssetTools` 等 Editor 模块引用 | 非 Editor 构建链接失败 |

### 3.3 运行时依赖检查

| 检查项      | 搜索关键词                                                                                      | 问题表现                            | 修复方式                               |
| -------- | ------------------------------------------------------------------------------------------ | ------------------------------- | ---------------------------------- |
| GPU/渲染依赖 | `GEngine->GameViewport`、`FSceneView`、`UGameViewportClient`、`GetWorld()->GetGameViewport()` | `-NullRHI` 下 crash 或 null deref | 添加 `nullptr` 检查，跳过渲染相关路径           |
| 弹窗/对话框   | `FMessageDialog`、`OpenMsgDlgInt`、`FPlatformMisc::MessageBoxExt`                            | `-Unattended` 下卡住（等待用户点击）       | 改为 `UE_LOG` + 返回值                  |
| 编辑器 UI   | `FLevelEditorModule`、`SLevelViewport`、`FAssetEditorManager`                                | 启动 crash 或功能不可用                 | 条件编译，提供命令行替代方案                     |
| 关卡加载     | `UGameplayStatics::OpenLevel`、`UWorld::ServerTravel`、`LoadMap`                             | `-NullRHI` 下关卡可能加载失败            | 使用 transient package 创建测试对象，避免依赖关卡 |
| Slate UI | `SNew`、`FSlateApplication`、`AddWindow`                                                     | `-NullRHI` 下 Slate 可能不可用        | 避免在启动路径创建 Slate widget             |
| 文件对话框    | `IDesktopPlatform::OpenFileDialog`、`FPlatformMisc::FileDialog`                             | 卡住等待用户选择文件                      | 用命令行参数传递文件路径                       |

### 3.4 日志验证

在 `-NullRHI -Unattended` 模式下，日志是最重要的调试手段：

```bash
# 运行测试并保存日志
UnrealEditor.exe MyProject.uproject -NoSplash -NullRHI -Unattended \
    -ExecCmds="Automation RunTests MyPlugin; Quit" \
    -Log 2>&1 | tee test_output.log
```

关键日志标记：

- `LogAutomationController: ... Test Passed` — 测试通过
- `LogAutomationController: Error: ... Test Failed` — 测试失败
- `[FAIL]` — 自定义测试宏的失败标记
- `Fatal error` — 致命错误，进程 crash

### 3.5 完整验证清单

按顺序执行以下步骤，全部通过则功能确认支持无头 CMD：

| 步骤       | 命令/操作                                                                               | 预期结果                                         |
| -------- | ----------------------------------------------------------------------------------- | -------------------------------------------- |
| 1. 基础启动  | `UnrealEditor.exe Project.uproject -NoSplash -NullRHI -Unattended -ExecCmds="Quit"` | 进程正常退出，无 crash                               |
| 2. 模块加载  | 检查日志中是否有模块加载成功的信息                                                                   | 日志包含 `LogModuleManager: ... Loaded MyPlugin` |
| 3. 测试列表  | `-ExecCmds="Automation List; Quit"`                                                 | 输出中包含你的测试名称                                  |
| 4. 单条测试  | `-ExecCmds="Automation RunTests MyPlugin.SimpleTest; Quit"`                         | 测试通过，无 crash                                 |
| 5. 批量测试  | `-ExecCmds="Automation RunTests MyPlugin.All; Quit"`                                | 所有测试通过                                       |
| 6. 长时间运行 | 批量测试循环运行 10 次                                                                       | 无内存泄漏，无随机失败                                  |
| 7. CI 集成 | 在 CI 环境中运行（通常无 GPU）                                                                 | 与本地结果一致                                      |

---

## Part 4: CI/CD 集成模板

### 4.1 PowerShell 脚本

```powershell
# run_tests.ps1
param(
    [string]$ProjectPath = "E:\MyProject\MyProject.uproject",
    [string]$TestFilter = "MyPlugin"
)

$UE_EDITOR = "D:\UnrealEngine\Engine\Binaries\Win64\UnrealEditor.exe"
$LOG_FILE = "test_output_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

& $UE_EDITOR $ProjectPath `
    -NoSplash `
    -NullRHI `
    -Unattended `
    -ExecCmds="Automation RunTests $TestFilter; Quit" `
    -Log 2>&1 | Tee-Object -FilePath $LOG_FILE

$FAIL_COUNT = (Select-String -Path $LOG_FILE -Pattern "\[FAIL\]" -AllMatches).Matches.Count

if ($FAIL_COUNT -gt 0) {
    Write-Host "❌ $FAIL_COUNT test(s) FAILED"
    exit 1
} else {
    Write-Host "✅ All tests PASSED"
    exit 0
}
```

### 4.2 Jenkins / GitHub Actions 片段

```yaml
# .github/workflows/ue-tests.yml
- name: Run UE Automation Tests
  run: |
    powershell -File run_tests.ps1 -TestFilter "MyPlugin"
```

---

## Part 5: 常见问题排查

### 启动就 crash

```bash
# 1. 先用最小参数启动，确认基础环境
UnrealEditor.exe Project.uproject -ExecCmds="Quit"
# 如果这个也 crash，说明不是 -NullRHI 的问题

# 2. 逐步添加参数，定位问题
UnrealEditor.exe Project.uproject -NoSplash -ExecCmds="Quit"       # ✅?
UnrealEditor.exe Project.uproject -NoSplash -NullRHI -ExecCmds="Quit"  # 💥?
UnrealEditor.exe Project.uproject -NoSplash -Unattended -ExecCmds="Quit" # 💥?
```

### 测试注册了但找不到

```
Error: No tests found matching 'MyPlugin'
```

**原因**：

- 模块未被加载（检查 Build.cs 和 .uplugin/.uproject 中的模块注册）
- 测试文件未编译进 Editor 构建（检查 `Target.bBuildEditor` 条件）
- `IMPLEMENT_SIMPLE_AUTOMATION_TEST` 的路径字符串写错了

**验证**：先用 `Automation List` 列出所有测试，确认测试名。

### 测试通过但进程退出码不为 0

UE Editor 的退出码反映的是 Editor 进程本身是否正常退出，**不反映测试结果**。测试失败表现为日志中的 `[FAIL]` 或 `Error:` 标记，需要解析日志来判定。

### NullRHI 下某些 API 返回 null

`GEngine->GameViewport`、`FSlateApplication::IsInitialized()` 等在 `-NullRHI` 下返回 null/false。始终在调用前添加 null 检查，并设计降级路径。

---

## Part 6: 如何添加自定义控制台命令（供 `-ExecCmds` 调用）

`-ExecCmds` 实际上就是向引擎注入控制台命令。你可以注册自定义命令，让无头模式下执行任意逻辑。UE 提供了三种注册方式：

### 6.1 方式一：`IConsoleManager::RegisterConsoleCommand`（手动注册）

在模块的 `StartupModule()` 或构造函数中调用，适合需要动态管理生命周期的场景：

```cpp
#include "HAL/IConsoleManager.h"

void FMyModule::StartupModule()
{
    // 注册无参数命令
    IConsoleManager::Get().RegisterConsoleCommand(
        TEXT("MyPlugin.DoSomething"),
        TEXT("Do something useful"),
        FConsoleCommandDelegate::CreateLambda([]()
        {
            UE_LOG(LogTemp, Log, TEXT("MyPlugin.DoSomething executed!"));
        }),
        ECVF_Default
    );

    // 注册带参数的命令
    IConsoleManager::Get().RegisterConsoleCommand(
        TEXT("MyPlugin.DoSomethingWithArgs"),
        TEXT("Do something with arguments. Usage: MyPlugin.DoSomethingWithArgs <Value>"),
        FConsoleCommandWithArgsDelegate::CreateLambda([](const TArray<FString>& Args)
        {
            for (const FString& Arg : Args)
            {
                UE_LOG(LogTemp, Log, TEXT("Arg: %s"), *Arg);
            }
        }),
        ECVF_Default
    );
}
```

**启动时调用**：
```bash
UnrealEditor.exe MyProject.uproject -NoSplash -NullRHI -Unattended \
    -ExecCmds="MyPlugin.DoSomething; MyPlugin.DoSomethingWithArgs hello world; Quit"
```

### 6.2 方式二：`FAutoConsoleCommand`（静态全局注册——推荐）

构造即注册，销毁即注销。在 .cpp 文件中定义为静态/全局变量，最简单：

```cpp
#include "HAL/IConsoleManager.h"

// 无参数命令
static FAutoConsoleCommand GMyPluginDoSomething(
    TEXT("MyPlugin.DoSomething"),
    TEXT("Do something useful"),
    FConsoleCommandDelegate::CreateLambda([]()
    {
        UE_LOG(LogTemp, Log, TEXT("MyPlugin.DoSomething executed!"));
    })
);

// 带参数命令
static FAutoConsoleCommand GMyPluginDoSomethingWithArgs(
    TEXT("MyPlugin.DoSomethingWithArgs"),
    TEXT("Do something with arguments. Usage: MyPlugin.DoSomethingWithArgs <Value>"),
    FConsoleCommandWithArgsDelegate::CreateLambda([](const TArray<FString>& Args)
    {
        for (const FString& Arg : Args)
        {
            UE_LOG(LogTemp, Log, TEXT("Arg: %s"), *Arg);
        }
    })
);
```

**`FAutoConsoleCommand` 支持的委托类型**：

| 委托类型 | 用途 |
|----------|------|
| `FConsoleCommandDelegate` | 无参数、无返回值 |
| `FConsoleCommandWithArgsDelegate` | 接收 `const TArray<FString>&` 参数 |
| `FConsoleCommandWithWorldDelegate` | 接收 `UWorld*`（适合需要 World 上下文的命令） |
| `FConsoleCommandWithOutputDeviceDelegate` | 接收 `FOutputDevice&`（可自定义输出目标） |
| `FConsoleCommandWithWorldArgsAndOutputDeviceDelegate` | 全部组合 |

### 6.3 方式三：`UFUNCTION(Exec)`（UObject 成员函数）

在 `UObject` 派生类（如 `UGameInstance`、`APlayerController`、`UCheatManager` 等）中直接声明：

```cpp
// MyGameInstance.h
UCLASS()
class UMyGameInstance : public UGameInstance
{
    GENERATED_BODY()

    UFUNCTION(Exec)
    void MyCustomCommand();
};

// MyGameInstance.cpp
void UMyGameInstance::MyCustomCommand()
{
    UE_LOG(LogTemp, Log, TEXT("MyCustomCommand executed via Exec!"));
}
```

**限制**：
- 必须是 `UObject` 派生类成员
- 仅在 `UGameInstance`、`APlayerController`、`APawn`、`AHUD`、`UCheatManager` 等特定类中自动生效
- 更适合 Runtime/Game 模式，Editor 模式下需要确保 Exec 链可达
- **若要在 Editor 无头 CMD 下稳定使用，推荐方式一或二（全局注册）**

### 6.4 标志位说明（`ECVF_*`）

```cpp
ECVF_Default      // 默认，发布版和开发版都可用
ECVF_Cheat        // 作弊命令，仅在开发版可用
ECVF_ReadOnly     // 只读变量
ECVF_SetByConsole // 可通过控制台修改
```

### 6.5 在无头模式下混合自定义命令与自动化测试

常见的无头工作流：先执行自定义设置命令，再跑测试：

```bash
UnrealEditor.exe MyProject.uproject -NoSplash -NullRHI -Unattended \
    -ExecCmds="MyPlugin.PreTestSetup; Automation RunTests MyPlugin.All; MyPlugin.PostTestCleanup; Quit"
```