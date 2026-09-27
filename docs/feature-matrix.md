# validator：feature 组合与最小版本契约门禁

本文档记录 feature 组合矩阵门禁（`scripts/feature-matrix.sh`）的设计取舍、
失败分类与验证证据。门禁、负向测试（`scripts/feature-matrix-test.sh`）与
本说明同步提交；所有证据均可断网重现（见文末「复现」）。

## 目标

- 用精简矩阵覆盖核心库、`derive`、全部可选验证器（`card`、`indexmap`）与
  最小 Rust 版本（MSRV，workspace `rust-version = 1.88`）。
- 每个组合编译并运行一个真实使用 fixture（`validator/examples/*_fixture.rs`），
  而不是只检查 Cargo 元数据。
- 离线执行：准备阶段 `cargo fetch --locked`，门禁与验收全部
  `--locked --offline`，禁止网络型验证。
- 共享 `target/` 目录可复用，但前一组合的 feature 不得泄漏到下一组合。
- 失败分类与诊断输出覆盖：共享 target 的 feature 污染、MSRV、依赖锁定；
  边界行为不依赖随机调度或重试次数。

## 矩阵设计：组合覆盖率 vs 执行成本

可选 feature 为 `derive`、`card`、`indexmap`（`derive_nightly_features` 见
「预期不支持的组合」）。全组合为 2^3 = 8 个；精简矩阵取 6 个组合：

| 组合 | feature | 工具链 | fixture |
| --- | --- | --- | --- |
| `core` | 无（`--no-default-features`） | 默认 stable | `core_fixture` |
| `derive` | `derive` | 默认 stable | `derive_fixture` |
| `card` | `card` | 默认 stable | `card_fixture` |
| `indexmap` | `indexmap` | 默认 stable | `indexmap_fixture` |
| `all-stable` | `derive,card,indexmap` | 默认 stable | 三个 feature fixture |
| `msrv-core` | 无 | 已装工具链中 ≥ MSRV 的最低版本 | `core_fixture` |

取舍理由：

- 每个可选 feature 单独一个组合，可定位回归到具体 feature；`all-stable`
  并集组合捕获 feature 交互与 unification 问题（如 `indexmap` 扩展
  `ValidateLength` 后与 `derive` 生成代码共存）。两两/全组合（如
  `derive+card` 单独跑）被 `all-stable` 吸收，省去 2 个组合的成本。
- `msrv-core` 只跑核心库：MSRV 风险集中在基础 API 与依赖解析，derive 的
  proc-macro 依赖链在 stable 组合已覆盖；为每个组合都加 MSRV 变体会让
  成本翻倍而边际收益低。
- 成本实测（本机，共享 `target/`）：冷启动约 12s，热缓存约 3s；主要成本
  是 `derive` 组合的 proc-macro 依赖链（syn/darling）。fixture 复用上一
  组合的增量产物，不重复全量编译。
- 资源边界与关闭路径：组合顺序执行、无后台任务、无重试；日志只写
  `target/feature-matrix/logs/`（被 `target/` 的 gitignore 覆盖）；脚本
  退出后不留下后台工作或临时产物。

## 共享 target 目录的 feature 污染

分析：cargo 按「包 + feature 集 + 工具链」做指纹，共享 `target/` 在不同
组合间切换时会自动重编受影响单元，本身不会串 feature。真实的污染向量是
调用方环境：组合间泄漏的环境变量、feature 标志拼写错误、脚本变量复用。

备选方案与取舍：

- **每组合独立 `CARGO_TARGET_DIR`**：隔离最彻底，但每个组合全量重编，
  成本约为共享目录的 6 倍，且违背「目标目录可复用」的要求 —— 未采用。
- **共享 `target/` + 守卫 fixture（采用）**：`core_fixture` 内置运行时
  守卫，仅当门禁通过 `VALIDATOR_MATRIX_CORE_COMBO=1` 声明「本组合无
  feature」时武装；一旦 `derive`/`card`/`indexmap` 任一泄漏进 core 组合，
  fixture 退出非零并打印 `feature pollution: ...`，门禁分类为
  `feature-pollution`。守卫用 `option_env!` 武装，因此
  `cargo test --workspace --all-features` 只编译不运行它时不会误伤。
- 泄漏可捕获性由负向测试 `leak-injection` 证明：通过测试钩子
  `VALIDATOR_MATRIX_INJECT_FEATURES=card` 构造一次泄漏，门禁必须以
  `class=feature-pollution` 失败。

## MSRV 与依赖锁定

依赖锁定（采用）：

- `Cargo.lock` 从 `.gitignore` 移除并入库，workspace 级锁定。
- 准备：`cargo fetch --locked`（唯一允许联网的步骤）。
- 门禁、负向测试、验收（`cargo test --locked --workspace --all-features`）
  全部 `--locked`；门禁内部另加 `--offline`。锁文件缺失/漂移 →
  `class=lockfile`。

MSRV 备选方案：

- **(a) 精确 1.88 工具链**：最严格，但本离线环境只装了
  1.82.0 / 1.94.0 / 1.98.1 / nightly，禁止网络导致无法安装 1.88 —— 未采用。
- **(b) 已装工具链中 ≥ MSRV 的最低版本作为 floor（采用）**：当前选中
  1.94.0 跑 `msrv-core`；另用 1.82.0（< MSRV）做负向测试，cargo 拒绝
  （`edition2024` / `rust-version` 不满足）→ `class=msrv`。若将来环境装
  了 1.88，floor 选择逻辑会自动优先选中它（取 ≥ MSRV 的最低版本）。
- **(c) `cargo msrv` 等外部工具**：需联网安装 —— 未采用。
- 已知边界：floor 不等于精确 MSRV；锁定依赖的 `rust-version` 由解析器
  在锁定版本上保证，1.88 的精确验证需在可联网环境安装该工具链后重跑
  门禁（无需改代码）。

## 失败分类与诊断输出

每个组合输出一行确定的 key=value（固定顺序、`LC_ALL=C`、无时间戳、无
重试，重复运行逐字节一致）：

```
combo=core rustc=1.98.1 target=aarch64-apple-darwin features=none fixtures=core_fixture result=pass
combo=core rustc=1.98.1 target=aarch64-apple-darwin features=none+injected:card fixtures=core_fixture result=fail class=feature-pollution crate=validator log=target/feature-matrix/logs/core.log
```

失败分类（`class=`）：

| 分类 | 含义 | 触发示例 |
| --- | --- | --- |
| `lockfile` | `Cargo.lock` 缺失或与清单漂移 | 负向测试 `lockfile-drift` |
| `msrv` | 工具链低于 MSRV / edition 不受支持 / `#![feature]` 用于 stable | 负向测试 `below-msrv`（1.82.0） |
| `unknown-feature` | 组合引用了不存在的 feature | 负向测试 `unknown-feature`（`unic`） |
| `feature-pollution` | 可选 feature 泄漏进声明为无 feature 的组合 | 负向测试 `leak-injection` |
| `test` | 编译通过但断言/单测失败 | fixture 断言失败 |
| `compile` | 其余编译错误（兜底） | 普通编译错误 |

诊断行同时给出 `rustc`、编译目标 `target` 与失败 crate（从 cargo 输出
`could not compile \`<crate>\`` 提取，默认 `validator`），完整日志路径
随 `log=` 给出。

## 预期不支持的组合（显式说明）

- **`unic`**：上游 0.19+ 已移除该 feature（Unicode 支持改由 regex 内置）。
  组合引用它会被门禁分类为 `unknown-feature`，由负向测试锁定该行为。
- **`derive_nightly_features` 的真实 nightly 诊断**：`proc-macro-error3`
  的 `nightly` feature 含 `#![feature(proc_macro_diagnostic)]`，在非
  nightly 工具链上必然 E0554；而 `--all-features` 会启用 workspace 全部
  feature，导致验收命令 `cargo test --locked --workspace --all-features`
  在 stable/MSRV 工具链上无法编译。取舍：`validator_derive` 的
  `nightly_features` 保留为 no-op（feature 名兼容，`derive_nightly_features`
  仍隐含 `derive`），nightly 诊断组合列为预期不支持。未使用该功能的
  调用者不受任何影响；显式 opt-in 的 nightly 用户失去的仅是更丰富的
  诊断文案，宏行为不变。
- **精确 1.88 工具链组合**：离线环境未安装；若无任何 ≥ MSRV 的工具链，
  `msrv-core` 输出 `result=unsupported` 显式跳过而非假通过。

## 对调用者的影响

- 未改动 `validator`/`validator_derive` 的任何模块边界与公开入口；
  fixture 是 examples，不进入库产物，生产调用者零行为/性能回退。
- 唯一行为变化是上述 `nightly_features` no-op 化，已记录。

## 验证证据（断网重现）

准备（唯一联网步骤）：

```
$ cargo fetch --locked
（Cargo.lock 已锁定 69 个包，fetch 无输出即成功）
```

门禁（`CARGO_NET_OFFLINE=true` 模拟断网，输出与有网一致）：

```
contract msrv=1.88 lockfile=locked offline=1 target_dir=shared
combo=core rustc=1.98.1 target=aarch64-apple-darwin features=none fixtures=core_fixture result=pass
combo=derive rustc=1.98.1 target=aarch64-apple-darwin features=derive fixtures=derive_fixture result=pass
combo=card rustc=1.98.1 target=aarch64-apple-darwin features=card fixtures=card_fixture result=pass
combo=indexmap rustc=1.98.1 target=aarch64-apple-darwin features=indexmap fixtures=indexmap_fixture result=pass
combo=all-stable rustc=1.98.1 target=aarch64-apple-darwin features=derive,card,indexmap fixtures=derive_fixture,card_fixture,indexmap_fixture result=pass
combo=msrv-core rustc=1.94.0 target=aarch64-apple-darwin features=none fixtures=core_fixture result=pass
summary total=6 passed=6 failed=0 unsupported=0
```

负向测试：

```
negtest=leak-injection result=pass class=feature-pollution
negtest=unknown-feature result=pass class=unknown-feature
negtest=below-msrv result=pass class=msrv
negtest=lockfile-drift result=pass class=lockfile
summary total=4 passed=4 failed=0 unsupported=0
```

稳定性：连续两次 `bash scripts/feature-matrix.sh` 输出 `diff` 为空。

验收：

```
$ cargo test --locked --workspace --all-features
（全部 test result: ok，含 trybuild 编译失败用例 62 项与 doc-tests；退出码 0）
```

## 复现

```bash
cargo fetch --locked                                # 准备（联网，一次）
CARGO_NET_OFFLINE=true bash scripts/feature-matrix.sh        # 门禁
CARGO_NET_OFFLINE=true bash scripts/feature-matrix-test.sh   # 负向测试
cargo test --locked --workspace --all-features               # 验收
```
