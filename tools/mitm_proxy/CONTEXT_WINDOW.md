# 让客户端看到的上下文窗口 = 实际承载请求的模型窗口

## 问题

模型路由把内置模型 id（`claude-sonnet-5-5`、`gpt-oss-120b` …）转到自家后端（DeepSeek / GLM / 本地推理）。
但 language_server **不探测窗口**：它从 Google 下发的模型目录里读 `maxTokens`，并按这个数字排布上下文预算、
决定什么时候做 checkpoint（上下文压缩）。

于是内置窗口（几十万～上百万）与真实窗口（32k / 128k）立刻对不上：

- 目录说 1M，真实 32k → 压缩永远不触发，一直到上游 4xx 或内容被截断；
- 目录说很小，真实很大 → 只是提前压缩，可接受。

## 落点

`fetchAvailableModels` 的响应就是客户端认知的唯一来源：

```
FetchAvailableModelsResponse.models[modelId] = ModelDetails {
    display_name, supports_images, supports_thinking, thinking_budget,
    recommended, max_tokens, max_output_tokens, tokenizer_type, ...
}
```

`max_tokens` 即客户端认为的窗口，`max_output_tokens` 即它给输出留的额度。
响应本身由 `handler/gemini_handler.go` 的 `handleFetchAvailableModels` 缓存 12h，
所以在**返回响应时**按路由规则改写这两个字段即可，不需要改二进制、不需要 sudo、不需要自建 gateway。

实现见 `tools/mitm_proxy/handler/model_window.go`。

## 配置

在路由规则上加 `options`（与 provider 的 `options` 同构，纯字符串 map）：

```json
{
  "source_model_pattern": "claude-sonnet-5-5",
  "source_type": "google",
  "target_provider_id": "deepseek",
  "target_model": "deepseek-v4-pro",
  "enabled": true,
  "options": { "context_window": "128000", "max_output_tokens": "8192" }
}
```

| option | 写入 | 说明 |
| --- | --- | --- |
| `context_window` | `ModelDetails.maxTokens` | 填**该后端模型的真实输入窗口**；宁小不大 |
| `max_output_tokens` | `ModelDetails.maxOutputTokens` | 独立留够；过大会让上游截断 |

两个键都可单独使用；缺省时保留 Google 原值。未配置 `options` 的规则不影响任何字节（响应原样透传）。

**内置 Gemini 模型不启用自定义窗口**：`target_provider_id == gemini_builtin` 的规则即使带 `options` 也会被忽略
（客户端只看官方窗口，改小只会让它对真实 1M 窗口的模型过度节流），日志会说明原因：
`[Gemini] model window: <model> targets the built-in Gemini provider; custom window ignored`。

也可以在启动器 UI 里直接填：「模型映射 → 模型路由映射规则」每条规则**映射目标模型右侧**的两个输入框
（上下文窗口 / 最大输出），只会收数字，清空即从 `options` 移除；切换目标模型会自动清空这两格
（避免沿用上一个模型的窗口）。LLM Router 规则也可填，按可能命中的最小窗口填。
`launcher` 侧的 `RoutingRule` 已补 `options` 字段参与 Codable 往返，避免 UI 保存时被抹掉
（实测：带 options 的规则保存后字段保留，未填的规则输出中不出现该键）。

## 压缩阈值：不动

客户端有两条压缩配置路径（来自二进制 rodata，v2.34.0，已逐个核对）：

1. **命中内置 profile 表**（12 个条目，键是 `MODEL_*` proto 枚举）：`token_threshold` 全部是 `50000`。

   | profile | max_token_limit | token_threshold | max_output |
   | --- | --- | --- | --- |
   | MODEL_GOOGLE_GEMINI_2_5_FLASH | 128000 | 50000 | 16384 |
   | MODEL_GOOGLE_GEMINI_2_5_PRO | 128000 | 50000 | 16384 |
   | MODEL_OPENAI_GPT_OSS_120B_MEDIUM | 80000 | 50000 | 8192 |
   | MODEL_PLACEHOLDER_M26 | 160000 | 50000 | 16384 |
   | MODEL_PLACEHOLDER_M124 / M400 / M408 | 256000 | 50000 | 32768 |
   | MODEL_PLACEHOLDER_M417 / M432 / M465 / M537 / M667 | 512000 | 50000 | 32768 |
   | 变体键 `.../claude-1m_840k`（`checkpoint-variant` 选中） | 840000 | 50000 | 32768 |

2. **未命中 profile 表** → 日志 `Model %s is falling back to a default checkpoint config. This uses
   the model's defined maxTokens parameter to define the MaxTokenLimit.`：`MaxTokenLimit` 直接取模型目录里的
   `maxTokens`，也就是**本工具改写的那个窗口**。这条路径的 `token_threshold` 没有一个常量字符串可查，
   静态分析定不下来；实测服务端不下发任何阈值（见下），故最终取决于客户端内部默认。

另外 profile 里 `use_model_reported_token_count: true`，说明阈值比较用的是**模型上报的 token 数**
（不是客户端自己分词），tokenizer 不同的后端会让实际触发点漂移。

本工具**不改**阈值（不改二进制、不改实验下发），只改窗口声明。两条路径下的行为：

| 声明的窗口 | 行为 |
| --- | --- |
| ≥ 约 71k（如 131072） | 50000 落在窗口内，压缩正常触发，安全；只用得上约 38% 的窗口 |
| ≤ 50000（8k / 32k） | 阈值到不了，压缩发生在"预算装不下"的兜底路径（`Checkpointing: no messages fit the executor budget`），偏晚但不会撑爆 |

窗口 ≤ 50000 时会打一条提示日志（只打一次）：

```
[Gemini] model window: <model> declares maxTokens=32000, below the client's checkpoint trigger (50000); compaction will only run when the budget overflows
```

小窗口又想让压缩更早发生的话，把 `context_window` 声明得比真实值更小即可（例如真实 32k 声明 24000），
让预算兜底路径更早触发——仍然不触碰固定阈值。

## 验证：服务端不下发压缩阈值（已实测确认）

结论先说：`v1internal:listExperiments`、`v1internal:loadCodeAssist`、`v1internal:fetchUserInfo`
三个 RPC 的响应里**既没有 `token_threshold`，也没有 `model_profiles`**。服务端唯一参与压缩配置的是 flag：

```
checkpoint-variant          = "claude-1m_840k"   # 只决定选哪条 profile，阈值仍取表里的 50000
use-model-reported-token-count = true
max-tokens-per-step         = 16384
rules-token-budget          = 20000
customization-token-budget  = 20000
Chat__chat_context_window_size = -1              # 聊天侧 auto，不参与 agent 预算
```

因此运行时阈值 = 二进制内置表的值（12 条 profile + `claude-1m_840k` 变体，13/13 全是 `50000`），
**不存在服务端覆盖路径**。

复现方式（只读取证，默认关闭）：

```bash
touch ~/.config/antigravity/dump_rpc
# 重启代理（启动器点「保存并应用」）→ 重启 Antigravity，让客户端重新拉取辅助 RPC
ls ~/.config/antigravity/rpc_dump/
grep -l "token_threshold\|model_profiles" ~/.config/antigravity/rpc_dump/* \
  || echo "服务端从未下发 token_threshold"
```

`rpc_dump/` 下每个 RPC 一个文件（`listExperiments.json`、`loadCodeAssist.json` 等），每次调用覆盖写、
不累积目录；`text/event-stream` 响应不落盘；响应体原样回传，不影响客户端。不要时 `rm ~/.config/antigravity/dump_rpc`。

触发客户端重新拉实验（任选其一，都会让 LS 重启并从服务端重取）：

```bash
# 1) 等到没有生成任务时，强制重启内置服务（宿主 2s 后自动拉起，pid 会变）
pkill -f 'Antigravity_Unlocked.app/Contents/Resources/bin/language_server'

# 2) 或者直接退出并重开 Antigravity
osascript -e 'quit app "Antigravity"' && open -a /Users/kevinliangx/Applications/Antigravity_Unlocked.app && sleep 8
```

## 验证

1. 代理日志：`[Gemini] model window: <model> -> maxTokens=<n> maxOutputTokens=<n>`。
2. 客户端 `language_server.log`：不再出现 `[ModelConfig] ... applied ... family defaults` 之类的
   兜底提示；出现 `## Prior Session Summary` + `## Step History (append-only)` 说明 checkpoint 真的跑了。
3. UI 的上下文用量条（`context_window_usage`）分母应等于 `context_window`；
   压缩触发点仍按官方 50000（窗口更小时按预算兜底）。实测：声明 128000 时，会话常驻
   80–110k tokens（body 250–380 KB）仍无报错，说明起作用的杠杆是窗口声明本身，
   而不是 50000 那个固定阈值。

## 注意

- `fetchAvailableModels` 有 12h 缓存，但改写发生在**每次返回时**，所以改配置后重启客户端即可生效，
  不必等缓存过期。
- 只对**出现在 `fetchAvailableModels` 目录里**的模型生效：客户端不认识的模型 id 本来也选不到。
- `max_output_tokens` 填得 ≥ `context_window` 时会打一条告警日志（客户端会拒绝或截断）。
- **已用真实长对话验证**：Claude 规则声明 128000 后，同一会话此前会把 prompt 顶到
  262,676 tokens 而被后端拒绝（`maximum context length is 262144`，仅超 532 token），
  声明窗口生效后连续 22 次请求 0 报错、峰值约 112k tokens。说明目录窗口确实被用来夹预算。
  仍无法从代理日志读到精确的 `precompaction_token_count`（未开 `stream_options.include_usage`），
  需要精确数字时用 `CompactionUsageMetadata` 那侧观测。
- 这些只影响**客户端怎么排布上下文**。服务端是否接受仍取决于后端模型自己；
  声明窗口大于真实窗口 = 上游 4xx/截断，小于真实 = 只是更早压缩。
