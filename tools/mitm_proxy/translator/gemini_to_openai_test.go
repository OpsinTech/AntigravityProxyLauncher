package translator

import (
	"strings"
	"testing"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
)

func TestTextOnlyNoDuplication(t *testing.T) {
	translator := NewGeminiToOpenAI()
	state := NewStreamState()

	// Simulate text streaming: 4 delta chunks then Done
	chunks := []provider.StreamChunk{
		{Delta: "Hello "},
		{Delta: "World"},
		{Delta: "! "},
		{Delta: "How are you?"},
		{Done: true, Usage: &provider.Usage{PromptTokens: 10, CompletionTokens: 4}},
	}

	var allOutput []string
	for _, chunk := range chunks {
		out, err := translator.TranslateStreamChunk(&chunk, "test-model", state)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if out != nil {
			allOutput = append(allOutput, string(out))
		}
	}

	// Verify: text deltas should only appear once each
	textCount := 0
	for _, out := range allOutput {
		if strings.Contains(out, "Hello") {
			textCount++
		}
	}
	if textCount > 1 {
		t.Errorf("text 'Hello' appeared %d times, expected 1 (duplication bug)", textCount)
	}

	// Done event should NOT contain accumulated text
	for _, out := range allOutput {
		if strings.Contains(out, `"finishReason"`) {
			if strings.Contains(out, "Hello") && strings.Contains(out, "World") {
				t.Errorf("Done event contains accumulated text: %s", out)
			}
		}
	}

	t.Logf("Output chunks: %d", len(allOutput))
	for i, out := range allOutput {
		t.Logf("  [%d] %s", i, out[:min(120, len(out))])
	}
}

func TestToolCallOnlyAtDone(t *testing.T) {
	translator := NewGeminiToOpenAI()
	state := NewStreamState()

	// Simulate tool call streaming: args accumulate, then Done
	chunks := []provider.StreamChunk{
		{ToolCalls: []provider.ToolCall{
			{Id: "call_1", Type: "function", Function: provider.ToolFunction{Name: "view_file", Arguments: ""}},
		}},
		{ToolCalls: []provider.ToolCall{
			{Function: provider.ToolFunction{Arguments: `{"AbsolutePath":"`}},
		}},
		{ToolCalls: []provider.ToolCall{
			{Function: provider.ToolFunction{Arguments: `/tmp/test"}`}},
		}},
		{Done: true, Usage: &provider.Usage{PromptTokens: 5, CompletionTokens: 3}},
	}

	var allOutput []string
	for _, chunk := range chunks {
		out, err := translator.TranslateStreamChunk(&chunk, "test-model", state)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if out != nil {
			allOutput = append(allOutput, string(out))
		}
	}

	// Tool call chunks should NOT emit intermediate events (suppressed)
	// Only the Done event should contain the functionCall
	if len(allOutput) != 1 {
		t.Errorf("expected 1 output (Done), got %d", len(allOutput))
	}

	lastOut := allOutput[len(allOutput)-1]
	if !strings.Contains(lastOut, "functionCall") {
		t.Error("Done event missing functionCall")
	}
	if !strings.Contains(lastOut, "view_file") {
		t.Error("Done event missing functionCall name")
	}
	if !strings.Contains(lastOut, "AbsolutePath") || !strings.Contains(lastOut, "/tmp/test") {
		t.Errorf("Done event missing complete args: %s", lastOut)
	}
	if strings.Contains(lastOut, "Hello") {
		t.Error("Done event should not contain text")
	}

	t.Logf("Final output: %s", lastOut[:min(300, len(lastOut))])
}

func TestTextAndToolCall(t *testing.T) {
	translator := NewGeminiToOpenAI()
	state := NewStreamState()

	// Text first, then tool call
	chunks := []provider.StreamChunk{
		{Delta: "Let me check that file."},
		{ToolCalls: []provider.ToolCall{
			{Id: "call_1", Type: "function", Function: provider.ToolFunction{Name: "view_file", Arguments: `{"path":"/tmp/x"}`}},
		}},
		{Done: true, Usage: &provider.Usage{PromptTokens: 5, CompletionTokens: 5}},
	}

	var allOutput []string
	for _, chunk := range chunks {
		out, err := translator.TranslateStreamChunk(&chunk, "test-model", state)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if out != nil {
			allOutput = append(allOutput, string(out))
		}
	}

	// Text delta should appear in output (not duplicated)
	textOutputs := 0
	for _, out := range allOutput {
		if strings.Contains(out, "Let me check") && !strings.Contains(out, "finishReason") {
			textOutputs++
		}
	}
	if textOutputs != 1 {
		t.Errorf("text delta appeared %d times, expected 1", textOutputs)
	}

	// Done event should have functionCall but NOT the text
	lastOut := allOutput[len(allOutput)-1]
	if strings.Contains(lastOut, "Let me check") {
		t.Error("Done event should not contain text")
	}
	if !strings.Contains(lastOut, "functionCall") {
		t.Error("Done event missing functionCall")
	}

	t.Logf("Outputs: %d", len(allOutput))
	for i, out := range allOutput {
		t.Logf("  [%d] %s", i, out[:min(150, len(out))])
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// Gemini's proto3 JSON encoding sends numeric JSON-Schema keywords as strings
// ("minLength": "1"). Strict OpenAI-compatible backends reject that outright, so
// the translator has to emit real integers.
func TestNormalizeToolSchema_CoercesStringNumericKeywords(t *testing.T) {
	schema := map[string]interface{}{
		"type": "OBJECT",
		"properties": map[string]interface{}{
			"Recipient": map[string]interface{}{
				"type":      "STRING",
				"minLength": "1",
				"maxLength": "64",
			},
			"tags": map[string]interface{}{
				"type":     "ARRAY",
				"minItems": "0",
				"maxItems": "10",
				"items": map[string]interface{}{
					"type":      "STRING",
					"minLength": "2",
				},
			},
			"score": map[string]interface{}{
				"type":    "NUMBER",
				"minimum": "0",
				"maximum": "100",
			},
		},
	}

	got := normalizeToolSchema(schema)

	recipient := got["properties"].(map[string]interface{})["Recipient"].(map[string]interface{})
	if recipient["minLength"] != 1 {
		t.Errorf("Recipient.minLength = %#v, want int 1", recipient["minLength"])
	}
	if recipient["maxLength"] != 64 {
		t.Errorf("Recipient.maxLength = %#v, want int 64", recipient["maxLength"])
	}
	if recipient["type"] != "string" {
		t.Errorf("Recipient.type = %#v, want \"string\"", recipient["type"])
	}

	tags := got["properties"].(map[string]interface{})["tags"].(map[string]interface{})
	if tags["minItems"] != 0 {
		t.Errorf("tags.minItems = %#v, want int 0", tags["minItems"])
	}
	item := tags["items"].(map[string]interface{})
	if item["minLength"] != 2 {
		t.Errorf("tags.items.minLength = %#v, want int 2 (nested schemas must be coerced too)", item["minLength"])
	}

	score := got["properties"].(map[string]interface{})["score"].(map[string]interface{})
	if score["minimum"] != float64(0) {
		t.Errorf("score.minimum = %#v, want float64 0", score["minimum"])
	}
	if score["maximum"] != float64(100) {
		t.Errorf("score.maximum = %#v, want float64 100", score["maximum"])
	}
}

// Already-numeric or non-numeric values must survive untouched.
func TestNormalizeToolSchema_LeavesOtherValuesAlone(t *testing.T) {
	schema := map[string]interface{}{
		"type":      "OBJECT",
		"minLength": 3,
		"properties": map[string]interface{}{
			"name": map[string]interface{}{
				"type":    "STRING",
				"pattern": "1",
			},
		},
	}

	got := normalizeToolSchema(schema)
	if got["minLength"] != 3 {
		t.Errorf("numeric minLength changed: %#v", got["minLength"])
	}
	name := got["properties"].(map[string]interface{})["name"].(map[string]interface{})
	if name["pattern"] != "1" {
		t.Errorf("pattern string changed: %#v", name["pattern"])
	}
}
