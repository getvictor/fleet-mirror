package ai_agent_sessions

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/fleetdm/fleet/v4/orbit/pkg/table/internal/fsutil"
	"github.com/fleetdm/fleet/v4/orbit/pkg/table/internal/homes"
)

// Gemini CLI records each session under ~/.gemini/tmp/<project>/chats/ as
// session-<time>-<id prefix>.json (one document, up to v0.38) or .jsonl
// (append-only, replayed with last-write-wins and $set/$rewindTo/$patch
// records). Sub-agents get chats/<parent session id>/<id>.jsonl. Older
// sessions may only be in the project's logs.json, which records prompts.
// Under the macOS sandbox the same layout lives in ~/.cache/.gemini.
var geminiCLI = &agent{
	name:     agentGeminiCLI,
	discover: discoverGeminiCLI,
	parse:    parseGeminiCLI,
	account:  geminiAccount,
}

func geminiRoots(h homes.Home) []string {
	return []string{filepath.Join(h.Dir, ".gemini"), filepath.Join(h.Dir, ".cache", ".gemini")}
}

type geminiSource struct {
	project string
	// logs holds logs.json's entries for a session only found there.
	logs []geminiLogEntry
}

// maxGeminiLogSessions bounds how many sessions one logs.json yields, and
// maxGeminiMessages how many messages a chat replay keeps.
const (
	maxGeminiLogSessions = 1000
	maxGeminiMessages    = 100_000
)

type geminiLogEntry struct {
	SessionID string `json:"sessionId"`
	Type      string `json:"type"`
	Message   string `json:"message"`
	Timestamp string `json:"timestamp"`
}

func discoverGeminiCLI(a *agent, h homes.Home, cutoff time.Time) []*source {
	type chat struct {
		path, project string
		deps          []string
		mod           time.Time
	}
	fresh := func(p string) (time.Time, bool) {
		fi, ok := regularFile(p)
		if !ok || (!cutoff.IsZero() && fi.ModTime().Before(cutoff)) {
			return time.Time{}, false
		}
		return fi.ModTime(), true
	}

	projects := geminiProjects(h)
	var projectFiles []string
	for _, root := range geminiRoots(h) {
		projectFiles = append(projectFiles, filepath.Join(root, "projects.json"))
	}
	mains := map[string]chat{}
	subs := map[string][]string{}
	type logFile struct {
		path, project string
		deps          []string
	}
	var logs []logFile
	for _, root := range geminiRoots(h) {
		tmp := filepath.Join(root, "tmp")
		for _, name := range subdirs(tmp) {
			if name == "bin" {
				continue
			}
			dir := filepath.Join(tmp, name)
			project := geminiProjectPath(dir, name, projects)
			deps := append([]string{filepath.Join(dir, ".project_root")}, projectFiles...)
			chats := filepath.Join(dir, "chats")
			for _, p := range filesWithSuffix(chats, ".json", ".jsonl") {
				if !strings.HasPrefix(filepath.Base(p), "session-") {
					continue
				}
				mod, ok := fresh(p)
				if !ok {
					continue
				}
				id := geminiChatID(p)
				// Upgrades and resumes copy a session rather than move it;
				// the newest copy is the most complete.
				if c, dup := mains[id]; id == "" || (dup && !mod.After(c.mod)) {
					continue
				}
				mains[id] = chat{p, project, deps, mod}
			}
			for _, parent := range subdirs(chats) {
				for _, p := range filesWithSuffix(filepath.Join(chats, parent), ".json", ".jsonl") {
					if _, ok := fresh(p); ok {
						subs[parent] = append(subs[parent], p)
					}
				}
			}
			if p := filepath.Join(dir, "logs.json"); func() bool { _, ok := fresh(p); return ok }() {
				logs = append(logs, logFile{p, project, deps})
			}
		}
	}

	ids := make([]string, 0, len(mains))
	for id := range mains {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var srcs []*source
	for _, id := range ids {
		c := mains[id]
		if src, ok := newSource(a, h, id, append([]string{c.path}, subs[id]...), cutoff); ok {
			src.extra = geminiSource{project: c.project}
			src.deps = c.deps
			srcs = append(srcs, src)
		}
	}
	for _, l := range logs {
		// One read per scan, shared by every session in the file.
		var entries []geminiLogEntry
		readJSON(l.path, &entries)
		bySession := map[string][]geminiLogEntry{}
		var order []string
		for _, e := range entries {
			if _, inChats := mains[e.SessionID]; e.SessionID == "" || inChats {
				continue
			}
			if _, ok := bySession[e.SessionID]; !ok {
				if len(order) == maxGeminiLogSessions {
					continue
				}
				order = append(order, e.SessionID)
			}
			bySession[e.SessionID] = append(bySession[e.SessionID], e)
		}
		for _, id := range order {
			if src, ok := newSource(a, h, id, []string{l.path}, cutoff); ok {
				src.extra = geminiSource{project: l.project, logs: bySession[id]}
				src.deps = l.deps
				srcs = append(srcs, src)
			}
		}
	}
	return srcs
}

// geminiChatID reads a chat file's session id.
func geminiChatID(path string) string {
	var meta struct {
		SessionID string `json:"sessionId"`
	}
	if strings.HasSuffix(path, ".jsonl") {
		firstRecord(path, &meta)
	} else {
		readJSON(path, &meta)
	}
	return meta.SessionID
}

// geminiProjectIndex maps project slugs to paths, from projects.json.
type geminiProjectIndex struct {
	bySlug map[string]string
	paths  []string
}

func geminiProjects(h homes.Home) geminiProjectIndex {
	idx := geminiProjectIndex{bySlug: map[string]string{}}
	for _, root := range geminiRoots(h) {
		var pj struct {
			Projects map[string]string `json:"projects"`
		}
		readJSON(filepath.Join(root, "projects.json"), &pj)
		for path, slug := range pj.Projects {
			idx.bySlug[slug] = path
			idx.paths = append(idx.paths, path)
		}
	}
	return idx
}

// geminiProjectPath recovers the project a tmp/<name> directory belongs to:
// from its .project_root file, from projects.json, or, for directories named
// by the hash of the path (before v0.29), by hashing the known paths.
func geminiProjectPath(dir, name string, idx geminiProjectIndex) string {
	if b, err := fsutil.ReadFileBounded(filepath.Join(dir, ".project_root")); err == nil {
		if p := strings.TrimSpace(string(b)); p != "" {
			return p
		}
	}
	if p, ok := idx.bySlug[name]; ok {
		return p
	}
	for _, p := range idx.paths {
		sum := sha256.Sum256([]byte(p))
		if hex.EncodeToString(sum[:]) == name {
			return p
		}
	}
	return ""
}

type geminiToolCall struct {
	ID            string          `json:"id"`
	Name          string          `json:"name"`
	DisplayName   string          `json:"displayName"`
	Args          json.RawMessage `json:"args"`
	Status        string          `json:"status"`
	Result        json.RawMessage `json:"result"`
	ResultDisplay json.RawMessage `json:"resultDisplay"`
}

type geminiMessage struct {
	ID        string          `json:"id"`
	Timestamp string          `json:"timestamp"`
	Type      string          `json:"type"`
	Model     string          `json:"model"`
	Content   json.RawMessage `json:"content"`
	Thoughts  []struct {
		Subject     string `json:"subject"`
		Description string `json:"description"`
	} `json:"thoughts"`
	Tokens *struct {
		Input  int64 `json:"input"`
		Output int64 `json:"output"`
		Cached int64 `json:"cached"`
	} `json:"tokens"`
	ToolCalls []geminiToolCall `json:"toolCalls"`
}

type geminiConversation struct {
	SessionID   string          `json:"sessionId"`
	StartTime   string          `json:"startTime"`
	LastUpdated string          `json:"lastUpdated"`
	Kind        string          `json:"kind"`
	Messages    []geminiMessage `json:"messages"`

	ids map[string]int // message id -> index, built for replays
}

// mergeMeta copies the metadata set in o.
func (c *geminiConversation) mergeMeta(o geminiConversation) {
	c.SessionID = firstNonEmpty(o.SessionID, c.SessionID)
	c.StartTime = firstNonEmpty(o.StartTime, c.StartTime)
	c.LastUpdated = firstNonEmpty(o.LastUpdated, c.LastUpdated)
	c.Kind = firstNonEmpty(o.Kind, c.Kind)
}

func (c *geminiConversation) index(id string) int {
	if c.ids == nil {
		c.reindex()
	}
	if i, ok := c.ids[id]; ok {
		return i
	}
	return -1
}

func (c *geminiConversation) reindex() {
	c.ids = make(map[string]int, len(c.Messages))
	for i, m := range c.Messages {
		c.ids[m.ID] = i
	}
}

// loadGeminiConversation reads a chat file, replaying a .jsonl one.
func loadGeminiConversation(path string) (geminiConversation, bool) {
	var c geminiConversation
	if !strings.HasSuffix(path, ".jsonl") {
		return c, readJSON(path, &c)
	}
	ok := false
	_ = scanJSONL(path, func(line []byte) bool {
		var probe struct {
			ID        *string         `json:"id"`
			Type      string          `json:"type"`
			SessionID string          `json:"sessionId"`
			RewindTo  *string         `json:"$rewindTo"`
			Set       json.RawMessage `json:"$set"`
			Patch     json.RawMessage `json:"$patch"`
		}
		if json.Unmarshal(line, &probe) != nil {
			return true
		}
		ok = true
		switch {
		case probe.RewindTo != nil:
			// Drop that message and everything after it.
			if i := c.index(*probe.RewindTo); i >= 0 {
				c.Messages = c.Messages[:i]
				c.reindex()
			}
		case probe.Set != nil:
			var set struct {
				geminiConversation
				Messages *[]geminiMessage `json:"messages"`
			}
			if json.Unmarshal(probe.Set, &set) == nil {
				c.mergeMeta(set.geminiConversation)
				if set.Messages != nil {
					c.Messages = *set.Messages
					c.reindex()
				}
			}
		case probe.Patch != nil:
			c.patch(probe.Patch)
		case probe.ID != nil && *probe.ID != "" && probe.Type != "":
			var m geminiMessage
			if json.Unmarshal(line, &m) == nil {
				// The same message is re-appended as it updates.
				if i := c.index(m.ID); i >= 0 {
					c.Messages[i] = m
				} else if len(c.Messages) < maxGeminiMessages {
					c.Messages = append(c.Messages, m)
					c.ids[m.ID] = len(c.Messages) - 1
				}
			}
		case probe.SessionID != "":
			var meta geminiConversation
			if json.Unmarshal(line, &meta) == nil {
				c.mergeMeta(meta)
			}
		}
		return true
	})
	return c, ok
}

type geminiMessagePatch struct {
	ID        string          `json:"id"`
	Content   json.RawMessage `json:"content"`
	ToolCalls []struct {
		ID     string          `json:"id"`
		Result json.RawMessage `json:"result"`
	} `json:"toolCalls"`
}

func (c *geminiConversation) patch(raw json.RawMessage) {
	var p struct {
		geminiMessagePatch
		Updates   []geminiMessagePatch `json:"updates"`
		RemoveIDs []string             `json:"removeIds"`
		OrderIDs  []string             `json:"orderIds"`
	}
	if json.Unmarshal(raw, &p) != nil {
		return
	}
	for _, u := range append([]geminiMessagePatch{p.geminiMessagePatch}, p.Updates...) {
		i := c.index(u.ID)
		if u.ID == "" || i < 0 {
			continue
		}
		if u.Content != nil {
			c.Messages[i].Content = u.Content
		}
		for _, tp := range u.ToolCalls {
			for j := range c.Messages[i].ToolCalls {
				if c.Messages[i].ToolCalls[j].ID == tp.ID {
					c.Messages[i].ToolCalls[j].Result = tp.Result
				}
			}
		}
	}
	if len(p.RemoveIDs) > 0 {
		remove := set{}
		for _, id := range p.RemoveIDs {
			remove[id] = struct{}{}
		}
		kept := c.Messages[:0]
		for _, m := range c.Messages {
			if !remove.has(m.ID) {
				kept = append(kept, m)
			}
		}
		c.Messages = kept
		c.reindex()
	}
	if len(p.OrderIDs) > 0 {
		rank := map[string]int{}
		for i, id := range p.OrderIDs {
			rank[id] = i
		}
		sort.SliceStable(c.Messages, func(i, j int) bool {
			ri, iok := rank[c.Messages[i].ID]
			rj, jok := rank[c.Messages[j].ID]
			if iok != jok {
				return iok
			}
			return ri < rj
		})
		c.reindex()
	}
}

func parseGeminiCLI(src *source, r *recorder) {
	s := r.s
	ext, _ := src.extra.(geminiSource)
	s.ProjectPath = ext.project
	if ext.logs != nil {
		parseGeminiLogs(src, ext.logs, r)
		return
	}
	for i, path := range src.files {
		sub := i > 0
		c, ok := loadGeminiConversation(path)
		if !ok {
			continue
		}
		r.file(path)
		r.seen = true
		if !sub {
			s.observe(parseTime(c.StartTime))
			s.observe(parseTime(c.LastUpdated))
		}
		for _, m := range c.Messages {
			if r.done() {
				break
			}
			geminiMessageRows(r, m, sub)
		}
	}
}

func geminiMessageRows(r *recorder, m geminiMessage, sub bool) {
	s := r.s
	ts := parseTime(m.Timestamp)
	s.observe(ts)
	switch m.Type {
	case "user":
		// Since v0.44 tool results are also recorded as user messages; they
		// are already shown with their calls.
		if geminiHasFunctionResponse(m.Content) {
			return
		}
		role := roleSystem
		if !sub {
			s.UserMessages++
			role = roleUser
		}
		r.next()
		r.at(ts, "", "")
		r.text(role, blockText, func() string { return textOf(m.Content) })
	case "gemini":
		s.AssistantMessages++
		if m.Model != "" && !sub {
			s.Model = m.Model
		}
		// cached is part of input.
		if t := m.Tokens; t != nil {
			s.InputTokens += t.Input - t.Cached
			s.CacheReadTokens += t.Cached
			s.OutputTokens += t.Output
		}
		r.next()
		r.at(ts, m.Model, "")
		for _, th := range m.Thoughts {
			r.text(roleAssistant, blockThinking, func() string {
				if th.Subject == "" {
					return th.Description
				}
				return th.Subject + ": " + th.Description
			})
		}
		r.text(roleAssistant, blockText, func() string { return textOf(m.Content) })
		for _, tc := range m.ToolCalls {
			r.toolUse(tc.Name, tc.ID, func() string { return rawString(tc.Args) }, func() (string, string) {
				if server, tool, ok := geminiMCP(tc.DisplayName); ok {
					return classifyMCP(server, tool, parseArgs(tc.Args))
				}
				return classifyNative(agentGeminiCLI, tc.Name, parseArgs(tc.Args))
			})
			switch tc.Status {
			case "success", "error", "cancelled":
				r.toolResult(tc.ID, func(string) string { return geminiDecision(tc) }, func() string { return geminiResult(tc) })
			}
		}
	}
	// info, error and warning messages are the CLI's own notices.
}

func geminiHasFunctionResponse(content json.RawMessage) bool {
	var parts []struct {
		FunctionResponse json.RawMessage `json:"functionResponse"`
	}
	if json.Unmarshal(content, &parts) != nil {
		return false
	}
	for _, p := range parts {
		if p.FunctionResponse != nil {
			return true
		}
	}
	return false
}

var geminiMCPDisplay = regexp.MustCompile(`^(.+) \((.+) MCP Server\)$`)

// geminiMCP reads an MCP call's server and tool from its display name, the
// only place every version records them unambiguously.
func geminiMCP(displayName string) (server, tool string, ok bool) {
	m := geminiMCPDisplay.FindStringSubmatch(displayName)
	if m == nil {
		return "", "", false
	}
	return m[2], m[1], true
}

// geminiResult is a tool call's output: the function responses sent back
// to the model, else what the CLI displayed.
func geminiResult(tc geminiToolCall) string {
	var parts []struct {
		Text             string `json:"text"`
		FunctionResponse *struct {
			Response map[string]any `json:"response"`
		} `json:"functionResponse"`
	}
	var out []string
	if json.Unmarshal(tc.Result, &parts) == nil {
		for _, p := range parts {
			if p.Text != "" {
				out = append(out, p.Text)
			}
			if p.FunctionResponse == nil {
				continue
			}
			for _, k := range []string{"output", "error"} {
				switch v := p.FunctionResponse.Response[k].(type) {
				case nil:
				case string:
					out = append(out, v)
				default:
					if b, err := json.Marshal(v); err == nil {
						out = append(out, string(b))
					}
				}
			}
		}
	}
	if len(out) == 0 {
		return firstNonEmpty(unquote(tc.Result), unquote(tc.ResultDisplay))
	}
	return strings.Join(out, "\n")
}

var geminiExitCode = regexp.MustCompile(`(?m)^Exit Code: (-?\d+)`)

// geminiDecision maps a tool call's final status to its outcome. Failed
// shell commands are recorded as successful; only the output says.
func geminiDecision(tc geminiToolCall) string {
	output, display := geminiResult(tc), unquote(tc.ResultDisplay)
	switch tc.Status {
	case "cancelled":
		for _, t := range []string{output, display} {
			if strings.HasPrefix(strings.TrimSpace(t), "User denied execution.") {
				return decisionDenied
			}
		}
		return decisionError
	case "error":
		return decisionError
	}
	// The shell tool ends its output with the exit code; a command can print
	// the same words earlier, so the last one counts.
	if ms := geminiExitCode.FindAllStringSubmatch(output, -1); len(ms) > 0 && ms[len(ms)-1][1] != "0" {
		return decisionError
	}
	return decisionAllowed
}

func parseGeminiLogs(src *source, entries []geminiLogEntry, r *recorder) {
	r.file(src.files[0])
	for _, e := range entries {
		if e.Type != "user" || r.done() {
			continue
		}
		ts := parseTime(e.Timestamp)
		r.s.observe(ts)
		r.s.UserMessages++
		r.next()
		r.at(ts, "", "")
		r.text(roleUser, blockText, func() string { return e.Message })
	}
}
