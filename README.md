# moonflac-encoder

[![CI](https://github.com/Sakuraqwq1/moonflac-encoder/actions/workflows/ci.yml/badge.svg)](https://github.com/Sakuraqwq1/moonflac-encoder/actions/workflows/ci.yml)

纯 MoonBit 实现的 **FLAC 编码器**：把 PCM 采样写成原生 `.flac` 文件。

> 状态：**0.2.0，核心功能可用**。STREAMINFO + MD5、定长块帧与 CRC-8/CRC-16、CONSTANT / VERBATIM / FIXED(0–4) / LPC(1–12) 子帧、Rice 分区搜索、立体声去相关均已实现，并通过 libsndfile 与 `Xcsa-ee/moonflac` 两个独立解码器验证。流式编码与压缩率对齐见「路线图」。

## 为什么需要它

MoonBit 生态里已经有两个 FLAC **解码器**（`Xcsa-ee/moonflac`、`CXREN/flac`），它们都明确写了「不做编码器」。也就是说：

- 解码有，编码没有；
- 用 MoonBit 写的工具、游戏、编辑器，能**读** FLAC，但没法**写出** FLAC；
- 想把素材压缩成无损体积、想在 CI 里生成 `.flac` 测试数据，只能退回 C 工具链。

本项目的目标就是补上"写出"这一半：纯 MoonBit、零 FFI、可在 wasm-gc 与 native 上跑，输出能被参考解码器正常读取。

## 当前能力

| 能力 | 状态 |
| --- | --- |
| `fLaC` 标记 + STREAMINFO（含 PCM 的 MD5） | ✅ |
| 定长块帧（默认 4096），可变块长按尾块处理 | ✅ |
| 帧头 CRC-8、帧尾 CRC-16 | ✅ |
| CONSTANT / VERBATIM 子帧 | ✅ |
| FIXED 0–4 阶预测 + Rice 残差（参数搜索） | ✅ |
| 位深 4–32 bit 路径、1–8 声道（8/16/24 经参考解码器验证；32 bit libsndfile 不支持） | ✅ |
| 立体声去相关（left/side、right/side、mid/side，按位代价选优） | ✅ |
| LPC 子帧（Levinson-Durbin + 15-bit 系数量化 + 移位选择） | ✅ |
| Rice 分区搜索（partition order 1–8） | ✅ |
| 流式 / 增量编码 | ⬜ 计划中 |

## 用法（库）

```moonbit
// 交织的有符号 PCM，已经缩放到 bits_per_sample 的二进制补码范围
let samples : Array[Int64] = [0L, 100L, 200L, 300L]
let flac : Bytes = @moonflac_encoder.encode(samples, 44100, 1, 16)
```

`encode` 的四个参数依次是：交织采样、采样率、声道数、位深。返回值是一个完整的 `.flac` 文件（标记 + STREAMINFO + 若干帧）。

## 用法（命令行）

MoonBit 核心库没有可移植的文件系统 API，所以 CLI 和周边音频工具保持一致，用 base64 传二进制：

```bash
# 自检：合成 1 秒 440 Hz 正弦，编码后打印 base64
moon run cmd/main -- selftest

# 把 base64 的 WAV 编码成 base64 的 FLAC
moon run cmd/main -- encode "$(base64 -w0 input.wav)"

# 生成测试信号（采样率 声道 位深 帧数 类型）
moon run cmd/main -- gen 44100 2 16 4096 0

# MD5 自检，验证摘要实现
moon run cmd/main -- md5 abc
```

`gen` 的最后一个参数：`0` 正弦、`1` 双音、`2` 静音、`3` 锯齿、`4` 伪随机。

## 验证方式

编码器的正确性不是靠"能跑"判断的，而是拿**独立解码器**逐样本比对：

1. 用 MoonBit 编码器产出 `.flac`；
2. 交给 Python `soundfile`（libsndfile，完全独立于 MoonBit 生态）解码；
3. 把解码出的 PCM 按 FLAC 规范（小端、`ceil(bits/8)` 字节）重新拼字节流，算 MD5；
4. 与文件 `STREAMINFO` 里记录的 MD5 比对。

当前矩阵（单/双声道 × 16/24-bit × 正弦/静音/噪声 × 1/4095/4096/4097 帧，共 48 例）全部通过：解码成功、帧数/采样率/声道一致、MD5 一致。典型压缩比（1 秒 440 Hz 正弦）：

| 配置 | FLAC | 原始 PCM | 压缩比 |
| --- | --- | --- | --- |
| 单声道 16-bit | 1,896 B | 8,192 B | 4.31× |
| 单声道 24-bit | 4,034 B | 12,288 B | 3.05× |
| 立体声 16-bit | 3,680 B | 16,384 B | 4.45× |
| 立体声 24-bit | 8,714 B | 24,576 B | 2.82× |
| 立体声 16-bit（两声道相同） | 1,899 B | 16,384 B | 8.61× |

## 测试

仓库自带可复现的验证脚本（需要 Python 的 `numpy` 与 `soundfile`）：

```bash
python tools/verify.py matrix      # 48 例跨解码器矩阵，逐样本比对 STREAMINFO 摘要
python tools/verify.py benchmark   # 同一段 PCM 上与 libFLAC 的体积对比
```


```bash
moon check --deny-warn
moon test  --deny-warn
moon fmt --check
```

单元测试覆盖 MD5 标准向量、CRC-8/CRC-16 标准向量、STREAMINFO 字段、子帧选择、错误路径。

### 与生态内解码器的互操作

除了 libsndfile，本编码器产出的文件也交给生态里已有的纯 MoonBit FLAC 解码器
`Xcsa-ee/moonflac` 解码（单声道/立体声、8/16/24-bit、噪声与块边界共 6 组配置）：
全部解码成功，且它重算的 PCM 摘要与文件 STREAMINFO 中记录的一致。该解码器自带
MD5 校验，因此这等于一个独立的 MoonBit 实现认可了本编码器的输出。

## 实现要点

- **位流优先**：FLAC 帧是连续的位流，所有字段经由一个 MSB-first 的 `BitWriter` 写出，避免手工对齐出错。
- **代价精确**：每个子帧候选（CONSTANT / FIXED 0–4 / VERBATIM）都按**实际位数**计算，包括子帧头与残差头，取最小者；因此不存在"选了更差的编码"的情况。
- **LPC 与固定预测同等对待**：两种候选都按实际位数计算代价，取最小者；双音素材上 LPC 让单声道从 4,311 B 降到 3,537 B（−18%），立体声从 9,241 B 降到 5,436 B（−41%），而噪声素材不会被误选成 LPC。
- **阶数用残差能量估计**：先算 1..12 阶的自相关与 Levinson-Durbin 递推，用各阶残差能量估出最省的阶，只对该阶及其前后各一阶做精确代价计算，避免逐阶全算。
- **代价用 Int64 累加**：32 位精度会让 24-bit 噪声的位数估算溢出，从而误选编码器写不下的参数——这一点在开发中被矩阵测试抓出过。
- **MD5 自实现**：核心库没有 MD5，而 STREAMINFO 的校验依赖它；实现后用 RFC 1321 标准向量验证。

## 路线图

- [ ] 流式 / 增量编码（当前 API 需要整块 PCM 驻留内存）
- [ ] 压缩率对齐 libFLAC：同一段 PCM 上，当前输出比 libFLAC 默认设置大 12%–83%（噪声信号基本持平），差距集中在 LPC 系数量化与分区代价模型
- [ ] 自适应块长
- [ ] 12 / 20 / 32 bit 的参考解码器验证（当前矩阵覆盖 8 / 16 / 24）

## 许可证与参考

Apache-2.0，原创实现。

- 规范：[RFC 9639](https://www.rfc-editor.org/rfc/rfc9639.txt)（FLAC，2024-12）、[xiph.org/flac 格式文档](https://xiph.org/flac/format.html)
- 未复制任何第三方源码；STREAMINFO 的 MD5 语义按 RFC 9639 §8.4 实现（交织、小端、每样本 `ceil(bits/8)` 字节）
