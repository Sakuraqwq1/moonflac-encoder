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

本项目提供纯 MoonBit、零 FFI 的原生 FLAC 写入接口，可在 wasm-gc 和 native 上使用。输出由 Xiph 参考解码器与社区解码器 `Xcsa-ee/moonflac` 验证。生态中的 `CXREN/flac` 提供解码，`0717lee/moonflac` 也提供独立的编码实现。

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

定长块流的末块可短于常规块长，保留原始采样数。一次性和流式接口都要求输入总计至少有 16 个采样帧。

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

实时写入管道时，`stream_header` 将 STREAMINFO 的总采样数和 PCM 摘要设为 RFC 9639 定义的未知值。写入可回填的文件时，成功调用 `stream_finish` 后，用 `stream_final_header` 替换开头 42 字节，即可获得和一次性编码逐字节一致的文件。若已收集音频帧，也可以直接把最终头部拼接在它们之前。

`stream_finish` 会拒绝空流和总长度不足 16 帧的流，可以继续写入达到下限后再收尾。成功收尾后继续写入会返回 `StreamFinished`。v0.6.0 起，原来在非抛错函数中调用 `stream_finish` 的使用方需要处理 `EncodeError`。

## 性能

`python tools/verify.py perf` 实测（Windows，native 目标，16-bit 单声道整数锯齿波）：**约 66 万样本/秒**（约为 44.1 kHz 实时的 15 倍）。

FIXED 会比较各合法阶数的完整 Rice 分区代价。LPC 先根据自相关估计筛选阶数并量化系数，再把候选的实际位数与其他模式比较。写出时复用选定的子帧类型、系数与分区阶。

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
| 单声道音乐型（和弦 + 包络 + 瞬态 + 底噪） | 4,720 B | 4,803 B | −1.7% |
| 立体声音乐型 | 8,767 B | 9,044 B | −3.1% |

（复现：`python tools/verify.py benchmark`）

## 测试

仓库自带可复现的验证脚本（需要 Python 的 `numpy` 与 `soundfile`）：

```bash
python tools/verify.py matrix      # 96 例 libsndfile 解码矩阵，比对 PCM 与 STREAMINFO 摘要
python tools/verify.py bitdepths   # 4/8/12/16/20/24/32-bit 所列位深的源 PCM 摘要与官方 flac 参考解码器验证
python tools/verify.py stream      # 验证回填最终头部后与一次性编码整文件逐字节一致
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
