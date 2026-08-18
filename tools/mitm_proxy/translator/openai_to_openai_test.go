package translator

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
)

// sseEvents splits a raw SSE body into its `data: ` payload lines.
func sseEvents(t *testing.T, body string) []string {
	t.Helper()
	var events []string
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "data: ") {
			events = append(events, strings.TrimPrefix(line, "data: "))
		}
	}
	return events
}

func TestDoneEmitsTerminalChunkBeforeDone(t *testing.T) {
	translator := &OpenAIToOpenAI{}
	state := NewStreamState()

	var allOutput []byte
	for _, chunk := range []provider.StreamChunk{
		{Delta: "Hello"},
		{Delta: " world"},
		{Done: true},
	} {
		out, err := translator.TranslateStreamChunk(&chunk, "test-model", state)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		allOutput = append(allOutput, out...)
	}

	events := sseEvents(t, string(allOutput))
	if len(events) < 3 {
		t.Fatalf("expected >=3 events (2 content + terminal + [DONE]), got %d: %q", len(events), allOutput)
	}
	if events[len(events)-1] != "[DONE]" {
		t.Fatalf("stream must end with [DONE], got last event %q", events[len(events)-1])
	}

	// The event immediately before [DONE] is the terminal chunk.
	var terminal struct {
		Choices []struct {
			Index        int             `json:"index"`
			Delta        json.RawMessage `json:"delta"`
			FinishReason string          `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(events[len(events)-2]), &terminal); err != nil {
		t.Fatalf("terminal event is not valid JSON: %v (event: %s)", err, events[len(events)-2])
	}
	if len(terminal.Choices) != 1 {
		t.Fatalf("terminal chunk must have exactly one choice, got %d", len(terminal.Choices))
	}
	choice := terminal.Choices[0]
	if choice.FinishReason != "stop" {
		t.Errorf("terminal finish_reason = %q, want \"stop\" (default when upstream sends none)", choice.FinishReason)
	}
	if choice.Index != 0 {
		t.Errorf("terminal choice index = %d, want 0", choice.Index)
	}
	if string(choice.Delta) != "{}" {
		t.Errorf("terminal delta = %s, want empty object {}", choice.Delta)
	}
}

func TestDoneEchoesUpstreamFinishReason(t *testing.T) {
	translator := &OpenAIToOpenAI{}
	state := NewStreamState()

	// Tool-call turn: delta chunks carry tool_calls, terminal chunk echoes "tool_calls".
	toolCall := provider.ToolCall{
		Id:   "call_123",
		Type: "function",
		Function: provider.ToolFunction{
			Name:      "read",
			Arguments: "{\"file_path\":\"a.ts\"}",
		},
	}
	var allOutput []byte
	for _, chunk := range []provider.StreamChunk{
		{Delta: "", ToolCalls: []provider.ToolCall{{Id: "call_123", Type: "function", Function: provider.ToolFunction{Name: "read"}}}},
		{ToolCalls: []provider.ToolCall{toolCall}},
		{Done: true, FinishReason: "tool_calls"},
	} {
		out, err := translator.TranslateStreamChunk(&chunk, "test-model", state)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		allOutput = append(allOutput, out...)
	}

	events := sseEvents(t, string(allOutput))
	if events[len(events)-1] != "[DONE]" {
		t.Fatalf("stream must end with [DONE], got last event %q", events[len(events)-1])
	}
	var terminal struct {
		Choices []struct {
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(events[len(events)-2]), &terminal); err != nil {
		t.Fatalf("terminal event is not valid JSON: %v", err)
	}
	if got := terminal.Choices[0].FinishReason; got != "tool_calls" {
		t.Errorf("terminal finish_reason = %q, want %q echoed from upstream", got, "tool_calls")
	}

	// Tool-call deltas must still be forwarded in content chunks (regression guard).
	foundToolCall := false
	for _, event := range events[:len(events)-2] {
		if strings.Contains(event, "call_123") && strings.Contains(event, "\"tool_calls\"") {
			foundToolCall = true
			break
		}
	}
	if !foundToolCall {
		t.Errorf("tool_calls delta not forwarded in content chunks: %q", allOutput)
	}
}

// TestArgumentOnlyDeltasOmitEmptyIdName is a regression guard for the
// DSH integration bug: CodeBuddy (and other OpenAI-compatible upstreams)
// stream tool_calls as fragments — the FIRST chunk carries id+type+name,
// subsequent chunks carry ONLY an arguments fragment. The gateway must
// forward those fragments with id/type/name OMITTED (omitempty), never as
// explicit empty strings, because a downstream consumer that checks
// `field !== undefined` (DSH llm-deepseek translate.ts) treats "" as a real
// value and overwrites the id/name already set by the first chunk — yielding
// `unknown tool ""` and duplicate empty tool_call_ids that the DeepSeek API
// rejects with "Duplicate value for 'tool_call_id'".
func TestArgumentOnlyDeltasOmitEmptyIdName(t *testing.T) {
	translator := &OpenAIToOpenAI{}
	state := NewStreamState()

	var allOutput []byte
	for _, chunk := range []provider.StreamChunk{
		{ // first fragment: id + type + name (arguments empty)
			ToolCalls: []provider.ToolCall{{
				Id:   "call_abc123",
				Type: "function",
				Function: provider.ToolFunction{
					Name: "get_weather",
				},
			}},
		},
		{ // argument-only fragment: id/type/name absent upstream
			ToolCalls: []provider.ToolCall{{
				Function: provider.ToolFunction{Arguments: `{"city": "北京"}`},
			}},
		},
		{Done: true, FinishReason: "tool_calls"},
	} {
		out, err := translator.TranslateStreamChunk(&chunk, "test-model", state)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		allOutput = append(allOutput, out...)
	}

	events := sseEvents(t, string(allOutput))
	var gotID, gotName string
	var sawArgumentOnly bool
	for _, event := range events {
		if event == "[DONE]" {
			continue
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					ToolCalls []provider.ToolCall `json:"tool_calls"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(event), &chunk); err != nil {
			continue
		}
		if len(chunk.Choices) == 0 {
			continue
		}
		for _, tc := range chunk.Choices[0].Delta.ToolCalls {
			if tc.Id != "" {
				gotID = tc.Id
			}
			if tc.Function.Name != "" {
				gotName = tc.Function.Name
			}
			if tc.Function.Arguments != "" {
				sawArgumentOnly = true
				// The argument-only fragment must NOT carry empty-string
				// id/type/name on the wire (omitempty must drop them).
				if tc.Id != "" || tc.Type != "" || tc.Function.Name != "" {
					t.Errorf("argument-only delta re-serialized with empty-string fields: id=%q type=%q name=%q (must be omitted)",
						tc.Id, tc.Type, tc.Function.Name)
				}
			}
		}
	}

	if !sawArgumentOnly {
		t.Fatalf("argument fragment not forwarded: %q", allOutput)
	}
	if gotID != "call_abc123" {
		t.Errorf("id = %q, want %q (must survive from the first fragment)", gotID, "call_abc123")
	}
	if gotName != "get_weather" {
		t.Errorf("name = %q, want %q (must survive from the first fragment)", gotName, "get_weather")
	}
}

// TestParallelToolCallIndexSurvives is a regression guard for the multi-tool
// DSH failure: OpenAI streaming protocol interleaves PARALLEL tool calls in
// the same delta stream, distinguishing them by `index` (0, 1, ...). The
// gateway must forward that index on every fragment — including argument-only
// fragments — because DSH's translate.ts groups deltas by `call.index`. If the
// index is dropped (all fragments arrive as index 0 / undefined), every
// parallel tool call merges into ONE assembled block: arguments concatenate
// across tools (invalid JSON -> missing required property), and the last
// id/name overwrites the others (unknown tool "" / wrong id).
func TestParallelToolCallIndexSurvives(t *testing.T) {
	translator := &OpenAIToOpenAI{}
	state := NewStreamState()

	// Upstream (CodeBuddy) interleaves two tool calls: index 0 = get_weather,
	// index 1 = get_time. First fragment of each carries id+name; later
	// fragments are argument-only but MUST still carry their index.
	upstream := []provider.StreamChunk{
		{ToolCalls: []provider.ToolCall{
			{Index: 0, Id: "call_0", Type: "function", Function: provider.ToolFunction{Name: "get_weather"}},
		}},
		{ToolCalls: []provider.ToolCall{
			{Index: 1, Id: "call_1", Type: "function", Function: provider.ToolFunction{Name: "get_time"}},
		}},
		{ToolCalls: []provider.ToolCall{
			{Index: 0, Function: provider.ToolFunction{Arguments: `{"city": "北京"}`}},
		}},
		{ToolCalls: []provider.ToolCall{
			{Index: 1, Function: provider.ToolFunction{Arguments: `{"timezone": "Asia/Shanghai"}`}},
		}},
		{Done: true, FinishReason: "tool_calls"},
	}

	var allOutput []byte
	for _, chunk := range upstream {
		out, err := translator.TranslateStreamChunk(&chunk, "test-model", state)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		allOutput = append(allOutput, out...)
	}

	// Reconstruct what DSH's translate.ts sees: group tool-call deltas by
	// index, exactly like packages/llm/llm-deepseek/src/translate.ts does
	// (`toolBlocks.get(call.index)`).
	type dshDelta struct {
		ToolCalls []struct {
			Index    *int   `json:"index"`
			Id       string `json:"id"`
			Function struct {
				Name      string `json:"name"`
				Arguments string `json:"arguments"`
			} `json:"function"`
		} `json:"tool_calls"`
	}
	blocks := map[int]*struct{ id, name, args string }{}
	for _, event := range sseEvents(t, string(allOutput)) {
		if event == "[DONE]" {
			continue
		}
		var wire struct {
			Choices []struct {
				Delta dshDelta `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(event), &wire); err != nil {
			continue
		}
		if len(wire.Choices) == 0 {
			continue
		}
		for _, call := range wire.Choices[0].Delta.ToolCalls {
			if call.Index == nil {
				t.Fatalf("tool_calls fragment lost its index: %s", event)
			}
			b, ok := blocks[*call.Index]
			if !ok {
				b = &struct{ id, name, args string }{}
				blocks[*call.Index] = b
			}
			if call.Id != "" {
				b.id = call.Id
			}
			if call.Function.Name != "" {
				b.name = call.Function.Name
			}
			b.args += call.Function.Arguments
		}
	}

	if len(blocks) != 2 {
		t.Fatalf("expected 2 distinct tool-call blocks (index 0 and 1), got %d: %q", len(blocks), allOutput)
	}
	b0 := blocks[0]
	if b0.id != "call_0" || b0.name != "get_weather" || b0.args != `{"city": "北京"}` {
		t.Errorf("index 0 block wrong: id=%q name=%q args=%q", b0.id, b0.name, b0.args)
	}
	b1 := blocks[1]
	if b1.id != "call_1" || b1.name != "get_time" || b1.args != `{"timezone": "Asia/Shanghai"}` {
		t.Errorf("index 1 block wrong: id=%q name=%q args=%q", b1.id, b1.name, b1.args)
	}
}
