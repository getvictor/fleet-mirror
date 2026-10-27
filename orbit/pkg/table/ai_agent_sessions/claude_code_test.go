package ai_agent_sessions

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

// claudeTranscript is a trimmed-down session: a prompt, an assistant turn
// written as two records of one API message (so usage repeats), a failed
// command, a refused command, a refused-looking MCP result and a final reply.
var claudeTranscript = lines(
	`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-11T13:27:08.788Z","sessionId":"5d1f26db","content":"..."}`,
	`{"type":"user","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:10.000Z","cwd":"/Users/alice/GitHub/fleet","version":"2.1.222","gitBranch":"main","message":{"role":"user","content":"fix the build"}}`,
	`{"type":"assistant","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:20.000Z","cwd":"/Users/alice/GitHub/fleet","version":"2.1.222","gitBranch":"main","message":{"id":"m1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/Users/alice/GitHub/fleet/Makefile"}}],"usage":{"input_tokens":10,"output_tokens":248,"cache_read_input_tokens":30802,"cache_creation_input_tokens":22539}}}`,
	`{"type":"assistant","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:21.000Z","cwd":"/Users/alice/GitHub/fleet","version":"2.1.222","gitBranch":"main","message":{"id":"m1","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"make build\necho done"}}],"usage":{"input_tokens":10,"output_tokens":248,"cache_read_input_tokens":30802,"cache_creation_input_tokens":22539}}}`,
	`{"type":"user","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:25.000Z","cwd":"/Users/alice/GitHub/fleet","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file contents"},{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Exit code 2\nboom"}]}}`,
	`{"type":"assistant","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:40.000Z","cwd":"/Users/alice/GitHub/fleet","message":{"id":"m2","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"rm -rf /tmp/x"}}],"usage":{"input_tokens":5,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0}}}`,
	`{"type":"user","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:45.000Z","toolDenialKind":"user-rejected","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","is_error":true,"content":"The user doesn't want to proceed with this tool use."}]}}`,
	`{"type":"assistant","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:50.000Z","message":{"id":"m3","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"t4","name":"mcp__github__create_issue","input":{"title":"x"}}],"usage":{"input_tokens":1,"output_tokens":1}}}`,
	`{"type":"user","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:55.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t4","is_error":true,"content":[{"type":"text","text":"The user doesn't want to proceed"}]}]}}`,
	`{"type":"assistant","sessionId":"5d1f26db","timestamp":"2026-08-11T13:28:10.000Z","cwd":"/Users/alice/GitHub/fleet","version":"2.1.222","gitBranch":"allenhouchins/fix","message":{"id":"m4","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"Done."}]}}`,
)

var claudeSubagent = lines(
	`{"type":"user","isSidechain":true,"agentId":"a1","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:30.000Z","message":{"role":"user","content":"explore src"}}`,
	`{"type":"assistant","isSidechain":true,"agentId":"a1","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:31.000Z","message":{"id":"s1","role":"assistant","model":"claude-haiku-5","content":[{"type":"tool_use","id":"t9","name":"Grep","input":{"pattern":"TODO","path":"src"}}],"usage":{"input_tokens":2,"output_tokens":3,"cache_read_input_tokens":4,"cache_creation_input_tokens":5}}}`,
	`{"type":"user","isSidechain":true,"agentId":"a1","sessionId":"5d1f26db","timestamp":"2026-08-11T13:27:32.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"found"}]}}`,
)

func writeClaudeFixture(t *testing.T, home string) (main, sub string) {
	t.Helper()
	proj := filepath.Join(home, ".claude", "projects", "-Users-alice-GitHub-fleet")
	main = filepath.Join(proj, "5d1f26db.jsonl")
	sub = filepath.Join(proj, "5d1f26db", "subagents", "agent-a1.jsonl")
	writeFile(t, main, claudeTranscript)
	writeFile(t, sub, claudeSubagent)
	return main, sub
}

func TestClaudeCodeSession(t *testing.T) {
	home := setup(t)
	main, _ := writeClaudeFixture(t, home)

	s := onlySession(t, agentClaudeCode)
	require.Equal(t, map[string]string{
		"agent":          agentClaudeCode,
		"session_id":     "5d1f26db",
		"username":       "alice",
		"project_path":   "/Users/alice/GitHub/fleet",
		"git_branch":     "allenhouchins/fix",
		"git_repository": "",
		"agent_version":  "2.1.222",
		"model":          "claude-opus-5",
		"started_at":     "1786454828", // the queue-operation record
		"ended_at":       "1786454890",
		// Only the typed prompt counts; tool results and the sub-agent's
		// instructions don't.
		"user_messages": "1",
		// One per API message, including the sub-agent's.
		"assistant_messages": "5",
		"tool_calls":         "5",
		// Usage repeated on the split record counts once; the sub-agent's adds.
		"input_tokens":       "18",
		"output_tokens":      "352",
		"cache_read_tokens":  "31806",
		"cache_write_tokens": "22544",
		"transcript_path":    main,
	}, pick(s, "agent", "session_id", "username", "project_path", "git_branch", "git_repository", "agent_version", "model",
		"started_at", "ended_at", "user_messages", "assistant_messages", "tool_calls", "input_tokens", "output_tokens",
		"cache_read_tokens", "cache_write_tokens", "transcript_path"))
	require.Equal(t, "61", s["duration_seconds"])
}

func TestClaudeCodeMessages(t *testing.T) {
	home := setup(t)
	main, sub := writeClaudeFixture(t, home)

	rows := messageRows(t, eq("session_id", "5d1f26db"))
	var got []string
	for _, r := range rows {
		got = append(got, r["message_index"]+"."+r["block_index"]+" "+r["role"]+"/"+r["block_type"]+" "+r["tool_name"])
	}
	require.Equal(t, []string{
		"0.0 user/text ",
		"1.0 assistant/text ",
		"1.1 assistant/tool_use Read",
		"2.0 assistant/tool_use Bash",
		"3.0 system/tool_result ",
		"3.1 system/tool_result ",
		"4.0 assistant/tool_use Bash",
		"5.0 system/tool_result ",
		"6.0 assistant/tool_use mcp__github__create_issue",
		"7.0 system/tool_result ",
		"8.0 assistant/text ",
		// The sub-agent follows, its instructions as system text.
		"9.0 system/text ",
		"10.0 assistant/tool_use Grep",
		"11.0 system/tool_result ",
	}, got)

	require.Equal(t, "fix the build", rows[0]["content"])
	require.Equal(t, "claude-opus-5", rows[1]["model"])
	require.Empty(t, rows[0]["model"])
	require.Equal(t, "Done.", rows[10]["content"])
	require.Empty(t, rows[10]["model"], "synthetic model is dropped")
	require.JSONEq(t, `{"file_path":"/Users/alice/GitHub/fleet/Makefile"}`, rows[2]["content"])
	require.Equal(t, "t1", rows[2]["tool_use_id"])
	require.Equal(t, "t1", rows[4]["tool_use_id"])
	require.Equal(t, "/Users/alice/GitHub/fleet", rows[2]["cwd"])
	require.Equal(t, "1786454840", rows[2]["timestamp"])
	require.Equal(t, main, rows[0]["transcript_path"])
	require.Equal(t, sub, rows[len(rows)-1]["transcript_path"])

	require.Equal(t, []string{
		"Read | read | /Users/alice/GitHub/fleet/Makefile | allowed",
		"Bash | execute | make build | error",
		"Bash | execute | rm -rf /tmp/x | denied",
		// An MCP server's text never counts as a refusal.
		"mcp__github__create_issue | mcp | github: create_issue | error",
		`Grep | search | "TODO" in src | allowed`,
	}, summary(toolRows(t, "5d1f26db")))
}

func TestClaudeCodeDecisionFallbackForOlderTranscripts(t *testing.T) {
	home := setup(t)
	results := []string{
		"The user doesn't want to take this action right now.",
		"Permission to use Bash has been denied.",
		"Hook PreToolUse:Bash denied this tool",
		"PreToolUse:Bash hook error: exit 1",
		"[Request interrupted by user for tool use]",
		"<tool_use_error>File not found</tool_use_error>",
	}
	var ls []string
	for i, r := range results {
		ls = append(ls,
			`{"type":"assistant","timestamp":"2026-08-01T10:00:00.000Z","message":{"id":"m`+string(rune('a'+i))+`","content":[{"type":"tool_use","id":"t`+string(rune('a'+i))+`","name":"Bash","input":{"command":"x"}}]}}`,
			`{"type":"user","timestamp":"2026-08-01T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t`+string(rune('a'+i))+`","is_error":true,"content":"`+r+`"}]}}`,
		)
	}
	ls = append(ls,
		`{"type":"assistant","timestamp":"2026-08-01T10:00:00.000Z","message":{"id":"mz","content":[{"type":"tool_use","id":"tz","name":"Bash","input":{"command":"x"}}]}}`,
		`{"type":"user","timestamp":"2026-08-01T10:00:01.000Z","toolDenialKind":"interrupted","message":{"content":[{"type":"tool_result","tool_use_id":"tz","is_error":true,"content":"Interrupted"}]}}`,
	)
	writeFile(t, filepath.Join(home, ".claude", "projects", "-p", "old.jsonl"), lines(ls...))

	var decisions []string
	for _, r := range toolRows(t, "old") {
		decisions = append(decisions, r["decision"])
	}
	require.Equal(t, []string{"denied", "denied", "denied", "error", "error", "error", "error"}, decisions)
}

func pick(row map[string]string, cols ...string) map[string]string {
	out := map[string]string{}
	for _, c := range cols {
		out[c] = row[c]
	}
	return out
}
