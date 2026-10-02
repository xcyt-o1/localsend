# LocalSend Chat 验证记录

验证日期：2026-10-02。官方基线：`fcf9e98f358cc85c75cb38e6e0ee73d8590c113e`。开发分支：`feature/local-chat`；只推送自己的 fork，不创建 PR。

## 已完成的自动检查

| 检查 | 结果 |
| --- | --- |
| 应用 `flutter analyze` | 通过，无问题 |
| 应用 `flutter test` | 81 项通过；含 6 项数据库测试及 Windows 键盘测试 |
| isolates 包 `flutter analyze` | 通过，无问题 |
| isolates 包 `flutter test` | 22 项通过；原生 DLL 桥接和取消文件会话均实际运行 |
| Rust core 聊天集成测试 | 5 项通过 |
| Rust core 全量测试 | 148 项通过，排除下述 2 项已复现的基线失败 |
| Rust core `cargo clippy --features full --all-targets` | 通过；存在上游既有警告 |
| `cargo check --package rust_lib_localsend_app --package localsend-cli` | 通过 |
| FRB 2.12.0 / build_runner / slang | 已生成，生成代码与功能一起提交 |
| Windows Release | 构建通过；包含完整 DLL、SQLite 原生资产和 data 目录 |
| Windows Release 启动及 HTTPS 检查 | 独立测试 APPDATA 中实际启动并创建 `chat.sqlite`；固定证书的 mTLS 查询 info；未授权拒绝；预置 SQLite 授权夹具后验证中文/多行落盘、重复请求同一确认且只有 1 条记录、冲突 409、撤销后 403 且历史保留 |
| Windows 便携模式与移动目录 | 通过；中文及空格目录中实际启动，设置和数据库写入程序旁；移动后证书不变、原数据库保留，聊天接口继续工作 |
| Android 签名 Release APK | 构建通过；`apksigner verify` 验证 v2 签名、自己的 RSA 4096 证书；applicationId 和标签核对通过 |
| Android 原生库与打包对齐 | ARMv7 / ARM64 / x86_64 均包含 Rust 和 SQLite；NativeAssetsManifest 三架构齐全；ZIP 16 KiB 对齐及两种 64 位架构的 Rust/SQLite ELF LOAD 对齐检查通过 |

数据库测试验证 125 条消息分 3 页完整读取、按本地顺序处理时钟偏差、正文与 UTC 时间落盘、磁盘重启恢复、授权/撤销/关闭聊天、未读与已读、清空历史不取消授权、相同 ID 去重及不同正文冲突。重复请求返回最初的毫秒精度确认时间。

Rust 测试验证正文和请求体字节边界、空白/无效 UUID/时间拒绝、HTTPS 和客户端证书要求、网页匿名客户端拒绝、错误证书固定拒绝、独立请求 ID 并发响应、等待持久化确认，以及文件会话占用时仍能聊天。桥接测试使用真实 Rust DLL，逆序响应并发请求，检查证书身份和请求关联；同时修复服务停止后事件流不能结束的问题。

键盘测试验证 Windows Enter 发送中文与表情、发送后清空输入框、Shift+Enter 换行、输入法组合输入时 Enter 不发送。Android 键盘及真实 Windows 输入法仍属于实机项目。

## 官方基线已有的两项失败

在独立 checkout 的**未修改官方基线**上，以同一 Windows / Rust 环境重复运行了以下测试，得到相同失败：

- `model::transfer::tests::formats_nanosecond_timestamp`：Windows 文件时间只保留 100 ns 精度，纳秒格式断言不一致。
- `test_register_over_ipv6`：本机 IPv6 loopback 连接被 Windows 拒绝，错误 `10013 / PermissionDenied`。

没有修改这些测试来掩盖失败。其余 core 测试用下列命令运行并通过：

```powershell
cargo test --package localsend --features full -- --skip formats_nanosecond_timestamp --skip test_register_over_ipv6
```

## 尚需 Windows ↔ Android 实机验收

这些项目没有用构建成功替代，也没有宣称已通过：

本机 `adb devices -l` 未发现 Android 设备，故没有执行实机安装和双设备界面验收。

- 首次授权接受/拒绝、身份图标核对、撤销及重新授权、不同证书设备。
- 双向连续与同时互发、中文输入法、表情、多行、时间戳、超过 30 条和翻页、未读与重启。
- 断网、确认丢失后同 ID 重试、数据库写入失败的界面反馈。
- 文件传输期间聊天、原版手动 `IP:53317` 文件互通和不支持聊天提示。
- 原版与 fork 同时运行无冲突；便携目录移动已自动验证，仍建议在自己的使用目录再次检查。
- Android 切后台被暂停后恢复，再由发送方手动重试。

完成这些验收后才把功能合入自己 fork 的 `chat-main` 并发布。当前产物用于验收；不会创建上游 PR。

## 本机重现和产物

工具环境：`D:\code\.localsend-tools\env.ps1`。构建和检查日志：`D:\code\.localsend-tools\*.log`，不提交到仓库。Flutter 固定为 3.41.9（Dart 3.11.5），Rust 1.97.1，FRB codegen 2.12.0，Visual Studio 2022 C++ Build Tools，JDK 17，SDK / build-tools 36，NDK 28.2.13676358。

Windows 插件目录用 junction 准备，无需更改 Windows 开发者模式；SQLite build hook 产物和仓库已有 VC 运行库由新增的 CMake 安装规则复制。首次 Android 构建使用官方 Gradle/Maven/Google 源；两个 Flutter 引擎 JAR 长时间停顿后，改用 [Flutter 文档列出的 CFUG 镜像](https://docs.flutter.dev/community/china) 下载相同固定引擎版本，核对 Google Storage 的官方对象校验和。镜像仅用于此次构建的进程环境，没有修改全局配置或仓库依赖源。

构建日志中有 Kotlin 增量缓存跨 C / D 盘路径异常，编译器自动回退后构建成功；以及 Google Billing 库的 R8 信息提示。这些不作为成功测试隐藏处理。后续跨盘构建可按 README 临时关闭 Kotlin 增量编译。四个 Flutter 引擎 JAR 已逐一核对 Google 官方对象长度和 MD5 校验和。

验收产物放在 `app/dist`：`LocalSendChat-1.18.2-chat.1-windows-x64.zip`、`LocalSendChat-1.18.2-chat.1-android-universal.apk`，旁边提供 `SHA256SUMS.txt`。Windows ZIP 保留完整 Release 目录、许可证和本 fork 的使用说明。

Android 签名密钥和密码在仓库外的 `D:\code\.localsend-tools\signing`。必须离线备份并长期保留；后续更新不能更换密钥或 applicationId。不会将密码或密钥提交/上传到 fork。
