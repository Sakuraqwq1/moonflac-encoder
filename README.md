# moonflac-encoder

[![CI](https://github.com/Sakuraqwq1/moonflac-encoder/actions/workflows/ci.yml/badge.svg)](https://github.com/Sakuraqwq1/moonflac-encoder/actions/workflows/ci.yml)

纯 MoonBit 实现的 **FLAC 编码器**：把 PCM 采样写成原生 `.flac` 文件。

> 状态：**核心功能可用**。STREAMINFO + MD5、定长块帧与 CRC-8/CRC-16、CONSTANT / VERBATIM / FIXED(0–4) / LPC(1–12) 子帧、Rice 分区搜索、立体声去相关、流式/增量编码均已实现；12 组测试信号中有 11 组的编码体积小于或等于 libsndfile 默认 FLAC 输出。具体版本与变更见 [CHANGELOG](CHANGELOG.md)。

## 安装

```bash
moon add Sakuraqwq1/moonflac-encoder
```

发布在 [mooncakes.io](https://mooncakes.io/docs/Sakuraqwq1/moonflac-encoder)。也可以直接克隆仓库，用 `moon run cmd/main -- selftest` 做一次自检（它会合成一段正弦、编码、再打印结果）。

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
| 定长块帧（通常为每声道 4096 个采样），末块按剩余采样数编码 | ✅ |
| 帧头 CRC-8、帧尾 CRC-16 | ✅ |
| CONSTANT / VERBATIM 子帧 | ✅ |
| FIXED 0–4 阶预测 + Rice 残差（参数搜索） | ✅ |
| 位深 4–32 bit 路径、1–8 声道（4/8/12/16/20/24/32 经官方 Xiph.Org flac 1.4.3 参考解码器验证） | ✅ |
| 立体声去相关（left/side、right/side、mid/side，按位代价选优） | ✅ |
| LPC 子帧（Levinson-Durbin + 15-bit 系数量化 + 移位选择） | ✅ |
| Rice 分区搜索（partition order 1–8） | ✅ |
| 流式 / 增量编码（`StreamEncoder`，STREAMINFO 的总样本数与摘要留空） | ✅ |

定长块流的末块可短于常规块长，保留原始采样数。一次性接口要求输入至少有 16 个采样帧。

## 用法（库）

```moonbit
// 交织的有符号 PCM，已经缩放到 bits_per_sample 的二进制补码范围（遵循 RFC 9639 至少 16 帧）
let samples = Array::make(4096, 0L)
for i = 0; i < 4096; i = i + 1 {
  samples[i] = ((i * 29) % 2048).to_int64() - 1024L
}
let flac : Bytes = @moonflac-encoder.encode(samples, 44100, 1, 16)
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

# 同时输出源 PCM（base64），用于和任意解码器做逐位比对
moon run cmd/main -- gen 44100 2 16 4096 0 --pcm

# MD5 自检，验证摘要实现
moon run cmd/main -- md5 abc
```

`gen` 的最后一个参数：`0` 正弦、`1` 双音、`2` 静音、`3` 锯齿、`4` 伪随机。

## 流式 / 增量编码

`StreamEncoder` 接受按完整声道组切分的交织 PCM。先输出头部，再逐批传入 PCM 并收集完整的音频帧，最后调用 `stream_finish` 输出剩余采样。

将下面的示例保存为 `stream_test.mbt`，并在 `moon.pkg` 中添加测试导入 `import { "Sakuraqwq1/moonflac-encoder" } for "test"`，然后运行 `moon test`。

```moonbit
test "encode interleaved PCM in chunks" {
  // 双声道输入，每个切片的样本数须为 2 的倍数。
  let incoming_pcm = [Array::make(8192, 0L), [0L, 1L]]
  let encoder = @moonflac-encoder.stream_encoder(44100, 2, 16)
  let mut out = @moonflac-encoder.stream_header(encoder)
  for chunk in incoming_pcm {
    out = out + @moonflac-encoder.stream_write(encoder, chunk)
  }
  out = out + @moonflac-encoder.stream_finish(encoder)
  assert_true(out.length() > 42)
}
```

流式模式下 STREAMINFO 的总样本数与 PCM 摘要是 0（RFC 9639 定义为"未知"），因为流开始时两者都还不知道；参考实现 `flac` 输出到管道时也是这么做的。解码仍然正常，只是无法用摘要校验解码结果。需要摘要时用一次性的 `encode`。

## 性能

`python tools/verify.py perf` 实测（Windows，native 目标，16-bit 单声道整数锯齿波，避开信号合成的开销）：**约 80 万样本/秒**（约 18 倍实时，测量波动 ±20%）。

每个声道平面每帧只规划一次，写出直接复用规划结果（含子帧类型、LPC 系数与分区阶）；代价计算、选型与写出共用同一个 Rice 参数搜索函数，因此既没有重复搜索，选型代价与实际写出的位数也严格一致。

## 验证方式

- **Xiph.Org 参考解码器**。使用 `flac 1.4.3` 复测了 4、8、12、16、20、24、32 bit。运行 `python tools/verify.py bitdepths` 可比对源 PCM 与 STREAMINFO 的 MD5，并通过 `flac -t` 检查解码。将 `flac` 加入 PATH，或用环境变量 `FLAC` 指向可执行文件。输出中的 `flac-cli` 列为 `ok` 时表示该项已执行并通过。
- **libsndfile 1.2.2**。实测 8、16、24 bit 可解码。仓库的 `python tools/verify.py matrix` 覆盖 1/2/4/8 声道 × 16/24 bit × 正弦/静音/噪声 × 16/4095/4096/4097 帧，共 96 例。脚本通过 Python `soundfile` 解码，把 PCM 按 FLAC 规范重新打包，并将摘要与 STREAMINFO 的 MD5 比对。

下表列出相同 PCM 经本编码器与 libsndfile 的 FLAC 写入器编码后的文件体积。

| 信号（4096 帧，16-bit） | 本编码器 | libsndfile 默认 FLAC | 差距 |
| --- | --- | --- | --- |
| 单声道正弦 | 1,326 B | 1,285 B | +3.2% |
| 立体声正弦 | 2,549 B | 2,607 B | −2.2% |
| 单声道双音 | 1,634 B | 1,977 B | −17.3% |
| 立体声双音 | 3,124 B | 3,918 B | −20.3% |
| 单声道谐波堆叠 | 1,468 B | 1,723 B | −14.8% |
| 单声道扫频 | 2,583 B | 3,451 B | −25.2% |
| 单声道噪声 | 7,948 B | 7,992 B | −0.6% |
| 单声道音乐型（和弦 + 包络 + 瞬态 + 底噪） | 4,725 B | 4,803 B | −1.6% |
| 立体声音乐型 | 8,767 B | 9,044 B | −3.1% |

（复现：`python tools/verify.py benchmark`）

## 测试

仓库自带可复现的验证脚本（需要 Python 的 `numpy` 与 `soundfile`）：

```bash
python tools/verify.py matrix      # 96 例 libsndfile 解码矩阵，比对 PCM 与 STREAMINFO 摘要
python tools/verify.py bitdepths   # 4/8/12/16/20/24/32-bit 所列位深的源 PCM 摘要与官方 flac 参考解码器验证
python tools/verify.py stream      # 流式增量编码与一次性编码的帧级逐字节一致性验证
python tools/verify.py benchmark   # 同一段 PCM 上与 libsndfile 默认 FLAC 输出的体积对比
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
- **代价精确**：每个子帧候选（CONSTANT / FIXED 0–4 / LPC / VERBATIM）都按**实际位数**计算，包括子帧头、残差头与 Rice 分区搜索——选型时的代价与最终写出的位数完全一致，因此不存在"选了更差的编码"的情况。
- **LPC 与固定预测同等对待**：两种候选都按实际位数计算代价，取最小者；双音素材上 LPC 让单声道从 4,311 B 降到 3,537 B（−18%），立体声从 9,241 B 降到 5,436 B（−41%），而噪声素材不会被误选成 LPC。
- **阶数用残差能量估计**：先算 1..12 阶的自相关与 Levinson-Durbin 递推，用各阶残差能量估出最省的阶，只对该阶及其前后各一阶做精确代价计算，避免逐阶全算。
- **代价用 Int64 累加**：32 位精度会让 24-bit 噪声的位数估算溢出，从而误选编码器写不下的参数——这一点在开发中被矩阵测试抓出过。
- **MD5 自实现**：核心库没有 MD5，而 STREAMINFO 的校验依赖它；实现后用 RFC 1321 标准向量验证。

## 已交付功能与验证

- [x] 流式 / 增量编码（`StreamEncoder`）
- [x] 压缩体积对比（`python tools/verify.py benchmark`）：12 组测试信号中 11 组体积小于或等于 libsndfile 默认 FLAC 输出，最差一组（单声道正弦）高 3.2%
- [x] 4 / 8 / 12 / 16 / 20 / 24 / 32 bit 的官方参考解码器验证（`python tools/verify.py bitdepths`）

## 许可证与参考

Apache-2.0，原创实现。

- 规范：[RFC 9639](https://www.rfc-editor.org/rfc/rfc9639.txt)（FLAC，2024-12）、[xiph.org/flac 格式文档](https://xiph.org/flac/format.html)
- 未复制任何第三方源码；STREAMINFO 的 MD5 语义按 RFC 9639 §8.2 实现（交织、小端、每样本 `ceil(bits/8)` 字节）
