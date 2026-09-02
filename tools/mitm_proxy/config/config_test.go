package config

import (
	"strings"
	"testing"
)

// openAIBody builds an OpenAI-format request body with a single user message.
func openAIBody(userContent string) []byte {
	return []byte(`{"model":"gpt-oss-120b","messages":[{"role":"user","content":` +
		jsonString(userContent) + `}]}`)
}

func jsonString(s string) string {
	// JSON-escape the input (sufficient for the test strings used here).
	escaped := strings.ReplaceAll(s, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	return `"` + escaped + `"`
}

// routerFixture returns a RoutingConfig whose LLMRouter has one keyword rule
// targeting gemini_builtin and a concrete default of codebuddy/hy3.
func routerFixture() *RoutingConfig {
	return &RoutingConfig{
		LLMRouter: &LLMRouterConfig{
			DefaultProviderID: "codebuddy",
			DefaultModel:      "hy3",
			Rules: []LLMRouterRule{
				{
					Keywords:         []string{"图片"},
					TargetProviderID: GeminiBuiltinProviderID,
					TargetModel:      "gemini-3.6-flash-high",
					Enabled:          true,
				},
			},
		},
	}
}

func TestResolveLLMRouterTargetSkipsGeminiBuiltinForOpenAI(t *testing.T) {
	cfg := routerFixture()
	rule := &RoutingRule{TargetProviderID: LLMRouterSpecialID}

	providerID, model := cfg.ResolveLLMRouterTarget(rule, openAIBody("帮我生成一张图片"), "openai")
	if providerID != "codebuddy" || model != "hy3" {
		t.Fatalf("openai format: got (%s, %s), want default (codebuddy, hy3); gemini_builtin must not be exposed", providerID, model)
	}
}

func TestResolveLLMRouterTargetSkipsGeminiBuiltinForAnthropic(t *testing.T) {
	cfg := routerFixture()
	rule := &RoutingRule{TargetProviderID: LLMRouterSpecialID}

	// Anthropic-format body: system + user message.
	body := []byte(`{"system":"sys","messages":[{"role":"user","content":"帮我生成一张图片"}]}`)
	providerID, model := cfg.ResolveLLMRouterTarget(rule, body, "anthropic")
	if providerID != "codebuddy" || model != "hy3" {
		t.Fatalf("anthropic format: got (%s, %s), want default (codebuddy, hy3)", providerID, model)
	}
}

func TestResolveLLMRouterTargetHonorsGeminiBuiltinForGemini(t *testing.T) {
	cfg := routerFixture()
	rule := &RoutingRule{TargetProviderID: LLMRouterSpecialID}

	// Gemini-format body: contents[].parts[].text.
	body := []byte(`{"contents":[{"role":"user","parts":[{"text":"帮我生成一张图片"}]}]}`)
	providerID, model := cfg.ResolveLLMRouterTarget(rule, body, "gemini")
	if providerID != GeminiBuiltinProviderID || model != "gemini-3.6-flash-high" {
		t.Fatalf("gemini format: got (%s, %s), want (gemini_builtin, gemini-3.6-flash-high)", providerID, model)
	}
}

func TestResolveLLMRouterTargetNoKeywordUsesDefault(t *testing.T) {
	cfg := routerFixture()
	rule := &RoutingRule{TargetProviderID: LLMRouterSpecialID}

	providerID, model := cfg.ResolveLLMRouterTarget(rule, openAIBody("这个文档里面有哪些文件"), "openai")
	if providerID != "codebuddy" || model != "hy3" {
		t.Fatalf("no keyword: got (%s, %s), want default (codebuddy, hy3)", providerID, model)
	}
}

func TestResolveLLMRouterTargetConcreteRuleUnchanged(t *testing.T) {
	cfg := routerFixture()
	rule := &RoutingRule{
		TargetProviderID: "codebuddy",
		TargetModel:      "deepseek-v4-flash",
	}

	providerID, model := cfg.ResolveLLMRouterTarget(rule, openAIBody("any"), "openai")
	if providerID != "codebuddy" || model != "deepseek-v4-flash" {
		t.Fatalf("concrete rule: got (%s, %s), want (codebuddy, deepseek-v4-flash)", providerID, model)
	}
}

func TestMatchKeywords_CJKDelimiters(t *testing.T) {
	keywords := []string{"图片，images，image，截图，链接，方案，调研，评审，定位，检查"}
	if !matchKeywords(keywords, "请帮我评审一下这段代码", "any") {
		t.Errorf("Expected '评审' to match against full-width comma separated keywords")
	}
	if !matchKeywords(keywords, "这里有一个链接", "any") {
		t.Errorf("Expected '链接' to match")
	}
	if matchKeywords(keywords, "无关内容", "any") {
		t.Errorf("Did not expect '无关内容' to match")
	}
}

func TestExtractLatestGeminiUserContent_AgentMultiTurn(t *testing.T) {
	// Simulated multi-turn agent payload where contents[0] is user prompt with <USER_REQUEST>
	// and contents[2] is a tool execution result.
	body := []byte(`{
		"contents": [
			{
				"role": "user",
				"parts": [{"text": "<identity>system...</identity>\n<USER_REQUEST>\n请帮我评审代码\n</USER_REQUEST>"}]
			},
			{
				"role": "model",
				"parts": [{"functionCall": {"name": "view_file"}}]
			},
			{
				"role": "user",
				"parts": [{"text": "function test() { console.log(1); }"}]
			}
		]
	}`)

	extracted := ExtractLatestUserContent(body, "gemini")
	if extracted != "请帮我评审代码" {
		t.Fatalf("Expected extracted prompt '请帮我评审代码', got: %q", extracted)
	}
}
