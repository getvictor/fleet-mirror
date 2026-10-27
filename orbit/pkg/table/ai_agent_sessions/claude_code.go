package ai_agent_sessions

import (
	"encoding/json"
	"io/fs"
	"path/filepath"
	"strings"
	"time"

	"github.com/fleetdm/fleet/v4/orbit/pkg/table/internal/homes"
)

// Claude Code keeps one transcript per session in
// ~/.claude/projects/<project-slug>/<session-id>.jsonl, and each sub-agent it
// spawns in <project-slug>/<session-id>/subagents/[…/]agent-<id>.jsonl.
var claudeCode = &agent{
	name:     agentClaudeCode,
	discover: discoverClaudeCode,
	parse:    parseClaudeCode,
	account:  claudeAccount,
}

func discoverClaudeCode(a *agent, h homes.Home, cutoff time.Time) []*source {
	projects := filepath.Join(h.Dir, ".claude", "projects")
	var srcs []*source
	for _, project := range subdirs(projects) {
		dir := filepath.Join(projects, project)
		for _, path := range filesWithSuffix(dir, ".jsonl") {
			id := strings.TrimSuffix(filepath.Base(path), ".jsonl")
			files := append([]string{path}, claudeSubagentFiles(filepath.Join(dir, id, "subagents"))...)
			if src, ok := newSource(a, h, id, files, cutoff); ok {
				srcs = append(srcs, src)
			}
		}
	}
	return srcs
}

// claudeSubagentFiles lists sub-agent transcripts, which may nest.
// WalkDir doesn't follow links.
func claudeSubagentFiles(dir string) []string {
	var out []string
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil //nolint:nilerr // an unreadable subtree shouldn't stop the rest
		}
		if d.Type().IsRegular() && strings.HasSuffix(d.Name(), ".jsonl") {
			out = append(out, p)
		}
		return nil
	})
	return out
}

type claudeRecord struct {
	Type           string          `json:"type"`
	Timestamp      string          `json:"timestamp"`
	CWD            string          `json:"cwd"`
	Version        string          `json:"version"`
	GitBranch      string          `json:"gitBranch"`
	ToolDenialKind string          `json:"toolDenialKind"`
	Content        json.RawMessage `json:"content"` // system records
	Message        struct {
		ID      string          `json:"id"`
		Model   string          `json:"model"`
		Content json.RawMessage `json:"content"`
		Usage   *claudeUsage    `json:"usage"`
	} `json:"message"`
}

type claudeUsage struct {
	InputTokens              int64 `json:"input_tokens"`
	OutputTokens             int64 `json:"output_tokens"`
	CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
	CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
}

type claudeBlock struct {
	Type      string          `json:"type"`
	Text      json.RawMessage `json:"text"`
	Thinking  json.RawMessage `json:"thinking"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	IsError   bool            `json:"is_error"`
	Content   json.RawMessage `json:"content"`
}

// claudeBody decodes a message body: a plain string, or typed blocks.
func claudeBody(raw json.RawMessage) (text json.RawMessage, blocks []claudeBlock) {
	raw = json.RawMessage(strings.TrimSpace(string(raw)))
	if len(raw) > 0 && raw[0] == '"' {
		return raw, nil
	}
	_ = json.Unmarshal(raw, &blocks)
	return nil, blocks
}

func parseClaudeCode(src *source, r *recorder) {
	s := r.s
	// An API response is written as one record per content block, each
	// repeating the response's usage, so usage is counted once per id.
	usage := map[string]claudeUsage{}
	for i, path := range src.files {
		sub := i > 0
		r.file(path)
		_ = scanJSONL(path, func(line []byte) bool {
			if r.done() {
				return false
			}
			if r.skipNext() {
				var head struct {
					Type string `json:"type"`
				}
				if json.Unmarshal(line, &head) == nil && isClaudeMessage(head.Type) {
					r.next()
				}
				return true
			}
			var rec claudeRecord
			if json.Unmarshal(line, &rec) != nil {
				// Count it as the skip path above would, so a message's index
				// doesn't depend on the page asked for.
				var head struct {
					Type string `json:"type"`
				}
				if json.Unmarshal(line, &head) == nil && isClaudeMessage(head.Type) {
					r.next()
				}
				return true
			}
			r.seen = true
			ts := parseTime(rec.Timestamp)
			s.observe(ts)
			if !sub {
				// The first directory is where the session started; later ones
				// may be wherever the agent cd'd into.
				if s.ProjectPath == "" {
					s.ProjectPath = rec.CWD
				}
				if rec.GitBranch != "" {
					s.GitBranch = rec.GitBranch
				}
				if rec.Version != "" {
					s.AgentVersion = rec.Version
				}
			}

			switch rec.Type {
			case "user":
				r.next()
				r.at(ts, "", rec.CWD)
				claudeUser(r, rec, sub)
			case "assistant":
				model := rec.Message.Model
				if strings.HasPrefix(model, "<") { // "<synthetic>" isn't a model
					model = ""
				}
				if model != "" && !sub {
					s.Model = model
				}
				if id := rec.Message.ID; id == "" {
					s.AssistantMessages++
					if u := rec.Message.Usage; u != nil {
						addClaudeUsage(s, *u)
					}
				} else {
					u, dup := usage[id]
					if !dup {
						s.AssistantMessages++
					}
					if rec.Message.Usage != nil {
						u = *rec.Message.Usage
					}
					usage[id] = u
				}
				r.next()
				r.at(ts, model, rec.CWD)
				claudeAssistant(r, rec)
			case "system":
				r.next()
				r.at(ts, "", rec.CWD)
				r.text(roleSystem, blockText, func() string { return textOf(rec.Content) })
			}
			// Other record types (attachments, queued prompts, titles) aren't
			// part of the conversation.
			return true
		})
	}
	for _, u := range usage {
		addClaudeUsage(s, u)
	}
}

func isClaudeMessage(t string) bool { return t == "user" || t == "assistant" || t == "system" }

func addClaudeUsage(s *Session, u claudeUsage) {
	s.InputTokens += u.InputTokens
	s.OutputTokens += u.OutputTokens
	s.CacheReadTokens += u.CacheReadInputTokens
	s.CacheWriteTokens += u.CacheCreationInputTokens
}

// claudeUser handles a user record. A sub-agent's "user" is the parent agent,
// and a turn of only tool results is the agent loop; neither is a prompt.
func claudeUser(r *recorder, rec claudeRecord, sub bool) {
	text, blocks := claudeBody(rec.Message.Content)
	if text != nil {
		role := roleUser
		if sub {
			role = roleSystem
		} else {
			r.s.UserMessages++
		}
		r.text(role, blockText, func() string { return textOf(text) })
		return
	}

	prompt := false
	for _, b := range blocks {
		if b.Type != "tool_result" {
			prompt = true
		}
	}
	role := roleSystem
	if prompt && !sub {
		r.s.UserMessages++
		role = roleUser
	}
	for _, b := range blocks {
		switch b.Type {
		case "text":
			r.text(role, blockText, func() string { return textOf(b.Text) })
		case "tool_result":
			r.toolResult(b.ToolUseID, func(tool string) string {
				return claudeDecision(rec.ToolDenialKind, b, tool)
			}, func() string { return textOf(b.Content) })
		}
	}
}

func claudeAssistant(r *recorder, rec claudeRecord) {
	text, blocks := claudeBody(rec.Message.Content)
	if text != nil {
		r.text(roleAssistant, blockText, func() string { return textOf(text) })
		return
	}
	for _, b := range blocks {
		switch b.Type {
		case "text":
			r.text(roleAssistant, blockText, func() string { return textOf(b.Text) })
		case "thinking":
			r.text(roleAssistant, blockThinking, func() string { return textOf(b.Thinking) })
		case "tool_use":
			r.toolUse(b.Name, b.ID, func() string { return rawString(b.Input) },
				func() (string, string) { return classify(agentClaudeCode, b.Name, b.Input) })
		}
	}
}

// claudeDecision maps a tool result to the call's outcome. Every refusal and
// failure is marked is_error; newer transcripts say which kind of refusal in
// toolDenialKind, older ones only in the result text.
func claudeDecision(denialKind string, b claudeBlock, tool string) string {
	switch {
	case denialKind == "user-rejected" || denialKind == "permission-rule" || strings.HasPrefix(denialKind, "automode-"):
		return decisionDenied
	case denialKind == "interrupted" || denialKind == "cancelled":
		return decisionError
	case !b.IsError:
		return decisionAllowed
	case denialKind != "" || strings.HasPrefix(tool, "mcp__"):
		// An MCP server chooses its own error text, and could word it like a
		// refusal.
		return decisionError
	}
	first, _, _ := strings.Cut(textOf(b.Content), "\n")
	switch {
	case strings.HasPrefix(first, "The user doesn't want to proceed"),
		strings.HasPrefix(first, "The user doesn't want to take this action"),
		strings.HasPrefix(first, "Permission to use"),
		strings.HasPrefix(first, "Permission for this action"),
		strings.HasPrefix(first, "Hook PreToolUse:") && strings.Contains(first, "denied this tool"),
		strings.HasPrefix(first, "Blocked by hook"),
		strings.HasPrefix(first, "Permission denied by hook"):
		return decisionDenied
	}
	return decisionError
}
