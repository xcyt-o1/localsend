# LocalSend Chat fork

基于 LocalSend `fcf9e98f358cc85c75cb38e6e0ee73d8590c113e`，维护分支为 `feature/local-chat`，不向上游创建 PR。上游代码、署名和 MIT 许可证保留。

## 使用

1. 在 Windows 和 Android 上运行 LocalSend Chat，并连接同一局域网。
2. 保持网络设置中的加密开启。在「聊天」中选择附近设备，点击「请求聊天」。接收方核对设备验证图标后接受。
3. 双方随后可以连续发送文字；每条显示本地时间 `HH:mm:ss`，按本地记录顺序排列。Windows Enter 发送，Shift+Enter 换行，输入法组合输入期间不触发发送；Android 使用发送按钮。
4. 「发送未确认」表示没有收到落盘确认，包括对方离线和确认响应丢失。手动重试会使用原消息 ID；不会自动重发。发送中的记录在重启后转为未确认。
5. 长按/选中文字或使用复制按钮复制消息。聊天设置可关闭聊天、撤销设备授权和清空记录；清空仅影响本机，不撤销授权，撤销授权也不删除旧消息。

历史保存在本机 SQLite 数据库，不设 30 条上限，每次读取 50 条。数据库保存 UTC 时间、双方记录和证书指纹。昵称或 IP 改变不会创建新会话，证书改变会创建新设备身份。纯空白消息被忽略，正文最大 UTF-8 32 KiB。

聊天仅覆盖一对一局域网文字。没有附件、群聊、云同步、已读回执或 Android 常驻后台服务。Android 被系统暂停时不能保证接收；保持程序在前台，或恢复运行后让发送方手动重试。

## 与原版并存

| 项目 | Chat fork |
| --- | --- |
| TCP / UDP 默认端口 | `53318` |
| Windows 程序 | `localsend_chat.exe` |
| Windows 设置 / 数据库 | `%APPDATA%\LocalSendChat\settings.json` / `chat.sqlite` |
| Windows 便携模式 | 程序旁的 `settings.json` / `chat.sqlite` |
| Windows 自启动 / SendTo | `LocalSendChat` / `LocalSend Chat` |
| Android 发布 applicationId | `org.localsend.localsend_app.chat` |
| 可选 Windows MSIX 身份 | `LocalSend.Chat` |

原版仍使用 `53317`。向原版传文件时在发送页手动添加原版 `IP:53317`；在设备详情尝试聊天会提示不支持，普通文件传输保持可用。不要把原版设置、证书或历史复制进 fork。

Windows ZIP 解压后运行整个目录中的程序，不能只复制 EXE。便携模式应在启动前准备程序旁的 `settings.json`；移动时保留整个目录。可选 Windows Share Target helper 需要自己的签名，ZIP 的基本文件发送和聊天不依赖安装它。

全新便携目录可在启动前执行 `[IO.File]::WriteAllText("$PWD\settings.json", '{}')`。已有设置文件时不要覆盖它。

## 构建

安装 Git、Flutter 3.41.9、Rust 1.97.1、FRB codegen 2.12.0、JDK 17、Android SDK 36、NDK 28.2.13676358；Windows 安装 Visual Studio 的 Desktop development with C++ 工作负载。用 FVM 或仓库固定的 Flutter 子模块，避免混用不同 SDK。

```powershell
git clone https://github.com/xcyt-o1/localsend.git
Set-Location localsend
git remote add upstream https://github.com/localsend/localsend.git
git switch feature/local-chat
git submodule update --init support/submodules/flutter
$env:Path = "$PWD\support\submodules\flutter\bin;" + $env:Path
Set-Location app
flutter pub get
```

Windows 如果未启用符号链接权限，可在 `flutter pub get` 已写出 `.flutter-plugins-dependencies` 后从仓库根目录运行 `support/scripts/setup_windows_plugin_junctions.ps1`，用目录 junction 准备插件目录，再重试。不要移动/删除 junction 指向的 Pub 缓存内容。

如果 Flutter 引擎下载停顿，可按 [Flutter 中国网络文档](https://docs.flutter.dev/community/china) 在当前 PowerShell 中设置 `$env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'` 后重试。本次使用的引擎版本保持固定。

Windows 上若项目在 D 盘、Pub 缓存在 C 盘，Kotlin 增量缓存可能报 `different roots`。可依照 [Kotlin 增量编译说明](https://kotlinlang.org/docs/gradle-compilation-and-caches.html#incremental-compilation)，通过 [Gradle 进程环境属性](https://docs.gradle.org/current/userguide/build_environment.html#sec:project_properties) 临时关闭增量编译后构建：

```powershell
[Environment]::SetEnvironmentVariable('ORG_GRADLE_PROJECT_kotlin.incremental', 'false', 'Process')
flutter build apk --release
```

```powershell
Set-Location ..\packages\localsend_isolates
flutter_rust_bridge_codegen generate
dart run build_runner build
flutter analyze
flutter test
Set-Location ..\..\app
dart run build_runner build
dart run slang
flutter analyze
flutter test
Set-Location ..
cargo clippy --package localsend --features full --all-targets
cargo test --package localsend --features full
cargo check --package rust_lib_localsend_app --package localsend-cli
cargo build --package rust_lib_localsend_app
Set-Location packages\localsend_isolates
flutter test test/task/server/chat_bridge_test.dart
```

数据库 schema 目前为版本 1，手写 SQL 迁移位于 `app/lib/chat/chat_database.dart`，所有数据库查询由 `NativeDatabase.createInBackground` 执行。未来结构变更必须增加迁移，不能删除数据库来升级。

Windows 先在仓库根目录、Windows SDK Developer PowerShell 下运行 `support/scripts/compile_windows_msix_helper.ps1`，准备构建引用的可选 helper，再构建：

```powershell
Set-Location app
flutter build windows --release
flutter build apk --release
```

Android 使用自己的持久签名密钥。可将 `key.properties` 放在仓库外，通过 `LOCALSEND_CHAT_KEY_PROPERTIES` 环境变量指定其绝对路径，文件含 `storeFile`、`storePassword`、`keyPassword`、`keyAlias`。密钥、密码及备份不能提交到 Git；以后升级必须使用同一 applicationId 和签名。

本机的签名文件位置为 `D:\code\.localsend-tools\signing`。本机工具环境为 `D:\code\.localsend-tools\env.ps1`，只用于此电脑，不属于发布代码。

## 验证与发布门槛

自动检查覆盖 SQLite 落盘、125 条历史/分页、未读、取消授权、清空、重启恢复、重复确认/冲突、UTF-8 限制、HTTPS/mTLS、匿名网页客户端拒绝、错误证书固定、并发请求关联和文件会话期间聊天。原生桥接测试使用真实 Rust DLL。详细结果在 `CHAT_VERIFICATION.md`。

发布前仍需在 Windows ↔ Android 实机验收授权/拒绝/重新授权、同时互发、中文输入法、断网和确认丢失后的重试、原版文件互通、两版同时运行、便携目录移动以及 Android 切后台后恢复。构建成功不等于这些实机项目已通过。

验证通过后再合入自己 fork 的长期维护分支 `chat-main`，发布 Windows ZIP 和签名 APK。同步上游采用 merge，保留发布历史：

```powershell
git fetch upstream
git switch chat-main
git merge upstream/main
# 解决冲突，重新生成桥接和翻译，运行检查及双设备验收
git push origin chat-main
```

用户主动清空聊天记录后，再次重试已删除的旧消息可能重新出现；去重范围是本机仍保留的记录。取消授权会立即拒收新消息，历史保留。备份时先退出程序，再复制 `settings.json` 和 `chat.sqlite`；数据库迁移后不要直接降级旧程序覆盖数据。
